// THE DRIVE.
//
// Looking forward through the windscreen of a car, at night, in the rain.
// This is the only shot in the demo that is an ordinary place, and that is
// its whole job: after a cathedral that cannot exist and a white void with
// nothing in it, a wet motorway at 2am is what gives the rest of the demo
// somewhere to be. It is also the shot everyone already knows, so it has to
// be the one everyone knows - two rows of sodium lamps running away to a
// point, wet tarmac holding them, a car ahead, and water on the glass.
//
// What the first half second has to say: black frame, a road under you, and
// two lines of amber lights converging dead centre. Nothing else. The
// composition is a one point perspective with the vanishing point on the
// horizon and the horizon just above the middle of the frame, so the road
// owns the bottom half and the lamps own the middle band. Getting the
// horizon above centre is a SHOT job, not a shader job: aim `at` below `eye`
// (see the rows in shots.h). The light is all practical - sodium overhead,
// your own headlights on the tarmac in front of you, and one pair of tail
// lights twenty metres ahead.
//
// There is no raymarch here and no SDF. Every solid in the frame is ONE
// ray/plane intersect - the road against y = 0, the guard rail and the
// treeline against x = k, the sign gantry and the vehicle ahead against
// z = k - and every light is a closed form angular distance from the ray to
// a segment. That makes the perspective exact right down to the vanishing
// point, where a marched version would be a mess of step artefacts. Nothing
// in it scales with resolution the way a march does.
//
// ==========================================================================
// T H R E E   D I F F E R E N T   R O A D S
// --------------------------------------------------------------------------
// The shot appears three times (shots.h: bar 12, beat 80.3, bar 83) and it
// used to be the same picture three times, because the only things gTune
// changed were how fast the ground scrolled and how far the streaks were
// pulled. The road itself - its width, its lane count, the spacing and the
// height of the lamp columns, what else was on it - was carved into static
// consts and could not move.
//
// It is all derived per shot now, and gTune.y is what derives it. The three
// rows hand this file rain = 0.20 / 0.45 / 0.70, which is the cleanest
// separator in the table, so rain doubles as HOW FAR OUT OF TOWN WE ARE:
//
//   bar 12   3 bars, fast, drifting: a lit four lane motorway. Lamps every
//            26 m on short columns, woodland right up against the fence,
//            oncoming headlights every forty metres, two vehicles ahead of
//            you, gantry signs. It is crowded, and it is meant to be - it is
//            the establishing shot and it is the busiest frame in the demo.
//
//   beat 80.3  ONE SECOND, mid abstraction: three lanes, taller columns 35 m
//            apart, the woodland thinning to scrub, heavier rain and two
//            wipers going. Half the traffic, twice the streak.
//
//   bar 83   4 bars, held, up from black, abstraction 0.9: two lanes on an
//            open moor. A lamp every 43 m on ten metre columns, nothing at
//            the roadside at all, one pair of oncoming lights a hundred
//            metres out, and the tarmac essentially gone. What is left is
//            long light, which is what the held note wants.
//
// So the three appearances differ in LAYOUT before they differ in anything
// else, and the post pass's per-section palette cannot flatten a layout.
// ==========================================================================
//
// THE VALUE LADDER. This shot is graded downstream by a ten step quantiser
// (post.hlsl: `steps = 10`), so it has ten values to work with and no more.
// Two things follow and they govern every constant below:
//
//   - anything over 1.0 is white, and it is white by WHOLE pixels, so a
//     coverage-antialiased edge whose fill is 5.0 antialiases to nothing.
//     The first version of this shader lit the lane paint to 4.9, which meant
//     the careful `stripe()` coverage below was thrown away on every line in
//     the frame and the road markings crawled like a 1994 demo;
//   - the whole picture has to LAND on those ten steps, in big deliberate
//     jumps, because half a step of separation is not a value, it is noise.
//
// Measured off a rendered frame, not estimated. This is the ladder:
//
//     sky, away from the lamps      0.02   (black, and it must be black)
//     treeline silhouette           0.03
//     road at 3 m, off the beam     0.16
//     road at 30 m, between lamps   0.22
//     road under a lamp             0.30
//     sign panel, lit               0.35 .. 0.75
//     road in the headlight lobe    0.45
//     lane paint, mid distance      0.45 .. 0.62
//     lane paint at the bumper      1.1    (blown, and it should be)
//     lamp halo                     0.15 .. 0.9
//     lamp core                     1.6 .. 2.4  (the only clipped thing)
//
// BLOCKING, AND IT IS NOT IN THIS FILE: post.hlsl multiplies the Bayer
// threshold, which spans +-0.469, by gGrade.x = 0.85 (gfx.c) and adds it to a
// luminance that is then quantised in steps of 1/10. That makes the dither
// FOUR quantiser steps wide. An ordered dither has to span exactly one step
// to preserve the mean; four steps is additive noise that saturate() then
// rectifies upward at the black end, so a scene value of 0.0 comes out of the
// tube as a 7-of-16 speckle reaching step 0.4, and the whole range 0.0 -> 0.35
// is compressed into an output range of 3.5:1. Every scene in the demo is
// rendering to a flat grey field. The fix is one line in post.hlsl -
// `float thr = ((kBayer[bi] + 0.5) / 16.0 - 0.5) / steps;` - or equivalently
// gfx.c's `pc.grade[0] = 0.85f` becoming `0.11f`. Until that lands, nothing
// in this file can make the shot read, and once it lands this ladder is what
// it lands on.
//
// gTune.x  speed        world units per second the road scrolls past
// gTune.y  rain         0 dry glass .. 1 downpour. ALSO the road itself:
//                       lane count, lamp pitch, column height, what is at
//                       the roadside, how much traffic there is
// gTune.z  abstraction  0 a road .. 1 pure streaks of light
// gTune.w  wet          how much the tarmac mirrors, 0 dry .. 1 flooded

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

// ---- the road, in metres -------------------------------------------------
// These are the REFERENCE numbers, and they are real on purpose: a lane is
// 3.5 m, a lantern hangs about 7 m up, and the eye sits 1.35 m off the deck.
// Guessing at them is what makes most synthwave roads read as a toy, because
// the spacing of the lamps against the width of the tarmac is the only cue
// the viewer has for how fast they are going.
//
// Everything derived from them is now a local in main() and moves per shot;
// these stay as the mid point that the shot knob is measured against.
static const float ROAD_W = 5.2;    // half width of the tarmac
static const float RAIL_X = 7.4;    // guard rail, just off the hard shoulder
static const float LAMP_X = 7.9;    // lamp columns, behind the rail
static const float LAMP_Y = 7.0;    // and the height of the lantern
static const float LAMP_S = 24.0;   // one lamp every 24 m, both sides

// ---- noise ---------------------------------------------------------------

float hash21(float2 p)
{
    float3 q = frac(float3(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return frac((q.x + q.y) * q.z);
}

float2 hash22(float2 p)
{
    float3 q = frac(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return frac((q.xx + q.yz) * q.zy);
}

float vnoise(float2 p)
{
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash21(i),                   hash21(i + float2(1.0, 0.0)), f.x),
                lerp(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), f.x),
                f.y);
}

// How much of a pixel a painted stripe covers: `d` is how far the surface
// point is from the centre of the stripe, `halfw` is half its width, and `w`
// is how much ground one pixel spans there. Both terms are needed.
//
// Using a plain smoothstep with a fwidth() width instead - the usual reflex -
// is what put a fan of hard wedges across the road in the first version of
// this shader. On a ground plane, one pixel at the bottom of the frame spans
// tens of metres, so the smoothstep's edges open up to tens of metres too and
// the lane line paints half the carriageway; and because a ground plane maps
// x onto a screen radial, the bands come out as wedges from the vanishing
// point. The second term is the fix: once the stripe is thinner than a pixel
// it FADES rather than widening, which is what a real line does.
//
// It is also used for the guard rail's vertical extent, which is the same
// problem stood on its end: a converging ribbon four pixels tall at 20 m and
// a quarter of a pixel tall at 300 m.
float stripe(float d, float halfw, float w)
{
    return saturate((halfw - d) / w + 0.5) * saturate(2.0 * halfw / w);
}

// A periodic or noisy detail is only worth evaluating while a pixel is
// smaller than its period. Past that it must go to its MEAN, not carry on
// sampling, or it turns into slow crawling blobs that the dither then
// amplifies. `foot` is the pixel footprint and `per` the detail's period,
// both in the same units.
float bandlimit(float foot, float per)
{
    return saturate(foot / per * 1.7 - 0.35);
}

// ---- lights --------------------------------------------------------------

