/* ==========================================================================
   S Y N T H   -   realtime chip and metal synth, shared by both builds
   --------------------------------------------------------------------------
   Lifted verbatim out of crtkafa.c so the D3D11 engine and the original
   software build can play the same music from the same source. It owns the
   song clock: audioPlayedSamples() is the number of samples the sound card
   has actually played, and everything on screen is timed from that rather
   than from a wall clock, so the picture cannot drift away from the music.

   Needs, from the translation unit that includes it:
     - windows.h and mmsystem.h
     - song_data.h  (the baked note tables)
     - memset / memcpy
   ========================================================================== */
#ifndef CRTK_SYNTH_H
#define CRTK_SYNTH_H

/* The software build defines these before it includes us; the D3D11 build
   does not, so carry our own. */
#ifndef TAU
#define TAU 6.28318530718f
#endif
#ifndef PI
#define PI  3.14159265359f
#endif

/* ==========================================================================
   M U S I C   -   realtime 4 channel chip synth
   ========================================================================== */
#define SRATE     44100
#define NBUF      4
#define BUFFRAMES 2048
#define SPR       5000            /* samples per row  -> ~132 BPM 16ths */
#define TPR       6               /* ticks per row                      */
/* SPR/TPR is 833.33 and truncating it threw away two samples every row: the
   song ran 70 ms fast over its length, and every row was very slightly short,
   which is what a tight part sounds like when it feels loose. Worse now that
   the picture takes its clock from the sample counter - the synth advanced a
   row every 4998 samples while the visuals counted 5000, so the two drifted
   apart by 0.6 of a row by the end.

   Deriving each tick's length from the row boundary makes the six of them sum
   to SPR exactly: 833, 833, 834, 833, 833, 834. */
#define SPT        (SPR / TPR)          /* the nominal length, for buffer sizing */
#define TICKLEN(t) ((((t) + 1) * SPR) / TPR - ((t) * SPR) / TPR)
#define ROWS      32
#define ORDERS    48

static HWAVEOUT g_wo;
static WAVEHDR  g_whdr[NBUF];
static short    g_wbuf[NBUF][BUFFRAMES * 2];
static int      g_audioOk = 0;
static __int64  g_genSamples = 0;

/* note numbers: octave*12 + pitchclass, C-0 == 0 */
#define nC2 24
#define nD2 26
#define nE2 28
#define nF2 29
#define nG2 31
#define nA2 33
#define nB2 35
#define nC3 36
#define nD3 38
#define nE3 40
#define nF3 41
#define nG3 43
#define nA3 45
#define nA4 57
#define nB4 59
#define nC5 60
#define nD5 62
#define nE5 64
#define nF5 65
#define nG5 67
#define nGs5 68
#define nA5 69
#define nB5 71
#define nC6 72
#define nD6 74
#define nE6 76
#define nF4 53
#define nG4 55
#define RST (-1)

static const float g_baseFreq[12] = {
    16.35160f, 17.32391f, 18.35405f, 19.44544f, 20.60172f, 21.82676f,
    23.12465f, 24.49971f, 25.95654f, 27.50000f, 29.13524f, 30.86771f
};
static float noteFreq(int n)
{
    int oct = n / 12, pc = n % 12;
    float f = g_baseFreq[pc];
    while (oct-- > 0) f *= 2.0f;
    return f;
}

/* ---- song ---------------------------------------------------------------
   The arrangement lives in song_data.h, fully resolved by tools/export_song.py.
   Nothing here decides anything musical - it only reads notes and plays them.
   -------------------------------------------------------------------------- */
#undef ORDERS
#define ORDERS SNG_ORDERS

/* saturates properly at +-1, unlike a bare Pade tanh */
/* x^(-2/3), for the compressor's 3:1 gain law. There is no C runtime here,
   so this is the classic reciprocal-cube-root bit seed plus two Newton
   steps, squared. Worst case 0.38 percent (0.03 dB) over the range the
   compressor actually uses. */
static float invCbrt2(float x)
{
    union { float f; unsigned int i; } u;
    float c;
    u.f = x;
    u.i = 0x548c2b4bu - u.i / 3u;
    c = u.f;
    c = c * (1.3333333f - 0.33333333f * x * c * c * c);
    c = c * (1.3333333f - 0.33333333f * x * c * c * c);
    return c * c;
}

static float softClip(float x)
{
    if (x < -3.0f) return -1.0f;
    if (x >  3.0f) return  1.0f;
    return x * (27.0f + x * x) / (27.0f + 9.0f * x * x);
}

typedef struct {
    float phase, inc, amp, decay, sustain, duty, vib, lp;
    float env;          /* the VCA, 0..1, separate from the decay envelope */
    float atk, rel;     /* per sample, so 1/(seconds * SRATE)              */
    int   gate;         /* 1 while the key is down                        */
    int   active;
} Voice;

static Voice g_vLead, g_vArp, g_vBass;

/* two takes of a power chord, panned hard apart */
static struct {
    float p1, p2, p3, p4, q1, q2;
    float inc, amp, decay, lp, hp, lp2, hp2;
    int   on;
} g_gtr;

/* the solo, and its diatonic third */
static struct { float p1, p2, inc, amp, decay, lp, vib, level; int on; } g_sol, g_hsol;

/* church organ: drawbars, three notes, each partial with a detuned twin */
#define ORG_BARS 6
static const float g_orgMul[ORG_BARS] = { 0.5f, 1.0f, 1.5f, 2.0f, 3.0f, 4.0f };
static const float g_orgAmp[ORG_BARS] = { 0.62f, 1.00f, 0.40f, 0.58f, 0.24f, 0.30f };
/* Two banks, crossfaded. Resetting all 36 oscillator phases to zero at full
   level - which is what this did - put every partial in phase at once: the
   accumulator peaked at 3 x 3.14 against a steady-state RMS of 1.23, a
   +17.7 dB transient on every single chord change. Letting the phases
   free-run instead is not the answer either, because the detuned twins are
   only 0.22% apart and drift into cancellation over a held chord.

   So: on a chord change the new bank is seeded from the OUTGOING bank's
   phases, which makes the waveform continuous across the switch, and the two
   are crossfaded. The twins still start together relative to each other, so
   the cancellation cannot accumulate. */
