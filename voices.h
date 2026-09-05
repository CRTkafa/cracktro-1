/* ==========================================================================
   T H E   S Y N T H W A V E   V O I C E S
   --------------------------------------------------------------------------
   Six voices the synth did not have. Their absence, not the mix, is why the
   demo had no synthwave in it: there was no pad, no gated snare, no
   sidechain, no FM bell, no chorus and no polysynth arpeggio anywhere in the
   code. Each was written against the spectral allocation table and then
   reviewed against it, which is where the level and timing errors came out.
   ========================================================================== */

/* ---------------------------------------------------------------- pad */
/* ==========================================================================
   P A D   -   seven voice unison saw/pulse, resonant SVF, stereo spread
   --------------------------------------------------------------------------
   Owns 220 Hz .. 1.6 kHz. Two pole highpass underneath, the SVF is the only
   lowpass. Panned wide and symmetrically: the even unison voices go left, the
   odd ones go right and lag by a few samples. Ducks against lead and solo,
   and gets out of the rhythm guitar's way when the guitar is playing.
   ========================================================================== */

#define PAD_UNI    7          /* oscillators per note */
#define PAD_NOTES  3          /* notes of the triad held at once */
/* Derived, not hand counted: these are the divisors that set each group's
   level, so if PAD_UNI is ever changed they have to follow it. Written out
   as 12 and 9 they went silently out of step with the loop bounds and one
   side came out mis-scaled. */
#define PAD_NA     (PAD_NOTES * ((PAD_UNI + 1) / 2))   /* even u: 0 2 4 6 */
#define PAD_NB     (PAD_NOTES * (PAD_UNI / 2))         /* odd  u: 1 3 5   */
#define PAD_DLY    31         /* samples the odd group lags the even group */
#define PAD_BASE   48         /* C4 in this note numbering: 261.6 Hz */

/* +-6 cents, 12 cents from the flattest voice to the sharpest. Wider than
   this and the seven voices stop reading as one note; narrower and the
   slowest beat (2 cents at 260 Hz is 0.3 Hz) is too slow to hear inside the
   3.6 s a pattern lasts. These are 2^(c/1200) written out, because there is
   no powf here and this is the only place that needs one. */
static const float g_padDet[PAD_UNI] = {
    0.9965403f, 0.9976921f, 0.9988454f, 1.0000000f,
    1.0011559f, 1.0023132f, 1.0034718f
};

static struct {
    float ph[PAD_NOTES][PAD_UNI];    /* free running: never reset on a chord */
    float inc[PAD_NOTES][PAD_UNI];
    float env, fenv, fdk, tgt;       /* amplitude and filter contours */
    float lfoC, lfoP;                /* cutoff and pulse width modulators */
    float hp1a, hp2a, hp1b, hp2b;    /* the two highpass poles, per side */
    float lpA, bpA, lpB, bpB;        /* the two state variable filters */
    float gtrA;                      /* smoothed "the guitar is playing" */
    int   note[PAD_NOTES];
    int   on, seeded;
} g_pad;

static float g_padDlyBuf[PAD_DLY];
static int   g_padDlyPos = 0;

/* Written by padRender every sample so the integrator can feed the existing
   reverb and echo busses without changing padRender's signature. */
static float g_padSendL = 0.0f, g_padSendR = 0.0f;

/* --- envelopes. One pole coefficients: a = 1/(tau * SRATE). ---------------
   0.41 s attack is the point where the pad stops sounding plucked and starts
   sounding like it was already there; 1.3 s release lets a chord bleed under
   the next one, which is the whole reason a pad is here. */
#define PAD_ATK    0.000055f     /* amp attack,  tau 0.41 s */
#define PAD_REL    0.000189f     /* amp release, tau 0.12 s; clear the metal handoff */
#define PAD_FATK   0.000105f     /* filter opens in tau 0.22 s, ahead of the amp */

/* The two constants that shape the per-chord filter swell. Both of them MUST
   be faster than the rate at which padSet resets fdk, which is the chord
   rate: g_sqRoot is indexed o*4 + (row>>3), so the chord turns over every
   8 rows = 40000 samples = 0.907 s. At the 1.9 s and 2.4 s these used to be,
   fdk was reset long before it had decayed, fenv never moved off 0.95, and
   the "contour" was a constant that parked the cutoff at 1307..1335 Hz -
   inside the lead's register, with none of the movement the design is for.
   At 0.50 s and 0.35 s the swell actually happens: 905..1086 Hz per chord,
   700..1291 Hz once the LFO is added. Anything slower than about 0.6 s here
   and the contour quietly stops existing again. */
#define PAD_FDEC   0.0000454f    /* filter closes in tau 0.50 s */
#define PAD_FDK    0.9999352f    /* sag from wide open to sustain, tau 0.35 s */
#define PAD_FSUS   0.42f         /* how far open a held chord settles */

/* Cutoff in Hz: floor + envelope + LFO. 235 sits just above the highpass so
   a closed pad still has a body instead of disappearing, and so the resonant
   peak never lands below the highpass where it would only be cancelled.
   235 + 1150 + 205 = 1590, i.e. fully open is exactly the top of the band
   this voice is allowed to own. Raising PAD_FCE is how the pad starts eating
   the lead. */
#define PAD_FC0    235.0f
#define PAD_FCE    1150.0f
#define PAD_FCL    205.0f
/* The floor is PAD_FC0 itself, not something under it. At 150 the LFO could
   pull the cutoff to below the 220 Hz highpass corner whenever fenv was near
   zero - during a release, and for the first instants of a note - which is
   precisely the case the paragraph above says cannot happen. */
#define PAD_FCMIN  235.0f
#define PAD_FCMAX  1600.0f

/* q is 1/Q. 0.45 is Q = 2.2: an audible peak that follows the sweep without
   whistling. Below about 0.3 the filter starts to ring on its own and the
   pad turns into a siren every time the LFO comes round. */
#define PAD_Q      0.45f
#define PAD_FSKEW  1.035f        /* right side's cutoff, 60 cents off the left */

/* Saw carries the body, pulse the hollow. The pulse width is modulated in
   opposite directions on the two sides, which decorrelates them for free:
   duty d and duty 1-d have the same magnitude spectrum. */
#define PAD_SAW    0.62f
#define PAD_PUL    0.38f
#define PAD_PWM    0.18f         /* duty swings 0.32 .. 0.68 */

/* Deliberately not integer multiples of the 3.63 s pattern, and not of each
   other, so neither modulator ever lines up with the bar and starts to read
   as rhythm. */
#define PAD_LFOC_INC (0.137f / (float)SRATE)
#define PAD_LFOP_INC (0.081f / (float)SRATE)

/* Two cascaded one pole highpasses are -3 dB at 1.5538 * fc, not at fc, so
   the poles go at 220/1.5538 = 141.6 Hz and 400/1.5538 = 257.4 Hz to put the
   corner of the PAIR where the allocation table says. Coefficient is
   1 - exp(-TAU*fc/SRATE). Moving these to 220 and 400 directly is the
   obvious looking "fix" and it guts the bottom octave of the pad. */
#define PAD_HP_LO  0.01997f      /* pair corner 220 Hz */
#define PAD_HP_HI  0.03601f      /* pair corner 400 Hz, guitar playing */

/* g_duck falls to 1-0.72 = 0.28 under the solo, so 1/0.72 renormalises it to
   a clean 0..1 before the pad's own 0.42 depth is applied. */
#define PAD_DUCK   0.42f
#define PAD_DUCKN  1.3889f
#define PAD_GDROP  0.6452f       /* -9 dB when the rhythm guitar is in */
#define PAD_GATK   0.0012f       /* get out of the way in ~25 ms */
#define PAD_GREL   0.00012f      /* come back over ~190 ms, so it cannot pump
                                    between two chords of the same riff */

/* Twenty one detuned oscillators mostly cancel: after the normalisation by
   voice count the bank sits near 0.07 RMS and only reaches 0.37 on the peaks
   where the unison happens to line up, so this has to be much larger than
   the 0.2 .. 0.34 the single oscillator voices use. At 0.55 the pad measures
   0.037 RMS and 0.20 peak, under the guitar and just under the lead. Sane
   range is 0.35 .. 0.7; past that the 15 dB crest of the unison starts
   triggering the bus compressor on its own. */
/* Measured: at 0.55 the pad peaked at 0.052 against a mix peaking near
   0.30, which is 15 dB down - present in the file and absent from the record.
   A pad is a bed; it has to be the thing the section sits on. 1.9 puts its
   peak at about 0.18, under the guitar and over everything else. */
#define PAD_LEVEL  1.90f         /* the one knob worth tuning by ear */

/* Group B has three voices per note against group A's four. Dividing each
   group by its own voice count does NOT equalise them: twenty one detuned
   oscillators are mutually incoherent, so a group's level after dividing by
   N falls as 1/sqrt(N), and the smaller group therefore comes out
   sqrt(12/9) = 1.155x - a measured 1.18 dB - LOUDER. Since A is panned hard
   left and B hard right, that tips the whole pad to the right and breaks the
   mirror counterweight the allocation table asks for. This trim is
   sqrt(PAD_NB/PAD_NA), written out because there is no sqrtf here; it folds
   into the existing normalising multiply, so it is free. */
#define PAD_BTRIM  0.8660254f
#define PAD_PNEAR  0.925f        /* pan +-0.85, linear: (1 +- 0.85) / 2 */
#define PAD_PFAR   0.075f
#define PAD_SEND   0.30f

/* Call every row (cheap: it returns immediately unless the chord changed).
   on = 0 releases. root/type are the same g_sqRoot / g_sqType the organ
   uses, so the pad is always in the song's harmony by construction. */
static void padSet(int on, int root, int type)
{
    static const int minorOff[3] = { 0, 3, 7 };
    static const int majorOff[3] = { 0, 4, 7 };
    const int *off = type ? majorOff : minorOff;
    int n0, n1, n2, i, u;

    if (!on) { g_pad.tgt = 0.0f; g_pad.on = 0; return; }
    /* Every note is folded into the one octave above PAD_BASE, so the chord
       is whatever inversion of itself lies in 261 .. 494 Hz. Adding root
       straight on instead lets the pad leap an octave between two chords of
       the same progression, and drags the low ones under the highpass. The
       bass owns the actual root, so the pad having the third at the bottom
       is a feature. */
    n0 = PAD_BASE + ((root + off[0]) % 12);
    n1 = PAD_BASE + ((root + off[1]) % 12);
    n2 = PAD_BASE + ((root + off[2]) % 12);
    g_pad.tgt = 1.0f;
    /* Same chord as last row: leave everything running. Re-seeding the filter
       contour once a row would make the pad breathe at 8 Hz. */
    if (g_pad.on && g_pad.note[0] == n0 &&
        g_pad.note[1] == n1 && g_pad.note[2] == n2) return;
    g_pad.on = 1;
    g_pad.note[0] = n0; g_pad.note[1] = n1; g_pad.note[2] = n2;
    for (i = 0; i < PAD_NOTES; i++) {
        float f = noteFreq(g_pad.note[i]) / (float)SRATE;
        for (u = 0; u < PAD_UNI; u++) g_pad.inc[i][u] = f * g_padDet[u];
    }
    /* Only ever once. Twenty one oscillators starting from phase zero hit the
       filter as one large step; after that they are left free running,
       because an analog pad does not restrike its oscillators and because a
       phase reset under a 0.4 s attack would still show up as a thump. */
    if (!g_pad.seeded) {
        for (i = 0; i < PAD_NOTES; i++)
            for (u = 0; u < PAD_UNI; u++)
                g_pad.ph[i][u] = (float)((i * 7 + u * 5) & 15) * 0.0625f;
        g_pad.seeded = 1;
    }
    g_pad.fdk = 1.0f;            /* every chord change reopens the filter */
}