// One light source, drawn as a glow around the closest approach of the ray
// to the SEGMENT A..B. That segment is the whole trick in this shader:
//
//   with B == A it is a point, and this draws a lamp;
//   stretch B away down the road and the same code draws the long exposure
//   streak that lamp would leave on film.
//
// So the abstraction knob does not cross-fade between two different shaders.
// It opens up a segment, and the road turns into light because the lights
// stop being lights. Nothing else has to change for it to be believable.
//
// Everything in here is branchless on purpose. It is the body of a loop that
// runs up to thirty eight times and every compare in it is a compare the
// whole warp pays for, including the lanes it does not apply to.
float lightSeg(float3 ro, float3 rd, float3 A, float3 B,
               float rad, float pixAng, float fogK)
{
    // Closest approach between the ray (unit rd) and the segment. Standard
    // line/line solve with the segment parameter clamped to 0..1.
    float3 v  = B - A;
    float3 w0 = ro - A;
    float  b  = dot(rd, v), c = dot(v, v), d = dot(rd, w0), e = dot(v, w0);

    // `den` is zero when the ray runs PARALLEL to the segment - which, for a
    // 34 m light trail lying down the road, is exactly what happens at the
    // vanishing point, the one place the streaks matter most. The original
    // guarded this with `(den > 1e-5) ? solve : 0.0`, and the result was that
    // every streak pinched back to a point in the centre of the frame. The
    // saturate already clamps the blow-up, so the guard only has to keep the
    // divide finite - and doing it this way also drops a cmp and a movc out
    // of the hot loop.
    float  tc = saturate((e - b * d) / max(c - b * b, 1e-6));

    float3 cp = A + v * tc;
    float  s  = max(dot(cp - ro, rd), 0.0);   // ray parameter at that point
    float  sq = max(s, 0.30);                 // and a safe version to divide by

    // Work in METRES at distance sq rather than in angles: one reciprocal
    // instead of three divides, and the clamp below reads as what it is.
    float perp = length(cp - (ro + rd * s));

    // Clamp the light's apparent radius to about a virtual pixel. A lamp two
    // hundred metres out is smaller than one pixel of a 360 line frame, and
    // if it is allowed to be it crawls and twinkles as the perspective moves
    // it - the one artefact that reads as "cheap shader" rather than as
    // "CRT". Giving it a floor and paying for it in brightness (k) is what a
    // real lens does, and it is the single most important line in the file
    // for how the far end of the lamp row behaves.
    float rw  = max(rad, pixAng * sq);
    float inv = 1.0 / rw;
    float k   = rad * inv;                    // energy lost to the clamp
    float x   = perp * inv;

    // A small hot core inside a soft halo, weighted towards the halo on
    // purpose: a tight bright point blows straight through the top of the
    // quantiser and comes back very nearly white, and the halo is what stays
    // amber and what survives the fog at three hundred metres.
    //
    // The halo's tail is QUARTIC, and that x^4 term is not a refinement - it
    // is the difference between this shot working and not working. A plain
    // 0.75/(1+0.85x^2) lobe still returns 5.5e-4 at forty radii out, which is
    // nothing until you remember this function runs thirty times per pixel
    // and every one of those lobes covers the whole frame. Summed, they put a
    // floor of 0.07 luminance over the entire picture - and 0.07 is a third
    // of a step on the post pass's ten step quantiser, so the sky stopped
    // being black and became a field of half-lit dither. The frame was amber
    // lamps on beige. With the quartic term the same tail is 1e-5, the sky
    // goes back to 0.01, and the dither has something to quantise.
    float x2   = x * x;
    float glow = exp(-x2 * 1.35) * 0.85 + 0.55 / (1.0 + x2 * (0.60 + x2 * 0.02));

    // saturate(s * 3.0) replaces an early `return 0` for lights behind the
    // windscreen. As a hard cut it threw away a passing lamp's ENTIRE streak
    // the instant its nearest point crossed the eye plane, which at 30 m/s is
    // a lamp popping out of frame every eight tenths of a second.
    return glow * k * exp(-s * fogK) * saturate(s * 3.0) / (1.0 + s * 0.0025);
}

// EVERY light in the shot goes through ONE loop and one inlined copy of
// lightSeg: both rows of lamps, the tail lights of the vehicles ahead, and
// the headlights of the traffic coming the other way.
//
// This matters more than it looks. Written the obvious way, as a function per
// kind of light called once for the direct pass and again for the reflection,
// fxc inlines that closest-approach solve eight times. Folding the side and
// the kind of light into index arithmetic costs a handful of selects per
// iteration and gets most of that back. Measured with fxc 10.0.26100:
// rolled, this shader is a 21 KB blob; with [unroll] forced on these two
// loops it is 61 KB, in an executable that wants to be 85 KB in total. The
// [loop] attribute is not decoration, and adding two more KINDS of light to
// the existing loop is nearly free where adding a second loop would not be.
//
// The index runs lamps first (two per rung, one each side), then the tail
// light entries, then two headlights per oncoming vehicle. Every group has
// an even length so `k & 1` is the left/right bit throughout.
//
// `lamps` is how many lamps ahead to walk; they are re-anchored to the camera
// every lampS, so the row is endless without the loop ever growing.
//
// Returns three channels, because the frame has exactly three colours of
// light in it and keeping them apart costs one select:
//   .x sodium amber   .y tail light red   .z oncoming headlight white
float3 lightPass(float3 ro, float3 rd, float zs, float camZ,
                 float4 lampP,   // x pitch, y column x, z lantern height, w radius
                 float4 carP,    // x world z of the lead car, y gap to the next,
                                 // z trail scale, w brake light lift
                 float4 oncP,    // x lane centre, y spacing, z anchor z, w trail
                 float trail, float pixAng, float fogK,
                 int lamps, int nCar, int nOnc)
{
    float3 sum   = float3(0.0, 0.0, 0.0);
    float  lampS = lampP.x;
    float  base  = floor((ro.z + zs) / lampS) * lampS - zs;
    int    nl    = lamps * 2;
    int    n     = nl + nCar + nOnc * 2;

    // The far end of the row. Because `base` re-anchors every lampS, the
    // last lamp in the loop sawtooths between (lamps-1)*lampS and one span
    // further out, which means WITHOUT this it appears from nothing at full
    // strength - a lamp switching itself on at the vanishing point every
    // eight tenths of a second. Fading the last span in costs three ops and
    // is what lets the fog stay as thin as it is.
    float zEnd = ro.z + float(lamps - 1) * lampS;

    // Where the oncoming stream is in its cycle. The nearest slot is the one
    // level with you or just past, so this also says how much of the FARTHEST
    // slot has arrived - same problem as zEnd, same three op fix.
    float oPh = frac((camZ - oncP.z) / oncP.y);

    [loop] for (int k = 0; k < n; k++) {
        int   kc   = k - nl;          // >= 0: a tail light
        int   ko   = kc - nCar;       // >= 0: an oncoming headlight
        bool  car  = (kc >= 0);
        bool  onc  = (ko >= 0);
        float side = ((k & 1) == 0) ? -1.0 : 1.0;

        // This rung of the lamp ladder, and its identity. `idx` is an integer
        // in WORLD space, not a loop counter, so a given lamp keeps the same
        // hash the whole way in: one lamp in twenty is dead, none of them is
        // quite as bright as its neighbour, and no two streaks are the same
        // length. That last one is what stops the abstract appearance from
        // being twenty six identical strokes.
        float  zl   = base + float(k >> 1) * lampS;
        float  idx  = floor((zl + zs) / lampS + 0.5);
        float2 h    = hash22(float2(idx * 1.37, side * 5.70 + 0.31));
        float  bulb = (0.72 + 0.56 * h.x) * step(0.052, h.y);
        float  jit  = 0.55 + 0.90 * h.y;

        float ci  = float(max(kc, 0) >> 1);      // which vehicle ahead
        float vi  = float(max(ko, 0) >> 1);      // which one coming at us

        // The streak trails behind where the light is now, which from inside
        // the car means it reaches away from you, towards the vanishing
        // point. That is the direction that makes the frame converge - and it
        // is the same direction for the oncoming traffic, whose trail is the
        // road it has already covered.
        float3 A = onc ? float3(oncP.x + side * 0.86, 0.70, oncP.z + vi * oncP.y)
                 : (car ? float3(side * 0.98, 0.80, carP.x + ci * carP.y)
                        : float3(side * lampP.y, lampP.z, zl - trail * jit * 0.25));
        float  r  = onc ? 0.30 : (car ? 0.20 : lampP.w);
        float  tl = onc ? oncP.w : (car ? trail * carP.z : trail * jit);
        float3 B  = A + float3(0.0, 0.0, tl);

        float g  = lightSeg(ro, rd, A, B, r, pixAng, fogK);
        float ef = saturate((zEnd - zl) * (1.0 / lampS));

        // A dipped beam is aimed away from you and drops off HARD as it comes
        // level - which is both what a real headlight does and the reason a
        // car every second and a half is not a flash. The photosensitivity
        // budget is two qualifying transitions per second and this shot
        // already spends most of it on the lamp row.
        float dOn = oncP.z + vi * oncP.y - camZ;
        float ow  = saturate(float(nOnc - 1) - vi + oPh)
                  * (0.20 + 0.80 * saturate((dOn - 5.0) * 0.045));

        sum += onc ? float3(0.0, 0.0, g * ow)
             : (car ? float3(0.0, g * (1.0 + carP.w), 0.0)
                    : float3(g * ef * bulb, 0.0, 0.0));
    }
    return sum;
}

