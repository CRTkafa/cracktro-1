// Shot 30 - MONOLITH IN THE WHITE VOID.
//
// The contrast shot. Everything else in this demo is dark, so one shot is
// almost entirely white, and the subject is a black shape standing in it.
// The dither in the post pass does most of the work here: against a flat
// white field the Bayer pattern is the texture, which is exactly the
// Marathon loading screen look.
//
// It appears ONCE, at bar 82, on the loudest flash cut in the piece: a stab
// on beat one and then 1.36 s of real silence. So it was never a repetition
// problem, it was a nothing-happens problem - a rectangle standing still for
// two seconds, seen through a flash it did not use.
//
// What it does now is the only thing that moment wants: the stab HITS it.
// The monolith comes apart under the white of the flash, and by the time
// the flash has decayed the pieces are already slowing. They decelerate
// asymptotically, so by the middle of the shot everything has stopped dead
// and hangs in the air, unfallen, for the whole of the silence. The picture
// stops when the music does - it just stops somewhere the eye has never
// seen it stop before. The base stays planted, so it still reads as the
// monolith and not as a pile of boxes.
//
// gTune.x  monolith lean, and which way the break throws
// gTune.y  how far the horizon has been pushed back
// gTune.z  fracture the shot STARTS at (0 = enters whole, 1 = already open)
// gTune.w  strike delay in seconds (0 = struck on the cut, which is the cut
//          this shot is written against)
//
// gSync.w  a tremor in the pieces that dies out with the sound itself
// gVoice.y the solo, riding the dust ring the strike throws along the floor

cbuffer Scene : register(b0)
{
    float4 gTime;
    float4 gCam;
    float4 gDir;
    float4 gTune;
/* What the music is doing at this exact sample. The three bands
   each drive a different SCALE of thing - low for big slow shapes,
   mid for mid-sized ones, high for fine texture - so the image ends
   up with the same frequency structure as the music instead of just
   reacting to it. */
float4 gSync;   // x low, y mid, z high, w master peak
float4 gVoice;  // x guitar, y solo, z organ, w hat
};

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

#define NSLAB 9
#define NCHIP 26

// The sun sits BEHIND the monolith relative to the camera and low, so the
// shadow runs forward out of the frame towards the viewer instead of hiding
// behind the shape. On a white floor the shadow is the only other graphic
// element in the picture; it should not be pointing away from us.
static const float3 SUN = float3(-0.4870, 0.7190, 0.4953);   // normalised

// Where the monolith is cut. Deliberately uneven - equal bands read as a
// stack of pancakes, uneven ones read as something that broke.
static const float kEdge[NSLAB + 1] = {
    0.000, 0.082, 0.171, 0.268, 0.352, 0.463, 0.576, 0.701, 0.848, 1.000
};

// Three more of them, standing out in the haze. They are almost entirely
// fogged out - a tenth of a stop each - and that is the point: they give
// the void a scale, so the white is a distance and not a backdrop.
static const float4 kFar[3] = {
    float4(-46.0,  70.0, 2.30, 20.0),   // x, z, half width, height
    float4( 74.0, 138.0, 3.40, 34.0),
    float4(-96.0, 232.0, 2.90, 22.0)
};

static float4 gSA[NSLAB];   // xyz: piece centre in monolith space, w: half height
static float4 gSB[NSLAB];   // cos/sin of its two tumble angles
static float3 gBmin, gBmax; // world box that contains every piece
static float3 gCmin, gCmax; // and one that contains every chip
static float  gLeanS, gLeanC;
static float  gA;           // how far the break has got. 0 whole, 1 open