static struct {
    float ph[2][3][ORG_BARS][2], inc[2][3][ORG_BARS][2];
    float amp, tgt, xf;          /* xf runs 0 -> 1, old bank -> new bank */
    int   note[3], mode, bars, bank;
} g_org;

/* 45 ms. One and a half cycles of the lowest partial in play (16 foot at
   A2 = 55 Hz, an 18 ms period): shorter than one cycle and the crossfade is
   itself a click, longer than about 80 ms and the chord change smears into
   the next beat, which at 132 BPM is only 455 ms away. */
#define ORG_XF_RATE (1.0f / (0.045f * (float)SRATE))

static float g_kickAmp, g_kickPhase, g_kickFreq, g_kickClick;
static float g_kickLast, g_kickTail, g_kickAtk;
static float g_snrAmp, g_snrPhase, g_snrHp;
static float g_hatAmp, g_hatHp;
/* A closed hat must not replace the crash's still-audible decay. */
static float g_crashAmp, g_crashHp;
static unsigned int g_noise = 0x2545f491u;

#define ECHOLEN (SPR * 2)          /* exactly two rows: the echo lands on the grid */
static float g_echoL[ECHOLEN], g_echoR[ECHOLEN];
static int   g_echoPos = 0;

/* comb bank reverb */
/* A hall, built the Schroeder way: a pre-delay, four damped combs, then two
   allpasses to smear the combs' resonances into something continuous.

   What was here before was four BARE combs - no damping, no diffusion, no
   pre-delay - which measured an RT60 of 0.82 to 1.69 s that was identical at
   80 Hz and at 8 kHz, with mode spacings of 35.7, 24.4, 16.6 and 13.0 Hz.
   That is not a room. That is four tuned pipes, and those four resonances
   were audible as a hollow ring under everything sustained. */
#define RVN 4
static const int   g_rvLen[2][RVN] = { {1237,1811,2657,3391}, {1289,1867,2713,3457} };
static const float g_rvFb[RVN]     = { 0.79f, 0.77f, 0.75f, 0.73f };
static float g_rvBuf[2][RVN][3457];
static int   g_rvPos[2][RVN];

/* One lowpass inside each comb's feedback path. This single coefficient is
   the whole difference between a room and a pipe: the top of the tail has to
   die faster than the bottom, because air and stone absorb high frequencies.
   0.26 is a ~2.0 kHz one-pole - dark stone, which is what a cathedral is. */
#define RV_DAMP 0.26f
static float g_rvDamp[2][RVN];

/* Schroeder allpasses. Flat magnitude, scrambled phase: they turn four
   discrete resonances into a continuous tail without colouring it. Prime
   lengths, and different on each side, which is what makes the tail stereo
   without anything being panned. */
#define APN 2
static const int g_apLen[2][APN] = { {225, 341}, {241, 359} };
static float g_apBuf[2][APN][359];
static int   g_apPos[2][APN];
#define AP_G 0.5f

/* 34 ms between the dry signal and the reverb input. Without it the room
   starts on top of the transient and every hit sounds distant; with it the
   attack is dry and defined and the hall arrives behind it. Of everything in
   this block, this is the number that does the most. */
#define RV_PREDELAY 1500
static float g_rvPre[2][RV_PREDELAY];
static int   g_rvPrePos;

static float g_vol = 1.0f;
static float g_fadeIn = 0.0f;
static float g_duck = 1.0f;
static float g_compEnv = 0.0f, g_drmEnv = 0.0f;
static float g_riserLp = 0.0f;
static int   g_rsOrder = 0, g_rsRow = 0, g_rsTick = 0;  /* pre-advance clock */
static float g_tapeL = 0.0f, g_tapeR = 0.0f;
static float g_masterDcL = 0.0f, g_masterDcR = 0.0f;

static int g_playOrder = 0, g_playRow = 0, g_playTick = 0;
static int g_sampToTick = 0;
static int g_leadRest = 0, g_bassRest = 0;   /* rows since this lane last played */
static float g_secGain = 1.0f;               /* the section intensity budget */

/* --------------------------------------------------------------------------
   T H E   S Y N C   R I N G
   --------------------------------------------------------------------------
   What the music is doing right now, so the picture can answer it.

   We synthesise the music ourselves, so there is no need for an FFT or an
   envelope follower on the output: the synth already knows exactly when the
   kick fired and what the guitar's envelope is. The only hard part is
   LATENCY. Audio is generated four buffers ahead of playback - 46 to 186 ms,
   up to eleven frames - so reading g_kickAmp straight from the render loop
   would fire the picture visibly early.

   The fix is to write a ring INDEXED BY ABSOLUTE SAMPLE and read it at the
   same sample index the edit clock already uses. waveOutGetPosition is
   already the authority for which row is on screen; asking it once per frame
   for both the row and the sync read makes picture, edit and music agree by
   construction, and the demo never has to know what the driver's latency is.

   Two details make it exact rather than approximate. The writer PEAK-HOLDS
   over each grain instead of point sampling, because a kick's click decays
   with a 5 ms time constant and point sampling every 256 samples would drop
   it entirely on most frames. And the reader drains the whole span since its
   last read, because 60 fps advances 2.87 grains and sampling one would skip
   two of every three.

   audioPump runs on the main thread (CALLBACK_NULL), so the ring is written
   earlier in the same frame than it is read: no thread, no atomics, no tear. */
#define SYNC_GRAIN  256          /* 5.8 ms */
#define SYNC_FRAMES 128          /* 743 ms of history: 4x the worst lead */
#define SYNC_MASK   (SYNC_FRAMES - 1)

typedef struct {                 /* eight channels, all 0..1 */
    float kick, snare, hat;
    float gtr, solo, org;
    float bass, level;
} SyncFrame;

static SyncFrame g_sync[SYNC_FRAMES];
static SyncFrame g_syncAcc;
static int       g_syncFill = 0;
static __int64   g_syncW = 0;    /* grains generated */
static __int64   g_syncR = 0;    /* next grain to consume */

/* Offline probe: the loudest the lead and bass VCAs reach inside each pattern.
   A lane with no notes in a pattern should read zero here; before the gate
   existed it read whatever the last note had decayed to, for seconds. */
static float g_probeLead[SNG_ORDERS], g_probeBass[SNG_ORDERS];
static float g_probeVoice[6][SNG_ORDERS];   /* pad arp fm gsnr pump chorus */