// ---- overhead signage ----------------------------------------------------
//
// A sign gantry striding the carriageway every gsp metres. It is one
// ray/plane intersect against z = const, and every extent of every box is a
// stripe() - never a pair of half planes. That is not fussiness. A product
// of two opposing half planes does NOT go to zero when the box it bounds
// falls below a pixel: both terms tend to 0.5 and the box settles at a
// quarter coverage forever. A 0.72 m beam is sub-pixel from about 220 m out,
// so half planes would leave a permanent grey ladder hanging across the
// vanishing point - the same failure the guard rail was rewritten to avoid.
// stripe()'s second term is what retires each member on its own.
//
// It is the only thing in the frame with a HORIZONTAL edge in it, and that is
// why it is here. Everything else in the shot converges on the vanishing
// point; a beam crossing the top of the picture and sweeping up out of frame
// is the one event that says how fast the road is actually moving.
//
// Returns rgb in .xyz and coverage in .w, plus the marker lamps on the beam
// ends, which are additive and have to survive outside the coverage.
float4 gantryHit(float3 ro, float3 rd, float D, float pixAng, float gw,
                 float fogK, float abk, float seed, out float3 glow)
{
    float rz = max(rd.z, 0.05);
    float tt = D / rz;
    float x  = ro.x + rd.x * tt;
    float y  = ro.y + rd.y * tt;
    float w  = max(tt * pixAng, 0.006);

    // Facing us, so the ray only reaches it going forward, and it is gone
    // long before it can be behind us: at 6 m the beam is already past the
    // top of a 31 degree frame.
    float front = saturate(rd.z * 8.0 - 0.2) * saturate((D - 6.0) * 0.22);

    float beam = stripe(abs(y - 6.05), 0.36, w) * stripe(abs(x), gw, w);
    // The legs start above the guard rail so the two never argue about which
    // of them owns the bottom eight pixels of the verge.
    float leg  = stripe(abs(abs(x) - gw), 0.20, w) * stripe(abs(y - 3.65), 2.80, w);

    // The sign itself hangs on the left half of the beam, which keeps the
    // vanishing point - the whole reason the shot exists - clear.
    float pcx = -2.50, pcy = 4.45, phx = 2.20, phy = 1.15;
    float py0 = pcy - phy;
    float pan = stripe(abs(x - pcx), phx, w) * stripe(abs(y - pcy), phy, w);
    float ins = stripe(abs(x - pcx), phx - 0.17, w) * stripe(abs(y - pcy), phy - 0.17, w);

    // Three lines of legend, each a different length. It is not text and it
    // does not have to be: at the distance a gantry is legible from, a road
    // sign IS three ragged white bars on green.
    float row = floor((y - py0) * 3.4);
    float rf  = frac((y - py0) * 3.4);
    float len = (phx * 2.0 - 0.90) * (0.34 + 0.62 * frac(seed * 5.17 + row * 0.413));
    float bx0 = pcx - phx + 0.45;
    float bar = smoothstep(0.16, 0.30, rf) * smoothstep(0.64, 0.50, rf)
              * stripe(abs(x - bx0 - len * 0.5), len * 0.5, w)
              * ins * (1.0 - saturate(w * 3.2));

    // Retroreflective sheeting: it is only bright because your own headlights
    // are pointed at it, so it comes up out of the dark as it arrives. The
    // gain is deliberately shallow. Sheeting really is that bright, but a
    // panel that reaches 1.1 at thirty metres is a white slab arriving in the
    // frame every four seconds, and the ten step quantiser has nowhere to put
    // it: at 0.9 it lands on the top step legibly instead of clipping.
    float head = exp(-D * 0.042) * 0.55 + 0.05;

    // NOT multiplied by the coverage - `cov` below already carries it, and
    // doing both is what makes an antialiased edge come back a step dark.
    float3 rgb = float3(0.26, 0.26, 0.29) * head * 1.7;
    rgb  = lerp(rgb, float3(0.075, 0.185, 0.115) * (0.30 + head * 2.1), pan);
    rgb += float3(0.92, 0.94, 0.90) * (bar + (pan - ins) * 0.55) * (0.14 + head * 1.9);

    float cov = saturate(max(max(beam, leg), pan)) * front * (1.0 - abk * 0.88);

    float fg = 1.0 - exp(-tt * fogK * 1.4);
    rgb = lerp(rgb, float3(0.016, 0.019, 0.032) * (1.0 - abk * 0.94), fg);

    // The two amber markers on the ends of the beam, and - once the shot has
    // abstracted far enough that the steel is gone - the beam itself, which
    // is by then just a bar of light lying across the top of the frame.
    float2 m1 = float2(x - gw, y - 6.45);
    float2 m2 = float2(x + gw, y - 6.45);
    glow = float3(1.00, 0.66, 0.26)
         * (exp(-dot(m1, m1) * 2.6) + exp(-dot(m2, m2) * 2.6)) * front
         * exp(-tt * fogK * 0.9)
         + float3(1.00, 0.72, 0.34) * beam * front * abk * 0.42;

    return float4(rgb, cov);
}

// ---- water on the glass --------------------------------------------------

// Returns a refraction offset in camera space, and how much of the frame is
// covered by water. The drops are NOT painted over the picture: they bend
// the ray before anything is traced, which is what a lens of water on a
// windscreen actually does. It costs nothing extra and it means the lamps
// smear through every drop correctly, including the ones behind you.
float2 glassWater(float2 g, float t, float amt, out float film)
{
    float2 o = float2(0.0, 0.0);
    film = 0.0;
    if (amt < 0.01) return o;

    // Beads. One cell lookup, with the drop kept away from the cell edges so
    // it never straddles a boundary and there is nothing to fix up. Five cells
    // across the frame, not twenty: a drop has to be six or eight virtual
    // pixels wide before the dither leaves anything of it, and anything finer
    // comes back as speckle that reads as a dirty sensor.
    float2 p  = g * 5.2;
    float2 c  = floor(p);
    float2 h  = hash22(c + 3.71);
    float  live = step(1.0 - amt * 0.9, hash21(c * 1.37 + 9.1));
    float2 dc = c + float2(0.30, 0.30) + h * 0.40;
    float2 dv = p - dc;
    float  rr = 0.13 + 0.15 * h.x;
    float  dd = length(dv) / rr;
    float  m  = smoothstep(1.0, 0.70, dd) * live;
    o    += dv * (-0.045 / rr) * m;               // a drop inverts what is behind it
    film += m;

    // Runners: the drops that have joined up and are sliding down the glass,
    // one per column, each with a tail above it. These are what sell rain at
    // speed - a still field of beads reads as a dirty lens instead.
    float  colx = floor(g.x * 4.5);
    float2 hh   = hash22(float2(colx, 21.3));
    float  live2 = step(1.0 - amt * 0.85, hh.x);
    float  gx0  = (colx + 0.5) / 4.5;
    float  dx   = g.x - gx0;
    float  dy   = g.y - (1.35 - frac(hh.y + t * (0.16 + hh.x * 0.22)) * 2.9);
    float  band = exp(-dx * dx * 620.0) * live2;
    float  head = band * exp(-dy * dy * 500.0);
    float  tail = band * exp(-max(dy, 0.0) * 4.5) * step(0.0, dy) * 0.55;
    float  run  = head + tail;
    o    += float2(-dx * 20.0, 0.30) * run * 0.042;
    film += run;

    return o * (0.45 + 0.55 * amt);
}

// ---- one instrument ------------------------------------------------------
// Returns .x the lit face, .y the bezel and its ticks, .z the needle. Two of
// these sit behind the wheel with only their top arcs above the dash line -
// which is all you ever see of your own instruments while you are driving,
// and it is what puts the camera inside the car rather than on a tripod
// strapped to the bumper.
float3 dial(float2 p, float r, float nd)
{
    // p.y grows UP the frame, so straight up is +y. Getting this sign wrong
    // sweeps the needle through the bottom of the dial, which is the half
    // that is behind the dash and never seen.
    float d = length(p);
    float a = atan2(p.x, p.y);               // 0 straight up, positive clockwise

    float face = smoothstep(r, r * 0.87, d);
    float ring = smoothstep(0.030, 0.012, abs(d - r * 0.94));

    // Ten ticks to the turn, and only on the outer band of the face.
    float tk   = abs(frac(a * (5.0 / 3.14159265)) - 0.5) * 2.0;
    float tick = smoothstep(0.74, 0.95, tk)
               * smoothstep(r * 0.95, r * 0.83, d) * smoothstep(r * 0.68, r * 0.76, d);

    // The needle is the distance to a ray from the centre, clamped short of
    // the bezel, so it has no tail sticking out the back of the pivot.
    float2 nv = float2(sin(nd), cos(nd));
    float  s  = clamp(dot(p, nv), 0.0, r * 0.80);
    float  nl = length(p - nv * s);
    float  ndl = smoothstep(0.024, 0.007, nl) * smoothstep(r * 1.02, r * 0.92, d);

    return float3(face, max(ring, tick), ndl);
}