float sdBox(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Slab test against an axis aligned box. Used to BOUND the raymarch rather
// than to draw anything: the pieces occupy a small part of the frame, so
// most pixels never take a march step at all, and the shader ends up
// cheaper than the one box version it replaces despite carrying nine.
bool hitAABB(float3 o, float3 d, float3 bn, float3 bx, out float t0, out float t1)
{
    float3 inv = 1.0 / (d + 1e-9);
    float3 a = (bn - o) * inv;
    float3 b = (bx - o) * inv;
    float3 lo = min(a, b), hi = max(a, b);
    t0 = max(max(lo.x, lo.y), lo.z);
    t1 = min(min(hi.x, hi.y), hi.z);
    return t1 > max(t0, 0.0);
}

/* ---- the break -------------------------------------------------------
   Everything about a piece depends only on constants and on uniforms, so
   it is solved once per pixel here and the marcher just reads it. Doing it
   inside map() would put nine normalize() and eighteen sincos inside a
   sixty step loop, which is the difference between a shot and a stall. */
void setupSlabs(float A, float trem, float ts)
{
    gLeanS = sin(gTune.x * 0.14);
    gLeanC = cos(gTune.x * 0.14);

    [unroll] for (int k = 0; k < NSLAB; k++) {
        float e0 = kEdge[k], e1 = kEdge[k + 1];
        float cy = (e0 + e1) * 4.6 - 4.6;     // band centre, monolith space
        float hy = (e1 - e0) * 4.6;           // and its half height

        // R3 low discrepancy, so nine pieces are well spread without a
        // hash and without a table to maintain.
        float3 r = frac(float3(0.7548776, 0.5698402, 0.3819660) * (float(k) + 2.0));

        // Thrown outward and slightly up. The lean biases the throw, so a
        // monolith that leans is one that comes apart the way it leans.
        float3 dir = normalize(float3((r.x - 0.5) * 2.00 + 0.55 * gTune.x,
                                      (r.y - 0.18) * 0.80,
                                      (r.z - 0.5) * 2.00) + float3(0.0, 0.02, 0.0));

        // The bottom of the shape barely moves and does not turn AT ALL.
        // What is left standing is what keeps this readable as the monolith
        // rather than as a pile of boxes - and a stump that spun in place
        // would both look wrong and swing geometry down through the floor,
        // so the hold gates the tumble exactly as it gates the throw.
        float hold = smoothstep(-0.02, 0.30, e0);
        float spd  = (0.55 + 2.35 * r.z) * hold;

        // A tremor that lives and dies with the sound, not with the clock.
        // Three centimetres of it - a vibration, never a flash.
        float wob = sin(ts * 26.0 + float(k) * 2.1) * trem * 0.035 * hold;

        float3 c = float3(0.0, cy, 0.0) + dir * (A * spd + wob);

        float a = (r.x - 0.5) * 2.10 * A * hold;
        float b = (r.y - 0.5) * 1.55 * A * hold;

        gSA[k] = float4(c, hy);
        gSB[k] = float4(cos(a), sin(a), cos(b), sin(b));
    }

    /* The bound is fitted to the exact swept extent of the nine oriented
       pieces with about fifteen percent to spare, because it is doing two
       jobs at once: a bound that clips is geometry that silently vanishes,
       and a bound that is loose is march steps spent on empty white. */
    gBmin = float3(-(1.55 + 2.60 * A), -0.50, -(1.80 + 1.95 * A));
    gBmax = float3(  1.55 + 2.60 * A,   9.60 + 1.70 * A,  1.80 + 1.95 * A);

    // The chips throw much further than the pieces do, and twenty six
    // analytic spheres is the one cost this shader pays on every single
    // pixel. Same trick: bound them, and the white two thirds of the frame
    // stops paying for debris it cannot see.
    gCmin = float3(-(1.20 + 6.60 * A), 0.50, -(1.60 + 5.70 * A));
    gCmax = float3(  1.20 + 6.60 * A,  9.40 + 5.50 * A,  1.60 + 5.70 * A);
}

// Just the pieces. The floor is solved analytically, so it is not in here.
float mapObj(float3 p)
{
    float3 m = p - float3(0.0, 4.6, 0.0);
    m.xy = float2(m.x * gLeanC - m.y * gLeanS, m.x * gLeanS + m.y * gLeanC);

    float d = 1e9;
    [unroll] for (int k = 0; k < NSLAB; k++) {
        float3 q = m - gSA[k].xyz;
        float4 R = gSB[k];
        q.xy = float2(q.x * R.x + q.y * R.y, -q.x * R.y + q.y * R.x);
        q.yz = float2(q.y * R.z + q.z * R.w, -q.y * R.w + q.z * R.z);
        d = min(d, sdBox(q, float3(0.608, gSA[k].w - 0.012, 1.538)) - 0.012);
    }
    return d;
}

float3 objNormal(float3 p)
{
    const float2 e = float2(1.0, -1.0) * 0.0022;
    return normalize(e.xyy * mapObj(p + e.xyy) + e.yyx * mapObj(p + e.yyx) +
                     e.yxy * mapObj(p + e.yxy) + e.xxx * mapObj(p + e.xxx));
}

/* Is this surface one of the faces the strike MADE? The monolith is
   polished black on the four faces it was born with; a fracture is raw.
   Finding which piece we are on costs one extra pass of nine boxes at a
   single point, and it buys the whole reason to break something on camera -
   you have to be able to see the inside.

   The test is on the normal turned back into the piece's own frame, not on
   the position: a cut face is the one whose local normal is +-y. Testing
   position instead wraps a grey stripe around the top edge of every side
   face, which reads as a bug rather than as an exposed section. */
float cutFace(float3 p, float3 n)
{
    float3 m = p - float3(0.0, 4.6, 0.0);
    m.xy = float2(m.x * gLeanC - m.y * gLeanS, m.x * gLeanS + m.y * gLeanC);
    float3 nl0 = float3(n.x * gLeanC - n.y * gLeanS, n.x * gLeanS + n.y * gLeanC, n.z);

    float best = 1e9, ny = 0.0;
    [unroll] for (int k = 0; k < NSLAB; k++) {
        float4 R = gSB[k];
        float3 q = m - gSA[k].xyz;
        q.xy = float2(q.x * R.x + q.y * R.y, -q.x * R.y + q.y * R.x);
        q.yz = float2(q.y * R.z + q.z * R.w, -q.y * R.w + q.z * R.z);
        float d = sdBox(q, float3(0.608, max(gSA[k].w - 0.012, 0.02), 1.538)) - 0.012;
        if (d < best) {
            best = d;
            float2 t = float2(nl0.x * R.x + nl0.y * R.y, -nl0.x * R.y + nl0.y * R.x);
            ny = t.y * R.z + nl0.z * R.w;
        }
    }
    return smoothstep(0.55, 0.86, abs(ny));
}

// The fine stuff the strike threw off. Analytic spheres rather than SDF
// geometry: at this distance a chip is three to ten pixels across, so a
// silhouette is all of it, and twenty six of them cost less than one more
// box inside the march.
float4 chipAt(int k)
{
    float3 r  = frac(float3(0.7548776, 0.5698402, 0.3819660) * (float(k) + 5.0));
    float3 r2 = frac(float3(0.8191725, 0.6710436, 0.5497004) * (float(k) + 11.0));

    float3 rest = float3((r.x - 0.5) * 1.10, (r.y - 0.5) * 9.00, (r.z - 0.5) * 2.70);
    float3 dir  = normalize(float3(rest.x * 1.70 + (r2.x - 0.5) * 1.90,
                                   (r2.y - 0.15) * 1.20,
                                   rest.z * 0.90 + (r2.z - 0.5) * 1.90)
                            + float3(0.0, 0.03, 0.0));

    // Same rule as the pieces: what is low down stays where it was.
    float3 lp = rest + dir * (gA * (1.6 + 6.4 * r2.x)
                                 * smoothstep(-3.6, -1.8, rest.y));

    float3 w = float3(lp.x * gLeanC + lp.y * gLeanS,
                      4.6 - lp.x * gLeanS + lp.y * gLeanC,
                      lp.z);
    float rad = 0.035 + 0.095 * r.z * r.z;
    w.y = max(w.y, rad * 0.92);          // nothing sinks into the floor
    return float4(w, rad);
}

float shadowSlabs(float3 o, float3 d)
{
    float t0, t1;
    if (!hitAABB(o, d, gBmin, gBmax, t0, t1)) return 1.0;

    float t = max(t0, 0.05), te = min(t1, 90.0), res = 1.0;
    [loop] for (int i = 0; i < 28; i++) {
        if (t > te) break;
        float h = mapObj(o + d * t);
        if (h < 0.0022) return 0.0;
        res = min(res, 7.5 * h / t);
        t += clamp(h, 0.05, 2.0);
    }
    return saturate(res);
}

// Twenty six little shadows scattered across a white floor. This is most of
// what sells the freeze: without them the chips are stickers.
float chipShade(float2 g)
{
    float s = 1.0;
    [unroll] for (int k = 0; k < NCHIP; k++) {
        float4 c = chipAt(k);
        float lift = max(c.y, 0.0) / SUN.y;
        float2 gp  = c.xz - SUN.xz * lift;
        float rad  = c.w * (1.7 + 0.55 * lift);
        float dd   = length(g - gp);
        s *= 1.0 - 0.55 * (1.0 - smoothstep(rad * 0.25, rad, dd));
    }
    return s;
}

// Ambient contact under the hanging pieces. The sun shadow is directional
// and long; this is the short dark bloom directly beneath a mass, and it is
// the difference between a piece that hangs and a piece that was pasted on.
float slabContact(float2 g)
{
    float o = 1.0;
    [unroll] for (int k = 0; k < NSLAB; k++) {
        float3 lp = gSA[k].xyz;
        float2 w  = float2(lp.x * gLeanC + lp.y * gLeanS, lp.z);
        float  h  = max(4.6 - lp.x * gLeanS + lp.y * gLeanC, 0.35);
        float  rad = 1.5 + h * 0.42;
        o *= 1.0 - 0.30 * exp(-dot(g - w, g - w) / (rad * rad)) / (1.0 + h * 0.22);
    }
    return o;
}

float4 main(VSOut i) : SV_Target
{
    float2 uv = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
    // y is FLIPPED here on purpose. The fullscreen triangle emits
    // uv.y = 0 at the top of the screen, so i.uv*2-1 gives -1 up
    // there and the top of the frame ended up looking DOWNWARD -
    // the cathedral vault springs at y=+12 and was rendering in the
    // lower half, the monolith hung from the ceiling.
    uv.x *= gTime.w;

    float3 fw = normalize(gDir.xyz);
    float3 rt = normalize(cross(float3(0.0, 1.0, 0.0), fw));
    float3 up = cross(fw, rt);
    float  cr = cos(gDir.w), sr = sin(gDir.w);
    float3 ro = gCam.xyz;
    float3 rd = normalize(fw + (uv.x * (rt * cr + up * sr) +
                                uv.y * (up * cr - rt * sr)) * gCam.w);

    /* ---- the strike clock ----------------------------------------------
       1 - exp(-kt) is the whole idea. Velocity is highest at the instant of
       the hit and decays from there, so the break is violent under the
       flash and has visibly stopped by the time the silence is half over.
       The tiny linear term on the end means it never becomes a literal
       still frame - the pieces creep about six centimetres across the rest
       of the shot, which you do not see so much as fail to be bored by. */
    float ts = max(gTime.x - gTune.w, 0.0);
    float A  = saturate(gTune.z) + (1.0 - exp(-ts * 3.4)) + ts * 0.030;
    gA = min(A, 1.35);
    setupSlabs(gA, saturate(gSync.w), ts);

    // The void. Not pure white at the top, or there is nothing for the
    // dither to bite on. The last term is a one percent swell across the
    // whole field - far too small to see as a gradient, just enough to
    // walk the dither threshold so the white is alive rather than dead.
    float3 sky = lerp(float3(0.972, 0.972, 0.962),
                      float3(0.780, 0.800, 0.840),
                      saturate(rd.y * 1.6 + 0.10));
    sky += 0.009 * sin(rd.x * 2.7 + gTime.x * 0.30) * sin(rd.y * 3.3 - gTime.x * 0.21);

    float3 col = sky;
    float  tScene = 1e9;

    // ---- the floor, solved rather than marched ----
    float tG = (rd.y < -1e-5) ? (-ro.y / rd.y) : 1e9;
    if (tG < 0.0) tG = 1e9;

    // ---- the pieces, marched only inside their own bound ----
    float tObj = 1e9;
    {
        float t0, t1;
        if (hitAABB(ro, rd, gBmin, gBmax, t0, t1)) {
            float t  = max(t0, 0.05);
            float te = min(t1, min(tG, 300.0));
            [loop] for (int k = 0; k < 60; k++) {
                if (t > te) break;
                float h = mapObj(ro + rd * t);
                if (h < 0.0010 * t) { tObj = t; break; }
                t += h;
            }
        }
    }

    if (tObj < 1e8) {
        float3 p  = ro + rd * tObj;
        float3 n  = objNormal(p);
        float  sh = shadowSlabs(p + n * 0.02, SUN);
        float  di = saturate(dot(n, SUN));

        // Polished black where the shape was born, raw grey where the stab
        // opened it. The grain is coarse on purpose: it has to survive a
        // seven step quantiser to be a texture rather than a smudge.
        float  cut = cutFace(p, n);
        float3 gp  = floor(p * 21.0);
        float  gr  = frac(sin(dot(gp, float3(12.9898, 78.233, 37.719))) * 43758.5453);
        float3 albedo = lerp(float3(0.030, 0.032, 0.038),
                             float3(0.400, 0.394, 0.380) * (0.72 + 0.50 * gr),
                             cut);

        // The void is a lit dome, so upward faces pick up a lot of it.
        float amb = 0.30 + 0.42 * saturate(n.y * 0.5 + 0.5);
        col = albedo * (amb + 0.95 * di * sh);

        // A white world puts a hard rim on a black edge. On the quantiser
        // this becomes a one pixel outline, which is exactly the look.
        float fres = pow(1.0 - saturate(dot(n, -rd)), 4.0);
        col += (0.13 + 0.10 * cut) * fres * float3(0.95, 0.96, 1.00);

        tScene = tObj;
    }
    else if (tG < 400.0) {
        float3 p = float3(ro.x + rd.x * tG, 0.0, ro.z + rd.z * tG);
        float2 g = p.xz;
        float  r = length(g);

        // Every chip shadow lands inside r = 18.8 and every contact bloom
        // inside r = 22, measured against the throw. Past that the floor is
        // clean white and there is nothing to compute.
        float sh = shadowSlabs(p + float3(0.0, 0.015, 0.0), SUN);
        if (r < 20.0) sh = min(sh, chipShade(g));

        /* The ground opened where it was hit. The crack FRONT races out on
           its own envelope and then halts, so for the first third of a
           second there is something travelling across the floor even after
           the pieces have slowed - a second thing with its own timing,
           which is what keeps a held shot from being one idea. */
        float front = 2.5 + 58.0 * (1.0 - exp(-ts * 4.6));
        float a = atan2(g.y, g.x);

        float u   = a * (9.0 / 6.28318) + sin(r * 0.21) * 0.55
                                        + sin(r * 0.065 + 1.7) * 0.85;
        float arc = abs(frac(u) - 0.5) * r * 0.698;          // ~world width
        float crack = 1.0 - smoothstep(0.045, 0.24 + r * 0.02, arc);

        float ru   = r * 0.155 + sin(a * 5.0) * 0.22 + sin(a * 2.0 + 0.9) * 0.15;
        float ring = abs(frac(ru) - 0.5) * 6.45;
        crack = max(crack, (1.0 - smoothstep(0.10, 0.42 + r * 0.02, ring)) * 0.55);

        crack *= 1.0 - smoothstep(front * 0.80, front, r);   // the front
        crack *= smoothstep(0.6, 2.2, r);                    // not under the stump
        crack *= saturate(1.0 - r / 150.0);

        // Keep the fracture front subordinate to the standing silhouette.
        // Near-black rings used to compete with every suspended slab.
        float3 albedo = lerp(float3(0.940, 0.940, 0.930),
                             float3(0.085, 0.088, 0.095), crack * 0.32);

        // Dust swept out along the front. Written base + k*voice so the
        // floor never drops out from under the ring - this is a local
        // eleven percent smudge, never a frame that changes brightness.
        float dust = exp(-abs(r - front) * 0.30);
        albedo *= 1.0 - 0.11 * dust * (0.55 + 0.45 * saturate(gVoice.y));

        if (r < 22.0) albedo *= slabContact(g);

        col = albedo * (0.20 + 0.90 * SUN.y * sh);
        tScene = tG;
    }

    // ---- the chips ----
    {
        float ct0, ct1;
        if (hitAABB(ro, rd, gCmin, gCmax, ct0, ct1) && ct0 < tScene) {
            [unroll] for (int c = 0; c < NCHIP; c++) {
                float4 ch = chipAt(c);
                float3 oc = ro - ch.xyz;
                float  b  = dot(oc, rd);
                float  cc = dot(oc, oc) - ch.w * ch.w;
                float  hh = b * b - cc;
                if (hh > 0.0) {
                    float tt = -b - sqrt(hh);
                    if (tt > 0.05 && tt < tScene) {
                        float3 cn = (ro + rd * tt - ch.xyz) / ch.w;
                        float  cd = saturate(dot(cn, SUN));
                        col = float3(0.045, 0.047, 0.053) * (0.34 + 0.90 * cd)
                            + 0.10 * pow(1.0 - saturate(dot(cn, -rd)), 4.0);
                        tScene = tt;
                    }
                }
            }
        }
    }

    // ---- the others, standing out in the haze ----
    [unroll] for (int f = 0; f < 3; f++) {
        float4 F = kFar[f];
        float t0, t1;
        if (hitAABB(ro, rd, float3(F.x - F.z, 0.0, F.y - F.z * 2.3),
                            float3(F.x + F.z, F.w, F.y + F.z * 2.3), t0, t1)
            && t0 > 0.0 && t0 < tScene) {
            col = float3(0.055, 0.058, 0.066);
            tScene = t0;
        }
    }

    // Aerial haze back into the void, so the ground has no visible end.
    // Fogging towards the sky rather than towards a constant is what makes
    // the horizon a seam you cannot find.
    if (tScene < 1e8) {
        // Clear foreground air preserves black faces through the bleach
        // quantiser. The old zero-distance haze lifted the subject about
        // 0.4 towards white; the remote monoliths still dissolve normally.
        float fog = 1.0 - exp(-max(tScene - 18.0, 0.0) * 0.021);
        col = lerp(col, sky, fog * (0.55 + 0.45 * gTune.y));
    }

    return float4(col * gTime.z, 1.0);
}