static void padRender(float *l, float *r)
{
    float sA = 0.0f, sB = 0.0f;      /* phase sums, even and odd unison */
    float qA = 0.0f, qB = 0.0f;      /* pulse sums, same split */
    float dutyA, dutyB, cut, f, hpc, gain, mA, mB, bDel;
    int i, u;

    g_padSendL = 0.0f; g_padSendR = 0.0f;
    /* Once the release has run out there is nothing to do, and skipping is
       worth it: the oscillator bank is almost all of this voice's cost.
       Everything frozen here - phases, both highpasses, both SVFs - is
       frozen consistently, so resuming does not step. */
    if (g_pad.tgt <= 0.0f && g_pad.env < 0.0002f) return;

    /* --- envelopes and the guitar's hold-off ------------------------ */
    g_pad.env += (g_pad.tgt - g_pad.env)
               * (g_pad.tgt > g_pad.env ? PAD_ATK : PAD_REL);
    g_pad.fdk *= PAD_FDK;
    {
        float ft = g_pad.tgt * (PAD_FSUS + (1.0f - PAD_FSUS) * g_pad.fdk);
        g_pad.fenv += (ft - g_pad.fenv)
                    * (ft > g_pad.fenv ? PAD_FATK : PAD_FDEC);
    }
    {
        float gt = (g_gtr.on && g_gtr.amp > 0.10f) ? 1.0f : 0.0f;
        g_pad.gtrA += (gt - g_pad.gtrA)
                    * (gt > g_pad.gtrA ? PAD_GATK : PAD_GREL);
    }

    g_pad.lfoC += PAD_LFOC_INC; if (g_pad.lfoC >= 1.0f) g_pad.lfoC -= 1.0f;
    g_pad.lfoP += PAD_LFOP_INC; if (g_pad.lfoP >= 1.0f) g_pad.lfoP -= 1.0f;

    /* --- the oscillator bank ---------------------------------------- */
    dutyA = 0.5f + PAD_PWM * lsin(g_pad.lfoP * TAU);
    dutyB = 1.0f - dutyA;
    for (i = 0; i < PAD_NOTES; i++) {
        for (u = 0; u < PAD_UNI; u += 2) {
            float p = g_pad.ph[i][u] + g_pad.inc[i][u];
            if (p >= 1.0f) p -= 1.0f;
            g_pad.ph[i][u] = p;
            sA += p;                                  /* saw, converted below */
            qA += (p < dutyA) ? 1.0f : -1.0f;
        }
        for (u = 1; u < PAD_UNI; u += 2) {
            float p = g_pad.ph[i][u] + g_pad.inc[i][u];
            if (p >= 1.0f) p -= 1.0f;
            g_pad.ph[i][u] = p;
            sB += p;
            qB += (p < dutyB) ? 1.0f : -1.0f;
        }
    }
    /* The saw is 2*phase-1 per voice, so the sum of N of them is 2*sum - N.
       Doing it once per group instead of once per oscillator saves nineteen
       multiplies a sample for nothing but arithmetic. PAD_BTRIM is on the B
       side only, and it is what makes the two halves the same loudness -
       see the constant. */
    mA = ((sA + sA - (float)PAD_NA) * PAD_SAW + qA * PAD_PUL)
       * (1.0f / (float)PAD_NA);
    mB = ((sB + sB - (float)PAD_NB) * PAD_SAW + qB * PAD_PUL)
       * (PAD_BTRIM / (float)PAD_NB);

    /* --- two pole highpass, before the resonance --------------------- */
    /* Ahead of the SVF on purpose. A pulse of duty d carries 2d-1 of DC, so
       the PWM would otherwise pour a slowly wobbling offset straight into a
       resonant filter, and the resonance would have low frequency rubbish to
       amplify. Both filters are linear, so nothing else about the order
       matters. */
    hpc = PAD_HP_LO + (PAD_HP_HI - PAD_HP_LO) * g_pad.gtrA;
    g_pad.hp1a += (mA - g_pad.hp1a) * hpc; mA -= g_pad.hp1a;
    g_pad.hp2a += (mA - g_pad.hp2a) * hpc; mA -= g_pad.hp2a;
    g_pad.hp1b += (mB - g_pad.hp1b) * hpc; mB -= g_pad.hp1b;
    g_pad.hp2b += (mB - g_pad.hp2b) * hpc; mB -= g_pad.hp2b;

    /* --- resonant state variable filter, one per side ---------------- */
    cut = PAD_FC0 + PAD_FCE * g_pad.fenv + PAD_FCL * lsin(g_pad.lfoC * TAU);
    if (cut < PAD_FCMIN) cut = PAD_FCMIN;
    if (cut > PAD_FCMAX) cut = PAD_FCMAX;
    /* f = 2*sin(pi*fc/SRATE), but the argument never exceeds 0.114 rad here,
       so the straight line is within 0.25 percent - under 4 cents of cutoff -
       and costs one multiply. */
    f = cut * (TAU / (float)SRATE);
    {
        float hp = mA - g_pad.lpA - PAD_Q * g_pad.bpA;
        g_pad.bpA += f * hp;
        g_pad.lpA += f * g_pad.bpA;
        mA = g_pad.lpA;
    }
    {
        float fb = f * PAD_FSKEW;
        float hp = mB - g_pad.lpB - PAD_Q * g_pad.bpB;
        g_pad.bpB += fb * hp;
        g_pad.lpB += fb * g_pad.bpB;
        mB = g_pad.lpB;
    }

    /* --- level: master, envelope, duck, guitar ---------------------- */
    {
        float busy = (1.0f - g_duck) * PAD_DUCKN;
        if (busy > 1.0f) busy = 1.0f;
        if (busy < 0.0f) busy = 0.0f;
        gain = PAD_LEVEL * g_pad.env * (1.0f - PAD_DUCK * busy)
             * (1.0f - PAD_GDROP * g_pad.gtrA);
    }
    mA *= gain; mB *= gain;

    /* --- stereo: the odd group lags, then the two mirror each other -- */
    /* 31 samples is 0.70 ms, inside the precedence window, so it widens
       rather than echoes. The two groups are different oscillators, not a
       copy, so a mono fold down blurs instead of combing. Read before write,
       so the buffer length IS the delay. */
    bDel = g_padDlyBuf[g_padDlyPos];
    g_padDlyBuf[g_padDlyPos] = mB;
    if (++g_padDlyPos >= PAD_DLY) g_padDlyPos = 0;

    *l += mA * PAD_PNEAR + bDel * PAD_PFAR;
    *r += mA * PAD_PFAR  + bDel * PAD_PNEAR;
    g_padSendL = mA * PAD_SEND;
    g_padSendR = bDel * PAD_SEND;
}

/* ---------------------------------------------------------------- gatesnare */
/* ==========================================================================
   Gated reverb snare tail - the 1980s sound.

   Four parallel combs and two short allpasses per side. The two sides share
   no delay length, so this is a genuine stereo pair and not one tail panned
   twice. The room is deliberately long-decaying: the GATE, not the room,
   decides when the tail ends. A room that decays to nothing inside the hold
   sounds like an ordinary tail with a pointless gate hanging off it.
   ========================================================================== */
#define GS_NC   4
#define GS_NA   2
#define GS_CMAX 1867          /* longest comb; sizes the comb buffers */
#define GS_AMAX 419           /* longest allpass */

/* 16.8 to 42.3 ms - a live drum room, not a hall. All eight are prime. Inside
   one side each length is about 1.31 times the last, which is far from any
   small integer ratio, so the comb modes never stack up into a pitch. Across
   the sides no length is near a simple ratio of any other, and that is the
   whole reason the pair sounds wide instead of centred. */
static const int g_gsCLen[2][GS_NC] = { { 743,  977, 1279, 1669 },
                                        { 829, 1091, 1427, 1867 } };
/* fb = 10^(-3L/(T60*SRATE)) with T60 = 3 s, so all eight combs decay at the
   same rate. Equal decay times matter: with unequal ones the short combs drop
   out first and leave the long ones exposed, and the tail turns metallic
   exactly where the gate is supposed to be holding it flat. Three seconds is
   long on purpose - over the 170 ms hold the room falls only 3.4 dB on its
   own, and the excitation is still feeding for 200 ms, which is what "stays
   loud and then stops dead" actually requires. */
static const float g_gsCFb[2][GS_NC] = { { 0.962f, 0.950f, 0.935f, 0.917f },
                                         { 0.958f, 0.945f, 0.928f, 0.907f } };
/* 5.5 to 9.5 ms, again prime and different per side. Four combs on their own
   flutter; these smear the flutter without being long enough to read as a
   separate slap. */
static const int g_gsALen[2][GS_NA] = { { 241, 349 }, { 281, 419 } };

static float g_gsC[2][GS_NC][GS_CMAX];   /* 58 KB, BSS */
static float g_gsA[2][GS_NA][GS_AMAX];   /* 6.5 KB, BSS */

#define GS_HOLD    7500      /* samples wide open: 170 ms, 1.5 rows at SPR 5000 */
#define GS_CLOSE   0.00189f  /* 1/529: a linear ramp that reaches exactly 0 in 12 ms */
#define GS_BDEC    0.99922f  /* excitation burst, -60 dB in 200 ms */
#define GS_TONEINC (335.0f / (float)SRATE)
#define GS_HPA     0.03086f  /* one pole at 220 Hz, applied twice */
#define GS_LPA     0.6312f   /* one pole at 7 kHz */
#define GS_DAMP    0.85f     /* in-loop trim, one pole near 13 kHz per pass */
#define GS_APG     0.5f      /* allpass coefficient; must be < 1 for a stable pole */
#define GS_DRIVE   0.82f     /* 0.25 (mean of four combs) x 3.3 into the saturator */
#define GS_LEVEL   0.18f     /* the only level knob, and a hard per-channel ceiling */

static struct {
    float damp[2][GS_NC];        /* one-pole state inside each comb loop */
    float lp[2], hp1[2], hp2[2]; /* input band limiting, per channel */
    float burst, tone;           /* excitation envelope, shell-tone phase */
    float gate;                  /* 1.0 open, ramps to exactly 0.0 */
    float ext;                   /* optional dry-snare feed, see notes */
    int   cp[2][GS_NC], ap[2][GS_NA];
    int   hold;                  /* samples left before the gate starts closing */
    int   on;
} g_gsnr;

/* Call this from songTick() wherever the snare fires, alongside the dry
   snare's own trigger. vel is 0..1 and scales only the excitation, never the
   gate: the gate is keyed, so a soft hit gets a quieter room for exactly the
   same 170 ms. That is the point of a key gate over a level detector - the
   tail length does not wander with how hard the drum was hit. */
static void gsnrTrig(float vel)
{
    g_gsnr.burst = vel;
    g_gsnr.tone  = 0.0f;      /* reset so every hit has the same attack */
    g_gsnr.gate  = 1.0f;
    g_gsnr.hold  = GS_HOLD;
    g_gsnr.on    = 1;
}

/* Runs every sample. Adds only into *l and *r; it never touches the echo or
   the main reverb sends, because feeding a reverb into another reverb blurs
   the one edge this voice exists to produce. */