static float noiseSample(void)
{
    g_noise ^= g_noise << 13; g_noise ^= g_noise >> 17; g_noise ^= g_noise << 5;
    return (float)(int)(g_noise >> 9) * (1.0f / 4194304.0f) - 1.0f;
}

/* A note now has an end. Before this there was no note-off at all: `active`
   was set once and never cleared, and the last note of a phrase rang on
   through every pattern that had no note on its lane - several seconds of
   drone under music that had moved on. */
static void trigVoice(Voice *v, int note, float decay, float sustain, float duty)
{
    v->inc = noteFreq(note) / (float)SRATE;
    v->amp = 1.0f; v->decay = decay; v->sustain = sustain;
    v->duty = duty; v->vib = 0.0f; v->active = 1;
    v->gate = 1;
    if (v->env < 0.0f) v->env = 0.0f;
}

/* The release is LINEAR on purpose. At 70 ms that is a clean stop with no
   click, where an exponential release of the same audible length takes about
   three times as long to actually reach zero - which is the drone coming
   back in through the door it was thrown out of. */
static void voiceEnv(Voice *v)
{
    if (v->gate) {
        v->env += v->atk;
        if (v->env > 1.0f) v->env = 1.0f;
    } else {
        v->env -= v->rel;
        if (v->env <= 0.0f) { v->env = 0.0f; v->active = 0; }
    }
}

static void gtrTrig(int note, int hold)
{
    float f = noteFreq(note) / (float)SRATE;
    g_gtr.inc = f;
    g_gtr.amp = 1.0f;
    g_gtr.decay = hold ? 0.999975f : 0.99984f;
    g_gtr.on = 1;
}

static void solTrig(int which, int note)
{
    float f = noteFreq(note) / (float)SRATE;
    if (which) { g_hsol.inc = f; g_hsol.amp = 1.0f; g_hsol.decay = 0.99985f; g_hsol.on = 1; }
    else       { g_sol.inc  = f; g_sol.amp  = 1.0f; g_sol.decay  = 0.99985f; g_sol.on  = 1; }
}

static void kickTrig(void)
{
    /* A sixteenth-note retrigger finds the old kick still at 55% amplitude.
       Blend from its outgoing sample with a 1 ms time constant, preserving
       the grid and the noise attack without abruptly discarding the tail. */
    g_kickTail = g_kickLast;
    g_kickAtk = 0.0f;
    g_kickAmp = 1.0f; g_kickFreq = 165.0f;
    g_kickPhase = 0.0f; g_kickClick = 1.0f;
}

static void orgSet(int mode, int root, int type)
{
    static const int minorOff[3] = { 0, 3, 7 };
    static const int majorOff[3] = { 0, 4, 7 };
    static const int pedalOff[3] = { 0, 7, 12 };
    int i, b, base, n0, n1, n2;
    const int *off;
    if (!mode) { g_org.tgt = 0.0f; g_org.mode = 0; return; }
    base = 24 + (mode == 2 ? 12 : 0) + root;
    off  = (mode == 1) ? pedalOff : (type ? majorOff : minorOff);
    n0 = base + off[0]; n1 = base + off[1]; n2 = base + off[2];
    g_org.tgt  = (mode == 1) ? 1.0f : 1.35f;
    g_org.bars = (mode == 1) ? 3 : ORG_BARS;
    if (g_org.mode == mode && g_org.note[0] == n0 &&
        g_org.note[1] == n1 && g_org.note[2] == n2) return;
    g_org.mode = mode;
    g_org.note[0] = n0; g_org.note[1] = n1; g_org.note[2] = n2;
    g_org.bank ^= 1;
    g_org.xf = 0.0f;
    for (i = 0; i < 3; i++) {
        float f = noteFreq(g_org.note[i]) / (float)SRATE;
        for (b = 0; b < ORG_BARS; b++) {
            g_org.inc[g_org.bank][i][b][0] = f * g_orgMul[b];
            g_org.inc[g_org.bank][i][b][1] = f * g_orgMul[b] * 1.0022f;
            /* Both twins start together on every chord, exactly as the
               reference render does. The twin is only 0.22 percent sharp, so
               its beat period is many seconds: starting it a third of a cycle
               late left the 16 foot and 8 foot drawbars near antiphase for as
               long as a chord was held, and that cancelled the pedal. Letting
               them free-run instead just drifts into the same cancellation. */
            /* seeded from the outgoing bank, so the waveform does not step */
            g_org.ph[g_org.bank][i][b][0] = g_org.ph[g_org.bank ^ 1][i][b][0];
            g_org.ph[g_org.bank][i][b][1] = g_org.ph[g_org.bank ^ 1][i][b][1];
        }
    }
}

/* These two are leaf helpers with no dependencies, and they sit here
   rather than further down because every voice below needs them. */
static float pulseWave(Voice *v)
{
    float s = (v->phase < v->duty) ? 1.0f : -1.0f;
    v->phase += v->inc;
    if (v->phase >= 1.0f) v->phase -= 1.0f;
    return s;
}

static float sawAt(float *ph, float inc)
{
    float s = *ph * 2.0f - 1.0f;
    *ph += inc;
    if (*ph >= 1.0f) *ph -= 1.0f;
    return s;
}

#include "voices.h"   /* pad, gated snare, sidechain, FM, chorus, arp */

/* Which patterns the synthwave voices play in. This was a hardcoded range
   while the arrangement was still v10; it is a lane in the baked data now,
   like every other musical decision in this program. */
static int isSynthwave(int o) { return g_sqSyn[o] != 0; }

/* The quiet sections, where a bell has room: the cold open, the void, and
   the outro. Section indices come from the same bake. */
static int isQuiet(int o)
{
    int k = g_sqSect[o];
    return k == 0 || k == 7 || k == 10;
}

