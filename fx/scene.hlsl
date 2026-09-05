// Shot 05 - CATHEDRAL / ORGAN HALL.
//
// The one room in the demo that IS an organ, and it gets five seconds under
// the cold open with the camera barely moving - 1.15 units per second down a
// nave whose key light stays 74 units ahead forever. A push that never
// arrives is a still frame unless the ROOM moves, so everything here that
// reads is either built out of the bay rhythm the camera slides past, or it
// is animated on gTime.x on its own clock:
//
//   the arcade      real arches spanning every bay, so the colonnade is an
//                   arcade and not a row of posts. It is what turns the push
//                   into travel: arches pass overhead, one per bay.
//   the aisle glass tall leaded lancets in the outer wall, one per bay,
//                   seen THROUGH the arcade. A slow wave of brightness runs
//                   down the row, and the whole rank breathes on gSync.y.
//   the aisle light cool daylight pooling in the side aisles under those
//                   windows, against the warm key down the axis. The band it
//                   fills drifts vertically as if the sun were moving.
//   the organ       a rank of pipes on a gallery at |x| = 13.6, running the
//                   length of the hall behind the arcade, tips lit by
//                   gVoice.z. The organ is playing alone; the pipes should
//                   know that.
//   the rose        the light at the end of the nave is now a rose window
//                   with tracery, an oculus and a shimmer, still a bright
//                   disc dead centre so the MATCH CUT still has its shape.
//   the lamps       three lamps on chains down the axis, swaying on their
//                   own periods. Pure parallax: they are what tells you the
//                   camera is moving at all.
//   the floor       flagstones, and the key light smeared the length of the
//                   polished stone. The eye sits 6.5 above the floor on this
//                   shot, so that reflection is a third of the frame.
//
// NOTHING in here multiplies the whole picture by an audio envelope. Every
// music-driven term is base + k*s, so no floor ever drops out.
//
// Everything is [loop], never [unroll]. An unrolled march is the one thing
// that would blow the executable size out on its own.
//
// The volumetric is deliberately built out of LOW frequencies only. March
// steps in the open nave are five or six units long; anything with detail
// finer than that would flicker as the camera pushed through it. The
// per-bay rhythm you see in the air is a shallow 30% modulation on a smooth
// lobe - the sharp per-bay detail lives in the window SURFACES, where there
// is no sampling problem at all.