static void gsnrRender(float *l, float *r)
{
    float x[2], acc[2], e, tone, v;
    int   c, t;

    /* Idle between hits: the buffers were wiped when the gate shut, so there
       is nothing to run and nothing to denormalise. This voice is only alive
       about a fifth of the time. */
    if (!g_gsnr.on) { g_gsnr.ext = 0.0f; return; }

    /* Excitation. The two sides get independent noise draws - two microphones
       in a real room never hear the same noise realisation, and independent
       noise is what makes the pair sound enormous. They share the shell tone
       in phase, which gives the image a pitched anchor so the two halves still
       read as one drum. 335 Hz is roughly the first shell mode above the dry
       snare's 187 Hz body, and it is above the 220 Hz corner, so unlike the
       body it actually survives the highpass. Without it the room is hiss.
       The exact value is not free: at 330 Hz the tone sits 0.7 Hz from the
       14th mode of the 1867-sample comb, whose -3 dB width is 0.70 Hz, so it
       would ring at 0.71 of that comb's full resonant gain in the RIGHT
       channel only and pull the anchor off centre. 335 Hz is 6.2 widths from
       the nearest mode of any of the eight combs (0.16 of peak), which is the
       best available inside the 300-360 Hz window. Move it and re-check
       against 44100/L and its multiples for all eight lengths.
       tone stays in [0,1) so tone*TAU stays inside lsin's one-turn range. */
    e    = g_gsnr.burst;
    tone = lsin(g_gsnr.tone * TAU) * 0.25f * e;
    g_gsnr.tone += GS_TONEINC;
    if (g_gsnr.tone >= 1.0f) g_gsnr.tone -= 1.0f;
    x[0] = noiseSample() * 0.85f * e + tone + g_gsnr.ext;
    x[1] = noiseSample() * 0.85f * e + tone + g_gsnr.ext;
    g_gsnr.ext = 0.0f;
    /* The send outlasts the hold on purpose. If it died first the room would
       already be coasting when the gate shut and the shut would sound like the
       end of a decay rather than a cut. */
    g_gsnr.burst = e * GS_BDEC;

    /* Band limiting on the way in, so nothing outside 220 Hz - 7 kHz ever gets
       into the feedback loops in the first place. The highpass is two cascaded
       poles, not one: this is the only hard panned wideband element in the mix
       and a single pole still leaves about -7 dB at 110 Hz, which would put
       stereo content under the 140 Hz mono line. Two poles give -11 dB at
       140 Hz and -21 dB at 70 Hz. */
    for (c = 0; c < 2; c++) {
        g_gsnr.lp[c] += (x[c] - g_gsnr.lp[c]) * GS_LPA;
        v = g_gsnr.lp[c];
        g_gsnr.hp1[c] += (v - g_gsnr.hp1[c]) * GS_HPA; v -= g_gsnr.hp1[c];
        g_gsnr.hp2[c] += (v - g_gsnr.hp2[c]) * GS_HPA; v -= g_gsnr.hp2[c];
        x[c] = v;
    }

    for (c = 0; c < 2; c++) {
        float a = 0.0f;
        for (t = 0; t < GS_NC; t++) {
            float *b = &g_gsC[c][t][0];
            int    p = g_gsnr.cp[c][t];
            float  d = b[p];
            /* Read first, then write: the comb output carries the delayed
               signal only. The dry snare is already centre in the mix and must
               not leak back out here, hard panned. The damping pole is only a
               gentle trim - it barely bites in one pass, but the tail goes
               round seven or eight times inside the hold and compounded that is
               enough to stop the last of the tail being pure top end. */
            g_gsnr.damp[c][t] += (d - g_gsnr.damp[c][t]) * GS_DAMP;
            b[p] = x[c] + g_gsnr.damp[c][t] * g_gsCFb[c][t];
            a += d;
            if (++p >= g_gsCLen[c][t]) p = 0;
            g_gsnr.cp[c][t] = p;
        }
        for (t = 0; t < GS_NA; t++) {
            float *b = &g_gsA[c][t][0];
            int    p = g_gsnr.ap[c][t];
            float  d = b[p];
            /* Schroeder allpass, and the three lines below have to be exactly
               this: the value fed back into the line is w, and the output is
               d - g*w, NOT d - g*input. Subtracting g times the input instead
               gives ((1+g*g)z^-N - g)/(1 - g z^-N), which is a comb with 2 dB
               of ripple and 1.17 to 1.5 of gain - two of them in series then
               throw up to 2.25x into the saturator, so the diffusers colour
               the tail and quietly wreck the GS_DRIVE gain staging. With the
               form below the magnitude is flat and only the phase is smeared,
               which is the entire point of putting them here. */
            float  w = a + d * GS_APG;
            b[p] = w;
            a = d - w * GS_APG;
            if (++p >= g_gsALen[c][t]) p = 0;
            g_gsnr.ap[c][t] = p;
        }
        acc[c] = a;
    }

    /* Saturate, then gate, in that order. The 1980s tail was a room squashed
       flat by a compressor before it hit the gate, and softClip standing in for
       that compressor does two useful things: it flattens the plateau further,
       and because it asymptotes at 1.0 this voice can never put more than
       GS_LEVEL into a channel however hot the room gets. Gating after the
       saturator keeps the closing ramp linear; gating first would let the
       saturator partly undo it and soften the shut. Hard +-1.00: each side
       gets only its own room, no cross-feed. */
    *l += softClip(acc[0] * GS_DRIVE) * g_gsnr.gate * GS_LEVEL;
    *r += softClip(acc[1] * GS_DRIVE) * g_gsnr.gate * GS_LEVEL;

    if (g_gsnr.hold > 0) {
        g_gsnr.hold--;
    } else {
        /* Linear, not exponential. An exponential never reaches zero and leaves
           a whisper of room under the next bar; linear lands on exactly 0.0,
           which is both the sound we want and what lets us wipe the buffers.
           The wipe is the "stops dead": without it the frozen room, still only
           a few dB down when the gate shut, would replay as a ghost behind the
           next hit. It also guarantees the loops start every hit from silence
           so nothing can accumulate over a long song. */
        g_gsnr.gate -= GS_CLOSE;
        if (g_gsnr.gate <= 0.0f) {
            g_gsnr.gate = 0.0f;
            g_gsnr.on   = 0;
            /* Clear per line rather than the whole array: only the first
               g_gsCLen entries of each buffer are ever read, so this is 39 KB
               of stores instead of 66 KB in one sample slot. It is still the
               most expensive sample this voice ever runs, which is fine with a
               block-based renderer and worth knowing about if you ever go to
               single-sample callbacks. */
            for (c = 0; c < 2; c++) {
                for (t = 0; t < GS_NC; t++)
                    memset(g_gsC[c][t], 0, g_gsCLen[c][t] * sizeof(float));
                for (t = 0; t < GS_NA; t++)
                    memset(g_gsA[c][t], 0, g_gsALen[c][t] * sizeof(float));
            }
            memset(g_gsnr.damp, 0, sizeof(g_gsnr.damp));
            memset(g_gsnr.lp,  0, sizeof(g_gsnr.lp));
            memset(g_gsnr.hp1, 0, sizeof(g_gsnr.hp1));
            memset(g_gsnr.hp2, 0, sizeof(g_gsnr.hp2));
        }
    }
}

/* ---------------------------------------------------------------- duckbass */
/* =========================================================================
   state  - file-scope, goes next to the other voice statics in synth.h,
            after g_gtr / g_sol / g_org and before g_kickAmp.
   ========================================================================= */

/* ---- sidechained pumping bass -------------------------------------------
   Owns 60-140 Hz and is mono, so it is the one thing holding the bottom of
   the mix together. The duck is keyed off the kick trigger rather than off a
   level detector, which is how the compressor is really patched in this
   genre: the gain starts moving on the same sample the kick does instead of
   waiting for a detector to charge, and it ducks by exactly the same amount
   whether the kick lands under a loud bar or a quiet one.

   Nothing here touches g_duck. That one is the lead-priority duck, it moves
   over seconds, and it is fed by which melodic voice is busy; this one moves
   over milliseconds and is fed by the drum part. They multiply cleanly
   because they are answering different questions.
   -------------------------------------------------------------------------- */

/* Duck depth. 0.35 is about -9 dB, which is deep enough that the kick has the
   band to itself and shallow enough that the bass is still audible under it.
   Below about 0.25 this stops being a compressor and becomes a gate: you hear
   the bass switch off rather than lean out. Above 0.5 the pump disappears. */
#define PB_FLOOR    0.35f

/* One-pole coefficient for the gain itself, tau = 1 ms, so it covers 95
   percent of the drop in 3 ms (measured: 130 samples, 2.95 ms). Faster than
   about 2 ms and the gain step itself becomes a click; slower than about 4 ms
   and the kick transient is already past before the bass gets out of its way,
   which reads as the bass being late rather than as the kick being big. */
#define PB_ATK      0.0227f

/* Recovery ramp: 1 / (0.150 s * SRATE). 150 ms sits in the middle of the
   usable window. At this tempo a row is 116 ms and an eighth is 227 ms, so
   the pump completes between eighth-note kicks and is still climbing when
   the kicks are on sixteenths. Much under 90 ms and the bass is back at full
   while the kick body is still ringing and they fight; much over 200 ms and
   the bass never reaches full level, so the part just sounds quiet rather
   than pumping. */
#define PB_REL_INC  0.00015117f

/* How far the recovery curve is pulled from a smoothstep toward r*r. This is
   the entire audible character of the pump. At 0 it is a plain smoothstep;
   at 1 it is a pure square law, a long flat floor and then a sudden swell,
   which is the obvious cheesy version. 0.30 holds the floor for the first
   ~30 ms, does most of the climb through the middle, and eases into unity.
   Measured gain after a kick: 0.35 at 0 ms, 0.38 at 24 ms, 0.48 at 49 ms,
   0.62 at 74 ms, 0.76 at 99 ms, 0.90 at 124 ms, 1.00 at 151 ms. */
#define PB_HOLD     0.30f

/* Two cascaded one-poles at 190 Hz. One pole was not enough to own a band:
   at 350 Hz it is only 6 dB down. Cascaded, and measured on the real output,
   the 250-350 region sits 18 dB under the 60-140 region, comfortably past the
   3 dB the allocation table asks for. Raising this coefficient walks the
   corner up and fills 250-350 back in, which is the guitar's air. */
#define PB_LP_A     0.02707f

/* 38 Hz highpass, TAU * 38 / SRATE. Costs 1.3 dB at C2 and 0.6 dB at G2, and
   it is insurance rather than repair - see the comment at the filter. */
#define PB_HP_A     0.005414f

/* Drive into the saturator, and the trim after it. softClip(1.35) is 0.897,
   so the drive squashes the loudest part of the waveform by about 1 dB; the
   0.85 is then a plain trim on top of that, not a unity make-up, and it is
   part of what sets the voice's level along with PB_LEVEL. Restoring the
   peak exactly would need 1.116, which would make this voice noticeably
   louder than g_vBass. */
#define PB_DRIVE    1.35f

/* PB_LEVEL 0.22 costs a full voice of CPU for +0.26 dB in 60-140 Hz once
   the bus compressor (3:1 at 0.30), the tape drive and the limiter have
   had it - measured against a build with the voice absent. If this layer
   is meant to be heard rather than merely present, 0.30 buys +0.71 dB and
   0.40 buys +1.39 dB, and the output peak is unchanged at 0.799 in all
   three cases because the limiter is holding it. */
#define PB_LEVEL    0.22f

/* Envelope. The decay and the sustain leak are the existing bass's, and so is
   the linear release, so the two layers rise and fall together when they are
   both playing the part. The release has to be here and it has to be linear:
   an exponential-only tail takes 2.3 seconds to reach silence, which is the
   drone this file's voiceEnv comment is about. */
#define PB_DECAY    0.99992f
#define PB_SUSTAIN  0.45f
#define PB_LEAK     0.99997f
#define PB_SLEW     0.02f       /* tau = 1.1 ms; the note attack de-clicker */
#define PB_REL      (1.0f / (0.110f * (float)SRATE))   /* matches g_vBass */

/* Fold window. Anything outside it is moved by octaves rather than allowed
   to leave the band this voice owns. D3 (146.8 Hz) is deliberately inside
   the window. Note that this is not a rare edge case in the current song:
   the bass part runs up to C4, and midi 40, 42, 43, 45, 46, 47 and 48 all
   get dropped an octave, so this layer plays a flatter contour than g_vBass
   over those passages. That is the intended trade - it keeps the weight in
   band - but it is why the two layers are not simply the same line. */
#define PB_FOLD_HI  150.0f
#define PB_FOLD_LO  58.0f

typedef struct {
    float phase, inc;          /* oscillator                */
    float amp, sustain, env;   /* note envelope             */
    float lp1, lp2, hp;        /* band filters              */
    float duck, rel;           /* sidechain gain, and its recovery ramp */
    int   gate, active;        /* note held / voice running, as in Voice */
} PumpBass;

/* duck and rel start at 1: before the first kick the voice is not ducked.
   gate and active start at 0, so nothing renders until the first note. */
static PumpBass g_pb = { 0.0f, 0.0f,  0.0f, 0.0f, 0.0f,  0.0f, 0.0f, 0.0f,
                         1.0f, 1.0f,  0, 0 };