static void songTick(void)
{
    static const int minorOff[3] = { 0, 3, 7 };
    static const int majorOff[3] = { 0, 4, 7 };
    int o = g_playOrder, r = g_playRow, k = o * SNG_ROWS + r;
    int ci = r >> 3;

    g_rsOrder = o; g_rsRow = r; g_rsTick = g_playTick;
    if (r == 0 && g_playTick == 0) g_riserLp = 0.0f;
    int root = g_sqRoot[o * 4 + ci], typ = g_sqType[o * 4 + ci];

    if (g_playTick == 0) {
        int n, drum;
        /* The note-off comes from the arrangement without needing a new
           table: a lane that has been resting for long enough releases. Two
           rows is an eighth note at 132 BPM, the shortest rest that should
           actually sound like one; the bass gets four, because a bass line
           wants to ring through sixteenth-note gaps. */
        n = g_sqLead[k];
        if (n >= 0) { trigVoice(&g_vLead, n, 0.999975f, 0.55f, 0.5f); g_leadRest = 0; }
        else if (++g_leadRest >= 2) g_vLead.gate = 0;

        /* Two basses, with a brief release tail at the handoff. The pumping bass
           REPLACES the plain one through the synthwave stretch rather than
           sitting on top of it - two voices in the same octave holding the
           same note is not a thicker bass, it is a comb filter. The kick keys
           the duck either way. */
        n = g_sqBass[k];
        if (isSynthwave(o)) {
            g_vBass.gate = 0;
            if (n >= 0) pumpBassNote(n);
            else if (++g_bassRest >= 4) pumpBassRelease();
            if (n >= 0) g_bassRest = 0;
        } else {
            pumpBassRelease();
            if (n >= 0) { trigVoice(&g_vBass, n, 0.99992f, 0.45f, 0.5f); g_bassRest = 0; }
            else if (++g_bassRest >= 4) g_vBass.gate = 0;
        }
        n = g_sqGtr[k];  if (n >= 0) gtrTrig(n, g_sqHold[k]);
        n = g_sqSolo[k];
        if (n >= 0) {
            solTrig(0, n);
            if (g_sqHarm[k] >= 0) solTrig(1, g_sqHarm[k]);
        }
        drum = g_sqDrum[k];
        /* Combined downbeats retain their kick and sidechain trigger. */
        if (drum == 6 || drum == 7) {
            kickTrig();
            pumpBassKick();
            drum = (drum == 6) ? 5 : 2;
        }
        switch (drum) {
        case 1: kickTrig();
                pumpBassKick();          /* the sidechain is keyed off the kick
                                            itself, not off a level detector */
                break;
        case 2: g_snrAmp  = 0.85f; g_snrPhase = 0.0f;
                gsnrTrig(0.85f);         /* and the gate off the snare */
                break;
        case 3: g_hatAmp  = 0.30f; break;
        case 4: g_hatAmp  = 0.55f; break;
        case 5: g_crashAmp = 0.95f; break;
        default: break;
        }
        orgSet(g_sqOrgMode[o], root, typ);

        /* The pad holds the chord, so it is set from the same root and type
           the organ gets, and only in the synthwave stretch. */
        padSet(isSynthwave(o), root, typ);
        chorusSet(isSynthwave(o) ? 0.85f : 0.0f);

        /* A bell on the first beat of a pattern where nothing else is
           carrying a line. Sparse is the whole character of the voice: it is
           an accent, and one every three and a half seconds is already a lot. */
        if (r == 0 && isQuiet(o) && (o & 1) == 0)
            bellTrig(48 + root, 0.55f);
    }

    /* The polysynth arpeggio runs on the same grid as the chip arp but an
       eighth apart, and only in the synthwave stretch. It is a different
       voice, not a louder version of the old one: detuned saws through a
       filter that gets plucked on every note. */
    if (isSynthwave(o) && g_playTick == 0 && (r & 1) == 0) {
        static const int aOff[4] = { 0, 3, 7, 12 };
        static const int aMaj[4] = { 0, 4, 7, 12 };
        int st = (r >> 1) & 3;
        arpTrig(36 + root + (typ ? aMaj[st] : aOff[st]), (r & 7) == 0 ? 1.0f : 0.62f);
        /* No hard-coded section offset: C's negative remainder pushed the
           relocated synthwave sweep below its intended range. */
        arpSetSweep(0.35f + 0.55f * (float)(o & 3) * 0.25f);
    }

    if (g_sqArpOct[o] >= 0) {
        int step = (g_playTick + r * TPR) % 3;
        int off  = typ ? majorOff[step] : minorOff[step];
        int note = g_sqArpOct[o] + root + off;
        /* An Amiga arpeggio changes pitch every tick; it does not restrike.
           Retriggering here was firing about 53 note attacks a second, which
           is why the chiptune voice swamped everything else. */
        if (g_playTick == 0) trigVoice(&g_vArp, note, 0.99975f, 0.0f, 0.35f);
        else                 g_vArp.inc = noteFreq(note) / (float)SRATE;
    }

    if (++g_playTick >= TPR) {
        g_playTick = 0;
        if (++g_playRow >= SNG_ROWS) {
            g_playRow = 0;
            if (++g_playOrder >= SNG_ORDERS) g_playOrder = 0;
        }
    }
}



/* Attack and release, once. 1.5 ms on the lead is short enough to still read
   as a chip pulse and long enough not to click. The bass is slower on both
   counts: a bass transient that fast just sounds like a click sitting on top
   of the kick. The arp's own decay ends its notes, so its gate stays open. */
static int g_synthReady = 0;
static void synthInit(void)
{
    g_vLead.atk = 1.0f / (0.0015f * (float)SRATE);
    g_vLead.rel = 1.0f / (0.070f  * (float)SRATE);
    g_vBass.atk = 1.0f / (0.0040f * (float)SRATE);
    g_vBass.rel = 1.0f / (0.110f  * (float)SRATE);
    g_vArp.atk  = 1.0f / (0.0010f * (float)SRATE);
    g_vArp.rel  = 1.0f / (0.040f  * (float)SRATE);
    g_vArp.gate = 1;
    g_synthReady = 1;
}

/* Absolute sample positions: the last exported sample is exactly silent. */
static float songEndGain(__int64 sample)
{
    const __int64 total = (__int64)SNG_ORDERS * SNG_ROWS * SPR;
    const int fade = SRATE * 9 / 5;  /* 1.8 seconds */
    float t;
    if (sample >= total - 1) return 0.0f;
    if (sample <= total - fade) return 1.0f;
    t = (float)(total - 1 - sample) / (float)(fade - 1);
    return t * t * (3.0f - 2.0f * t);
}

