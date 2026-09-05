// The boot screen, in the middle of the demo.
//
// It was at the START once, and the author cut it: fourteen seconds of text
// before anything happens is a bad opening. But the breakdown at bar 53 is
// the middle of the piece both by the clock and by the form, and a half-time
// bar is exactly where a demo can afford to stop and be a computer for a
// moment. So it lives there now, and it is over in four bars.
//
// The text is theirs, baked out of crtkafa.c by tools/bake_font.py rather
// than retyped, so it cannot drift from what they wrote. NOTHING in here
// touches a word or an order of it. Everything below is about the MACHINE
// the words are printed on: how far the boot has got, what the drive is
// doing, whether the tube has warmed up, and who owns the raster.
//
// The scene is cut TWICE, at bar 53 and bar 55, and the shot table hands the
// second one a later boot than the first. So the two appearances are not two
// looks at the same screen - they are one boot, continued. The first takes
// the machine from a cold tube to the middle of a load. The second picks up
// exactly where that left off, watches READY. and RUN arrive, and then hands
// the raster over to the program, which is the shot the dissolve into the
// corridor is cut against.
//
// gTune.x  the progress the boot has reached by the END of this shot, 0..1.
//          The shot animates INTO it from x - BOOT_STEP, so consecutive
//          entries in the table chain rather than repeat. Line arrival is on
//          the schedule below, which is the author's own g_bootAt.
// gTune.y  screen brightness
// gTune.z  barrel of the tube's own curvature, on top of the post pass
// gTune.w  tube age: extra warm-up droop and roll that never quite settles.
//          0 is a healthy set, and both current shots are healthy.

cbuffer Scene : register(b0)
{
    float4 gTime;
    float4 gCam;
    float4 gDir;
    float4 gTune;
    float4 gSync;
    float4 gVoice;
};

// b1, uploaded once and never touched again - b0 is rewritten every frame for
// every shot and this has no business being in it.
cbuffer Font : register(b1)
{
    uint4 gFont[24];    // 47 glyphs x 2 uints, padded to float4 rows
    uint4 gText[40];    // 40x16 cells, four to a uint
};

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

#define COLS 40
#define ROWS 16

// How much of the whole boot one shot of this scene gets through. It is the
// gap between the two gTune.x values in shots.h (0.55 and 1.00) written down
// once, so a shot starts where the shot before it stopped.
#define BOOT_STEP 0.45

// How long a shot takes to travel that distance, in seconds. Shorter than
// either shot on purpose: the boot finishes and the picture then SITS in the
// state it reached, which is what gives the second appearance its handover.
#define BOOT_SPAN 2.2

// When each line arrives, as a fraction of the whole boot. This is the same
// schedule as g_bootAt[] in crtkafa.c - the author's pacing, not mine - kept
// in step by hand because a shader cannot read that array. Rows past the end
// of the text never arrive.
static const float kBootAt[16] = {
    0.02, 0.02, 0.02, 0.02, 0.02, 0.02,   // the banner, up the instant it is on
    0.14, 0.14,                           // LOAD, typed
    0.22,                                 // SEARCHING
    0.32,                                 // LOADING  - and then the long wait
    0.74,                                 // READY.
    0.86,                                 // RUN
    9.0,  9.0,  9.0,  9.0                 // blank glass
};

uint cellAt(uint col, uint row)
{
    uint i = row * COLS + col;          // which cell
    uint w = i >> 2;                    // which uint
    uint b = (i & 3u) * 8u;             // which byte in it
    uint v = gText[w >> 2][w & 3u];
    return (v >> b) & 0xFFu;
}

bool glyphBit(uint gi, uint x, uint y)
{
    uint w = gi * 2u + (y >> 2);        // rows 0-3 in the first uint, 4-7 in the second
    uint v = gFont[w >> 2][w & 3u];
    uint row = (v >> (8u * (3u - (y & 3u)))) & 0xFFu;
    return ((row >> (7u - x)) & 1u) != 0u;
}

float hash1(float n)
{
    return frac(sin(n * 91.3458) * 47453.5453);
}