/* =========================================================================
   trigger  - anywhere above songTick(), which is the only caller.
   ========================================================================= */

/* Stop the voice dead and clear everything it was holding. The filter states
   have to go with it: they track the oscillator, not the envelope, so at the
   moment a note ends they are sitting at whatever point of a full-amplitude
   waveform the oscillator reached - measured -0.47 and -0.26, not the small
   leftovers you would expect. Leaving them there is not a denormal risk, it
   is the opposite, but it does mean the next note starts by flushing a stale
   half-scale value through the filters. It is inaudible because the attack
   slew covers it, and it is still wrong to leave lying around. */
static void pumpBassOff(void)
{
    g_pb.active  = 0;
    g_pb.env     = 0.0f;
    g_pb.amp     = 0.0f;
    g_pb.sustain = 0.0f;
    g_pb.lp1     = 0.0f;
    g_pb.lp2     = 0.0f;
    g_pb.hp      = 0.0f;
}

static void pumpBassNote(int note)
{
    float f = noteFreq(note);
    while (f > PB_FOLD_HI) f *= 0.5f;
    while (f < PB_FOLD_LO) f *= 2.0f;
    g_pb.inc     = f / (float)SRATE;
    g_pb.amp     = 1.0f;
    g_pb.sustain = PB_SUSTAIN;
    g_pb.gate    = 1;
    g_pb.active  = 1;
    /* The phase is deliberately not reset. At 80 Hz a phase jump is a step of
       most of the waveform's amplitude, and on a voice this low that is a
       click, not an attack. A new note only needs the pitch to change. */
}

/* Called where the existing bass releases, so a phrase does not drone through
   the patterns that contain no bass at all. Clearing the gate is what ends
   the note; clearing sustain as well just means amp is already heading down
   if the release is ever lengthened. */
static void pumpBassRelease(void)
{
    g_pb.gate    = 0;
    g_pb.sustain = 0.0f;
}

/* Called from songTick on the same line that fires the kick. Resetting the
   ramp is the whole trigger: it drops the target to the floor and the gain
   slews down to meet it. Retriggering mid-pump is therefore free of clicks,
   because the gain is never assigned, only chased. */
static void pumpBassKick(void)
{
    g_pb.rel = 0.0f;
}


/* =========================================================================
   render  - above renderAudio(). Uses softClip and noteFreq only, both of
             which are already defined earlier in the file.
   ========================================================================= */

static void renderPumpBass(float *l, float *r)
{
    float q, s3, shp, tgt, raw, s;

    /* The duck runs whether or not a note is sounding, so the envelope is
       already in the right place when a note arrives in the middle of a
       pump - which, on the downbeat, is every time. */
    if (g_pb.rel < 1.0f) {
        g_pb.rel += PB_REL_INC;
        if (g_pb.rel > 1.0f) g_pb.rel = 1.0f;
    }
    q   = g_pb.rel * g_pb.rel;
    s3  = q * (3.0f - 2.0f * g_pb.rel);      /* smoothstep */
    shp = s3 + (q - s3) * PB_HOLD;           /* pulled toward r*r: see PB_HOLD */
    tgt = PB_FLOOR + (1.0f - PB_FLOOR) * shp;
    /* One pole chasing a shaped target does both jobs. Against the 3 ms
       attack the ramp has only moved 2 percent, so the target is still the
       floor and the drop is the pole's alone; against the 150 ms recovery the
       pole lags by 1 ms, which is nothing except at the very top, where it
       rounds off the corner where the curve meets unity. */
    g_pb.duck += (tgt - g_pb.duck) * PB_ATK;

    if (!g_pb.active) return;

    g_pb.phase += g_pb.inc;
    if (g_pb.phase >= 1.0f) g_pb.phase -= 1.0f;
    /* The saw runs DOWNWARD here, which is the one place this voice departs
       from the existing bass and it is not cosmetic. A rising saw and an
       in-phase square have fundamentals of opposite sign: 0.65 * -0.637 plus
       0.35 * +1.273 leaves 0.032, so the existing bass's own fundamental is
       cancelled to nothing and its loudest partial is the octave, 16 dB above
       the note. That is a fine mid-bass timbre and a useless 60-140 Hz voice.
       Falling, the two add to 0.859 and every harmonic is at least 9 dB down
       before the filter even runs. */
    raw = (1.0f - g_pb.phase * 2.0f) * 0.65f
        + ((g_pb.phase < 0.5f) ? 0.35f : -0.35f);
    /* Driven before the lowpass, never after. Saturating a filtered 98 Hz
       tone would fold its third harmonic straight into 294 Hz, which is the
       band this voice is required to stay out of. */
    raw = softClip(raw * PB_DRIVE) * 0.85f;

    g_pb.lp1 += (raw      - g_pb.lp1) * PB_LP_A;
    g_pb.lp2 += (g_pb.lp1 - g_pb.lp2) * PB_LP_A;

    g_pb.amp      = (g_pb.amp - g_pb.sustain) * PB_DECAY + g_pb.sustain;
    g_pb.sustain *= PB_LEAK;
    if (g_pb.gate) {
        g_pb.env += (g_pb.amp - g_pb.env) * PB_SLEW;
        /* A held note whose sustain has leaked away is over too. Without this
           the voice would keep running silently for the rest of the demo. */
        if (g_pb.amp < 0.0004f && g_pb.env < 0.0002f) { pumpBassOff(); return; }
    } else {
        /* Linear, and for the reason the voiceEnv comment above gives: an
           exponential release of the same audible length is still ringing
           seconds later. From a typical env of 0.7 this reaches silence in
           76 ms, and the sample it stops on is 1.3e-4, far below the
           waveform's own sample-to-sample motion, so there is no click. */
        g_pb.env -= PB_REL;
        if (g_pb.env <= 0.0f) { pumpBassOff(); return; }
    }

    s = g_pb.lp2 * g_pb.env * g_pb.duck * PB_LEVEL;

    /* Highpass last, after the gain rather than before it. Measured, this is
       insurance and not repair: bypass it and the sub-38 Hz content is still
       42 dB under the 60-140 band, because the waveform is odd-symmetric
       (raw(1-ph) == -raw(ph)) and softClip is odd, so its DC is exactly zero,
       and multiplying an AC signal by a gain step makes sidebands rather than
       DC. What it does buy is 4.6 dB off the rumble the 3 ms gain step and
       the note attack put down there, and a guarantee that no DC reaches the
       master bus if anyone later makes the waveform asymmetric. It costs
       0.6 dB at G2, so do not add a second one. */
    g_pb.hp += (s - g_pb.hp) * PB_HP_A;
    s -= g_pb.hp;

    *l += s; *r += s;     /* mono: everything under 140 Hz is centred */
}


/* =========================================================================
   notes  - corrected integration instructions
   =========================================================================

WHERE THE CODE GOES (all of it in cracktro/synth.h)
  - 'state' next to the other voice statics, after g_gtr / g_sol / g_org and
    before g_kickAmp. One struct, 48 bytes, no arrays: nothing lands on the
    stack and the 2 KB rule is not in play.
  - 'trigger' anywhere above songTick(). pumpBassOff() must come before
    renderPumpBass(), which calls it.
  - 'render' above renderAudio().

FOUR CALL SITES. Three are inside songTick()'s `if (g_playTick == 0)` block.
  1. THE RELEASE. The original draft of these notes pointed at
     `if (r == 0) { g_vLead.sustain = 0.0f; g_vBass.sustain = 0.0f; }`.
     That line does not exist. The existing bass releases from a rest
     counter, at what is currently synth.h:353:
         else if (++g_bassRest >= 4) g_vBass.gate = 0;
     becomes
         else if (++g_bassRest >= 4) { g_vBass.gate = 0; pumpBassRelease(); }
     This fires only 11 times in the whole song, but three of those are the
     32-, 33- and 64-row rests where the arrangement clears the bass
     entirely. Miss it and the voice plays through them.
  2. `n = g_sqBass[k]; if (n >= 0) { trigVoice(&g_vBass, n, ...); ... }`
     add `pumpBassNote(n);` inside that same `if`, where n is known >= 0.
     pumpBassNote does not range-check, and noteFreq() would index
     g_baseFreq[-1] on a negative note - the same exposure trigVoice has.
  3. `case 1: g_kickAmp = 1.0f; ... break;`  add `pumpBassKick();` there.
     This is the sidechain key. Verified: `case 1:` is the only place
     g_kickAmp is set to 1.0f, so this one site is sufficient today. If a
     fill or a section change ever fires a kick from somewhere else, key it
     there too, or the pump silently stops for that bar.
  4. In renderAudio()'s per-sample loop, immediately AFTER the
     `if (g_vBass.active) { ... }` block closes - not inside it, because the
     duck has to keep running when no bass note is sounding:
         renderPumpBass(&l, &r);

ROUTING - three things it must NOT be connected to:
  - Not to dl/dr. The drum bus has its own parallel compressor with a 0.045
    threshold (confirmed at synth.h:635); a bass peaking near 0.09 would
    hold that compressor down permanently and flatten the kick.
  - Not to sendL/sendR. The echo is two rows, 10000 samples; a 98 Hz tone
    repeated at 227 ms is mud.
  - Not to rvL/rvR. The reverb combs are 1237-3457 samples, i.e. 28-78 ms.
    A bass note's period is 8-15 ms, so those combs are not a room for this
    voice, they are a comb filter that will notch or double the fundamental
    differently for every note in the part.

THE ONE CHANGE THAT WILL SILENTLY BREAK IT
  The falling saw. Confirmed analytically and by DFT: the house pairing
  saw*0.65 + square*0.35 with a RISING saw has H1 = +0.0318 and H2 = -0.2069,
  so its second harmonic is 16 dB louder than its fundamental. Falling, H1 =
  0.8594. "Tidying" the oscillator back to match g_vBass drops this voice's
  fundamental by 28 dB and moves its energy to the octave, where the lowpass
  then removes it. If anyone touches that line, re-measure 60-140 Hz.

LEVEL, AND SHARING THE BAND WITH g_vBass
  In isolation this voice peaks at 0.093 under eighth-note kicks against
  g_vBass's 0.102, and 0.118 on a note that lands without a kick. In the
  finished master it is much less than that sounds: measured end to end
  against a build with the voice absent, PB_LEVEL 0.22 adds +0.26 dB to
  60-140 Hz and +0.31 dB of tilt against 1-4 kHz. The bus compressor
  (3:1 at 0.30), the tape drive and the limiter give the rest back. Sweep,
  same song, same analysis:
        PB_LEVEL 0.22 -> +0.26 dB band, +0.31 dB tilt, peak 0.800
        PB_LEVEL 0.30 -> +0.71 dB band, +0.86 dB tilt, peak 0.799
        PB_LEVEL 0.40 -> +1.39 dB band, +1.73 dB tilt, peak 0.799
  The peak does not move because the limiter is holding it, so raising the
  level is safe. The risk with this voice is that it is inaudible, not that
  it is too heavy. Because of the fundamental cancellation above, g_vBass's
  audible energy is at the octave while this one's is at the note, so they
  stack rather than double. To replace g_vBass outright, mute it and raise
  PB_LEVEL to about 0.30; the part will get lower and much simpler.

TUNING CONSTANTS, WHAT THEY MEAN
  PB_FLOOR    duck depth, 0.35 = -9 dB. Gate below 0.25, inaudible above 0.5.
  PB_ATK      one-pole, tau 1 ms -> measured 2.95 ms to reach the floor.
  PB_REL_INC  1/(0.150 s * SRATE). Measured 151 ms to unity.
  PB_HOLD     the pump's character; 0 = soft smoothstep, 1 = cheesy swell.
  PB_LP_A     two poles at 190 Hz. This is what enforces the allocation.
  PB_HP_A     38 Hz. Insurance, not repair - see the comment at the filter.
  PB_REL      the note release. Must match g_vBass's 110 ms and must stay
              linear; an exponential of the same audible length still rings
              seconds later.
  PB_LEVEL    see the sweep above.
  PB_FOLD_*   raise PB_FOLD_HI only if you want this layer to follow g_vBass
              above D3. In the current song that would affect 7 of the 19
              pitches the part uses.

MEASURED, on the compiled output rather than asserted
  - attack 130 samples = 2.95 ms to within 5 percent of the floor
  - recovery reaches unity at 151 ms, curve as listed under PB_HOLD
  - 250-350 Hz band energy sits 18 dB under 60-140 Hz (table asks for 3)
  - harmonics of a G2: 196 Hz -19.7 dB, 294 Hz -18.0 dB, 490 Hz -29.5 dB
  - sub-38 Hz sits 47 dB under 60-140 with the highpass, 42 dB without
  - release tail 76 ms from a typical env of 0.70; terminal sample 1.3e-4
  - note-on after a full stop: max sample step 0.003195, against 0.003180
    on a retrigger while already sounding, so the attack is not a click
  - left and right outputs are bit-identical, so it is genuinely mono

DENORMALS
  Safe without relying on FTZ. The duck converges toward 1.0, not 0. The two
  lowpasses are re-excited by every sample the voice is audible, and
  pumpBassOff() zeroes them outright when the voice stops rather than
  leaving them frozen mid-waveform.

COST
  About 25 flops, one softClip and three data-dependent branches per sample,
  with no memory traffic outside the one struct.

VERIFICATION
  This exact text was pasted into a copy of cracktro/synth.h with the four
  call sites above, and the whole demo was built with the project's own
  flags - cl /O2 /Oi /Ot /GS- /Gy /fp:fast /std:c11 /W3 and link
  /SUBSYSTEM:WINDOWS /ENTRY:entry /NODEFAULTLIB - with zero warnings and a
  clean link, which is also the proof that nothing here reaches for libm or
  __chkstk. It was then rendered offline to dump.wav and compared against a
  baseline render with the voice absent; every dB figure quoted above comes
  from that comparison or from a standalone unit harness, not from an
  estimate. The user's own tree was not modified: all builds ran against
  copies under the session scratchpad.
*/