static void renderAudio(short *out, int frames)
{
    int i;
    if (!g_synthReady) synthInit();
    while (frames > 0) {
        int n;
        /* g_rsTick is the tick songTick() just fired, captured before it
           advanced its counters, so this is that tick's own length. */
        if (g_sampToTick <= 0) { songTick(); g_sampToTick = TICKLEN(g_rsTick); }
        n = frames < g_sampToTick ? frames : g_sampToTick;
        g_sampToTick -= n;
        frames -= n;

        for (i = 0; i < n; i++) {
            float l = 0.0f, r = 0.0f, sendL = 0.0f, sendR = 0.0f;
            float dl = 0.0f, dr = 0.0f, rvL = 0.0f, rvR = 0.0f, s;
            float busy = 0.0f;

            /* --- lead ------------------------------------------------- */
            if (g_vLead.active) {
                s = pulseWave(&g_vLead);   /* no vibrato: the reference lead
                                              is a plain pulse, and the wobble
                                              was what made it dominate */
                g_vLead.amp = (g_vLead.amp - g_vLead.sustain) * g_vLead.decay + g_vLead.sustain;
                voiceEnv(&g_vLead);
                if (g_vLead.amp * g_vLead.env > 0.12f) busy = 0.55f;
                /* Only the second half of the pattern. A note that holds
                   across the bar line and then releases is correct, so
                   measuring from row 0 would count that as a drone. By row 16
                   the two-row rest threshold and the 70 ms release are both
                   long finished. */
                if (g_rsRow >= 16 && g_vLead.env > g_probeLead[g_rsOrder])
                    g_probeLead[g_rsOrder] = g_vLead.env;
                s *= g_vLead.amp * g_vLead.env * 0.20f;
                l += s * 0.62f; r += s * 0.38f;
                sendL += s * 0.45f; sendR += s * 0.30f;
            }
            /* --- solo and its third ----------------------------------- */
            if (g_sol.on && g_sol.amp > 0.0004f) {
                float w, sat, vib;
                g_sol.vib += 5.4f / (float)SRATE;
                vib = 1.0f + lsin(g_sol.vib * TAU) * 0.010f;
                w = (sawAt(&g_sol.p1, g_sol.inc) +
                     sawAt(&g_sol.p2, g_sol.inc * 1.004f)) * 0.5f;
                sat = softClip(w * vib * 9.0f);   /* drive, not pitch */
                g_sol.lp += (sat - g_sol.lp) * 0.66f;
                g_sol.amp *= g_sol.decay;
                g_sol.level += (g_sol.amp - g_sol.level) * 0.0227f;
                if (g_sol.amp > 0.12f) busy = 0.72f;
                s = g_sol.lp * g_sol.level * 0.30f;
                l += s * 1.06f; r += s * 0.94f;
                sendL += s * 0.34f; sendR += s * 0.26f;
            }
            if (g_hsol.on && g_hsol.amp > 0.0004f) {
                float w = (sawAt(&g_hsol.p1, g_hsol.inc) +
                           sawAt(&g_hsol.p2, g_hsol.inc * 1.004f)) * 0.5f;
                float sat = softClip(w * 8.0f);
                g_hsol.lp += (sat - g_hsol.lp) * 0.60f;
                g_hsol.amp *= g_hsol.decay;
                g_hsol.level += (g_hsol.amp - g_hsol.level) * 0.0227f;
                s = g_hsol.lp * g_hsol.level * 0.20f;
                l += s * 0.80f; r += s * 1.20f;
            }
            g_duck += ((1.0f - busy) - g_duck) * 0.000517f;

            /* --- arp -------------------------------------------------- */
            if (g_vArp.active) {
                s = pulseWave(&g_vArp);
                g_vArp.lp += (s - g_vArp.lp) * 0.34f;
                g_vArp.amp *= g_vArp.decay;
                s = g_vArp.lp * g_vArp.amp * 0.10f * g_duck;
                l += s * 0.34f; r += s * 0.66f;
                sendL += s * 0.30f; sendR += s * 0.45f;
            }
            /* --- bass ------------------------------------------------- */
            if (g_vBass.active) {
                float raw;
                g_vBass.phase += g_vBass.inc;
                if (g_vBass.phase >= 1.0f) g_vBass.phase -= 1.0f;
                raw = g_vBass.phase * 2.0f - 1.0f;
                raw = raw * 0.65f + ((g_vBass.phase < 0.5f) ? 0.35f : -0.35f);
                g_vBass.lp += (raw - g_vBass.lp) * 0.22f;
                g_vBass.amp = (g_vBass.amp - g_vBass.sustain) * g_vBass.decay + g_vBass.sustain;
                voiceEnv(&g_vBass);
                if (g_rsRow >= 16 && g_vBass.env > g_probeBass[g_rsOrder])
                    g_probeBass[g_rsOrder] = g_vBass.env;
                s = g_vBass.lp * g_vBass.amp * g_vBass.env * 0.30f;
                l += s; r += s;
            }
            /* --- guitar, two takes ------------------------------------ */
            if (g_gtr.on && g_gtr.amp > 0.0004f) {
                float a, b, sa, sb, w3, w4;
                /* Both takes are power chords. The second one used to be the
                   octave pair alone, so the hard panned double track had
                   different harmonic content from the take beside it. */
                w3 = sawAt(&g_gtr.p3, g_gtr.inc * 1.4983f);
                w4 = sawAt(&g_gtr.p4, g_gtr.inc * 1.5065f);
                a = (sawAt(&g_gtr.p1, g_gtr.inc) +
                     sawAt(&g_gtr.p2, g_gtr.inc * 1.0055f)) * 0.5f
                  + (w3 + w4) * 0.30f;
                b = (sawAt(&g_gtr.q1, g_gtr.inc * 0.9962f) +
                     sawAt(&g_gtr.q2, g_gtr.inc * 1.0091f)) * 0.5f
                  + (w3 + w4) * 0.30f;
                sa = softClip(a * 7.5f);
                sb = softClip(b * 7.5f);
                g_gtr.lp  += (sa - g_gtr.lp)  * 0.52f;
                g_gtr.lp2 += (sb - g_gtr.lp2) * 0.49f;
                g_gtr.hp  += (g_gtr.lp  - g_gtr.hp)  * 0.019f;
                g_gtr.hp2 += (g_gtr.lp2 - g_gtr.hp2) * 0.019f;
                g_gtr.amp *= g_gtr.decay;
                {
                    float ga = (g_gtr.lp  - g_gtr.hp)  * g_gtr.amp * 0.34f;
                    float gb = (g_gtr.lp2 - g_gtr.hp2) * g_gtr.amp * 0.34f;
                    l += ga * 1.00f + gb * 0.16f;
                    r += ga * 0.16f + gb * 1.00f;
                }
            }
            /* --- organ ------------------------------------------------ */
            g_org.amp += (g_org.tgt - g_org.amp) * 0.000209f;
            if (g_org.xf < 1.0f) {
                g_org.xf += ORG_XF_RATE;
                if (g_org.xf > 1.0f) g_org.xf = 1.0f;
            }
            if (g_org.amp > 0.001f) {
                float lowN = 0.0f, upN = 0.0f;   /* the live bank  */
                float lowO = 0.0f, upO = 0.0f;   /* the outgoing one */
                int ni, b, bk = g_org.bank;

                for (ni = 0; ni < 3; ni++)
                    for (b = 0; b < g_org.bars; b++) {
                        float *p0 = &g_org.ph[bk][ni][b][0];
                        float *p1 = &g_org.ph[bk][ni][b][1];
                        float v = (lsin(*p0 * TAU) + lsin(*p1 * TAU))
                                * (g_orgAmp[b] * 0.5f);
                        if (b < 2) lowN += v; else upN += v;
                        *p0 += g_org.inc[bk][ni][b][0]; if (*p0 >= 1.0f) *p0 -= 1.0f;
                        *p1 += g_org.inc[bk][ni][b][1]; if (*p1 >= 1.0f) *p1 -= 1.0f;
                    }

                /* The outgoing bank only costs anything during the 45 ms of a
                   chord change, which is a tenth of a percent of the demo. */
                if (g_org.xf < 1.0f) {
                    int ob = bk ^ 1;
                    for (ni = 0; ni < 3; ni++)
                        for (b = 0; b < g_org.bars; b++) {
                            float *p0 = &g_org.ph[ob][ni][b][0];
                            float *p1 = &g_org.ph[ob][ni][b][1];
                            float v = (lsin(*p0 * TAU) + lsin(*p1 * TAU))
                                    * (g_orgAmp[b] * 0.5f);
                            if (b < 2) lowO += v; else upO += v;
                            *p0 += g_org.inc[ob][ni][b][0]; if (*p0 >= 1.0f) *p0 -= 1.0f;
                            *p1 += g_org.inc[ob][ni][b][1]; if (*p1 >= 1.0f) *p1 -= 1.0f;
                        }
                }
                {
                    float g  = g_org.amp * (g_org.mode == 1 ? 0.030f : 0.042f)
                             * (0.45f + 0.55f * g_duck);
                    float xf = g_org.xf;
                    float lo = (lowN * xf + lowO * (1.0f - xf)) * g;
                    float up = (upN  * xf + upO  * (1.0f - xf)) * g;
                    s = lo + up;
                    /* The 16 and 8 foot drawbars are the pedal, and they sit dead
                       centre. A level difference on a 55 Hz partial buys no
                       audible width and spends real limiter headroom on nothing,
                       so only 5 1/3 foot and above are allowed off centre. */
                    l += lo + up * 0.92f;
                    r += lo + up * 1.08f;
                }
                sendL += s * 0.26f; sendR += s * 0.26f;
                rvL += s * 0.85f; rvR += s * 0.85f;
            }
            /* --- drums onto their own bus ----------------------------- */
            if (g_kickAmp > 0.0005f) {
                g_kickPhase += g_kickFreq / (float)SRATE;
                if (g_kickPhase >= 1.0f) g_kickPhase -= 1.0f;
                s = lsin(g_kickPhase * TAU) * g_kickAmp * 0.55f;
                if (g_kickClick > 0.002f) {
                    s += noiseSample() * g_kickClick * 0.22f;
                    g_kickClick *= 0.9955f;
                }
                g_kickFreq = 46.0f + (g_kickFreq - 46.0f) * 0.99955f;
                g_kickAmp *= 0.99988f;
                g_kickAtk += (1.0f - g_kickAtk) * 0.0227f;
                s = g_kickTail * (1.0f - g_kickAtk) + s * g_kickAtk;
                g_kickLast = s;
                dl += s; dr += s;
            } else g_kickLast = 0.0f;
            if (g_snrAmp > 0.0005f) {
                float nz = noiseSample();
                g_snrHp += (nz - g_snrHp) * 0.45f;
                g_snrPhase += 187.0f / (float)SRATE;
                if (g_snrPhase >= 1.0f) g_snrPhase -= 1.0f;
                s = ((nz - g_snrHp * 0.6f) * 0.75f + lsin(g_snrPhase * TAU) * 0.35f)
                  * g_snrAmp * 0.30f;
                g_snrAmp *= 0.99977f;
                dl += s * 1.05f; dr += s * 0.95f;
                /* No discrete two-row snare echo over the written fills. */
                rvL += s * 0.30f; rvR += s * 0.30f;
            }
            if (g_hatAmp > 0.0005f) {
                float nz = noiseSample();
                g_hatHp += (nz - g_hatHp) * 0.70f;
                s = (nz - g_hatHp) * g_hatAmp * 0.28f;
                g_hatAmp *= 0.9988f;
                dl += s * 0.85f; dr += s * 1.15f;
                rvL += s * 0.5f;  rvR += s * 0.5f;
            }

            if (g_crashAmp > 0.0005f) {
                float nz = noiseSample();
                g_crashHp += (nz - g_crashHp) * 0.70f;
                s = (nz - g_crashHp) * g_crashAmp * 0.28f;
                g_crashAmp *= 0.99975f;
                dl += s * 0.85f; dr += s * 1.15f;
                rvL += s * 0.5f; rvR += s * 0.5f;
            }

            /* --- parallel drum bus ------------------------------------ */
            {
                float pk = (dl > 0.0f ? dl : -dl);
                float pr = (dr > 0.0f ? dr : -dr);
                float m = pk > pr ? pk : pr;
                float g;
                g_drmEnv = (m > g_drmEnv) ? m : g_drmEnv + (m - g_drmEnv) * 0.00082f;
                g = (g_drmEnv > 0.045f) ? 0.045f / g_drmEnv : 1.0f;
                l += dl * (1.0f + g * 3.2f * 0.34f);
                r += dr * (1.0f + g * 3.2f * 0.34f);
            }

            /* --- riser into the next section -------------------------- */
            if (g_sqRiser[g_rsOrder]) {
                /* Filtered noise only. This used to carry a sine sweeping
                   200 -> 2600 Hz whose t^4 swell put its peak exactly on the
                   section change: an audible whistle every 3.6 seconds.
                   The counters are the ones captured before songTick advanced
                   them, so t no longer snaps back a tick early at the bar. */
                float t = ((float)g_rsRow * (float)TPR + (float)g_rsTick)
                        / (float)(SNG_ROWS * TPR - 1);
                float amt = t * t * t * t;
                float nz = noiseSample();
                g_riserLp += (nz - g_riserLp) * (0.02f + 0.55f * t * t);
                s = (nz - g_riserLp) * 0.62f * amt * 0.62f;
                l += s; r += s;
            }

            /* --- the synthwave voices --------------------------------- */
            /* Probed one at a time: the peak each voice adds, per pattern.
               A voice that is wired up but silent looks exactly like a voice
               that is working, right up until you measure it. */
            {
                float b0 = l, b1 = r, d;
                int   pv = g_rsOrder;
                #define VPROBE(idx, call)                     b0 = l; b1 = r; call;                     d = (l - b0); if (d < 0.0f) d = -d;                     { float e = (r - b1); if (e < 0.0f) e = -e; if (e > d) d = e; }                     if (d > g_probeVoice[idx][pv]) g_probeVoice[idx][pv] = d;
                VPROBE(0, padRender(&l, &r))
                VPROBE(1, arpRender(&l, &r))
                VPROBE(2, fmRender(&l, &r))
                VPROBE(3, gsnrRender(&l, &r))
                VPROBE(4, renderPumpBass(&l, &r))
                /* The chorus is a SEND. It was wired up and rendering silence
                   because nothing ever fed it - the pad already computes the
                   send level it wants, so use that. */
                chorusFeed(g_padSendL + g_padSendR);
                VPROBE(5, chorusRender(&l, &r))
                #undef VPROBE
            }

            /* --- echo, locked to two rows ----------------------------- */
            {
                float eL = g_echoL[g_echoPos], eR = g_echoR[g_echoPos];
                l += eR * 0.42f;
                r += eL * 0.42f;
                g_echoL[g_echoPos] = sendL + eL * 0.28f;
                g_echoR[g_echoPos] = sendR + eR * 0.28f;
                if (++g_echoPos >= ECHOLEN) g_echoPos = 0;
            }
            /* --- reverb ----------------------------------------------- */
            {
                int t;
                float accL = 0.0f, accR = 0.0f, inL, inR;

                /* pre-delay */
                inL = g_rvPre[0][g_rvPrePos];
                inR = g_rvPre[1][g_rvPrePos];
                g_rvPre[0][g_rvPrePos] = rvL;
                g_rvPre[1][g_rvPrePos] = rvR;
                if (++g_rvPrePos >= RV_PREDELAY) g_rvPrePos = 0;

                /* four damped combs in parallel */
                for (t = 0; t < RVN; t++) {
                    float *bl = &g_rvBuf[0][t][0], *br = &g_rvBuf[1][t][0];
                    int pl = g_rvPos[0][t], pr2 = g_rvPos[1][t];
                    float yl = bl[pl], yr = br[pr2];
                    g_rvDamp[0][t] += (yl - g_rvDamp[0][t]) * RV_DAMP;
                    g_rvDamp[1][t] += (yr - g_rvDamp[1][t]) * RV_DAMP;
                    bl[pl]  = inL + g_rvDamp[0][t] * g_rvFb[t];
                    br[pr2] = inR + g_rvDamp[1][t] * g_rvFb[t];
                    accL += yl; accR += yr;
                    if (++g_rvPos[0][t] >= g_rvLen[0][t]) g_rvPos[0][t] = 0;
                    if (++g_rvPos[1][t] >= g_rvLen[1][t]) g_rvPos[1][t] = 0;
                }
                accL *= 1.0f / (float)RVN;
                accR *= 1.0f / (float)RVN;

                /* two allpasses in series, per channel */
                for (t = 0; t < APN; t++) {
                    float *al = &g_apBuf[0][t][0], *ar = &g_apBuf[1][t][0];
                    int pl = g_apPos[0][t], pr2 = g_apPos[1][t];
                    float dl = al[pl], dr = ar[pr2];
                    al[pl]  = accL + dl * AP_G;
                    ar[pr2] = accR + dr * AP_G;
                    accL = dl - accL * AP_G;
                    accR = dr - accR * AP_G;
                    if (++g_apPos[0][t] >= g_apLen[0][t]) g_apPos[0][t] = 0;
                    if (++g_apPos[1][t] >= g_apLen[1][t]) g_apPos[1][t] = 0;
                }

                l += accL * 0.30f;
                r += accR * 0.30f;
            }

            /* THE INTENSITY BUDGET. Each section is allowed a loudness, and
               it is applied here - before the bus compressor, so the
               compressor and the limiter cannot simply undo it, which is
               exactly what happened when the sections differed only in how
               many voices were playing. This is the mechanism that lets the
               climax be the climax without adding a single layer to it: the
               chorus actually has more voices than the arrival does. */
            {
                float want = (float)g_sqGain[g_rsOrder] * (1.0f / 1024.0f);
                g_secGain += (want - g_secGain) * 0.00006f;   /* ~0.4 s glide */
                l *= g_secGain; r *= g_secGain;
            }

            /* The reference fades before the bus compressor, so the intro
               never engages it and the makeup lifts the quiet organ back up.
               Fading after the limiter instead made the first 3 s far too
               quiet. */
            g_fadeIn += 1.0f / (float)(SRATE * 3);
            if (g_fadeIn > 1.0f) g_fadeIn = 1.0f;
            l *= g_fadeIn * g_fadeIn;
            r *= g_fadeIn * g_fadeIn;

            /* --- bus compressor, tape, limiter ------------------------ */
            {
                float pk = (l > 0.0f ? l : -l), pr = (r > 0.0f ? r : -r);
                float m = pk > pr ? pk : pr, g = 1.0f;
                /* A real 3:1 knee. The old approximation floored at 0.33, so
                   the loudest transients got far less reduction than the
                   reference; the attack was also instantaneous. */
                g_compEnv += (m - g_compEnv) * (m > g_compEnv ? 0.0017f : 0.00007f);
                if (g_compEnv > 0.30f) g = invCbrt2(g_compEnv * (1.0f / 0.30f));
                l *= g; r *= g;
            }
            {
                /* tape then limiter, in that order, matching the reference
                   render in tools/music_render.py */
                float fv = g_vol;
                float pa = l * 2.6f, pb = r * 2.6f;
                float ta = softClip(pa * 0.9f) + 0.04f * softClip(pa * pa * 0.5f);
                float tb = softClip(pb * 0.9f) + 0.04f * softClip(pb * pb * 0.5f);
                float sa = 0.72f * ta + 0.28f * g_tapeL;
                float sb = 0.72f * tb + 0.28f * g_tapeR;
                g_tapeL = ta; g_tapeR = tb;
                sa = softClip(sa * 1.15f) * 0.94f;      /* the reference drive, exactly */
                sb = softClip(sb * 1.15f) * 0.94f;
                /* Tape's even-order term introduces positive DC. Remove it
                   after the nonlinear stages and before the end fade.
                   10 Hz one-pole: <0.21 dB loss at the 46 Hz kick floor. */
                g_masterDcL += (sa - g_masterDcL) * 0.001424f;
                g_masterDcR += (sb - g_masterDcR) * 0.001424f;
                sa -= g_masterDcL; sb -= g_masterDcR;
                /* g_genSamples advances after each n-sample chunk; i is the
                   current sample within it, not within the caller's buffer. */
                {
                    float endGain = songEndGain(g_genSamples + i);
                    sa *= endGain;
                    sb *= endGain;
                }
                *out++ = (short)(sa * fv * 32700.0f);
                *out++ = (short)(sb * fv * 32700.0f);

                /* The sync grain. Here at the bottom of the sample loop
                   because the master peak only exists at this point and every
                   instrument's envelope is still live.

                   Hat and crash share the existing visual sync channel;
                   peak-hold either envelope while their audio tails remain
                   independent. */
                {
                    float pa = sa > 0.0f ? sa : -sa;
                    float pb = sb > 0.0f ? sb : -sb;
                    #define SPK(f, v) { float t_ = (v); \
                        if (t_ > g_syncAcc.f) g_syncAcc.f = t_; }
                    SPK(kick,  g_kickAmp)
                    SPK(snare, g_snrAmp * (1.0f / 0.85f))
                    SPK(hat,   (g_hatAmp > g_crashAmp ? g_hatAmp : g_crashAmp) * (1.0f / 0.95f))
                    SPK(gtr,   g_gtr.on ? g_gtr.amp : 0.0f)
                    SPK(solo,  g_sol.on ? g_sol.amp : 0.0f)
                    SPK(org,   g_org.amp * (1.0f / 1.35f))
                    SPK(bass,  g_vBass.amp * g_vBass.env)
                    SPK(level, pa > pb ? pa : pb)
                    #undef SPK
                    if (++g_syncFill >= SYNC_GRAIN) {
                        g_sync[g_syncW & SYNC_MASK] = g_syncAcc;
                        g_syncW++;
                        g_syncFill = 0;
                        memset(&g_syncAcc, 0, sizeof(g_syncAcc));
                    }
                }
            }
        }
        g_genSamples += n;
    }
}