float4 bootRaster(VSOut i)
{
    float t = gTime.x;

    // ---- where the boot has got to ------------------------------------
    // One clock for the whole scene. Everything else - the drive, the tube,
    // the cursor, the margin, who owns the raster - is read off it, so a
    // shot handed a different gTune.x is a different picture and not a
    // different colour.
    float pEnd   = saturate(gTune.x);
    float pStart = pEnd - BOOT_STEP;
    float u      = saturate(t / BOOT_SPAN);
    float p      = lerp(pStart, pEnd, u);

    float age  = saturate(gTune.w);
    // A set that has only just been switched on. True of the first shot,
    // false of the second, because the second starts halfway through a load.
    float cold = saturate(1.0 - pStart * 2.2);
    float warm = saturate(cold * saturate(1.0 - u * 0.9) + age * 0.55);

    // The drive is working between SEARCHING and READY. - which is most of
    // the first appearance and only the head of the second.
    float load = saturate((p - 0.19) * 22.0) * saturate((0.74 - p) * 16.0);
    // RUN is away and the program has the machine.
    float ran  = saturate((p - 0.90) * 10.0);

    // ---- the glass ----------------------------------------------------
    float2 uv = i.uv;

    // A raster line stolen by the drive comes out short. Coherent per line
    // and only while the drive is actually turning.
    float ln   = floor(uv.y * 240.0);
    float torn = hash1(ln * 3.13 + floor(t * 24.0) * 71.7);
    float tear = (torn > 0.962) ? (hash1(ln + 5.0) - 0.5) * 0.030 : 0.0;

    float2 c = uv - 0.5;

    // The tube's own curvature, under the post pass. Zero is flat.
    c *= 1.0 + gTune.z * dot(c, c) * 2.0;

    // The yoke is cold, so the raster starts short and creeps out to size;
    // the high tension sags on the bass and the picture breathes wider with
    // it. Geometry, not brightness - none of this touches the floor.
    float squeeze = 1.0 - 0.34 * warm;
    float sag     = 1.0 + 0.012 * gSync.x;
    float rattle  = load * (0.0016 * sin(t * 61.0) + 0.0009 * sin(t * 23.7));

    c.x = c.x / sag + rattle + tear * load;
    c.y = c.y / squeeze;
    uv  = c + 0.5;

    // The raster grows into the tube as the machine settles: a screen that
    // has just come up sits in a fat margin, and a screen about to hand over
    // to a demo does not. This is the difference you see first.
    float mgn = lerp(0.150, 0.048, saturate(p));
    mgn = lerp(mgn, 0.016, ran);              // and the program goes for the edges
    float2 m    = float2(mgn, mgn * 1.10);
    float2 in01 = (uv - m) / (1.0 - 2.0 * m);

    float3 border = float3(0.24, 0.22, 0.62);
    float3 paper  = float3(0.16, 0.14, 0.50);
    float3 ink    = float3(0.62, 0.60, 0.94);

    // ---- the border ---------------------------------------------------
    // A fastloader talks to the drive by writing the border register every
    // few raster lines, so a machine that is LOADING wears bands and a
    // machine that is not wears none. They scroll rather than blink: the
    // mean over the border never moves, which is the only honest way to do
    // this. The high band nudges the phase, not the level.
    float3 col;
    {
        float band = floor(uv.y * 34.0 - t * 9.0 - gSync.z * 1.6);
        float k    = 0.74 + 0.58 * hash1(band);
        float3 hue = float3(0.86 + 0.32 * hash1(band + 7.0),
                            0.82 + 0.28 * hash1(band + 19.0),
                            1.00);
        col = lerp(border, border * k * hue, load);
    }

    // Once RUN is away the program owns the border too, and the first thing
    // any of them ever did was make it agree with the screen.
    col = lerp(col, paper, ran * 0.92);

    // ---- the screen ---------------------------------------------------
    if (all(in01 >= 0.0) && all(in01 < 1.0))
    {
        col = paper;

        float2 cell = in01 * float2(COLS, ROWS);
        uint   cx   = (uint)cell.x;
        uint   glass= (uint)cell.y;          // the row on the tube
        float2 f    = frac(cell);
        uint   px   = (uint)(f.x * 8.0);
        uint   py   = (uint)(f.y * 8.0);

        // The program starts printing and the terminal scrolls what was
        // there off the top, a whole line at a time the way it must.
        uint cy = glass + (uint)floor(ran * 3.0);

        // The reveal is per LINE, not per character: this machine printed a
        // line at a time and a per-character crawl would be a different
        // decade's idea of a computer. A line that has only just landed
        // still has the beam's heat in it for a moment.
        if (cy < (uint)ROWS)
        {
            float thr = kBootAt[cy];
            uint  gi  = cellAt(cx, cy);
            if (p >= thr && gi != 0u && glyphBit(gi, px, py))
            {
                float fresh = saturate(1.0 - (p - thr) * 14.0);
                col = ink * (1.0 + 0.45 * fresh);
            }
        }

        // The cursor sits at the head of the first line that has not arrived
        // and blinks on the demo's own clock rather than on a wall clock - a
        // blink that ignores the music is a screensaver. While the drive is
        // turning the machine is not listening, so it stops blinking and
        // just sits there; once RUN is away there is no cursor at all,
        // because the cursor belongs to BASIC and BASIC is no longer here.
        {
            uint cur = 0u;
            [unroll] for (uint r = 0u; r < (uint)ROWS; r++)
                if (kBootAt[r] <= p) cur = r + 1u;

            float blink = frac(t * 1.7) < 0.55 ? 1.0 : 0.0;
            float on    = lerp(blink, 1.0, load) * (1.0 - ran);
            if (cy == cur && cx == 0u && on > 0.5) col = ink;
        }
    }

    // Phosphor bloom around the lit cells, cheap: the border picks up a
    // little of the paper colour near the edge of the text box.
    {
        float2 d = abs(in01 - 0.5) - 0.5;
        float  e = length(max(d, 0.0));
        col += paper * 0.35 * exp(-e * 26.0);
    }

    // The frame a cold set has not locked yet: the seam walks down the tube
    // and stops walking once the machine is warm. A moving band, never a
    // flashing one - the mean barely moves, and the floor never drops out.
    //
    // No scanlines here on purpose. The post pass owns those and draws them
    // in virtual space; a second set drawn in this one would beat against
    // them.
    {
        float rb = frac(uv.y + t * (0.11 + 0.25 * age));
        float x0 = (rb - 0.50) * 16.0;
        float x1 = (rb - 0.58) * 44.0;
        col *= 1.0 + (0.26 * exp(-x0 * x0) - 0.11 * exp(-x1 * x1)) * warm;
    }

    // The program is writing to the screen faster than the beam can get off
    // it, and the beam shows it. Only after RUN, so it is the second
    // appearance's alone.
    {
        float hb = 0.5 + 0.5 * sin(uv.y * 62.0 + t * 26.0);
        col *= 1.0 + 0.15 * hb * ran;
    }

    col *= gTune.y;

    // A cold cathode does not emit. It comes up, it does not flash up.
    col *= 1.0 - 0.20 * warm;

    // The whole tube is very slightly brighter when the organ is holding a
    // chord - the same mains that runs the machine runs the amplifier.
    col *= 1.0 + gVoice.z * 0.05;

    return float4(col * gTime.z, 1.0);
}