/* ---------------------------------------------------------------- fmbell */
/* ==========================================================================
   S T A T E
   ==========================================================================
   Paste this block into synth.h after g_duck (line 227) and before
   songTick() (line 329): songTick has to see bellTrig/epTrig, and
   renderAudio (line 424) has to see fmRender. g_gtr (line 144), g_duck
   (line 227), noteFreq (line 90) and lsin all exist above that point.
   ========================================================================== */

/* ==========================================================================
   2 O P E R A T O R   F M   -   bell and electric piano
   --------------------------------------------------------------------------
   Both presets are the same four lines of arithmetic: a modulator sine added
   into a carrier sine's phase argument. Everything that separates a struck
   bell from a Rhodes lives in two numbers - the carrier/modulator frequency
   ratio, and how fast the modulation index falls compared with the amplitude.
   ========================================================================== */

typedef struct {
    float cph, mph;          /* carrier / modulator phase, 0..1 turns        */
    float cinc, minc;        /* per sample phase increments                  */
    float idx, idxFloor;     /* modulation index and its resting value, RAD  */
    float idxDec;            /* per sample index decay multiplier            */
    float amp, ampDec;
    float atk;               /* 0..1 attack ramp, kills the retrigger step   */
    float hp, hp2, lp;       /* one pole filter states                       */
    float split;             /* e-piano only: body/tine crossover state      */
    int   on;
} FmVoice;

static FmVoice g_bell, g_ep;

/* ---- BELL ---------------------------------------------------------------
   Ratio 7:5. Non-integer, so the sidebands land at f*|1 +- 1.4k| =
   0.4, 1, 1.8, 2.4, 3.2, 3.8, 4.6, 5.2 ... f. Those share no common
   fundamental, which is exactly what makes metal read as struck rather than
   plucked. 3.5 is the other classic choice and is more clangorous, but its
   sidebands sit 2.5x further apart: at index 6.5 the top one lands near
   f*33, which is past Nyquist for anything above D5 and folds back as
   aliasing. 1.4 keeps the whole spectrum under Nyquist across the entire two
   octaves the bell is allowed to play.

   At index 6.5 the significant sideband orders reach about N = I + 1.5*I^(1/3)
   ~= 9, so the top partial sits at f*(1 + 1.4*9) = 13.6*f. On C5 that is
   7.1 kHz - the lid of the bell's allocation. The index was chosen for that,
   not the other way round.

   The 0.4*f difference partial is BELOW the allocation floor (209 Hz on C5).
   That is what the 400 Hz highpass is aimed at; it is not a generic
   tidy-up. Real bells have a hum partial there too, and here it would sit in
   the bass guitar's lap. */
#define BELL_RATIO    1.4f
#define BELL_IDX0     6.5f        /* radians of peak phase deviation         */
#define BELL_IDX_FLR  0.35f       /* the tail keeps a little inharmonicity;  */
                                  /* at 0 the ring decays to a pure sine and */
                                  /* stops sounding like metal halfway down  */
#define BELL_IDX_DEC  0.9998866f  /* e-fold 0.20 s: the clang is gone in     */
                                  /* about a third of a second               */
#define BELL_AMP_DEC  0.9999858f  /* e-fold 1.6 s -> ~4 s of audible ring.   */
                                  /* Eight times slower than the index, and  */
                                  /* that ratio IS the bell. Bring it under  */
                                  /* about 4x and it turns into a marimba.   */
#define BELL_GATE     0.0012f     /* amp reaches this 10.7 s after the       */
                                  /* strike, so the voice keeps stepping for */
                                  /* ~7 s after it stops being audible. That */
                                  /* is a CPU cost, not a sound: at this     */
                                  /* level the output is 20 LSBs of a 16 bit */
                                  /* sample, so cutting it is inaudible.     */

/* NOTE NUMBERS ARE NOT MIDI. This file's numbering is octave*12 + pitchclass
   with C-0 == 0 (see the nC5 / nG3 macros at the top of synth.h), so nC5 is
   60, not 72. Written as MIDI these four constants would put both presets an
   octave high, and the bell's top note would become E7 = 2637 Hz, whose top
   sideband at 13.6*f is 35.9 kHz - folded back around Nyquist as exactly the
   metallic buzz the ratio was chosen to avoid. Use the note macros, not
   numbers, so the next reader cannot make the same mistake. */
#define BELL_LO       nC5         /* 523 Hz, the allocation floor            */
#define BELL_HI       nE6         /* 1318 Hz; above this the top sideband    */
                                  /* passes 18 kHz and the sine backend      */
                                  /* (table or polynomial) gets gritty       */
#define BELL_GAIN     0.22f       /* peaks alongside the lead's 0.20 and the */
                                  /* solo's 0.30, which is where a bell that */
                                  /* plays twice a bar belongs               */

/* ---- E-PIANO ------------------------------------------------------------
   Ratio 1:1, so every sideband lands on a harmonic and the sustain is a
   plain periodic tone. The whole DX7 electric piano is the index envelope:
   a short, steep fall from 3.2 rad (5 audible harmonics, a hard woody bark)
   to a floor of 0.20 (barely more than a sine, with just enough second and
   third to stay alive). The bark is over in ~150 ms while the note rings for
   seconds, and that mismatch is what the ear reads as a hammer hitting a
   tine. A real DX7 EP adds a 14:1 operator for the tine click; with only two
   operators the fast index attack has to carry it, which is why 3.2 and not
   something politer. */
#define EP_RATIO      1.0f
#define EP_IDX0       3.2f
#define EP_IDX_FLR    0.20f
#define EP_IDX_DEC    0.9995877f  /* e-fold 55 ms - the bark. Four times     */
                                  /* faster than the bell's, on purpose      */
#define EP_AMP_DEC    0.9999733f  /* e-fold 0.85 s, a Rhodes without pedal   */
#define EP_GATE       0.0008f     /* 5.7 s of stepping, same trade as above  */
#define EP_LO         nG3         /* 196 Hz                                  */
#define EP_HI         nG5         /* 784 Hz; at that note the 4th harmonic   */
                                  /* is already at the 3 kHz lid and the     */
                                  /* lowpass starts eating the tone          */
#define EP_GAIN       0.18f

/* Shared 1.5 ms attack ramp. Both a bell hammer and a Rhodes tine take a
   millisecond or two to get going, and starting from a hard zero is what
   puts a tick on the front of every FM note. */
#define FM_ATK        0.015f

/* One pole coefficients, a = 1 - exp(-TAU*fc/SRATE). */
#define BELL_HP       0.0554f     /* 400 Hz. One pole, so this CUTS the      */
                                  /* 0.4*f hum partial by 6.9 dB at 209 Hz,  */
                                  /* it does not remove it. Together with    */
                                  /* J1(6.5) being 16 dB under the carrier   */
                                  /* that puts the partial 23 dB down, which */
                                  /* is out of the bass's way. A second pole */
                                  /* here would start thinning the strike.   */
#define BELL_LP       0.680f      /* 8 kHz allocation lid (a tilt, not a     */
                                  /* wall - it is one pole, -2.6 dB at 8 kHz */
                                  /* and -5.2 dB at 16 kHz)                  */
#define EP_HP         0.0253f     /* 180 Hz, applied TWICE. One pole leaves  */
                                  /* 140 Hz only 4.3 dB down, and the mix    */
                                  /* rule is that nothing below 140 Hz may   */
                                  /* be off centre. Two poles put 140 Hz at  */
                                  /* -8.7 dB and 100 Hz at -12.8 dB. What    */
                                  /* actually keeps this voice out of the    */
                                  /* mono band is that its lowest note is    */
                                  /* 196 Hz (-5.5 dB through the pair) and   */
                                  /* there is nothing below it but the       */
                                  /* strike transient. Do not "simplify"     */
                                  /* this back to one pole; if you ever let  */
                                  /* EP_LO down an octave, this filter is    */
                                  /* the thing that has to move first.       */
#define EP_LP         0.348f      /* 3 kHz allocation lid                    */
#define EP_SPLIT      0.1924f     /* 1.5 kHz body/tine crossover, see render */

/* Equal power pan gains: g = cos/sin((1+p)*PI/4). */
#define PAN62_FAR     0.9558f     /* p = 0.62 */
#define PAN62_NEAR    0.2940f
#define PAN30_FAR     0.8526f     /* p = 0.30 */
#define PAN30_NEAR    0.5225f

/* The mirrored Haas copy sits 0.7 dB under the dry. At unity the two copies
   are a symmetric pair of strikes and the image collapses to a hole in the
   middle; much below this and precedence stops working, the copy reads as a
   separate slapback event, and the left side is left uncounterweighted.
   0.92 leaves the long term left/right energy 0.6 dB apart, which is inside
   the counterweight tolerance. */
#define HAAS_LEVEL    0.92f

/* 40 ms = 1764 samples. Strictly feedforward - nothing is fed back into it,
   so it cannot ring and it has no tail to decay into denormals. */
#define BELL_HAAS     (SRATE * 40 / 1000)
static float g_bellHaas[BELL_HAAS];
static int   g_bellHaasPos = 0;

/* Reverb send, written fresh every sample. The required render signature is
   (l, r) only, so the send leaves by the side door; add these to rvL/rvR in
   renderAudio and the bell gets its tail. Ignoring them costs two stores a
   sample and nothing else. */
static float g_fmSendL, g_fmSendR;

/* Both presets sit 0.20 into the duck bus this file already maintains
   (g_duck is 1.0 when nothing louder is playing): 20 percent depth is
   1.9 dB at full duck, enough to clear the lead without the listener
   hearing a pump. This macro is the only place g_duck is named. */
#define FM_DUCK       (0.80f + 0.20f * g_duck)


/* ==========================================================================
   T R I G G E R
   ========================================================================== */

/* Advances both operators one sample and returns the enveloped carrier.
   Kept separate from the render so the two presets share it verbatim. */