cbuffer Scene : register(b0)
{
    float4 gTime;   // x time, y beat, z shot fade, w aspect (w/h)
    float4 gCam;    // xyz eye, w tan(vfov/2)
    float4 gDir;    // xyz look direction, w roll
    float4 gTune;   // per shot knobs
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

// ---- the per-shot dials, decoded once at the top of main() ---------------
//
// gTune.x  the arcade.     bay pitch and column proportion. 0 gives 13 unit
//                          bays and fat 1.3 columns; 1 gives 8 unit bays,
//                          slimmer columns and finer fluting. Everything
//                          that repeats down the nave - arches, ribs,
//                          windows, the shafts in the air - follows the bay,
//                          so this one float relays the whole hall.
// gTune.y  the organ loft. -0.6 and below deletes the pipe rank and its
//                          gallery outright and you get a bare hall; 0 is a
//                          medium rank; +0.4 a full one with a tall skyline.
// gTune.z  the air.        haze, fog density, how much volumetric there is.
// gTune.w  the glass.      stained glass brightness, how much daylight pools
//                          in the aisles, the rake of the shafts, and the
//                          spoke count of the rose window (8 to 16).
static float sBay    = 13.0;
static float sBayInv = 0.076923077;
static float sColR   = 1.30;
static float sFlute  = 18.0;
static float sLoft   = 0.60;
static float sSpread = 0.55;

// ---- distance field ------------------------------------------------------

float vmax3(float3 v) { return max(v.x, max(v.y, v.z)); }

float sdBox(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(vmax3(q), 0.0);
}

float sdBox2(float2 p, float2 b)
{
    float2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// One column, centred on the origin, standing on the floor.
float column(float3 p)
{
    float2 q = p.xz;
    float  d = length(q) - sColR;
    d += 0.055 * sin(atan2(q.y, q.x) * sFlute);   // flutes
    d = max(d, p.y - 13.2);                       // stop under the capital
    d = min(d, sdBox(p - float3(0.0, -5.3, 0.0), float3(sColR + 0.65, 0.75, sColR + 0.65)) - 0.10);
    d = min(d, sdBox(p - float3(0.0, 13.0, 0.0), float3(sColR + 0.80, 0.85, sColR + 0.80)) - 0.14);
    return d;
}

float map(float3 p)
{
    float d = p.y + 6.0;                        // floor

    // Walls, and a barrel vault springing from y = 12. Below the spring
    // line the max() collapses this to a flat wall at |x| = 16.5.
    float2 v  = float2(p.x, max(p.y - 12.0, 0.0));
    float  lv = length(v);
    d = min(d, 16.5 - lv);

    // Two colonnades, repeated down the nave. cz is zero AT a column.
    float3 c = p;
    c.x = abs(c.x) - 10.0;
    c.z = frac(p.z * sBayInv + 0.5) * sBay - sBay * 0.5;
    d = min(d, column(c));

    // A transverse rib over each bay, on the column line. Without them the
    // vault is one smooth surface that takes the fill light evenly and reads
    // as a flat grey ceiling rather than as a curve. It reuses lv, which is
    // the same length() the wall already paid for.
    d = min(d, max(15.75 - lv, abs(c.z) - 0.62));

    // A ridge rib along the crown, running the length. It is the only line
    // in the room that points where the camera is going, and on a five
    // second push down the axis that is most of the composition.
    d = min(d, max(15.80 - lv, abs(p.x) - 0.50));

    // THE ARCADE. A semicircular arch spanning each bay between the columns,
    // springing just above the capitals. Below the springing the same
    // expression collapses to a 0.62 shaft standing exactly at the column
    // centres, which is buried inside the columns and costs nothing.
    {
        float  ax = abs(p.x) - 10.0;
        float  az = frac(p.z * sBayInv) * sBay - sBay * 0.5;   // zero MID bay
        float2 rq = float2(az, max(p.y - 13.9, 0.0));
        float  ring = length(rq) - sBay * 0.5;
        d = min(d, length(float2(ring, ax)) - 0.62);
    }

    // THE ORGAN. A rank of pipes on a gallery behind the arcade, heights
    // walked by a golden-ratio sequence so the skyline reads as random
    // without a single transcendental. The 0.65 is a deliberate
    // underestimate: neighbouring cells have different heights, which breaks
    // the Lipschitz bound near a tip, and marching short is cheaper than
    // marching a punched-through pipe.
    if (sLoft > 0.02) {
        float ax = abs(p.x) - 13.60;
        float pu = p.z * 1.0526316;                    // period 0.95
        float g  = frac(floor(pu) * 0.61803399 + 0.137);
        float pz = (frac(pu) - 0.5) * 0.95;
        float top = 15.40 + (2.20 + 2.40 * sSpread) * g;

        float pipe = length(float2(ax, pz)) - 0.32;
        pipe = max(pipe, p.y - top);
        pipe = max(pipe, 13.95 - p.y);

        float ledge = sdBox2(float2(ax, p.y - 13.55), float2(1.15, 0.40)) - 0.08;
        d = min(d, min(pipe * 0.65, ledge));
    }

    return d;
}

// Tetrahedral, not central-difference. The room got two new solids this
// pass and map() is inlined once per tap, so four taps instead of six is
// twenty percent off the compiled blob for a normal nobody can tell apart.
float3 mapNormal(float3 p)
{
    const float e = 0.0022;
    float3 k = float3(1.0, -1.0, 1.0);
    return normalize(k.xyy * map(p + k.xyy * e) +
                     k.yyx * map(p + k.yyx * e) +
                     k.yxy * map(p + k.yxy * e) +
                     k.xxx * map(p + k.xxx * e));
}

float softShadow(float3 ro, float3 lightPos)
{
    float3 toLight = lightPos - ro;
    float lightDist = length(toLight);
    float tMax = min(55.0, lightDist);
    float res = 1.0, t = 0.35;
    if (tMax <= t) return res;
    float3 rd = toLight / lightDist;
    [loop] for (int i = 0; i < 24; i++) {
        // Test before map(): an overshooting step must not sample past the light.
        if (t >= tMax) break;
        float h = map(ro + rd * t);
        if (h < 0.002) return 0.0;
        res = min(res, 11.0 * h / t);
        t  += clamp(h, 0.12, 2.5);
    }
    return saturate(res);
}

// Cheap ambient occlusion: how much of the field is nearby along the normal.
float occlusion(float3 p, float3 n)
{
    float o = 0.0, s = 1.0;
    [loop] for (int i = 0; i < 5; i++) {
        float d = 0.10 + 0.28 * float(i);
        o += (d - map(p + n * d)) * s;
        s *= 0.62;
    }
    return saturate(1.0 - 1.4 * o);
}

// ---- shading -------------------------------------------------------------

float4 main(VSOut i, out float depth : SV_Depth) : SV_Target
{
    depth = 0.0;   // far, under reversed Z

    // ---- dials ----
    float a  = saturate(gTune.x);
    sBay     = 13.0 - 5.0 * a;
    sBayInv  = 1.0 / sBay;
    sColR    = 1.30 - 0.42 * a;
    sFlute   = 18.0 + 10.0 * a;
    sLoft    = saturate(0.60 + gTune.y);
    sSpread  = saturate(0.55 + gTune.y);

    float air    = saturate(0.55 + gTune.z);
    float glass  = saturate(0.70 + gTune.w);
    float spokes = 8.0 + floor(glass * 8.0);
    float tilt   = 0.42 + 0.55 * glass;          // rake of the daylight
    float drift  = gTime.x * 0.020 * (0.4 + air);
    // The sun, moving. It is the slowest thing in the demo on purpose: over
    // five seconds it lifts the lit band on the aisle wall by about a metre,
    // which you do not see happen but do see the result of.
    float sunTop = 12.6 + 1.7 * sin(gTime.x * 0.155);

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
    float3 r2 = rt * cr + up * sr;
    float3 u2 = up * cr - rt * sr;
    float3 ro = gCam.xyz;
    float3 rd = normalize(fw + (uv.x * r2 + uv.y * u2) * gCam.w);

    // The light at the end of the nave, and a much dimmer one over the
    // camera so the nearest columns are not pure silhouette. Inverse square
    // over 70 units eats almost everything, so the key is genuinely huge.
    float3 lp  = float3(0.0, 15.0, ro.z + 74.0);
    float3 lp2 = float3(0.0, 16.0, ro.z + 4.0);
    // The organ breathing the key. Small on purpose: the key lights the far
    // end of a 74 unit nave, so this is a swell and not a flash.
    float  keyM = 1.0 + 0.25 * gVoice.z + 0.10 * gSync.x;

    float  t     = 0.0;
    float  shaft = 0.0;
    float  beams = 0.0;
    bool   hit   = false;

    [loop] for (int k = 0; k < 104; k++) {
        float3 p = ro + rd * t;
        float  h = map(p);
        float  w = min(h, 1.2);

        // Volumetric: distance from this sample to the light, accumulated.
        // It is what makes the hall read as full of air rather than vacuum.
        float dl = length(p - lp);
        shaft += 900.0 / (1.0 + dl * dl) * w;

        // DAYLIGHT IN THE AISLES, on every other step. Trace the sample back
        // along the rake to the outer wall and ask how far up that wall it
        // came from: below the lit band you get light, above it you get the
        // dark haunch of the vault. The per-bay lobe is only a 30% ripple on
        // top - see the note at the head of the file about step length.
        if ((k & 1) == 0) {
            float ax = abs(p.x);
            float s  = max(16.5 - ax, 0.0);
            float wy = p.y + tilt * s;

            float bw   = abs(frac(p.z * sBayInv + drift) - 0.5);
            float lobe = saturate(1.0 - bw * 2.2); lobe *= lobe;

            float pool = saturate((ax - 6.5) * 0.15)          // aisles, not the nave
                       * saturate((sunTop - wy) * 0.22)       // under the lit band
                       * saturate((p.y + 7.5) * 0.30);        // and off the floor

            // The air itself, turning over. Twenty unit wavelengths, so the
            // march resolves it however long the steps get.
            float swirl = 0.86 + 0.14 * sin(p.z * 0.29 + gTime.x * 0.47)
                                      * sin(p.y * 0.25 - gTime.x * 0.31);

            beams += pool * (0.70 + 0.30 * lobe) * swirl * w;
        }

        if (h < 0.0016 * t) {
            hit = true;
            // rd is normalised, so t is RAY LENGTH. Projecting it onto the
            // forward axis is what makes this VIEW depth - without the dot
            // the mesh punches through the field towards the screen edges
            // while looking perfectly correct dead centre.
            depth = saturate(0.05 / max(t * dot(rd, fw), 0.001));
            break;
        }
        t += h * 0.86;
        if (t > 190.0) break;
    }

    float3 col  = float3(0.0, 0.0, 0.0);
    float3 warm = float3(1.00, 0.74, 0.46);
    float3 cool = float3(0.30, 0.38, 0.56);
    float3 day  = float3(0.60, 0.71, 0.96);

    if (hit) {
        float3 p  = ro + rd * t;
        float3 n  = mapNormal(p);
        float3 ld = normalize(lp - p);
        float  dl = length(lp - p);

        float dif = saturate(dot(n, ld)) * (5200.0 * keyM / (1.0 + dl * dl));
        dif *= softShadow(p + n * 0.03, lp);

        float3 ld2 = normalize(lp2 - p);
        float  dl2 = length(lp2 - p);
        float  fil = saturate(dot(n, ld2)) * (260.0 / (1.0 + dl2 * dl2));

        float ao   = occlusion(p, n);
        float fres = pow(1.0 - saturate(dot(n, -rd)), 4.0);

        // ---- who am I standing on --------------------------------------
        // Position is a cheaper material id than carrying one through the
        // march, and in a room this rigid it is exact.
        float ax      = abs(p.x);
        float onFloor = saturate((-5.80 - p.y) * 40.0) * saturate(n.y * 4.0 - 2.0);
        float onPipe  = saturate((p.y - 14.00) * 6.0)
                      * saturate((ax - 13.05) * 8.0) * saturate((14.15 - ax) * 8.0);
        float onWall  = saturate((ax - 15.75) * 5.0) * saturate((12.20 - p.y) * 4.0);

        // Flagstones. A grid this coarse survives the CRT quantiser, which a
        // finer one would not.
        float3 alb = float3(1.0, 1.0, 1.0);
        {
            float2 fg = abs(frac(p.xz * 0.24) - 0.5);
            float grout = saturate(min(fg.x, fg.y) * 26.0);
            alb = lerp(alb, float3(0.90, 0.88, 0.85) * (0.55 + 0.45 * grout), onFloor);
        }
        alb = lerp(alb, float3(0.78, 0.80, 0.86), onPipe);   // tin, not stone

        col  = warm * dif * alb;
        col += cool * fil * 0.42 * alb;
        col += cool * ao * 0.075 * (0.35 + 0.65 * saturate(n.y));
        col += warm * fres * 0.30 * ao;
        col *= 0.35 + 0.65 * ao;

        // Specular. Polished stone and tin only; the rest of the hall is
        // rough and gets essentially none.
        {
            float3 hv  = normalize(ld - rd);
            float  spc = pow(saturate(dot(n, hv)), 60.0);
            col += warm * spc * (0.08 + 2.4 * onPipe + 1.4 * onFloor) * saturate(dif * 4.0);
        }

        // The key light smeared the length of the polished floor. The eye
        // sits 6.5 above the flagstones on the one shot this scene has, so
        // this reflection runs from the bottom of the frame to the horizon
        // and is doing as much work as the light itself.
        {
            float rk = saturate(dot(reflect(rd, n), ld));
            col += warm * onFloor * (pow(rk, 30.0) * 0.60 + pow(rk, 5.0) * 0.09)
                        * (0.55 + 0.45 * keyM);
        }

        // The pipes catching the organ. Fresnel on a cylinder is an edge
        // light, which is exactly how a rank of tin pipes reads at sixty
        // units - two bright verticals per pipe and nothing in between.
        col += float3(0.95, 0.80, 0.58) * onPipe * fres * ao * (0.30 + 0.85 * gVoice.z) * 1.6;

        // ---- THE AISLE GLASS -------------------------------------------
        // One tall leaded lancet per bay in the outer wall, centred MID bay
        // so it sits under an arch rather than behind a column. Emissive, so
        // it goes on after the ao multiply.
        {
            float bz = frac(p.z * sBayInv) * sBay - sBay * 0.5;
            float bi = floor(p.z * sBayInv);
            float wt = (p.y - 4.0) * 0.142857;                       // 0..1 up the window
            float hw = 0.185 * sBay * saturate(1.0 - saturate((wt - 0.58) * 2.4));

            float inw  = saturate((hw - abs(bz)) * 6.0)
                       * saturate(wt * 8.0) * saturate((1.0 - wt) * 8.0);
            float mull = saturate(abs(frac(bz * 1.30) - 0.5) * 7.0 - 0.55);   // mullions
            float tran = saturate(abs(frac(p.y * 0.95) - 0.5) * 7.0 - 0.55);  // transoms
            float cell = frac(floor(bz * 1.30) * 0.6180 + floor(p.y * 0.95) * 0.3125
                            + bi * 0.271);

            float3 tint = lerp(float3(0.98, 0.63, 0.28), float3(0.32, 0.57, 0.95),
                               frac(bi * 0.6180 + 0.31));
            tint = lerp(tint, float3(0.82, 0.91, 1.00), 0.35 * cell);

            // A wave of brightness running down the row, plus the mid band.
            // Both are base + k*s; the rank never goes out.
            float wave = 0.84 + 0.16 * sin(p.z * 0.085 - gTime.x * 0.62);
            float lum  = inw * mull * tran * (0.60 + 0.65 * cell)
                       * glass * (0.55 + 0.45 * gSync.y) * wave;

            col += tint * lum * onWall * 1.5;
        }
    }

    col += float3(1.00, 0.76, 0.50) * shaft * 0.0016 * (1.0 + 0.30 * gVoice.z);
    // The aisles, cool, against the warm key down the axis. w is capped at
    // 1.2 while steps in the open run to five units, so this accumulator
    // under-weights open space by roughly four to one - which is where the
    // 0.22 comes from and why it looks nothing like the 0.0016 above it.
    col += day * beams * 0.220 * (0.35 + 0.65 * glass) * (0.5 + 0.5 * air);

    // ---- THE ROSE WINDOW ---------------------------------------------------
    // The source at the end of the nave used to be a featureless blob. It is
    // still a bright disc dead centre - the MATCH CUT at bar 9 depends on
    // that - but now it has tracery, an oculus and a shimmer, and it swells
    // with the organ. The disc is a coherent region of screen, so the atan2
    // behind the rr < 1.25 test is paid for by almost no wave that is not
    // looking straight at it.
    {
        float3 tol  = lp - ro;
        float  proj = dot(tol, rd);
        if (proj > 0.0) {
            float perp = length(tol - rd * proj);
            float vis  = (proj < t) ? 1.0 : 0.0;

            col += float3(1.00, 0.80, 0.55) * (2.4 / (1.0 + perp * perp * 0.55))
                 * (proj < t ? 1.0 : 0.30) * (0.72 + 0.42 * keyM);

            if (rd.z > 0.05 && vis > 0.5) {
                float  tz = (lp.z - ro.z) / rd.z;
                float2 wp = float2(ro.x + rd.x * tz - lp.x, ro.y + rd.y * tz - lp.y);
                float  rr = length(wp) * 0.19231;              // window radius 5.2
                if (rr < 1.25) {
                    float an = atan2(wp.y, wp.x);
                    float sp = an * spokes * 0.15915494;
                    float sw = abs(frac(sp) - 0.5) * 2.0;
                    float rg = abs(frac(rr * 3.0) - 0.5) * 2.0;

                    float lead = saturate(sw * 5.0 - 0.45) * saturate(rg * 5.0 - 0.35);
                    float cell = frac(floor(sp) * 0.6180 + floor(rr * 3.0) * 0.317);
                    float disc = saturate((1.0 - rr) * 7.0);
                    float rim  = saturate(1.0 - abs(rr - 1.0) * 14.0);
                    float ocu  = saturate(1.0 - rr * 7.0);

                    float3 gc  = lerp(float3(1.00, 0.72, 0.36),
                                      float3(0.55, 0.72, 1.00), cell);
                    float  shm = 0.90 + 0.10 * sin(rr * 16.0 - gTime.x * 0.9 + an * 2.0);
                    float  bri = (0.58 + 0.52 * gVoice.z) * shm;

                    col += gc * disc * lead * (0.55 + 0.90 * cell) * bri * 2.1;
                    col += float3(1.00, 0.86, 0.62) * rim * 1.3 * bri;
                    col += float3(1.00, 0.92, 0.72) * ocu * 2.6 * bri;
                }
            }
        }
    }

    // ---- LAMPS ON CHAINS ---------------------------------------------------
    // Three of them down the axis, each on its own period so they never line
    // up. They are the parallax: at 1.15 units per second the columns barely
    // move, but a lamp passing the frame at eight units does.
    [loop] for (int L = 0; L < 3; L++) {
        float  fl   = float(L);
        float  lz   = ro.z + 17.0 + fl * sBay * 1.5;
        float  sway = 1.05 * sin(gTime.x * (0.52 + 0.09 * fl) + fl * 2.4);
        float3 lm   = float3(sway, 6.2 - 0.10 * abs(sway), lz);
        float3 tl   = lm - ro;
        float  pj   = dot(tl, rd);
        if (pj > 0.0 && pj < t) {
            float pe = length(tl - rd * pj);
            col += float3(1.00, 0.72, 0.38) * (0.42 / (1.0 + pe * pe * 9.0))
                 * (1.0 + 0.50 * gSync.z);
        }
    }

    // Exponential distance fog, so the far end of the nave dissolves.
    float fog = exp(-t * (0.0042 + 0.0060 * air));
    col = col * fog + float3(0.055, 0.050, 0.062) * (1.0 - fog) * (0.85 + 0.35 * glass);

    return float4(col * gTime.z, 1.0);
}