// ---- the shot ------------------------------------------------------------

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

    float3 gx = rt * cr + up * sr;      // screen right, after roll
    float3 gy = up * cr - rt * sr;      // screen up, after roll

    // THE VERTICAL SENSE, AND IT WAS BACKWARDS.
    //
    // There used to be a `uv.y = -uv.y;` here, with a comment saying it was
    // what kept the tarmac under the horizon and the bonnet at the bottom
    // edge, "or the shot just reads as a mistake". It did the exact opposite:
    // it was the line putting the road on the CEILING.
    //
    // Measured, not argued. Rendering
    //     col = (rd.y > 0.0) ? blue : red;
    // and looking at the dumped frame put RED - the rays aimed DOWN, the ones
    // that hit the tarmac - across the TOP half of the picture, and the sky
    // across the bottom. The road, the lamp pools, the lane paint and the
    // guard rail were all being drawn above the horizon, upside down, and the
    // whole shot was a mirror of itself.
    //
    // It survived because this scene is nearly symmetrical about its own
    // horizon - two rows of lights converging on a point in the middle of the
    // frame look much the same either way up - and because the one element
    // that would have given it away instantly, the bonnet, is nearly black
    // and sat under a 2.39:1 matte in the only appearance that has one.
    // Putting a lit instrument cluster on the dash is what finally made it
    // obvious: the dials came out on the roof.
    //
    // fullscreen.hlsl emits uv.y = 0 at the TOP, and `uv` above is built as
    // 1 - i.uv.y*2, so uv.y is ALREADY +1 at the top and -1 at the bottom -
    // which is exactly what `gy` (world up, from cross(fw, rt)) wants, and
    // exactly what every 2D constant in this file was authored against: the
    // bonnet at uv.y < -0.66, the wiper pivot at -2.35 below the frame, the
    // runners on the glass sliding from +1.35 down to -1.55. Nothing needed
    // correcting. Deleting the flip makes the ray basis and the 2D layer
    // agree, and both of them right.
    float3 rd = normalize(fw + (uv.x * gx + uv.y * gy) * gCam.w);

    // The screen vertical the 2D layer works in: +1 at the TOP of the frame,
    // -1 at the BOTTOM. With the flip gone that is just uv.y, and the alias
    // is kept only so the wiper, the glass and the dash read as screen space
    // rather than as something to do with the ray.
    float sy = uv.y;

    float t     = gTime.x;
    float speed = gTune.x;
    float rain  = saturate(gTune.y);
    float ab    = saturate(gTune.z);
    // The knob is eased for everything that DESTROYS the road - the tarmac
    // going out, the paint turning neon, the rail going magenta - while the
    // light trails grow on the raw value. Linear on both, the first quarter
    // turn already had violet crash barriers, and the useful part of the
    // range (a real road whose lamps have just started to smear) was gone.
    float abk   = ab * ab;
    float wet   = saturate(gTune.w);
    float zs    = speed * t;                    // metres travelled this shot

    // ---- WHICH ROAD THIS IS ----------------------------------------------
    // See the header. `var` is the shot's place on the town-to-moor axis and
    // it is what makes the three appearances three different pictures rather
    // than three grades of the same one. Every number below used to be a
    // static const.
    float var    = saturate(rain * 1.45);          // 0.29 / 0.65 / 1.00
    float roadW  = lerp(7.40, 4.20, var);          // 6.5  / 5.3  / 4.2 m half width
    float railX  = roadW + 2.00;
    // The two lamp rows are the dominant SHAPE in the frame - a pair of
    // diagonals running out of the vanishing point - and the angle of those
    // diagonals is atan(lampY / lampX). Moving both, in opposite directions,
    // is what makes the three appearances different pictures rather than the
    // same picture at three exposures: 39 degrees on the motorway, 55 in the
    // middle, 65 out on the moor where the columns are tall and tight in.
    float lampX  = roadW + lerp(2.20, 1.40, var);  // 8.7  / 6.7  / 5.6
    float lampY  = lerp(5.20, 12.00, var);         // 7.2  / 9.6  / 12.0
    float lampS  = lerp(19.0, 43.0, var);          // 26   / 34.7 / 43 m pitch
    float lanes  = (var < 0.45) ? 4.0 : ((var < 0.85) ? 3.0 : 2.0);
    float dashP  = lerp(7.0, 13.0, var);           // and the dash pitch with it
    // Woodland right against the fence on the motorway, nothing at all on the
    // moor. The empty appearance is the one whose picture is made of light.
    float treeX  = railX + lerp(3.4, 9.0, var);
    // Real motorway planting is ten to fifteen metres, and it has to be: the
    // trees stand 5 m BEHIND the lamp columns, so at a 1.25 m eye anything
    // under about four metres never clears the horizon and the whole feature
    // renders as a two pixel smudge. The first version of this was nominally
    // 7.6 m and came out at 1.9 after its own modulation - 26 changed pixels
    // in a 1920x1080 frame, measured. Height, and gentler modulation with it.
    float treeH  = lerp(12.0, 1.2, var);           // 8.9 / 5.0 / 1.2
    float gsp    = lerp(110.0, 260.0, var);        // gantry spacing

    // How busy the road is. Straight off the speed, which is the other thing
    // the three rows disagree about (32 / 28 / 18), and which is also the
    // honest reason: nobody does thirty two on an empty moor.
    float traffic = saturate((speed - 14.0) * (1.0 / 16.0));   // 1.0 / .875 / .25
    // Clamped, so the loop bound below is provably constant however the shot
    // table is edited later: 26 lamp entries + 4 tail lights + 8 headlights.
    int   nOnc    = 2 + (int)clamp((speed - 16.0) * 0.14, 0.0, 2.0);   // 4 / 3 / 2
    int   nCar    = (traffic > 0.5) ? 4 : 2;                   // 2 / 2 / 1 ahead
    float oncSp   = lerp(150.0, 40.0, traffic);                // 40 / 54 / 122 m apart
    float oncSpd  = speed + 26.0;                              // closing rate
    float oncZ0   = ro.z - frac(oncSpd * t / oncSp) * oncSp;

    // gTime.y (beat) is hard-wired to 0.0f by drawScene() and gTime.z to 1.0f
    // - the post pass owns the shot fade via gGrade.w. The multiply by
    // gTime.z at the bottom is kept only because it is the documented
    // contract and the offline renderer may yet drive it.

    // ---- the wipers ------------------------------------------------------
    // A blade sweeping out and back from a pivot below the frame, and behind
    // it a band of glass that has just been scraped clear and is filling back
    // in. The refill is an approximation - it is keyed to how far a pixel is
    // from where the blade currently is rather than to a real per-pixel
    // memory of when it was last crossed - but at 360 lines and three seconds
    // a sweep, nobody can tell the difference, and a real one would need a
    // history buffer this engine does not have.
    //
    // The PERIOD is the rain knob now, and so is the blade count: at 0.20 it
    // is one blade on intermittent, four and a half seconds apart; at 0.70 it
    // is the pair of them going flat out every one and a half. That alone
    // makes the three appearances move at different rates, and a wiper is the
    // one clock in the frame the viewer already knows how to read.
    float wipeMul = 1.0, blade = 0.0;
    if (rain > 0.05) {
        float per = lerp(4.60, 1.55, rain);
        float u   = frac(t / per);
        float sw  = saturate(u / 0.45);
        float ph  = sin(sw * 3.14159265);

        float2 pv = float2(-0.10 * gTime.w, -2.35);
        float  a  = atan2(uv.x - pv.x, sy - pv.y);
        float  wb = lerp(-0.82, 0.88, ph);
        float  da = abs(a - wb);
        blade   = smoothstep(0.055, 0.014, da) * smoothstep(0.47, 0.44, u) * rain;
        wipeMul = lerp(saturate(0.10 + da * 1.6), 1.0, saturate((u - 0.45) / 0.45));

        // The passenger blade, in tandem. It only comes on once the rain is
        // heavy enough to warrant it, which is the second and third rows.
        if (rain > 0.33) {
            float2 pv2 = float2(1.05 * gTime.w, -2.28);
            float  a2  = atan2(uv.x - pv2.x, sy - pv2.y);
            float  wb2 = lerp(-0.94, 0.52, ph);
            float  da2 = abs(a2 - wb2);
            blade   = max(blade, smoothstep(0.052, 0.013, da2)
                                * smoothstep(0.47, 0.44, u) * rain);
            wipeMul = min(wipeMul,
                          lerp(saturate(0.10 + da2 * 1.6), 1.0,
                               saturate((u - 0.45) / 0.45)));
        }
    }

    float wfilm;
    // Screen space in, screen space out - and `gy` is the ray basis vector
    // for screen up, which is the same sense sy has, so the offset applies
    // with a plus.
    float2 refr = glassWater(float2(uv.x, sy), t, rain * wipeMul, wfilm);
    rd = normalize(rd + gx * refr.x + gy * refr.y);

    // One virtual pixel, in the same angular units lightSeg works in. The
    // frame is always 360 lines (gfx.c: VH), whatever the window is.
    float pixAng = 2.0 * gCam.w / 360.0;
    // Thin fog. The first version of this used ten times as much, on the
    // theory that a rainy night is murky, and it ate the lamp row four lamps
    // in - which took away the one thing the shot is about. Real sodium
    // carries for a kilometre in rain; the end of the row is now handled by
    // the per-lamp fade in lightPass rather than by drowning it.
    // Thicker out of town, where the rain is heavier. This sets how far down
    // the road you can see, which is a large-area change: it decides whether
    // the middle band of the frame is lifted or black.
    float fogK   = lerp(0.0042, 0.0105, var);

    // The vehicle ahead. Hoisted above BOTH light passes so the reflection
    // and the direct image agree about where it is - they did not before, and
    // a pair of tail lights whose reflection sits somewhere else is the kind
    // of thing nobody can name and everybody notices.
    //
    // It sits closer on the busy motorway and a long way off on the moor, and
    // it brakes: a slow, low duty pulse on the red, so that a held shot has
    // one event in it that is not the road going past.
    float carD  = lerp(16.0, 46.0, var);
    float carZ  = ro.z + carD + sin(t * 0.31) * 6.0;
    float brake = smoothstep(0.72, 0.97, sin(t * 0.83 + 1.7) * 0.5 + 0.5) * 0.9;
    // The solo is one held note through the third appearance, so hanging the
    // streak length on it means the picture breathes with the thing the edit
    // cut this shot for. base + k*s, never k*s.
    float trail = lerp(0.45, 34.0, abk) * (1.0 + 0.30 * gVoice.y);
    // A motorway lantern really is about three quarters of a metre across,
    // and using the real size is what finally made the row read: at a third
    // of that every lamp past the fourth one was a single dithered pixel.
    float lrad  = lerp(0.75, 1.05, ab) * (1.0 + rain * 0.22);

    float4 lampP = float4(lampS, lampX, lampY, lrad);
    float4 carP  = float4(carZ, 30.0, 0.5, brake);
    float4 oncP  = float4(-roadW * 0.52, oncSp, oncZ0, trail * 1.9 + 6.0);

    // ---- sky -------------------------------------------------------------
    // Almost nothing: a cold near-black, plus two warm bands - a tight one on
    // the skyline and a broad one up into the cloud. Sodium bouncing off low
    // cloud is most of what a night sky looks like from a motorway, it is the
    // only thing separating the horizon from the road before the lamps
    // arrive, and without it the top half of the frame is a flat field that
    // the dither turns into noise.
    float hy  = saturate(rd.y);
    float3 col = lerp(float3(0.022, 0.026, 0.046),
                      float3(0.005, 0.007, 0.019), saturate(rd.y * 2.8));
    // How much town there is beyond the treeline, and it is the single
    // largest-area difference between the three appearances: the sky is half
    // the frame. A lit motorway on the edge of somewhere sits under a real
    // sodium dome; the moor at bar 83 has nothing on the horizon at all, and
    // that emptiness is most of why the last appearance reads as arrival.
    float urb = lerp(1.90, 0.30, var);
    col += float3(0.19, 0.085, 0.024) * exp(-hy * 9.0) * 1.30 * urb;   // the skyline
    col += float3(0.13, 0.062, 0.024) * exp(-hy * 2.2) * 0.34 * urb;   // and the cloud
    col *= 1.0 - abk * 0.94;

    // ---- the roadside ----------------------------------------------------
    // A treeline beyond the fence, as a third ray/plane intersect - the same
    // solve as the guard rail, at a different x, and read as a SILHOUETTE
    // rather than as a surface. It costs two noise lookups and it is what
    // stops the upper half of the frame being an empty gradient: the lamps
    // now stand against something, and the horizon is a real horizon because
    // there is a mass on either side of it running to the same point.
    //
    // It also carries the biggest single difference between the three
    // appearances. Woodland at bar 12, scrub at bar 80, bare moor at bar 83.
    float sxr = (rd.x >= 0.0) ? 1.0 : -1.0;
    float rdx = max(abs(rd.x), 2e-4) * sxr;

    [branch] if (treeH > 0.4 && abk < 0.92) {
        float tT  = min((sxr * treeX - ro.x) / rdx, 4000.0);
        float yT  = ro.y + rd.y * tT;
        float zT  = ro.z + rd.z * tT + zs;
        float dTt = tT * tT * pixAng / treeX;
        float wty = max(tT * pixAng + abs(rd.y) * dTt, 1e-4);
        float wtz = max(abs(rd.z) * dTt, 1e-4);

        // Two octaves for the crowns and one very slow one for the gaps in
        // the planting, all band-limited: a treeline is a horizon line, and a
        // horizon line that aliases is a horizon line that boils.
        float n1 = lerp(vnoise(float2(zT * 0.055, 3.70)), 0.5, bandlimit(wtz, 18.0));
        float n2 = lerp(vnoise(float2(zT * 0.230 + 17.0, 9.10)), 0.5, bandlimit(wtz, 4.4));
        // Modulation ABOUT the height, not a fraction of it, or the mean
        // collapses and the treeline never clears the horizon. The clearings
        // are deliberately rare - a gap in the planting is an event, and when
        // one goes past you see the sky through it.
        float gap = smoothstep(0.20, 0.34, vnoise(float2(zT * 0.011 + 41.0, 2.30)));
        float hT  = treeH * (0.65 + 0.45 * n1) * (0.85 + 0.30 * n2)
                          * (0.25 + 0.75 * gap);

        float tcov = saturate((hT - yT) / wty + 0.5)
                   * step(0.5, tT) * saturate((1400.0 - tT) * 0.004);

        // Near black, with a little of your own headlights on the nearest
        // trunks. The fog takes it to the same value the sky already is, so
        // the treeline dies out rather than ending.
        // A silhouette and nothing else is worth two noise lookups and zero
        // pixels: near-black trees on a near-black sky is not a shape, and
        // for three appearances that was all this was. The lamp row stands in
        // FRONT of the planting and lights it, so the verge carries the same
        // rhythm the pools on the tarmac do - the same period, running to the
        // same point - and the frame gets a second pair of converging lines
        // for almost nothing. It is also the biggest thing separating the lit
        // motorway from the moor, where `urb` takes it back out again.
        float tpulse = 0.5 + 0.5 * cos(zT * (6.2831853 / lampS));
        tpulse = tpulse * tpulse;
        tpulse = lerp(tpulse, 0.375, bandlimit(wtz, lampS));

        float3 tc = float3(0.013, 0.015, 0.021)
                  + float3(0.34, 0.26, 0.16) * exp(-tT * 0.085) * 0.11
                  + float3(0.34, 0.22, 0.11) * (0.06 + 0.60 * tpulse)
                                             * exp(-tT * 0.030) * urb * 0.85;
        float fgt = 1.0 - exp(-tT * fogK * 1.7);
        tc = lerp(tc, float3(0.016, 0.019, 0.032) * (1.0 - abk * 0.94), fgt);

        col = lerp(col, tc, tcov * (1.0 - abk * 0.95));
    }

    // ---- the road --------------------------------------------------------
    // One intersect against y = 0. Exact perspective, no march, and the
    // vanishing point is a real vanishing point rather than the place the
    // step size gave up.
    float tG = (rd.y < -1e-4) ? (-ro.y / rd.y) : 1e9;
    float tg = clamp(tG, 0.0, 900.0);            // bounded, so the footprints
    float3 P = ro + rd * tg;                     // are finite even on sky pixels
    float xw = P.x;
    float zw = P.z + zs;

    // The horizon, as COVERAGE rather than as a bool. The old `bool hitG`
    // put a hard binary edge between fully fogged road (0.02) and the warm
    // skyline band (0.25) - a quarter of the ramp in one pixel, with nothing
    // in between, on the one line in the frame the eye is guaranteed to be
    // looking at. Any roll at all, or a drifting camera, and it stairsteps.
    // One vertical pixel is pixAng of rd.y, so the coverage is closed form.
    float gcov = saturate(-rd.y / pixAng + 0.5);

    // ---- screen footprints, ANALYTIC -------------------------------------
    // Not fwidth(). This shader draws the road inside a branch, and fxc sinks
    // both the road coordinates and the deriv_* instructions that measure
    // them into that branch - which was verified in the /Fc listing, not
    // guessed. A derivative under divergent control flow reads whatever the
    // inactive lanes of the quad last left in those registers, so along the
    // horizon - the exact line this coverage exists to clean up - half the
    // quads get a garbage footprint, and with it garbage lane-paint widths
    // and garbage band-limiting. The original shader has the same defect.
    //
    // For a ground plane there is no reason to ask the hardware anyway. The
    // whole chain is closed form:
    //
    //     tg   = -ro.y / rd.y            so   d(tg)/d(pixel) = tg^2/ro.y * pixAng
    //     xw   = ro.x + rd.x * tg
    //     zw   = ro.z + rd.z * tg + zs
    //
    // This is exact where it matters, bounded where tg is clamped, needs no
    // quad at all, and costs six ops against ten deriv instructions.
    float dTg = tg * tg * pixAng / max(ro.y, 0.25);   // metres of road per pixel
    float wx  = max(tg * pixAng + abs(rd.x) * dTg, 0.0025);
    float wzg = max(abs(rd.z) * dTg + tg * pixAng * 0.4, 0.0025);
    // The speed term is a cheap motion blur along z: at 30 m/s a dash moves
    // half a metre between frames, and without smearing the mark by that much
    // the lane line strobes horribly against chunky pixels. It belongs to the
    // PAINT, not to the surface texture - folding it into the one footprint
    // used everywhere is what wiped the road aggregate out at three metres.
    float wz  = wzg + speed * 0.017;

    // gTune.w is 0.0 in all three rows, so in practice the rain is what wets
    // the road - and it is worth a wide range, because a mirrored carriageway
    // and a matt one are different pictures over the whole bottom half.
    float wetAmt = saturate(wet + rain * 0.75);   // 0.15 / 0.34 / 0.53

    [branch] if (gcov > 0.002) {
        // Aggregate, streaked along the direction of travel - which is both
        // what worn asphalt actually looks like and four times cheaper to
        // keep in band, because a ground plane at a grazing angle compresses
        // metres of road into one virtual pixel along z while barely moving
        // along x. Isotropic noise here aliases into slow crawling blobs from
        // about fifteen metres out.
        float grain = vnoise(float2(xw * 2.2, zw * 0.55));
        grain = lerp(grain, 0.5,
                     max(bandlimit(wx, 0.45), bandlimit(wzg, 1.8)));

        // Where the tyres run, polished a little darker than the rest. It is
        // per LANE now rather than at two fixed offsets, so a four lane
        // motorway gets eight worn strips and a country road gets four - and
        // because they are keyed to the lane pitch they agree with the paint
        // instead of drifting across it.
        float lanePitch = 2.0 * roadW / lanes;
        float lc    = (frac((xw + roadW) / lanePitch) - 0.5) * lanePitch;
        float wl    = (abs(lc) - 0.85) * 1.5;
        float wheel = 1.0 - 0.14 * exp(-wl * wl);

        // The tarmac edge is metres wide, so it can use the raw footprint -
        // but not an unbounded one, or the far half of the road dissolves.
        float wxr    = min(wx, 1.2);
        float onRoad = smoothstep(roadW + wxr, roadW - wxr, abs(xw));
        // Asphalt is about a tenth reflective and the temptation is to use
        // the real figure. Do not: at a tenth, lit by lamps that are already
        // fifty metres up the road, the tarmac never leaves the bottom step
        // of the quantiser and the road has no width at all. These are
        // asphalt values with a thumb on them.
        float3 surf = lerp(float3(0.058, 0.062, 0.058) * (0.6 + 0.8 * grain),
                           lerp(float3(0.185, 0.190, 0.208),
                                float3(0.275, 0.282, 0.305), grain) * wheel,
                           onRoad);

        // Your own headlights: a wedge that starts a couple of metres off the
        // bumper and widens. This is the brightest thing at the bottom of the
        // frame and it is what anchors the camera inside a vehicle.
        //
        // The shape along z is a LOBE, not a decaying exponential, and that is
        // the difference between this reading as a car and reading as a white
        // slab. A ramp-in plus exp(-z k) peaks wherever the ramp finishes -
        // six metres, here - so the brightest tarmac in the frame was the
        // tarmac immediately under the bumper, and since a 1.35 m eye puts
        // everything below the middle of the frame within eight metres, that
        // was the entire bottom half of the picture at 0.7-0.94 luminance.
        // Measured off a vertical profile, not guessed.
        //
        // Real dipped beams are aimed down and cut off: dark under the car,
        // hot at fifteen to twenty metres, gone by fifty. z^2 e^-2z peaks at
        // exactly zn = 1, so the peak is placed by one constant - 16 m - and
        // the near field goes properly dark, which is also what lets the lamp
        // pools be seen at all.
        // Where that peak sits is per shot, and it is the biggest lever in
        // the bottom half of the frame: a short punchy beam on the lit
        // motorway, where you can see by the lamps anyway, against a long
        // wide one on the unlit moor, where your own lights are all there is.
        // The peak VALUE does not move - z^2 e^-2z is e^-2 at zn = 1 whatever
        // the scale - so this slides the bright wedge up and down the frame
        // without touching the value ladder.
        float xl   = P.x - ro.x;
        float zl   = max(P.z - ro.z, 0.0);
        float bw   = lerp(2.60, 3.80, var) + zl * 0.22;
        float zn   = zl / lerp(15.0, 21.0, var);
        float beam = exp(-(xl * xl) / (bw * bw) * 0.9) * zn * zn * exp(-zn * 2.0);
        float3 lit = float3(1.00, 0.92, 0.76) * beam * 11.0;

        // The pools under the lamps. The lamps are on a fixed grid, so the
        // pool pattern on the tarmac is periodic in z and needs no loop at
        // all - nearest lamp each side, proper inverse square with the
        // cosine, and the next one along is far enough away to ignore.
        float dz = (frac(zw / lampS + 0.5) - 0.5) * lampS;
        // Past about a hundred metres one pixel spans a whole span, and this
        // pattern - which does NOT fall off with camera distance, only with
        // fog - becomes a field of crawling lozenges running to the vanishing
        // point. A quarter of the pitch is where the mean of the falloff over
        // one span sits, so this fades to the correct average rather than to
        // an arbitrary constant.
        dz = lerp(abs(dz), lampS * 0.242, saturate(wzg * (1.5 / lampS)));
        float dxL = xw + lampX, dxR = xw - lampX;
        float d2L = dxL * dxL + dz * dz + lampY * lampY;
        float d2R = dxR * dxR + dz * dz + lampY * lampY;
        float pool = lampY * lampY * (rsqrt(d2L) / d2L + rsqrt(d2R) / d2R) * 26.0;
        // The low band under the sodium, so the pools have the same pulse the
        // bass does. Floor stays put: base * (1 + k*s), never k*s.
        lit += float3(1.00, 0.58, 0.20) * pool * (1.0 + 0.20 * gSync.x);
        // Kept close to neutral, and deliberately LOW. This is the term that
        // sets how dark the carriageway is between two lamps, and between two
        // lamps is most of the road: at 0.20 it lifted the whole surface onto
        // the same quantiser step as the pools and the road went flat and
        // concrete-coloured. The pool rhythm running away to the vanishing
        // point is the shot; the ambient only has to stop the gaps collapsing
        // into the dither floor.
        lit += float3(0.115, 0.114, 0.128);

        // Water darkens asphalt - it fills the pores and stops them
        // scattering - and then gives all of it back as a mirror. Doing both
        // is what separates a wet road from a road with lights painted on it:
        // the diffuse has to drop for the reflections to have anything to be
        // brighter than.
        surf = surf * lit * (1.0 - abk * 0.97) * lerp(1.0, 0.74, wetAmt);

        // Paint. Lane lines on the shot's own lane pitch, dashed, plus a
        // solid line at each edge of the tarmac. Four lanes on the motorway,
        // two on the moor - and because the lines are generated from the
        // pitch rather than written out, the count costs nothing.
        //
        // As the abstraction opens, the dashes join up into a continuous line
        // and the paint stops being paint and starts emitting - the road
        // markings are the last thing to survive, as long streaks.
        //
        // The albedo here is 0.46, not the 0.9 a real road marking has. That
        // is not a mistake and it is not timidity: at 0.9 the paint sits at
        // 1.4 under every lamp in the row, `stripe()` returns a coverage the
        // quantiser then rounds to white anyway, and the antialiasing that
        // the whole function exists to provide is thrown away. At 0.46 the
        // line clips only where it should - in the headlight wedge, at the
        // bumper - and stays a properly resolved line everywhere else.
        float q     = (xw + roadW) / lanePitch;
        float dl    = abs(q - floor(q + 0.5)) * lanePitch;
        float inner = smoothstep(roadW - 0.30, roadW - 1.30, abs(xw));
        float ph    = abs(frac(zw / dashP) - 0.5) * 2.0;
        float dash  = lerp(smoothstep(0.52 + wz / (dashP * 0.5),
                                      0.52 - wz / (dashP * 0.5), ph), 1.0, abk);
        // Paint that has stopped being paint does not stay 170 mm wide. Once
        // the line is emitting rather than reflecting it blooms, and letting
        // it do so is what keeps the abstract appearance's two long streaks
        // as the mass at the bottom of the frame - the thing that whole shot
        // is made of - on a carriageway only four metres to the side.
        // Twice normal paint at full abstraction and no more. At three times
        // it stops being a line becoming light and becomes a magenta slab up
        // the middle of the frame, wide enough at the bumper to cover the
        // instruments - which is the one thing at the bottom of the picture
        // worth seeing by then.
        float paintW = lerp(0.17, 0.34, abk);
        float cen   = stripe(dl, paintW, wx) * dash * inner;
        float edg   = stripe(abs(abs(xw) - (roadW - 0.42)), paintW * 0.85, wx);
        float3 paint = float3(0.46, 0.46, 0.42) * lit + 0.012;
        surf = lerp(surf, lerp(paint, float3(1.00, 0.20, 0.62) * 1.5, abk), cen * onRoad);
        surf = lerp(surf, lerp(paint, float3(0.24, 0.95, 1.00) * 1.3, abk), edg * onRoad);

        // Wet road. Schlick against a flat normal: a mirror at grazing
        // incidence, plain asphalt straight down. It is computed BEFORE the
        // reflection rather than after because it is also the cheapest
        // possible reason not to trace one - across the bottom third of the
        // frame, where the ray goes almost straight down, this term is worth
        // five per cent and the second light loop is worth nothing.
        float fres = 0.03 + 0.97 * pow(1.0 - saturate(-rd.y), 5.0);

        // The reflection is the same lamp row traced from the road point along
        // the mirrored ray, with the normal wobbled by two octaves of ripple.
        // Doing it this way rather than smearing the lamps downward is what
        // gives the long vertical streaks their shape for free: at a grazing
        // angle a tiny wobble in the normal throws the reflected ray a very
        // long way, which is exactly why a wet road smears and a wet wall
        // does not.
        [branch] if (wetAmt * fres > 0.05) {
            float3 rr = float3(rd.x, -rd.y, rd.z);
            // Both octaves are band-limited. They are the highest frequency
            // detail in the shot and they live in the part of the frame with
            // the worst footprint, so unfiltered they do not read as ripple -
            // they read as a boiling grey haze over the far carriageway, and
            // they take the streaks down with them.
            float f1 = 1.0 - max(bandlimit(wx, 0.55), bandlimit(wzg, 3.6));
            float f2 = 1.0 - max(bandlimit(wx, 0.20), bandlimit(wzg, 1.2));
            float rip1 = (vnoise(float2(xw * 1.8, zw * 0.28 - t * 1.6)) - 0.5) * f1;
            float rip2 = (vnoise(float2(xw * 5.1 + 11.0, zw * 0.85 - t * 3.2)) - 0.5) * f2;
            // The mid band ruffles the water. Same house rule, and the term
            // it scales is a normal offset rather than a brightness, so the
            // floor cannot move at all.
            float ripK = (0.4 + wetAmt) * (1.0 + 0.40 * gSync.y);
            rr.y += (rip1 * 0.060 + rip2 * 0.024) * ripK;
            rr.x += rip2 * 0.045 * wetAmt;
            rr = normalize(rr);

            // Five lamps is plenty in a reflection - the far ones are already
            // below the ripple. Twice the pixel angle softens it, which is
            // both cheaper and closer to what a rough mirror does. It takes
            // the SAME trail, radius, lamp pitch, lead car and oncoming
            // stream as the direct pass, so the reflection is of the scene
            // rather than of a near miss of it.
            float3 rl = lightPass(P, rr, zs, ro.z, lampP, carP, oncP,
                                  trail * 0.88, pixAng * 2.2, fogK, 5, 2, 2);
            // Asphalt is a ROUGH mirror, and the Schlick term above is a
            // smooth one - at six degrees below the horizontal it returns
            // 0.60, and at 0.60 x wetAmt x 1.70 the reflected lamp row was
            // being added at nearly full strength across the whole middle of
            // the carriageway. That washed the road into one flat pale slab
            // and took the lamp pools, which are the rhythm of the shot, out
            // with it. 1.35 keeps the vertical streaks - which are the reason
            // to trace a reflection at all - and gives the road back its
            // structure.
            surf += float3(1.00, 0.60, 0.22) * rl.x * fres * wetAmt * 1.35;
            surf += float3(1.00, 0.11, 0.06) * rl.y * fres * wetAmt * 0.95;
            // And the traffic coming the other way, smeared the length of the
            // carriageway. This is the single most recognisable thing about a
            // wet road at night and the shot did not have it.
            surf += float3(0.82, 0.88, 1.00) * rl.z * fres * wetAmt * 1.25;
        }

        // Aerial haze, on the road's own distance. Everything solid dies into
        // the same near-black the sky already is, so there is no visible end
        // to the road - which is the only way an infinite road can be built
        // out of thirteen lamps.
        float fg = 1.0 - exp(-tg * fogK * 1.4);
        surf = lerp(surf, float3(0.016, 0.019, 0.032) * (1.0 - abk * 0.94), fg);

        col = lerp(col, surf, gcov);
    }

    // ---- guard rail ------------------------------------------------------
    // A second ray/plane intersect, against whichever of the two rails the
    // ray is heading for. It is a thin horizontal ribbon converging on the
    // vanishing point, and in a frame that is otherwise black and amber it
    // is the line that tells you the road is going somewhere.
    //
    // It is also, at 360 lines, the single worst aliasing risk in the shot: a
    // near-horizontal line that is four pixels tall at twenty metres and a
    // quarter of a pixel tall at three hundred, carrying a periodic
    // brightness pulse along its length. The original drew it with a hard
    // `if (ry > 0.40 && ry < 1.02)` and a raw cos pulse, which is a recipe
    // for a crawling dashed ladder. Everything below is coverage.
    float tR  = min((sxr * railX - ro.x) / rdx, 4000.0);
    float ry  = ro.y + rd.y * tR;
    float rz  = ro.z + rd.z * tR + zs;

    // Same closed form, stood on its end. d(tR)/d(pixel) = tR^2/railX *
    // pixAng, so the rail's vertical footprint grows as tR^2 and passes the
    // 0.62 m height of the ribbon at about three hundred metres - which is
    // precisely where it should stop being drawn. The sub-pixel term inside
    // stripe() then retires it on its own, smoothly, and no arbitrary
    // distance cutoff is needed.
    float dTr     = tR * tR * pixAng / railX;
    float wry     = max(tR * pixAng + abs(rd.y) * dTr, 1e-4);
    float wrz     = max(abs(rd.z) * dTr, 1e-4);
    float railCov = stripe(abs(ry - 0.71), 0.31, wry)
                  * step(0.25, tR) * step(tR, tG)
                  * saturate((900.0 - tR) * 0.01);

    [branch] if (railCov > 0.002) {
        // Two ridges with a groove between them. That W section is the whole
        // silhouette of a crash barrier, and it is the only detail here that
        // still reads when the thing is four pixels tall. The smoothstep
        // edges open with the footprint so the ridges soften into the body
        // rather than strobing once they go sub-pixel.
        float prof = saturate(smoothstep(0.055 + wry, 0.0, abs(ry - 0.56)) +
                              smoothstep(0.055 + wry, 0.0, abs(ry - 0.88)));
        float body = 0.28 + 0.72 * prof;

        // The lamp pulse along the rail. Its period is the lamp pitch in rz,
        // and rz's footprint passes that pitch well before the rail itself
        // goes sub-pixel, so it has to fade to its own mean -
        // E[(0.5 + 0.5 cos)^3] = 5/16 - or the rail arrives at the vanishing
        // point as a bead curtain.
        float pulse = 0.5 + 0.5 * cos(rz * (6.2831853 / lampS));
        pulse = pulse * pulse * pulse;
        pulse = lerp(pulse, 0.3125, bandlimit(wrz, lampS));

        // Reflector studs on the posts, one every four metres, which is a
        // faster rhythm than the lamps and reads as speed on its own.
        float stud = 0.5 + 0.5 * cos(rz * (6.2831853 / 4.0));
        stud = stud * stud;
        stud = stud * stud;
        stud = lerp(stud, 0.375, bandlimit(wrz, 4.0))
             * smoothstep(0.055 + wry, 0.0, abs(ry - 0.72));

        float  head = exp(-tR * 0.060) * 0.55;   // your own headlights on it
        float3 rc   = float3(0.50, 0.44, 0.36) * body * (0.06 + pulse * 0.55 + head);
        rc += float3(1.00, 0.80, 0.42) * stud * (0.10 + head * 0.85);
        rc = lerp(rc, float3(1.00, 0.26, 0.72) * body * 1.1, abk);

        float fgr = 1.0 - exp(-tR * fogK * 1.4);
        rc = lerp(rc, float3(0.016, 0.019, 0.032) * (1.0 - abk * 0.94), fgr);

        col = lerp(col, rc, railCov);
    }

    // ---- the signs -------------------------------------------------------
    // The two nearest gantries. They are the only horizontal edges in the
    // frame, so they are the only thing that reads as ARRIVING rather than as
    // converging, and one of them sweeping up out of the top of the picture
    // is the shot's biggest gesture. Spacing is per shot: every 148 m on the
    // motorway, every 260 on the moor.
    float gz   = ro.z + zs;
    float gph  = frac(gz / gsp);
    float gsd  = floor(gz / gsp);
    float gw   = roadW + 3.6;
    {
        // Seeded by the gantry's own index, not by the slot it is in. Seed it
        // by the slot and the far one rewrites its legend at the instant it
        // becomes the near one.
        float3 gl2;
        float4 g2 = gantryHit(ro, rd, (2.0 - gph) * gsp, pixAng, gw,
                              fogK, abk, frac((gsd + 2.0) * 0.317), gl2);
        col = lerp(col, g2.xyz, g2.w);
        col += gl2 * (1.0 + 0.45 * gVoice.w);

        float3 gl1;
        float4 g1 = gantryHit(ro, rd, (1.0 - gph) * gsp, pixAng, gw,
                              fogK, abk, frac((gsd + 1.0) * 0.317), gl1);
        col = lerp(col, g1.xyz, g1.w);
        col += gl1 * (1.0 + 0.45 * gVoice.w);
    }

    // ---- the vehicle ahead ------------------------------------------------
    // Its tail lights were always there; its body never was, so the lights
    // hung in empty air twenty metres out. One more plane intersect, two
    // boxes - a body and a cabin - and there is something on the road with
    // you. It also throws spray, which is the reason the rain reads as rain
    // out in the world and not only on the glass.
    float Dc = carZ - ro.z;
    [branch] if (abk < 0.86) {
        float rzc = max(rd.z, 0.05);
        float tc  = Dc / rzc;
        float xc  = ro.x + rd.x * tc;
        float yc  = ro.y + rd.y * tc;
        float wc  = max(tc * pixAng, 0.005);

        float lowb = stripe(abs(xc), 1.06, wc) * stripe(abs(yc - 0.73), 0.43, wc);
        float cab  = stripe(abs(xc), 0.86, wc) * stripe(abs(yc - 1.39), 0.23, wc);
        float bcov = saturate(max(lowb, cab)) * saturate(rd.z * 8.0 - 0.2)
                   * saturate((Dc - 4.0) * 0.4) * saturate(1.0 - abk * 1.15);

        // Black bodywork with your own headlights on the back of it, and a
        // red wash out of its own lamps. Nothing else: at this size that is
        // all a car is.
        float3 bc = float3(0.040, 0.038, 0.044) * (0.5 + 2.2 * exp(-Dc * 0.055));
        float2 dl1 = float2(abs(xc) - 0.98, yc - 0.80);
        bc += float3(0.60, 0.07, 0.03) * exp(-dot(dl1, dl1) * 5.0) * (0.35 + brake);
        float fgc = 1.0 - exp(-tc * fogK * 1.4);
        bc = lerp(bc, float3(0.016, 0.019, 0.032) * (1.0 - abk * 0.94), fgc);
        col = lerp(col, bc, bcov);

        // The spray, as an angular lobe around the vehicle rather than a
        // volume - it is a metre and a half of haze twenty metres out and
        // there is nothing a march would tell us that this does not.
        float3 cv  = normalize(float3(0.0, 0.85, Dc));
        float  ca  = 1.0 - dot(rd, cv);
        float  swb = 0.62 + 0.38 * vnoise(float2(uv.x * 5.0, uv.y * 5.0 - t * 2.6));
        col += float3(0.44, 0.42, 0.46) * exp(-ca * 190.0) * swb
             * rain * (0.30 + 0.70 * traffic) * 0.60 * (1.0 - abk * 0.7);
    }

    // ---- the lamps themselves --------------------------------------------
    // Added over everything, including over the rail, the gantry and the
    // road. They are above the ground plane so nothing can occlude them
    // anyway, and letting the glow bleed through the near rail is what bloom
    // does.
    float3 lgt = lightPass(ro, rd, zs, ro.z, lampP, carP, oncP,
                           trail, pixAng, fogK, 13, nCar, nOnc);

    col += float3(1.00, 0.62, 0.24) * lgt.x * lerp(1.15, 2.0, ab)
         * (1.0 + 0.22 * gSync.x);
    // The tail lights are kept deliberately below the top of the ramp.
    // Pushed any brighter the quantiser lands them on the white step and the
    // post pass hands back two pink dots, and the only other colour in the
    // frame stops being red.
    col += float3(1.00, 0.11, 0.06) * lgt.y * 0.85 * (1.0 - abk * 0.65);
    // The traffic coming the other way. Cooler than the sodium on purpose -
    // it is the only cold light in the frame and it is what makes the amber
    // read as amber.
    col += float3(0.80, 0.88, 1.00) * lgt.z * lerp(0.90, 1.60, ab)
         * (1.0 + 0.25 * gSync.z);

    // ---- rain in the beam ------------------------------------------------
    // Falling rain seen from a moving car does not fall: it streams out of
    // the vanishing point, and the faster you go the longer the strokes get.
    // Radial noise in log polar is exactly that shape for two lookups, and it
    // is the last thing that separates a downpour from a drizzle once the
    // glass has been dealt with.
    [branch] if (rain > 0.06) {
        float2 qv = float2(uv.x, sy + 0.06);
        float  rr2 = length(qv) + 0.05;
        float  aa  = atan2(qv.y, qv.x);
        float  lr  = log(rr2) * lerp(2.4, 1.1, saturate(speed / 34.0));
        float  n1  = vnoise(float2(aa * 26.0, lr * 6.0 - t * (2.0 + speed * 0.10)));
        float  n2  = vnoise(float2(aa * 45.0 + 13.0, lr * 9.0 - t * (3.0 + speed * 0.16)));
        float  st  = smoothstep(0.66, 0.98, n1) * 0.9 + smoothstep(0.74, 1.00, n2) * 0.6;
        // Only where your headlights actually reach the drops: the lower
        // wedge of the frame, falling off away from the beam.
        float  litr = exp(-rr2 * 1.7) * smoothstep(0.45, -0.35, sy);
        col += float3(0.60, 0.65, 0.78) * st * litr * rain * 0.20
             * (1.0 + 0.40 * gSync.z);
    }

    // ---- back to the glass -----------------------------------------------
    // The drops have already bent the ray, so they are visible wherever they
    // have something to bend. This adds the little bit of scattered light
    // that makes them visible against the parts of the frame that are black.
    col += float3(0.30, 0.33, 0.40) * saturate(wfilm) * 0.130 * rain
         * (1.0 + 0.30 * gVoice.w);
    col = lerp(col, col * 0.10 + float3(0.030, 0.028, 0.032), blade);

    // ---- the bonnet, and what is on the dash -----------------------------
    // A sliver of car along the bottom edge, catching a little of the
    // headlight bounce and a little of the instruments. It is the difference
    // between "a road" and "seen from inside a car". It goes away as the shot
    // abstracts, because by then there is no car.
    //
    // The curvature term is small and it has to stay small: uv.x runs to
    // +-1.78 on a 32:9 display, so a coefficient that looks right at 16:9
    // squares up and swallows the bottom corners all the way to the horizon.
    // That is exactly what the first version of this line did.
    float by   = -0.66 + 0.045 * uv.x * uv.x;
    float hsh  = smoothstep(by + 0.010, by - 0.010, sy);
    float hood = hsh * (1.0 - abk);
    float3 hc  = float3(0.055, 0.050, 0.058) * (0.20 + 0.80 * smoothstep(-1.0, by, sy));
    // The lip of the bonnet catching the headlight spill. It is pushed up
    // from 0.155 because it is the line that separates the car from the road,
    // and at 0.13 luminance it and the black body of the bonnet landed on the
    // same quantiser step - which made the bottom of the frame one flat shape
    // instead of two.
    hc += float3(0.80, 0.55, 0.25) * 0.210 * smoothstep(by - 0.055, by, sy);
    hc += float3(0.90, 0.30, 0.10) * 0.075 * smoothstep(-0.78, -1.0, sy);
    col = lerp(col, hc, hood);

    // The instruments. Two dials with only their top arcs above the dash -
    // which is all you ever see of your own - a rev counter that answers to
    // the guitar, a speedometer that sits where gTune.x put it, and an
    // indicator ticking away on its own clock. They are LIGHT, so unlike the
    // bodywork they survive the abstraction: by the third appearance the
    // dashboard is two glowing rings at the bottom of the frame, which is the
    // right amount of car for a shot that no longer has a road in it.
    //
    // How much of them you get is also a matte question and therefore a
    // per-appearance one: the first row is still in 2.39:1 and sees a sliver,
    // the last two are in open frame and see the whole cluster.
    [branch] if (hsh > 0.002) {
        float3 inst = float3(0.0, 0.0, 0.0);

        // The pool of light the cluster throws onto the dash top.
        float2 gp = float2(uv.x, sy + 0.95);
        inst += float3(0.95, 0.55, 0.20) * exp(-gp.x * gp.x * 2.2 - gp.y * gp.y * 9.0) * 0.30;

        // Rev counter, left. Idle sits at a fifth of the sweep and the guitar
        // takes it round - base + k*s, and the needle is four pixels wide, so
        // nothing here can move a meaningful area of the frame.
        float nd1 = lerp(-2.10, 1.50, saturate(0.22 + 0.60 * gVoice.x
                                               + 0.05 * sin(t * 5.3)));
        float3 d1 = dial(float2(uv.x + 0.42, sy + 0.93), 0.27, nd1);
        inst += float3(1.00, 0.42, 0.16) * d1.x * 0.16
              + float3(1.00, 0.72, 0.36) * d1.y * 0.42
              + float3(1.00, 0.30, 0.16) * d1.z * 0.85;

        // Speedometer, right. It reads what gTune.x actually is, so the three
        // appearances genuinely show three different speeds.
        float nd2 = lerp(-2.10, 1.50, saturate(speed / 44.0 + 0.02 * sin(t * 0.9)));
        float3 d2 = dial(float2(uv.x - 0.42, sy + 0.93), 0.27, nd2);
        inst += float3(1.00, 0.42, 0.16) * d2.x * 0.16
              + float3(1.00, 0.72, 0.36) * d2.y * 0.42
              + float3(1.00, 0.30, 0.16) * d2.z * 0.85;

        // Telltales between them: an indicator ticking at its own tempo -
        // the one thing in the frame that is not synchronised to anything -
        // and a steady lamp beside it.
        float2 w1 = float2(uv.x + 0.075, sy + 0.735);
        float2 w2 = float2(uv.x - 0.075, sy + 0.735);
        float  tick = step(0.5, frac(t * 0.74));
        inst += float3(0.30, 1.00, 0.35) * exp(-dot(w1, w1) * 2600.0) * tick * 0.75;
        inst += float3(1.00, 0.55, 0.10) * exp(-dot(w2, w2) * 2600.0)
              * (0.35 + 0.55 * gVoice.z);

        col += inst * hsh * (1.0 - abk * 0.55);
    }

    // And the cluster in the windscreen, which is the detail that says there
    // is glass between you and the road at all. It is the dash pool mirrored
    // about the dash line, an eighth as bright, and it costs three ops.
    float mry = 2.0 * by - sy + 0.95;
    col += float3(0.85, 0.55, 0.28)
         * exp(-uv.x * uv.x * 2.0 - mry * mry * 7.0) * 0.055
         * smoothstep(by - 0.02, by + 0.30, sy) * (1.0 - abk * 0.6);

    // No dither, no scanlines, no grade, no vignette, no aberration and no
    // tonemap. All of that belongs to post.hlsl and doing any of it here
    // would be doing it twice. This shader's only job is to hand the post
    // pass a linear frame with a value ladder worth quantising.
    return float4(col * gTime.z, 1.0);
}