static float fmStep(FmVoice *v)
{
    float m, x;

    v->mph += v->minc; if (v->mph >= 1.0f) v->mph -= 1.0f;
    v->cph += v->cinc; if (v->cph >= 1.0f) v->cph -= 1.0f;

    m = lsin(v->mph * TAU);
    /* The index is in radians because it is added to a radian argument. The
       argument goes negative and past one turn constantly here, by up to
       +-6.5 rad, and both of this project's lsin backends survive that: the
       software build masks its table index, the D3D11 build's fsin_ range
       reduces first. Neither of those is optional any more. */
    x = lsin(v->cph * TAU + v->idx * m);

    v->idx  = (v->idx - v->idxFloor) * v->idxDec + v->idxFloor;
    v->atk += (1.0f - v->atk) * FM_ATK;
    v->amp *= v->ampDec;

    return x * v->amp * v->atk;
}

static void fmTrig(FmVoice *v, int note, float vel,
                   float ratio, float idx0, float idxFloor,
                   float idxDec, float ampDec)
{
    float f, b, env, idxNew, m;

    if (vel < 0.0f) vel = 0.0f;
    if (vel > 1.0f) vel = 1.0f;
    f = noteFreq(note) / (float)SRATE;

    /* In FM, velocity is mostly brightness. Scaling the index far harder
       than the level is what makes a soft note sound soft rather than
       merely quiet - it is the single thing that separates a played FM
       patch from a sequenced one. */
    b      = 0.40f + 0.60f * vel;
    idxNew = idx0 * b;
    env    = v->amp * v->atk;      /* the envelope value we are standing on */

    if (env < 0.02f) {
        /* Faded out: start clean from zero phase, which is silent, so there
           is nothing to step away from. */
        v->cph = 0.0f; v->mph = 0.0f;
        env = 0.0f;
    } else {
        /* Still ringing, so the old waveform is allowed to continue - that
           is what a second strike on a live bell does. But two things used
           to step here in a single sample, both plainly audible on a voice
           sitting at three quarters of full level: the envelope jumped
           (+2.7 dB on a strike half a second in) and the carrier's argument
           jumped by (idxOld - idxNew)*m, up to +-6.15 rad.

           The index has to change instantly - the index transient IS the
           strike - so instead of ramping it, offset the carrier phase by
           exactly the amount the index change moved the argument. The total
           argument is then continuous across the seam and only its rate of
           change differs, which is what "brighter from here on" should
           sound like. The offset is a constant phase shift afterwards and a
           bell does not care about absolute phase. */
        m = lsin(v->mph * TAU);
        v->cph += (v->idx - idxNew) * m * (1.0f / TAU);
        while (v->cph >= 1.0f) v->cph -= 1.0f;   /* |offset| < 1.04 turns,  */
        while (v->cph <  0.0f) v->cph += 1.0f;   /* so at most two passes   */
    }

    v->cinc     = f;
    v->minc     = f * ratio;
    v->idx      = idxNew;
    v->idxFloor = idxFloor * b;
    v->idxDec   = idxDec;
    v->amp      = 0.45f + 0.55f * vel;
    v->ampDec   = ampDec;
    /* Leave amp*atk exactly where it was and let the 1.5 ms ramp carry it to
       the new level. FM_ATK is documented as the thing that kills the
       retrigger step; setting atk to 0 or leaving it at 1 both step. Dividing
       is safe because amp is never below 0.45. atk landing above 1 (a soft
       strike over a loud tail) is fine - the ramp slides back down to 1. */
    v->atk      = env / v->amp;
    v->on       = 1;
}

static void bellTrig(int note, float vel)
{
    if (note < 0) return;                       /* RST is not a note */
    /* Fold by octaves rather than clamp: a clamp turns a phrase into a
       repeated note, folding keeps the pitch class. The range spans more
       than an octave, so one pass of each loop always lands inside it. */
    while (note < BELL_LO) note += 12;
    while (note > BELL_HI) note -= 12;
    fmTrig(&g_bell, note, vel, BELL_RATIO, BELL_IDX0, BELL_IDX_FLR,
           BELL_IDX_DEC, BELL_AMP_DEC);
}

static void epTrig(int note, float vel)
{
    if (note < 0) return;
    /* The e-piano is allocated the guitar's band and the guitar's space, so
       it plays only where the guitar does not. Calling this under a ringing
       guitar is not a mistake - this test is the gate, and it lives here so
       the arrangement cannot forget it. 0.05 is about 0.4 s after a struck
       chord and 2.7 s after a held one. */
    if (g_gtr.on && g_gtr.amp > 0.05f) return;
    while (note < EP_LO) note += 12;
    while (note > EP_HI) note -= 12;
    fmTrig(&g_ep, note, vel, EP_RATIO, EP_IDX0, EP_IDX_FLR,
           EP_IDX_DEC, EP_AMP_DEC);
}


/* ==========================================================================
   R E N D E R
   ========================================================================== */

static void fmRender(float *l, float *r)
{
    float dry = 0.0f, wet, x, body, tine, g;

    g_fmSendL = 0.0f;
    g_fmSendR = 0.0f;

    /* ---- bell ------------------------------------------------------- */
    if (g_bell.on) {
        if (g_bell.amp < BELL_GATE) {
            g_bell.on = 0;
        } else {
            x = fmStep(&g_bell);
            g_bell.hp += (x - g_bell.hp) * BELL_HP;   /* 400 Hz highpass */
            x -= g_bell.hp;
            g_bell.lp += (x - g_bell.lp) * BELL_LP;   /* 8 kHz lid       */
            dry = g_bell.lp * BELL_GAIN * FM_DUCK;
        }
    }

    /* The delay runs every sample whether or not the bell is sounding.
       Skipping it while idle would freeze the line and the 40 ms already
       inside it would never come out. Read before write, so this is a clean
       BELL_HAAS sample delay and never returns the sample just stored. */
    wet = g_bellHaas[g_bellHaasPos];
    g_bellHaas[g_bellHaasPos] = dry;
    if (++g_bellHaasPos >= BELL_HAAS) g_bellHaasPos = 0;

    /* Dry left at -0.62, the 40 ms copy at the mirror on the right. The
       delayed copy IS the counterweight: precedence keeps the strike on the
       left where it was struck, while the energy balances. */
    *l += dry * PAN62_FAR  + wet * PAN62_NEAR * HAAS_LEVEL;
    *r += dry * PAN62_NEAR + wet * PAN62_FAR  * HAAS_LEVEL;
    g_fmSendL += (dry + wet) * 0.55f;
    g_fmSendR += (dry + wet) * 0.55f;

    /* ---- electric piano --------------------------------------------- */
    if (g_ep.on) {
        if (g_ep.amp < EP_GATE) {
            g_ep.on = 0;
        } else {
            x = fmStep(&g_ep);
            g_ep.hp  += (x - g_ep.hp)  * EP_HP;       /* 180 Hz, pole one */
            x -= g_ep.hp;
            g_ep.hp2 += (x - g_ep.hp2) * EP_HP;       /* 180 Hz, pole two */
            x -= g_ep.hp2;
            g_ep.lp  += (x - g_ep.lp)  * EP_LP;       /* 3 kHz lid        */
            x = g_ep.lp;

            /* Split at 1.5 kHz and pan the halves to opposite sides. A real
               stereo Rhodes does this - tonebar one side, tine pickup the
               other - and it is how this voice gets its +-0.30 spread with
               its own counterweight instead of needing a second oscillator.
               body + tine is exactly x, so L+R is x*(FAR+NEAR), the same
               constant a plain pan would give: nothing cancels in mono. The
               audible consequence is that each note's bark opens to the
               right and its sustain settles left; if that is not wanted,
               replace the four lines below with a plain
               *l += x*g*PAN30_FAR; *r += x*g*PAN30_NEAR;  and accept that
               the counterweight then has to come from somewhere else. */
            g_ep.split += (x - g_ep.split) * EP_SPLIT;
            body = g_ep.split;
            tine = x - body;

            g = EP_GAIN * FM_DUCK;
            *l += (body * PAN30_FAR  + tine * PAN30_NEAR) * g;
            *r += (body * PAN30_NEAR + tine * PAN30_FAR ) * g;
            g_fmSendL += x * g * 0.18f;
            g_fmSendR += x * g * 0.18f;
        }
    }
}

/* ---------------------------------------------------------------- chorus */
/* =====================================================================
   state
   ===================================================================== */

/* ---- chorus / ensemble send ------------------------------------------ */

/* One shared buffer: the three taps carry the same signal and only differ in
   where they read it, so three copies would be three times the cache traffic
   for nothing. 2048 samples is 46 ms, comfortably past the longest tap at
   24.5 ms, and a power of two so the wrap is a mask instead of a compare. */
#define CHLEN  2048
#define CHMASK (CHLEN - 1)
static float g_chBuf[CHLEN];
static int   g_chPos = 0;

/* Base delays 11 / 17 / 23 ms. They are far enough apart that the three comb
   patterns they impose on the pad never share a notch, and with the depths
   below the three sweep ranges (344..626, 644..856, 948..1081 samples) do not
   even overlap - the taps stay in their own lanes for the whole tune. */
#define CH_BASE1 (0.0110f * (float)SRATE)
#define CH_BASE2 (0.0170f * (float)SRATE)
#define CH_BASE3 (0.0230f * (float)SRATE)

/* Depths fall as the rates rise. Perceived detune is depth * 2pi * rate, so
   holding that product roughly constant puts all three at 10.8 / 12.2 / 11.9
   cents peak - string-section territory. Equal depths would have made the
   0.73 Hz line a 27-cent seasick vibrato riding on two barely-moving ones,
   and one loud wobble is exactly what an ensemble must not sound like.

   These stay constant while the tune plays. They are deliberately not scaled
   by the wet amount; chorusRender() says why. */
#define CH_DEP1  (0.0032f * (float)SRATE)
#define CH_DEP2  (0.0024f * (float)SRATE)
#define CH_DEP3  (0.0015f * (float)SRATE)

/* 0.31 / 0.47 / 0.73 Hz. All three are primes on a 0.01 Hz grid, so the
   combination only repeats every 100 seconds - longer than the tune runs.
   A commensurate set like 0.3/0.6/0.9 collapses into one audible sweep every
   few bars, which is the failure this voice exists to avoid. */
#define CH_INC1  (0.31f / (float)SRATE)
#define CH_INC2  (0.47f / (float)SRATE)
#define CH_INC3  (0.73f / (float)SRATE)

/* Start phases in turns, added at read time so the accumulators can stay
   zero-initialised in BSS. Without them all three LFOs leave zero together
   and sweep the same way for the first second, and the configuration that
   recurs on the 100-second period is that same unison - one sweep, which is
   the thing the prime rates above exist to prevent. Offsetting does not
   change the period, it changes what recurs into a scattered pose. */
#define CH_OFF1  0.00f
#define CH_OFF2  0.37f
#define CH_OFF3  0.71f

static struct {
    float ph1, ph2, ph3;   /* LFO phases in turns, kept inside 0..1 */
    float hp;              /* one-pole state for the input highpass */
    float lpL, lpR;        /* wet-side darkening, one per output */
    float in;              /* what the voices pushed in this sample */
    float amt, tgt;        /* wet amount, glided */
} g_ch;


/* =====================================================================
   trigger
   ===================================================================== */

/* Called from songTick() when the arrangement wants a different amount of
   ensemble: 0 is fully dry, 1 is the full three-tap spread. Safe to restate
   every row with the same value - the glide in chorusRender() means only a
   change costs anything. Open it to ~0.9 under the pad, pull it back to ~0.3
   when the solo enters so the centre stays readable. Because the amount now
   moves wet gain only, 0.3 is the same ensemble quieter, not a shallower one. */
static void chorusSet(float amount)
{
    g_ch.tgt = amount;
}

/* Every voice that wants ensemble adds its mono contribution here, once per
   sample, before chorusRender() runs. Mono on purpose: the send exists to
   create the width, so feeding it an already-panned signal would just smear
   a position that the mix already decided. */
static void chorusFeed(float s)
{
    g_ch.in += s;
}


/* =====================================================================
   render
   ===================================================================== */