float caseBox(float3 p, float3 b) {
    float3 q=abs(p)-b;
    return length(max(q,0))+min(max(q.x,max(q.y,q.z)),0);
}
float machine(float3 p) {
    float body=caseBox(p-float3(0,.45,.5),float3(3.95,2.95,.9))-.12;
    float base=caseBox(p-float3(0,-2.85,.3),float3(1.5,.35,1.0))-.08;
    float keyboard=caseBox(p-float3(0,-3.22,-1.9),float3(3.75,.23,1.15))-.09;
    return min(body,min(base,keyboard));
}
float4 main(VSOut i, out float depth:SV_Depth):SV_Target {
    float t=gTime.x;
    float3 ro=float3(2.3-1.1*t,.8+ .15*t,-11.2+.5*t);
    float3 fw=normalize(float3(0,-.15,0)-ro);
    float3 rt=normalize(cross(float3(0,1,0),fw)), up=cross(fw,rt);
    float2 uv=float2(i.uv.x*2-1,1-i.uv.y*2);
    float lens=max(.43,.60/max(gTime.w,.25));
    float3 rd=normalize(fw+lens*(uv.x*gTime.w*rt+uv.y*up));
    float travel=.05; bool hit=false;
    [loop] for(int k=0;k<64;k++) {
        float d=machine(ro+rd*travel);
        if(d<.002) {hit=true;break;}
        travel+=max(d*.85,.001);
        if(travel>35)break;
    }
    float3 col=float3(.008,.013,.018); depth=0;
    if(hit) {
        float3 p=ro+rd*travel; float2 e=float2(.003,0);
        float3 n=normalize(float3(machine(p+e.xyy)-machine(p-e.xyy),
            machine(p+e.yxy)-machine(p-e.yxy),machine(p+e.yyx)-machine(p-e.yyx)));
        float lit=saturate(dot(n,normalize(float3(-.5,.8,-.7))));
        col=float3(.32,.30,.24)*(.16+.72*lit);
        col+=float3(.03,.13,.11)*pow(1-saturate(dot(n,-rd)),3);
        if(p.y < -2.92 && p.z < -.7 && n.y>.5) {
            float2 key=frac(float2(p.x*3.4,p.z*4.0));
            float gap=step(.14,key.x)*step(.14,key.y);
            col*=lerp(.3,1.25,gap);
        }
        depth=saturate(.05/(travel*dot(rd,fw)));
        if(p.z<-.38 && abs(p.x)<3.53 && abs(p.y-.50)<2.51) {
            VSOut screen=i;
            screen.uv=float2(p.x/7.06+.5,.5-(p.y-.50)/5.02);
            col=bootRaster(screen).rgb*1.25;
        }
    }
    return float4(col,1);
}