static int g_audioNext = 0;

static void audioCleanup(void)
{
    int i, pending = 0;
    g_audioOk = 0;
    if (!g_wo) return;
    /* Keep ownership if a driver refuses cleanup; a later call can retry. */
    if (waveOutReset(g_wo) != MMSYSERR_NOERROR) return;
    for (i = 0; i < NBUF; i++) {
        if ((g_whdr[i].dwFlags & WHDR_PREPARED) &&
            waveOutUnprepareHeader(g_wo, &g_whdr[i], sizeof(WAVEHDR))
                != MMSYSERR_NOERROR) pending = 1;
    }
    if (!pending && waveOutClose(g_wo) == MMSYSERR_NOERROR) g_wo = 0;
}

static void audioInit(void)
{
    WAVEFORMATEX wf;
    int i;
    HWAVEOUT opened = 0;
    audioCleanup();
    if (g_wo) return;
    g_audioNext = 0;
    memset(&wf, 0, sizeof(wf));
    wf.wFormatTag      = WAVE_FORMAT_PCM;
    wf.nChannels       = 2;
    wf.nSamplesPerSec  = SRATE;
    wf.wBitsPerSample  = 16;
    wf.nBlockAlign     = 4;
    wf.nAvgBytesPerSec = SRATE * 4;
    if (waveOutOpen(&opened, WAVE_MAPPER, &wf, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR)
        return;
    g_wo = opened;
    /* Start only after the complete initial queue has been submitted. */
    if (waveOutPause(g_wo) != MMSYSERR_NOERROR) { audioCleanup(); return; }
    for (i = 0; i < NBUF; i++) {
        memset(&g_whdr[i], 0, sizeof(WAVEHDR));
        g_whdr[i].lpData         = (LPSTR)g_wbuf[i];
        g_whdr[i].dwBufferLength = BUFFRAMES * 4;
        if (waveOutPrepareHeader(g_wo, &g_whdr[i], sizeof(WAVEHDR))
                != MMSYSERR_NOERROR) { audioCleanup(); return; }
        renderAudio(g_wbuf[i], BUFFRAMES);
        if (waveOutWrite(g_wo, &g_whdr[i], sizeof(WAVEHDR))
                != MMSYSERR_NOERROR) { audioCleanup(); return; }
    }
    if (waveOutRestart(g_wo) != MMSYSERR_NOERROR) { audioCleanup(); return; }
    g_audioOk = 1;
}

static void audioPump(void)
{
    int count;
    if (!g_audioOk) return;
    for (count = 0; count < NBUF; count++) {
        int i = g_audioNext;
        if (!(g_whdr[i].dwFlags & WHDR_DONE)) break;
        renderAudio(g_wbuf[i], BUFFRAMES);
        if (waveOutWrite(g_wo, &g_whdr[i], sizeof(WAVEHDR))
                != MMSYSERR_NOERROR) { audioCleanup(); return; }
        g_audioNext = (i + 1) % NBUF;
    }
}

static __int64 audioPlayedSamples(void)
{
    MMTIME mt;
    if (!g_audioOk) return -1;
    mt.wType = TIME_SAMPLES;
    if (waveOutGetPosition(g_wo, &mt, sizeof(mt)) != MMSYSERR_NOERROR) return -1;
    if (mt.wType != TIME_SAMPLES) return -1;
    return (__int64)mt.u.sample;
}

#endif  /* CRTK_SYNTH_H */