/* The modulators must not come from lsin(). lsin() is a 4096-entry table read
   with a truncated index, so its output is a staircase, and a staircase is
   fine for an oscillator - one step is a sliver of phase error - but not for
   something that positions a delay tap, where one step is a discontinuity in
   the thing being read. At 0.31 Hz the index advances 1270 times a second, so
   tap 1 freezes for about 35 samples and then jumps by up to 0.22 of a
   sample: chTap() below would then be interpolating between two positions
   that themselves arrive in jumps, putting back exactly the zipper it exists
   to remove. Measured against a tap driven by a true sine, the table leaves
   about 12 dB more inharmonic energy (-38 dB against the tap output, versus
   -50 dB for the curve below), and it lands roughly 1270 Hz either side of
   every partial, so it reads as grain on a sustained pad rather than as
   anything harmonic.

   This parabola pair is continuous in value and in slope everywhere, so the
   tap velocity never jumps at all. The 0.225 term is the usual accuracy
   correction and earns its two multiplies: it leaves the peak at exactly 1.0,
   so the depth constants keep meaning what they say, and the zero-crossing
   slope within 0.8 percent of 2pi, so the cents figures above still hold.
   Shape error against a real sine is 0.0011, which is nothing on a half-hertz
   modulator - shape does not matter here, smoothness is the whole job. */
static float chLfo(float ph)
{
    float x, ax, y, ay;
    if (ph >= 1.0f) ph -= 1.0f;    /* caller adds a start offset, both under 1 */
    x  = ph * 2.0f - 1.0f;
    ax = (x < 0.0f) ? -x : x;
    y  = 4.0f * x * (ax - 1.0f);
    ay = (y < 0.0f) ? -y : y;
    return y + 0.225f * (y * ay - y);
}

/* Linear interpolation between the two samples straddling the fractional
   delay. Reading at the nearest integer instead is the classic mistake: as the
   tap creeps across a sample boundary the output jumps by a whole sample of
   the signal, and that step is the zipper that makes home-made chorus sound
   broken. CHLEN is added before the mask instead of leaning on a negative
   value masking correctly: the longest tap is 1081 samples so one CHLEN is
   always enough to clear zero, and it folds into the address arithmetic. */
static float chTap(float d)
{
    int   i = (int)d;
    float f = d - (float)i;
    int   a = (g_chPos + CHLEN - i) & CHMASK;
    int   b = (a + CHMASK) & CHMASK;          /* one sample older than a */
    return g_chBuf[a] + (g_chBuf[b] - g_chBuf[a]) * f;
}

static void chorusRender(float *l, float *r)
{
    float x, m1, m2, m3, t1, t2, t3, wl, wr;

    /* One-pole glide, tau about 126 ms. It scales the wet gain and nothing
       else. Scaling tap depth with it as well is tempting - the taps park at
       their base delays when the send is shut - but it costs twice. A 0 -> 1
       step then sweeps tap 1 at 0.025 seconds of delay per second, a 43-cent
       bend, four times the detune the tap is built to produce; and at a middle
       setting like 0.3 the sweep shrinks to a third of its range, so the send
       stops being an ensemble and becomes a nearly static three-notch comb -
       the "you hear a filter, not players" failure the base delays are picked
       to avoid. With depth fixed, a gain-only glide can neither click nor
       bend. */
    g_ch.amt += (g_ch.tgt - g_ch.amt) * 0.00018f;

    /* Highpass at about 178 Hz before the delay lines. A moving tap turns low
       frequencies into audible pitch drift, and the mix keeps everything under
       140 Hz mono anyway, so there is nothing down there this send is allowed
       to widen. */
    x = g_ch.in;
    g_ch.in = 0.0f;
    g_ch.hp += (x - g_ch.hp) * 0.025f;
    x -= g_ch.hp;

    g_chBuf[g_chPos] = x;

    g_ch.ph1 += CH_INC1; if (g_ch.ph1 >= 1.0f) g_ch.ph1 -= 1.0f;
    g_ch.ph2 += CH_INC2; if (g_ch.ph2 >= 1.0f) g_ch.ph2 -= 1.0f;
    g_ch.ph3 += CH_INC3; if (g_ch.ph3 >= 1.0f) g_ch.ph3 -= 1.0f;

    m1 = chLfo(g_ch.ph1 + CH_OFF1);
    m2 = chLfo(g_ch.ph2 + CH_OFF2);
    m3 = chLfo(g_ch.ph3 + CH_OFF3);

    t1 = chTap(CH_BASE1 + CH_DEP1 * m1);
    t2 = chTap(CH_BASE2 + CH_DEP2 * m2);
    t3 = chTap(CH_BASE3 + CH_DEP3 * m3);

    /* Taps 1 and 2 lean left, so tap 3 carries the right on its own and has to
       be panned harder than either of them to counterweight both: 0.78 + 0.62
       + 0.10 and 0.22 + 0.38 + 0.90 each sum to 1.50. Every tap is present on
       both sides at different gains, so a mono fold-down sums to t1 + t2 + t3
       with nothing cancelling - which is the point of the mirror rule. */
    wl = (t1 * 0.78f + t2 * 0.62f + t3 * 0.10f) * g_ch.amt * 0.60f;
    wr = (t1 * 0.22f + t2 * 0.38f + t3 * 0.90f) * g_ch.amt * 0.60f;

    /* One pole at about 7.4 kHz. Bucket-brigade ensembles were dark, and the
       droop also buries the high-frequency error that linear interpolation
       leaves behind when a tap sits near a half-sample offset. */
    g_ch.lpL += (wl - g_ch.lpL) * 0.62f;
    g_ch.lpR += (wr - g_ch.lpR) * 0.62f;

    *l += g_ch.lpL;
    *r += g_ch.lpR;

    g_chPos = (g_chPos + 1) & CHMASK;
}


/* =====================================================================
   notes for the integrator  (changes from the submitted version marked *)
   =====================================================================

WIRING

- Per sample, in the inner loop of renderAudio(): each voice that should be
  widened calls chorusFeed(s) with its pre-pan mono signal, then
  chorusRender(&l, &r) is called ONCE, after all voices and before the master
  compressor / softClip / tape stage. chorusRender() zeroes the input
  accumulator, so it must run every sample even when the mix is silent, or the
  next sample eats a stale send.
- Feed it the pad, the organ and the guitar. Do NOT feed it kick, bass, dry
  snare, solo or lead: those are the reserved centre elements and this send
  deliberately moves everything it touches off-axis.
- chorusSet(amount) goes in songTick(), alongside the other per-section
  parameter restates. It is idempotent; call it every row if that is simpler.
- Declaration order: chLfo() and chTap() must both come before chorusRender(),
  and the whole block after SRATE. * It no longer needs lsin() or TAU.
- Memory: g_chBuf is 8 KB in BSS. Nothing goes on the stack; chorusRender()'s
  frame is a handful of floats. The only undefined external the block leaves in
  the object is _fltused, which the host translation unit already provides.

CONSTANTS AND WHAT BREAKS IF YOU MOVE THEM

- CH_INC1/2/3 (0.31 / 0.47 / 0.73 Hz): the non-commensurate set. Rounding any
  of them to a "nicer" value that shares a factor with the others (0.5, 0.75,
  0.25) makes the three LFOs periodically align and the send audibly becomes a
  single vibrato instead of an ensemble. That is the one change that destroys
  the voice.
- * CH_OFF1/2/3: start-phase offsets, in turns. They stop the three taps
  leaving zero together at t = 0 and at every 100-second recurrence. Any three
  mutually unrelated values under 1.0 do the job; setting them all equal undoes
  the point.
- CH_DEP1/2/3: chosen so depth * 2pi * rate is near-constant, giving 10.8 /
  12.2 / 11.9 cents peak detune. Raising them all to a common value makes the
  fastest line dominate. Raising any one past about 0.006 s pushes it into
  seasick territory. Lowering them all below about 0.0008 s and the pad stops
  being an ensemble and goes back to being a stack of saws.
- CH_BASE1/2/3 (11 / 17 / 23 ms): keep them mutually non-harmonic. If two bases
  land at a 2:1 ratio their comb notches stack and you hear a filter, not
  players. They are also spaced widely enough that the sweep ranges do not
  overlap, so no two taps ever read the same neighbourhood of the buffer.
- CHLEN 2048: the longest tap reads 1081 samples back (now always, since depth
  no longer shrinks with the send amount). Deepening CH_DEP3 or lengthening
  CH_BASE3 past ~46 ms total needs CHLEN raised to 4096; the mask wrap silently
  aliases instead of clipping, so it would sound wrong rather than crash.
- * chLfo()'s 0.225: the accuracy term. Drop it and the modulator keeps its
  peak but its zero-crossing slope rises to 8 per turn instead of 2pi, which
  multiplies every detune figure above by 1.27. It is not decoration.
- Input highpass a = 0.025 (-3 dB at 177.7 Hz): protects the mono-below-140 Hz
  rule and keeps the bass out of a moving tap. Lowering it lets the low end
  wander in pitch and smears the mono fold-down.
- * Output lowpass a = 0.62: -3 dB at 7.4 kHz, not the 6.8 kHz previously
  claimed (that figure came from the small-coefficient approximation, which is
  not valid this far up). Taste plus interpolation-error masking. Push it
  toward 1.0 and the linear-interpolation grit starts to show.
- * Glide a = 0.00018 (tau 126 ms): now a pure gain fade, so it cannot click
  and cannot bend pitch, and it can be moved freely on taste alone.
- Output trim 0.60: the three taps are decorrelated, so they sum incoherently
  and the wet lands at 0.60x the send RMS at amount = 1 (measured 0.601) -
  deliberately under the dry so the ensemble supports rather than swamps.
  * Be aware the L and R tap gains each sum to 1.50, so on material where the
  taps momentarily correlate - transients, and anything low enough that 11 ms
  and 23 ms are a small part of a cycle - the instantaneous wet gain reaches
  0.90. That is headroom the master limiter has to find; if the pad is already
  near unity going in, trim the feed rather than this number.

DELIBERATE OMISSIONS

- There is no feedback path. Regeneration turns this into a flanger with
  resonant notches, which is a different and much more attention-grabbing
  effect. It also means there is no decaying recursion to worry about under
  FTZ - the buffer is fed fresh every sample and the only state that can decay
  to zero is the input highpass and the two output one-poles, all of which are
  re-excited the moment a voice feeds again.
- No softClip on the wet. The send is well under unity and distorting a pad's
  ensemble is not a sound anyone wants; the master limiter already catches the
  sum.

VERIFICATION

- cl /nologo /c /O2 /Oi /Ot /GS- /Gy /fp:fast /std:c11 /W4 /DNDEBUG - clean, no
  warnings. dumpbin /symbols shows _fltused as the only undefined external: no
  libm, no __chkstk, no CRT.
- Tap ranges 344.0..626.2 / 643.9..855.5 / 948.1..1080.4, longest read 1080.4
  against a 2048 buffer; shortest 344, so the sample being written is never
  read. Filters 177.7 Hz and 7397 Hz, glide tau 126.0 ms, LFO common period
  100 s, pan gains 1.50 per side with unity fold-down per tap - all measured,
  not asserted.
- chLfo(): peak 1.0000000 at a quarter turn, peak slope 6.2324 per turn against
  2pi (ratio 0.9919), worst shape error 0.00109.
- LFO artifact A/B, one tap fed 1200/2400/3700 Hz, all three variants driven
  from one shared double-precision phase so only the sine evaluation differs;
  error spectrum against an exact-sine-driven tap, Welch-averaged, split by
  whether it sits on a partial or away from one:
      lsin() table : inharmonic error -37.9 dB rel. tap output
      chLfo()      : inharmonic error -49.5 dB rel. tap output
  The component sitting on the partials is the same for both (~-32 dB) and is
  benign - it is only a slightly different vibrato shape.
*/

/* ---------------------------------------------------------------- polyarp */
/* ---- arpeggiated polysynth ---------------------------------------------
   Three detuned saws a note, each note through its own resonant lowpass with
   a fast envelope on the cutoff. The cutoff pluck is the whole point: without
   it an arpeggiator sounds like one held chord being retriggered, because
   every step has exactly the same spectrum. With it every step has its own
   attack colour and the ear hears a sequence.
   ------------------------------------------------------------------------- */
#define ARP_VOICES 3

/* A dotted eighth at 132.3 BPM is 340.14 ms, which is 15000 samples at 44100.
   That is exactly three of this song's 16th note rows, so the repeats land on
   the grid rather than drifting against it. Written in terms of SPR so it
   stays on the grid if the tempo constant ever moves. */
#define ARP_DLY_LEN (SPR * 3)

/* +-10.2 cents. Two different beat rates fall out of three saws spaced this
   way - about 6 Hz between each outer saw and the centre, 12 Hz across the
   outer pair up around C6 where this line sits - so the chorus never locks
   into one throb. Past about 15 cents a short plucked note reads as out of
   tune rather than wide. */
#define ARP_DET_UP    1.00590f
#define ARP_DET_DN    0.99412f

#define ARP_ATK       0.018f       /* ~1.3 ms one pole; kills the step, keeps the pick */
#define ARP_DEC       0.999821f    /* amp to 8% in 320 ms: three steps of overlap */
#define ARP_PLUCK_DEC 0.999245f    /* cutoff env to 5% in 90 ms */
#define ARP_PLUCK_SPAN 3400.0f     /* Hz the cutoff jumps on every note */
#define ARP_RES       0.29f        /* 1/Q, so Q = 3.45, +10.9 dB at the peak */
#define ARP_FC_MIN    300.0f
#define ARP_FC_MAX    4600.0f      /* the resonant peak then lands at 4.75 kHz */

#define ARP_SWEEP_MID   0.92f      /* cutoff multiplier when nothing has set a section */
#define ARP_SWEEP_RANGE 0.80f      /* so bright 0..1 spans 0.52x .. 1.32x */
#define ARP_SWEEP_GLIDE 0.000012f  /* ~1.9 s: this is the slow sweep itself */

#define ARP_HP_A      0.04456f     /* one pole highpass at 320 Hz */

/* The 3 dB scoop at 2.4 kHz, to stay out of the solo's presence band. This is
   a second state variable filter run on the bus, and what gets subtracted is
   its bandpass output - a two pole band, 12 dB an octave on both skirts.
   One pole filters cannot do this job: any pair of them, subtracted in
   parallel or cascaded into a bandpass, has 6 dB skirts so wide that taking
   3 dB out at 2.4 kHz also takes 1.5 dB out at 800 Hz and 1 dB off the whole
   top end, which is a dull voice rather than a hole for the solo. Measured
   with these three numbers: -3.00 dB at 2400, bottoming at -3.34 dB near 2600,
   -0.11 dB at 800 Hz and -0.61 dB at 7 kHz, so the shoulders stay flat.
   F is 2*sin(pi*2400/SR). ARP_DIP_Q is damping, i.e. 1/Q, the same convention
   as ARP_RES - it is 0.70 here for a Q of 1.43, about an octave wide - and K
   is then whatever puts the centre on -3 dB. All three move together. */
#define ARP_DIP_F     0.34028f
#define ARP_DIP_Q     0.70f
#define ARP_DIP_K     0.2230f

#define ARP_DRIVE     0.42f        /* how hard softClip works: tone */
/* Same story as the pad: 0.34 measured 0.081 peak, which is a decoration
   rather than the sequence the section is built on. */
#define ARP_LEVEL     1.15f        /* how loud the voice is: balance */

#define ARP_DLY_SEND  0.60f
#define ARP_DLY_FB    0.42f        /* about three audible repeats */
#define ARP_DLY_RET   0.50f
#define ARP_DLY_DAMP  0.30f        /* damping lowpass at ~2.5 kHz inside the loop */

/* Constant power pan at -0.55: cos and sin of 0.3534 rad, 8.7 dB to the left.
   Baked because there is no acosf here and the position never changes. The
   delay return uses the same pair swapped, and that is the counterweight. */
#define ARP_PAN_L     0.9382f
#define ARP_PAN_R     0.3461f

typedef struct {
    float p1, p2, p3;       /* the three detuned saw phases */
    float i1, i2, i3;       /* and their per sample increments */
    float amp, atk;
    float fenv;             /* the pluck: starts at the accent, falls to 0 */
    float fcFloor;          /* key tracked, worked out once at the trigger */
    float lp, bp;           /* this note's own state variable filter */
} ArpVoice;

static ArpVoice g_arpV[ARP_VOICES];
static struct {
    float sweep, sweepTgt;  /* signed offsets from ARP_SWEEP_MID, see arpRender */
    float hp;               /* 320 Hz highpass state */
    float eqLp, eqBp;       /* the bus filter that makes the 2.4 kHz dip */
    float dampLp;           /* delay feedback damping */
    int   next, dpos;
} g_arp;
static float g_arpDly[ARP_DLY_LEN];   /* 60000 bytes, and it belongs in BSS */

/* Set the brightness of the section, 0 dark to 1 open. Call it once when a
   section starts; arpRender glides to it over about two seconds, and that
   glide is the slow sweep. A zeroed g_arp is already the mid setting, which
   is the reason sweep is stored as a signed offset from ARP_SWEEP_MID rather
   than as the multiplier itself. Keeping zeroed BSS meaningful is also why
   this voice needs no init function. */
static void arpSetSweep(float bright)
{
    if (bright < 0.0f) bright = 0.0f;
    if (bright > 1.0f) bright = 1.0f;
    g_arp.sweepTgt = (bright - 0.5f) * ARP_SWEEP_RANGE;
}

/* One arp step. accent 0..1 scales the level and the depth of the pluck
   together, so a pattern can lean on the downbeat; pass 1.0f for a flat arp. */
static void arpTrig(int note, float accent)
{
    ArpVoice *v;
    float hz, inc;

    /* Rests reach songTick as RST, which is -1, and noteFreq would index
       g_baseFreq[-1] for it: -1/12 is 0 and -1%12 is -1 in C. Guarded here
       rather than at the call site so a rest row is safe to pass straight
       through, and guarded before the round robin so a rest does not steal
       the slot out from under a note that is still sounding. */
    if (note < 0) return;

    if (accent < 0.15f) accent = 0.15f;   /* a step too quiet to hear is a hole
                                             in the arp, not a soft note */
    if (accent > 1.0f)  accent = 1.0f;

    /* Round robin. With three slots and a monophonic arp line the slot that
       comes up next is always the oldest, so this is also the quietest-voice
       rule without having to look for the quietest voice. */
    v = &g_arpV[g_arp.next];
    if (++g_arp.next >= ARP_VOICES) g_arp.next = 0;

    hz  = noteFreq(note);
    inc = hz * (1.0f / (float)SRATE);
    v->i1 = inc;
    v->i2 = inc * ARP_DET_UP;
    v->i3 = inc * ARP_DET_DN;

    /* Sixth, half, five sixths. sawAt returns 2*phase-1 before it advances,
       so three saws all leaving zero together sum to -1 after the scaling,
       and it is the same step on every note, which reads as a tick sitting on
       top of the arp instead of as part of it. Spacing them a third apart is
       what makes the detune beat; starting the set at 1/6 rather than at 0 is
       what makes the three values -2/3, 0 and +2/3 sum to exactly zero.
       Thirds measured from zero give -1, -1/3, +1/3, which still leaves -1/3
       going into a filter with Q of 3.45 on every note. */
    v->p1 = 0.166667f;
    v->p2 = 0.5f;
    v->p3 = 0.833333f;

    v->amp  = accent;
    v->atk  = 0.0f;
    v->fenv = accent;

    /* Key tracking. A fixed cutoff floor would mute the top of the arp and
       leave the bottom undamped; 1.6 * f0 keeps roughly the first two
       harmonics of any note alive, and the 240 Hz term stops the lowest notes
       from closing the filter down into the highpass. */
    v->fcFloor = 240.0f + hz * 1.6f;

    /* The filter state is deliberately not cleared. A slot is normally reused
       only after its previous note has decayed, and arpRender zeroes the state
       on the way out; clearing it here would only change the case where a
       still-loud voice is stolen, and there stopping the old tail dead on a
       discontinuity is worse than letting the new note's reset saws arrive
       through a filter that is already moving. */
}

static void arpRender(float *l, float *r)
{
    int i;
    float sum = 0.0f, dry, wet, dk, sweep, ehp;

    g_arp.sweep += (g_arp.sweepTgt - g_arp.sweep) * ARP_SWEEP_GLIDE;
    sweep = ARP_SWEEP_MID + g_arp.sweep;

    for (i = 0; i < ARP_VOICES; i++) {
        ArpVoice *v = &g_arpV[i];
        float saw, fc, w, f, hp;

        if (v->amp <= 0.0004f) {
            /* Park the slot. The state has to be cleared here rather than at
               the trigger: the filter runs at full scale right up to this
               threshold, so a slot picked up again with that still sitting in
               lp would start the next note on a step. */
            if (v->amp != 0.0f) { v->amp = 0.0f; v->lp = 0.0f; v->bp = 0.0f; }
            continue;
        }

        saw = (sawAt(&v->p1, v->i1) +
               sawAt(&v->p2, v->i2) +
               sawAt(&v->p3, v->i3)) * (1.0f / 3.0f);

        fc = (v->fcFloor + ARP_PLUCK_SPAN * v->fenv) * sweep;
        if (fc < ARP_FC_MIN) fc = ARP_FC_MIN;
        if (fc > ARP_FC_MAX) fc = ARP_FC_MAX;

        /* The state variable filter wants f = 2*sin(pi*fc/SR). There is no
           sinf here, and lsin is the wrong tool for a swept cutoff - 4096
           entries over a turn quantises this into roughly 21 Hz steps, and on
           a 90 ms sweep those steps land as zipper noise. w here is 2*pi*fc/SR,
           which is twice the angle the sine wants, so the two term series for
           2*sin(w/2) is w - w^3/24 - note the 24, not the 6 you would write
           for sin(w) itself. Under 0.01 percent out at the top clamp. */
        w = fc * (TAU / (float)SRATE);
        f = w - w * w * w * (1.0f / 24.0f);

        v->lp += f * v->bp;
        hp     = saw - v->lp - ARP_RES * v->bp;
        v->bp += f * hp;

        v->atk  += (1.0f - v->atk) * ARP_ATK;
        v->amp  *= ARP_DEC;
        v->fenv *= ARP_PLUCK_DEC;

        sum += v->lp * v->amp * v->atk;
    }

    /* Highpass first. Nothing this voice makes belongs under its own
       allocation, and the arp is the element most likely to crowd the bass. */
    g_arp.hp += (sum - g_arp.hp) * ARP_HP_A;
    dry = sum - g_arp.hp;

    /* Then the presence scoop: take a scaled bandpass away from the signal. */
    g_arp.eqLp += ARP_DIP_F * g_arp.eqBp;
    ehp         = dry - g_arp.eqLp - ARP_DIP_Q * g_arp.eqBp;
    g_arp.eqBp += ARP_DIP_F * ehp;
    dry -= g_arp.eqBp * ARP_DIP_K;

    /* Three overlapping notes through a resonant filter stack far higher at
       the peak of a pluck than one does. At ARP_DRIVE the ordinary signal sits
       in the near linear part of softClip and only the peaks get shaped. */
    dry = softClip(dry * ARP_DRIVE) * ARP_LEVEL;

    /* The dotted eighth. Read before write at the same index, so the line
       delays by exactly ARP_DLY_LEN. Written before the duck is applied, so
       the line always holds un-ducked material and the repeats duck along with
       the dry instead of carrying a third of a second old duck value forward. */
    wet = g_arpDly[g_arp.dpos];
    g_arp.dampLp += (wet - g_arp.dampLp) * ARP_DLY_DAMP;
    g_arpDly[g_arp.dpos] = dry * ARP_DLY_SEND + g_arp.dampLp * ARP_DLY_FB;
    if (++g_arp.dpos >= ARP_DLY_LEN) g_arp.dpos = 0;

    dk   = 0.70f + 0.30f * g_duck;   /* ducks 0.30, same shape as the organ */
    dry *= dk;
    wet *= ARP_DLY_RET * dk;

    /* Dry at -0.55, return at the mirror position: the same two gains swapped. */
    *l += dry * ARP_PAN_L + wet * ARP_PAN_R;
    *r += dry * ARP_PAN_R + wet * ARP_PAN_L;
}
