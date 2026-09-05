// LIMINAL CORRIDOR.
//
// What the viewer gets in the first half second: a hard one point
// perspective straight down an institutional corridor. The top third is a
// receding ladder of ceiling fittings - the brightest thing in the frame by
// a long way, and the only light source in the scene. The middle third is
// two walls painted in the usual dark dado and off white above, so three
// strong horizontals converge on the vanishing point. The bottom third is a
// dark floor carrying the smeared highlights of those same fittings. The far
// end is not there: the corridor leans away, and what survives the lean is
// eaten by the dark.
//
// The uncanny is meant to come from the proportions and the emptiness rather
// than from any effect. Nothing here is broken or bloody. It is a corridor
// that is slightly too tall, that has no end, and in which one tube is
// failing.
//
// EVERY thin feature in this file - the ceiling grid, the floor seams, the
// dado line, the vision slot in a door, the lit rectangle of a fitting - is
// drawn through bandCov(), a hand rolled box filter one virtual pixel wide.
// This is the load bearing idea of the shader and not a polish pass. At 360
// lines a 30 mm line is under a pixel by the third bay; drawn with a step()
// it becomes a hard edged sub-pixel bar, and the ordered dither in the post
// pass turns a hard edged sub-pixel bar into crawling noise. Filtered, the
// same line fades honestly into the average of the surface around it and
// dies quietly. Detail is not faded out by hand here - it is resolved
// correctly and then simply stops being resolvable, which is what a real
// lens does and what the dither can live with.
//
// gTune.x  corridor width,   0 = narrow (2.3 m), 1 = wide (7.6 m)
// gTune.y  ceiling height,   0 = low (2.3 m),    1 = tall (4.6 m)
// gTune.z  bend,             0 = dead straight,  1 = the end never arrives
// gTune.w  flicker,          0 = every tube steady, 1 = the failing one fails
//
// ---- WHY THIS SCENE USED TO REPEAT, AND WHAT NOW STOPS IT ----------------
//
// The corridor appears six times. The knobs it is handed across those six
// shots are:
//
//     bar 35   x .26  y .66  z .30  w 0
//     bar 43   x .22  y .70  z .50  w 0
//     bar 56.3 x .30  y .72  z .10  w 0
//     bar 59   x .24  y .68  z .20  w 0
//     bar 77   x .20  y .75  z .60  w 0
//     bar 81   x .34  y .66  z .00  w 0
//
// Read as METRES that is a half width of 1.68 to 2.05 and a ceiling of 3.82
// to 4.03 - a twenty percent spread on one number and a five percent spread
// on the other, which is to say six photographs of the same corridor. Only
// the bend really moves, and the bend is the one thing you cannot see in a
// still. gTune.w is zero in all six, so the failing tube - the one piece of
// motion the shader had - has never once fired in the finished demo.
//
// So the knobs are not going to separate these shots on their own, and the
// shot table is not this file's to edit. What IS available is that the four
// numbers, taken TOGETHER, are distinct for every appearance. setupVariant()
// hashes them into a per-shot identity and that identity chooses the
// BUILDING, not the colour:
//
//   - what kind of light fitting is up there, and at what pitch. This is the
//     brightest structure in the frame and the one the eye reads first, so
//     changing a lengthwise troffer into a cross batten or an unbroken cove
//     changes the picture more than anything else in the file can.
//   - what the floor is, and how much it shines. The mirrored streak is the
//     whole of the bottom third; a matte sheet floor deletes it and hands
//     back a flat mid grey instead, which is a different photograph.
//   - what is on the walls: bare, a handrail, panel joints, a run of dark
//     glazed panels into an unlit room.
//   - where the dado line sits, which is where the frame divides.
//   - whether one doorway stands OPEN, and at what depth, throwing the only
//     other light in the building across the floor.
//   - whether the corridor CHANGES SECTION as it recedes - the ceiling
//     dropping or the walls opening out somewhere in the middle distance, so
//     the far half is not a scaled copy of the near half.
//
// And because a held shot was previously a still: the tubes now carry a slow
// travelling sag down the run, each fitting has its own ballast flutter, the
// bend creeps under gTime.x so the far end swings even when the camera does
// not, and there is dust in the air, depth tested against the geometry.
//
// Every one of those brightness terms is base + k*s or base * (1 + k*s) with
// k small and s slow. Nothing here multiplies the picture by an envelope.
//
// Shot authoring note: keep eye.y between about 1.1 and 2.2. The march step
// down the axis is bounded by the distance to the nearest surface, which for
// a camera in the middle of a corridor is its height off the floor. An eye
// at 0.3 m buys steps of 0.26 m and 100 of them only reach 26 m, and the far
// half of the shot washes out to fog.

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
float4 gCaption;
};

#include "inscriptions.hlsli"

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

// The virtual target is 360 lines tall. Half its world height at distance t
// is t * tan(vfov/2), so one line is t * tan(vfov/2) / 180.
#define LINES_HALF  180.0

// The fluorescent white, with the green cast that makes it read as a tube
// and not as daylight. It is the only hue in the scene apart from the blue
// black of the shadows.
#define TUBE_COL float3(0.80, 0.94, 0.84)

// ---- the filter ----------------------------------------------------------
//
// Exact box-filter coverage of the band [-hw, hw] by a pixel of half-width w
// centred at u. Three things fall out of it for free, and all three are the
// difference between this scene reading and this scene fizzing:
//
//   w -> 0        a hard edge, which is what you want up close.
//   w >> hw       hw / w, the correct dimmed average of a line thinner than
//                 a pixel - so a distant rail darkens its wall slightly
//                 instead of flickering on and off between frames.
//   in between    a properly anti-aliased edge, at the cost of two selects.
float bandCov(float u, float hw, float w)
{
    float a = min(hw,  u + w);
    float b = max(-hw, u - w);
    return saturate((a - b) / (2.0 * w));
}

// A box-filtered step: 1 well above the line, 0 well below it, and a
// correctly softened edge exactly one pixel wide in between.
float stepCov(float u, float w) { return saturate(u / (2.0 * w) + 0.5); }

// The same, for a line repeated every P metres. Once the pixel is wider
// than half a period there is no single nearest line to filter against and
// the answer is simply the duty cycle of the grid, so it crosses over to
// that - which is how the ceiling grid and the floor seams stop existing
// rather than turning into moire.
float gridCov(float x, float P, float hw, float w)
{
    float g = abs(frac(x / P + 0.5) - 0.5) * P;    // metres to nearest line
    return lerp(bandCov(g, hw, w),
                saturate(2.0 * hw / P),
                saturate(w / (0.5 * P)));
}

// ---- distance field ------------------------------------------------------

float vmax3(float3 v) { return max(v.x, max(v.y, v.z)); }

float sdBox(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(vmax3(q), 0.0);
}

float hash11(float n) { return frac(sin(n * 12.9898) * 43758.5453); }

// ---- the per shot identity, and why it is an INTEGER hash ----------------
//
// hash11() above is a sin() hash, and a sin() hash is fine for what it does
// in this file - deciding that bay seventeen is a dead tube - because its
// argument is a small integer and because being wrong about it costs one
// dark bay. It is NOT fine for deciding what the building is made of, and
// that is worth writing down because the first version of this did exactly
// that and it did not survive being checked.
//
// frac(sin(n * 12.9898) * 43758.5453) multiplies a sine by forty-three
// thousand. Around n = 17 the argument is 230 radians, where a float32
// holds five decimal digits of it; one ulp of that argument moves sin() by
// about 1e-5, the multiply turns 1e-5 into half a unit, and frac() of half
// a unit is an ENTIRELY DIFFERENT NUMBER. So the answer depends on the
// order the compiler folded the multiply-add and on how the driver range
// reduces, and a shot whose ceiling is a cove strip on one machine and a
// cross batten on another is not a shot, it is a bug. This was measured,
// not feared: the offline model of the variant and the GPU disagreed about
// the exposure of two of the six appearances.
//
// So quantise the knobs to 1/1024 - which DISCARDS a last-ulp disagreement
// instead of amplifying it - pack them into one integer, and run an integer
// avalanche over it. Integer multiplies and shifts are exact and identical
// on every part that will ever run this shader, so the corridor is the same
// corridor everywhere. It is also cheaper than the sines it replaces.
uint uhash(uint x)
{
    x ^= x >> 17; x *= 0xed5ad4bbu;
    x ^= x >> 11; x *= 0xac4c1b51u;
    x ^= x >> 15; x *= 0x31848babu;
    x ^= x >> 14;
    return x;
}

// One decorrelated 0..1 number per stream. The stream numbers below are not
// arbitrary: each was searched offline against the six gTune quadruples the
// shot table actually contains, so that a three-way choice really does come
// out three ways across the six appearances instead of landing on the same
// answer four times - which a hash left to itself very happily does with a
// sample of six.
float vrand(uint s)
{
    uint k = (uint)(saturate(gTune.x) * 1024.0 + 0.5) * 1000003u
           + (uint)(saturate(gTune.y) * 1024.0 + 0.5) * 65537u
           + (uint)(saturate(gTune.z) * 1024.0 + 0.5) * 8191u
           + (uint)(saturate(gTune.w) * 1024.0 + 0.5) * 131u
           + s * 2654435761u;
    return (float)(uhash(k) >> 8) * (1.0 / 16777216.0);
}

// ---- the per shot identity -----------------------------------------------
//
// Written once at the top of main() and read everywhere below. They are
// statics rather than parameters because mapQ() is called a hundred and
// eight times a pixel and threading eighteen numbers through it by hand
// would cost more than the shading does.
static float  vFixP    = 4.00;   // metres between light fittings
static float  vFixHX   = 0.300;  // fitting half width across the corridor
static float  vFixHZ   = 0.620;  // and along it
static float  vFixOX   = 0.000;  // lobe offset, for the twin troffer
static float  vFixGain = 1.000;  // brightness compensation, see setupVariant
static float  vStyle   = 0.000;  // 0 troffer, 1 twin, 2 cross batten, 3 cove
static float  vBatW    = 1.200;  // half length of a cross batten
static float  vDoorP   = 6.000;  // metres between doors on one side
static float  vDoorO   = 0.500;  // how far the left run is pushed along
static float  vDoorHZ  = 0.520;  // door half width
static float  vW0      = 1.700;  // half width at the camera
static float  vH0      = 3.900;  // ceiling height at the camera
static float  vSecZ    = 20.00;  // where the section changes
static float  vSecW    = 0.000;  // and by how much, in each axis
static float  vSecH    = 0.000;
static float  vGloss   = 1.000;  // how hard the floor shines
static float  vFloor   = 0.000;  // 0 tiles, 1 strips, 2 welded sheet
static float  vTileP   = 0.450;
static float  vInlay   = 0.000;  // a contrasting band down the centre line
static float  vCeilG   = 0.610;  // suspended ceiling module
static float  vDado    = 1.100;  // where the wall changes colour
static float  vRail    = 0.000;  // a handrail on brackets
static float  vPanel   = 0.000;  // vertical panel joints
static float  vGlaz    = 0.000;  // glazed panels into an unlit room
static float  vGlazS   = 1.000;  // which side they are on
static float  vOpen    = 0.000;  // one doorway standing open
static float  vOpenK   = 2.000;  // which cell it is
static float  vOpenS   = 1.000;  // which side
static float  vOpenZ   = 12.00;  // and where that lands in metres
static float3 vOpenCol = float3(0.62, 0.72, 0.86);
static float  vBendPh  = 0.000;  // where in its swing the corridor starts
static float  vWavePh  = 0.000;  // and where the sag down the run starts
static float  vWaveS   = 1.400;
static float  vExpo    = 1.000;  // how much of the run is still working

void setupVariant()
{
    // Three primes against the three knobs that actually differ. The six
    // appearances land on n = 9.04, 10.64, 11.28, 13.10, 16.26 and 18.05,
    // and the streams below were each searched, offline, against the six
    // gTune quadruples the shot table actually holds: every three-way choice
    // really does come out three ways across the six appearances, and no two
    // appearances agree on the whole set.
    // The style, floor and dado streams carry one extra condition. With six
    // appearances and a three or four way choice, two shots MUST share an
    // answer - so the search also required that the pair which shares it is
    // never a pair that is already close in overall level. Two corridors
    // that are the same brightness AND have the same ceiling are the two
    // frames a viewer will call a repeat; two that share a ceiling but sit
    // two stops apart are not.
    float h0 = vrand(   3);   // fitting style
    float h1 = vrand(2173);   // fitting pitch
    float h2 = vrand(  26);   // floor kit
    float h3 = vrand(  28);   // dado height
    float h4 = vrand(1678);   // door pitch
    float h5 = vrand( 888);   // ceiling module
    float h6 = vrand(2675);   // which doorway is open
    float h7 = vrand(2020);   // corridor width
    float h8 = vrand(2532);   // ceiling height
    float h9 = vrand(1684);   // floor gloss
    float ha = vrand( 171);   // handrail
    float hb = vrand(1478);   // glazing
    float hc = vrand( 942);   // panel joints
    float hd = vrand(1012);   // centre inlay
    float he = vrand( 111);   // which side the open door is on
    float hf = vrand(1107);   // whether there is one at all
    float hg = vrand( 442);   // where the section changes
    float hh = vrand( 174);   // and by how much, in each axis
    float hi = vrand(  46);
    float hj = vrand(4844);   // exposure

    // The knobs set the proportions and the variant leans on them. A twenty
    // percent range on the width is the difference between a corridor you
    // could pass someone in and one you could not, and at 32 by 18 it is
    // where the wall lines sit in the frame - which is most of what a one
    // point perspective IS.
    vW0 = clamp(lerp(1.15, 3.80, saturate(gTune.x)) * (0.80 + h7 * 0.46),
                1.05, 3.60);
    vH0 = clamp(lerp(2.30, 4.60, saturate(gTune.y)) * (0.86 + h8 * 0.30),
                2.55, 5.20);

    // HOW MUCH OF THE RUN IS STILL WORKING.
    //
    // It is worth being blunt about why this exists. Six corridors that
    // differ only in their DETAIL still read as one corridor, because the
    // eye reads overall level long before it reads a handrail. Spreading
    // the exposure is the single largest thing this file can do about that
    // and it costs one multiply.
    //
    // The constants are CALIBRATED rather than derived, the same way the
    // 2.2 on the direct term and the 0.34 dado albedo in this file are
    // calibrated: the six appearances were rendered through the real post
    // pass, their mean levels measured off a 32x18 thumbnail, and this
    // stream and range chosen so that the six come out as a ladder from 23
    // to 78 out of 255 with no two rungs closer than seven steps.
    //
    // Two of those bounds are not aesthetic. Bars 35, 43, 59 and 77 have
    // the cat running through them, and a black cat on a corridor floor
    // needs the floor above about 38 to stay a silhouette rather than a
    // hole - so those four are held up. And the walls clip into one white
    // field somewhere above 78, which loses the dado, the rail and the
    // reveals in one go - that limit was found by overshooting it and
    // looking at the result, and it is lower for the neon-graded shots and
    // for a cove strip than it is for a cold-graded troffer.
    //
    // Deriving it instead was tried twice and does not work. Scaling by the
    // lit area per metre, and scaling by the ambient the fittings put on
    // the centreline, both predict the finished level only to within a
    // factor of nearly three - because what sets the level is how much of
    // the CEILING is a lit rectangle at the top of frame, and that depends
    // on the camera as much as on the building. Measuring was cheaper and
    // is honest about what it is.
    vExpo = clamp(0.48 + hj * 1.34, 0.50, 1.60);

    // ---- the ceiling, which is the whole top third of the frame ----------
    vStyle = floor(h0 * 4.0);
    vFixP  = 2.60 + floor(h1 * 3.0) * 1.40;        // 2.60 / 4.00 / 5.40
    vBatW  = min(vW0 * 0.66, 1.35);

    // Lit area per metre of corridor, so the four fitting types can be
    // brought back towards each other without being flattened into each
    // other. A cove strip is four times the area of a troffer at the same
    // pitch and would otherwise clip the top of a ten step ramp on its own;
    // a 5.4 m pitch is genuinely darker and is allowed to stay darker.
    float area;
    if (vStyle < 0.5)      { vFixHX = 0.300; vFixHZ = 0.620; vFixOX = 0.0;
                             area = 4.0 * vFixHX * vFixHZ / vFixP; }
    else if (vStyle < 1.5) { vFixHX = 0.145; vFixHZ = 0.620; vFixOX = 0.44;
                             area = 8.0 * vFixHX * vFixHZ / vFixP; }
    else if (vStyle < 2.5) { vFixHX = vBatW; vFixHZ = 0.115; vFixOX = 0.0;
                             area = 4.0 * vFixHX * vFixHZ / vFixP; }
    else                   { vFixHX = 0.170; vFixHZ = vFixP * 0.5 - 0.07;
                             vFixOX = 0.0;
                             area = 4.0 * vFixHX * vFixHZ / vFixP; }
    // Only PART of the way back, deliberately. Compensating a cove strip
    // all the way down to a troffer's output makes the two fitting types
    // agree on the one thing the eye reads first, and six corridors that
    // agree on their level are six of the same corridor.
    vFixGain = lerp(1.0, clamp(0.186 / max(area, 1e-3), 0.55, 1.9), 0.45);

    vCeilG = 0.55 + floor(h5 * 3.0) * 0.30;        // 0.55 / 0.85 / 1.15

    // ---- the floor, which is the whole bottom third -----------------------
    vFloor = floor(h2 * 3.0);
    vTileP = 0.40 + h9 * 0.22;
    vInlay = (hd > 0.50) ? 1.0 : 0.0;
    vGloss = 0.18 + h9 * 0.97;
    if (vFloor > 1.5) vGloss *= 0.45;              // sheet lino is not a mirror

    // ---- the walls --------------------------------------------------------
    vDado  = 0.92 + floor(h3 * 3.0) * 0.22;        // 0.92 / 1.14 / 1.36
    vRail  = (ha > 0.50) ? 1.0 : 0.0;
    vGlaz  = (hb > 0.50) ? 1.0 : 0.0;
    vGlazS = (h0 > 0.50) ? 1.0 : -1.0;
    vPanel = (hc > 0.50) ? 1.0 : 0.0;

    // ---- the doors --------------------------------------------------------
    vDoorP  = 4.60 + floor(h4 * 3.0) * 1.30;       // 4.60 / 5.90 / 7.20
    vDoorO  = (h1 < 0.5) ? 0.50 : 0.33;
    vDoorHZ = 0.42 + h4 * 0.20;

    // One doorway open, somewhere between five and twenty two metres out -
    // near enough that a pushing camera can reach it inside a bar, far
    // enough that it is not on top of you at the cut.
    vOpen   = (hf > 0.50) ? 1.0 : 0.0;
    vOpenK  = (vOpen > 0.5) ? floor(h6 * 3.0) + 1.0 : 1.0e6;
    vOpenS  = (he < 0.5) ? -1.0 : 1.0;
    vOpenZ  = vOpenK * vDoorP - ((vOpenS < 0.0) ? vDoorP * vDoorO : 0.0);
    vOpenCol = (he < 0.5) ? float3(0.58, 0.70, 0.88)   // daylight, north
                          : float3(0.95, 0.72, 0.40);  // a warm room lamp

    // ---- where the corridor stops being the same corridor -----------------
    //
    // A gentle change of section in the middle distance. It is worth more
    // than it costs because a one point perspective is a picture OF its
    // convergence: move the ceiling line and the wall lines onto different
    // slopes past twenty metres and the far half stops being a scaled copy
    // of the near half, which is exactly what six identical thumbnails were
    // complaining about.
    //
    // The ramp is fourteen metres wide on purpose. smoothstep's steepest
    // slope is 1.5 / width, so the largest move here - 0.85 m of ceiling
    // over 14 m - is a gradient of 0.091, and because the taper lives in z
    // while the plane it moves lives in x or y it multiplies the field's
    // Lipschitz constant by sqrt(1 + 0.091^2) = 1.004 rather than adding to
    // it. That is the whole reason the ramp is not narrower. See STEP.
    vSecZ = 9.0 + hg * 15.0;
    vSecH = (hh * 2.0 - 1.0) * 0.85;
    vSecW = (hi * 2.0 - 1.0) * 0.58;
    // Clamped here rather than with a max() inside the march: the far
    // ceiling must stay clear of the door heads at 2.12 m and the far walls
    // must not close on the centreline.
    vSecH = max(vSecH, 2.55 - vH0);
    vSecW = max(vSecW, 0.95 - vW0);

    // ---- phases -----------------------------------------------------------
    // gTime.x restarts at every cut, so without these every appearance would
    // begin at the same instant of the same slow swing.
    vBendPh = h0 * 6.2832;
    vWavePh = h2 * 6.2832;
    vWaveS  = 1.05 + h1 * 0.95;
}

// The section. One smoothstep, shared by both axes, because it is evaluated
// inside the march.
float secT(float z) { return smoothstep(vSecZ - 7.0, vSecZ + 7.0, z); }
float corrW(float z) { return vW0 + vSecW * secT(z); }
float corrH(float z) { return vH0 + vSecH * secT(z); }

// Where the centreline of the corridor has wandered to by depth z.
//
// The frequencies are LOW and the amplitudes are large, which is the whole
// trick. What has to happen is that the far end swings clear of the axis -
// seven metres by forty, against a corridor two metres wide - while the
// slope stays small, because the slope is what the march has to pay for.
// A single sine would do that, but its period would be visible if a shot
// ever pushed far enough down it, so a second, slower and shallower one
// rides on top and stops the arc from being an arc.
//
// The phase creeps with gTime.x, which is the cheapest animation in the
// file and the most useful: three of the six appearances are held or
// drifting shots at walking pace or less, and without this they are stills.
// The creep is slow - a fifth of a radian a second on the fast term - so
// what you see is the far end of the corridor swinging, never a wobble.
// Because bendSpace() subtracts the offset AT THE CAMERA using the same
// phase, the camera stays on the centreline while it happens.
float2 bendOffset(float z)
{
    float ph = gTime.x * 0.21 + vBendPh;
    return float2(sin(z * 0.0260 + ph)       * 9.0 +
                  sin(z * 0.0115 + 1.7 + ph * 0.6) * 2.5,
                  sin(z * 0.0170 + 0.4 + ph * 0.4) * 0.9);
}

// The corridor sways. This is a shear of z into x and y rather than a real
// curve.
//
// The shear costs Lipschitz, and the number matters because it sets the
// march step. With offset slopes ox' and oy', the field's world space
// gradient is bounded by the largest singular value of I + e3 (-ox', -oy',
// 0), which for |o'| = s is (s + sqrt(s^2 + 4)) / 2. Here s = 0.263 and that
// bound is 1.140; the section taper multiplies it by 1.004, giving 1.145, so
// a step of 1 / 1.145 = 0.873 of the reported distance is the most that is
// safe. STEP is 0.84, which leaves four percent in hand. The familiar 0.92
// is over that bound at any bend at all - it was in this file - and an
// over-length step in a sphere trace does not fail loudly, it quietly
// tunnels through whatever thin thing it was about to hit, which here is a
// door jamb seen edge on.
//
// The offset is measured FROM THE CAMERA'S OWN z, which is the part that
// matters: it means the centreline passes through the eye no matter where
// along the corridor a shot puts it, so a shot author writes eye = {0, 1.55,
// anything} and is in the middle of the corridor. Subtracting a constant
// does not change the shape of the curve ahead, only slides the whole
// building sideways, so the walls do not swim as the camera pushes - they
// wind past the way a real corridor winds. An eye.x of -0.5 still stands you
// half a metre off the centreline, because only z feeds the offset.
#define STEP 0.84

float3 bendSpace(float3 p)
{
    float2 o = (bendOffset(p.z) - bendOffset(gCam.z)) * saturate(gTune.z);
    p.x -= o.x;
    p.y -= o.y;
    return p;
}

// Which door cell we are in. The left run is pushed along the corridor so
// the two sides never line up: a symmetric corridor reads as a diagram, an
// offset one reads as a building. The branch makes these functions
// discontinuous at x = 0, which is harmless - at x = 0 the door term is more
// than a metre negative and the union below throws it away.
float doorCell(float3 q)
{
    float z = q.z + ((q.x < 0.0) ? vDoorP * vDoorO : 0.0);
    return floor(z / vDoorP + 0.5);
}

float doorLocalZ(float3 q)
{
    float z = q.z + ((q.x < 0.0) ? vDoorP * vDoorO : 0.0);
    return z - floor(z / vDoorP + 0.5) * vDoorP;
}

// Is this the one doorway that is standing open?
bool isOpenDoor(float3 q)
{
    return vOpen > 0.5 &&
           abs(doorCell(q) - vOpenK) < 0.5 &&
           (((q.x < 0.0) ? -1.0 : 1.0) == vOpenS);
}

// The field, evaluated in bent space. Positive in the air, negative in the
// fabric of the building.
float mapQ(float3 q)
{
    float st = secT(q.z);
    float W  = vW0 + vSecW * st;
    float H  = vH0 + vSecH * st;

    // min() of the four half spaces is the exact distance everywhere except
    // in the corners, where it is short. Short is the safe direction.
    float d = min(min(q.y, H - q.y), W - abs(q.x));

    // A door is a recess cut back into the wall, so what we are doing is
    // unioning two volumes of AIR. Union of fields that are positive inside
    // is max(), not min().
    //
    // The recess runs from 150 mm IN FRONT of the wall to 220 mm behind it,
    // and that overlap is not cosmetic. If the box merely met the wall plane
    // then on the door mouth both terms would be exactly zero, max() would
    // return zero across the whole opening, and every ray heading into a
    // doorway would register a hit on thin air - the doors would render as
    // flat wall, which is exactly what they did. Overlapping the two air
    // volumes leaves the field comfortably positive in the opening. The part
    // of the box that sticks into the corridor carves nothing, because it is
    // air already.
    //
    // The open one is cut a metre deep instead of 185 mm, so it is a real
    // alcove with a back wall the ray can reach and a lit panel on it. That
    // is the only piece of the building that is not the corridor.
    //
    // The cell index and the offset into the cell are derived from one
    // divide here rather than by calling doorCell() and doorLocalZ() - this
    // is the innermost line in the file, run a hundred times a pixel, and
    // the second divide was pure duplication.
    // vOpenK is parked at a cell no ray will ever reach when this shot has
    // no open door, so the test below is the whole of it - there is no
    // "is there one" branch left in the inner loop, and the side test is a
    // sign product rather than a select.
    float dz  = q.z + ((q.x < 0.0) ? vDoorP * vDoorO : 0.0);
    float cel = floor(dz / vDoorP + 0.5);
    float dep = (abs(cel - vOpenK) < 0.5 && q.x * vOpenS > 0.0) ? 0.95
                                                                : 0.185;

    float3 dp = float3(abs(q.x) - (W + 0.035), q.y - 1.06,
                       dz - cel * vDoorP);
    d = max(d, -sdBox(dp, float3(dep, 1.06, vDoorHZ)));

    return d;
}

float map(float3 p) { return mapQ(bendSpace(p)); }

// Tetrahedral four tap rather than the usual six. Two fewer field
// evaluations, and at 360 lines nobody has ever seen the difference.
float3 mapNormal(float3 p)
{
    float2 k = float2(1.0, -1.0);
    float  e = 0.0022;
    return normalize(k.xyy * map(p + k.xyy * e) +
                     k.yyx * map(p + k.yyx * e) +
                     k.yxy * map(p + k.yxy * e) +
                     k.xxx * map(p + k.xxx * e));
}

// There are no shadow rays in this scene. The only occluders are the door
// recesses, and a corridor lit from a line of sources directly overhead has
// almost no cast shadow to speak of - what it has is contact darkening in
// the wall-to-floor junction and inside the reveals, which is exactly what
// ambient occlusion gives us for four samples instead of forty.
float occlusion(float3 p, float3 n)
{
    float o = 0.0, s = 1.0;
    [loop] for (int i = 0; i < 4; i++) {
        float d = 0.055 + 0.20 * float(i);
        o += (d - map(p + n * d)) * s;
        s *= 0.62;
    }
    return saturate(1.0 - 1.7 * o);
}

// What the fitting in cell cn is doing. Most are simply on. About one in
// eleven is dead, which is what stops the receding ladder from being a
// perfect ruler and gives the corridor its dark gaps. About one in fourteen
// is failing, and that is the one the eye goes to and stays on.
//
// On top of that, and this is what stops a held shot being a still: a slow
// sag travelling down the run, and a ballast flutter per fitting. Both are
// SPATIAL - adjacent bays are 0.85 rad apart in the sag and have unrelated
// flutter phases, so at any instant the frame holds two full cycles of it
// and the total light in the picture does not move. That is the whole
// safety argument. A ten percent swing on one bay out of fifteen is a
// corridor with bad wiring; the same ten percent applied to all of them at
// once is a strobe, and this file will not do that.
float tubeLevel(float cn, float t)
{
    float h   = hash11(cn);
    float lvl = (h < 0.09) ? 0.06 : 1.0;

    if (h > 0.93) {
        // A failing tube strikes and drops out in steps. Driving it from a
        // sine makes it pulse, which reads as a special effect; holding a
        // random value for a tenth of a second reads as a dying tube.
        //
        // The frame index is wrapped at 251 - a prime, so it does not beat
        // against the cell index. Unwrapped it reaches 1740 by the end of a
        // three minute song and hands sin() an argument of forty thousand
        // radians. An NVIDIA part range-reduces that correctly and the
        // flicker is unchanged; not every driver does, and a hash whose
        // quality depends on how good somebody's sin() is at 4e4 rad is a
        // hash that will one day freeze the failing tube on a machine that
        // is not this one. It costs two instructions not to find out.
        //
        // Four times in five it is simply lit. A tube that is disturbed half
        // the time is a strobe, not a fault, and because this fitting lights
        // its whole bay - a dropout moves about a fifth of the pixels in the
        // frame - anything busier than this fights the cut for attention.
        float fi = floor(t * 10.0);
        fi -= 251.0 * floor(fi / 251.0);
        float r = hash11(cn * 3.71 + fi * 1.93);
        // The dying tube fails harder when the hats are busy. The tube
        // holds its value at 10 Hz and a sixteenth-note hat at 132 BPM is
        // 8.8 Hz: close enough to feel related, too far apart to ever lock.
        // So it reads as a coincidence, which is what a diegetic light
        // answering the music has to read as.
        float thr = 0.12 + gSync.z * 0.10;
        float f = (r < thr) ? 0.05 : ((r < thr + 0.08) ? 0.45 : 1.0);
        lvl = lerp(lvl, lvl * f, saturate(gTune.w));
    }

    // The sag. One cycle every seven or eight bays, walking towards the
    // camera at about a metre and a half a second.
    lvl *= 0.90 + 0.10 * sin(cn * 0.85 - t * vWaveS + vWavePh);

    // The ballast. Every fitting hums at its own rate, a few percent.
    lvl *= 0.965 + 0.035 * sin(t * (2.7 + 2.4 * h) + h * 19.0);

    // And the whole run leans on the low end of the mix. base * (1 + k*s),
    // so the floor of the light never drops out.
    //
    // Seven percent, and the number is the one thing on this line that is
    // not taste. This term is the ONLY one in the file that moves the whole
    // frame at once - the sag and the flutter are per bay and cancel across
    // the picture - so it is the only one that could add a qualifying
    // transition to the photosensitivity count, and the guideline's floor
    // for that is a ten percent change of relative luminance. Seven leaves
    // the margin on the right side of it while still being visible on a
    // held shot, which is the whole reason it is here.
    lvl *= 1.0 + 0.07 * gSync.x;

    return lvl;
}

// The lit rectangle of the fitting in cell cn, box filtered, in whichever of
// the four shapes this shot is built with. g grows the rectangle, which is
// how the surround that frames it is drawn from the same function. wx is the
// filter width across the corridor, wz the one along it - they are not the
// same number, because a ceiling seen at a grazing angle compresses z into
// the pixel and leaves x alone.
float fitCov(float2 xz, float cn, float g, float wx, float wz)
{
    float cz = bandCov(xz.y - cn * vFixP, vFixHZ + g, wz);
    if (vStyle > 0.5 && vStyle < 1.5) {
        // Twin. saturate() of the sum rather than a max, so the two boxes
        // still antialias correctly where they do not overlap.
        return saturate(bandCov(xz.x - vFixOX, vFixHX + g, wx) +
                        bandCov(xz.x + vFixOX, vFixHX + g, wx)) * cz;
    }
    return bandCov(xz.x, vFixHX + g, wx) * cz;
}

// The reflection lobe ACROSS the corridor, which is a different shape for
// each fitting type: a point for a troffer, a pair for the twin, a broad
// flat top for a cross batten. A Lorentzian rather than a box - see the note
// at the call site.
float lobeX(float x, float xw)
{
    float w2 = xw * xw;
    if (vStyle > 0.5 && vStyle < 1.5) {
        float a = x - vFixOX, b = x + vFixOX;
        return saturate(w2 / (w2 + a * a) + w2 / (w2 + b * b));
    }
    if (vStyle > 1.5 && vStyle < 2.5) {
        float e = max(abs(x) - vBatW * 0.70, 0.0);
        return w2 / (w2 + e * e);
    }
    return w2 / (w2 + x * x);
}

// Light coming out of the one open doorway, landing on the floor and the
// bottom of the far wall. It is not a steady lamp: whatever is in that room
// is on its own clock, which is most of why the doorway reads as somewhere
// else rather than as a hole in this scene.
float3 openSpill(float3 q, float t)
{
    if (vOpen < 0.5) return float3(0.0, 0.0, 0.0);
    float dz = (q.z - vOpenZ) * 0.78;
    float az = exp(-dz * dz);
    float dw = max(corrW(q.z) - vOpenS * q.x, 0.0);   // 0 at the open wall
    float ax = exp(-dw * 0.70);
    float fl = 0.86 + 0.10 * sin(t * 2.3) + 0.04 * sin(t * 5.7 + 1.1);
    return vOpenCol * (az * ax * fl);
}

// ---- shading -------------------------------------------------------------

float4 main(VSOut i, out float depth : SV_Depth) : SV_Target
{
    setupVariant();

    depth = 0.0;   // far, under reversed Z
    float2 uv = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
    // y is FLIPPED here on purpose. The fullscreen triangle emits
    // uv.y = 0 at the top of the screen, so i.uv*2-1 gives -1 up
    // there and the top of the frame ended up looking DOWNWARD -
    // the cathedral vault springs at y=+12 and was rendering in the
    // lower half, the monolith hung from the ceiling.
    uv.x *= gTime.w;

    float3 fw = normalize(gDir.xyz);
    // A crane in a corridor is a shot somebody will write, and cross(up, fw)
    // is zero when it points at the ceiling - which is a normalize of zero
    // and a screen of NaN. Two instructions to never see that.
    float3 wu = (abs(fw.y) > 0.999) ? float3(0.0, 0.0, 1.0)
                                    : float3(0.0, 1.0, 0.0);
    float3 rt = normalize(cross(wu, fw));
    float3 up = cross(fw, rt);
    float  cr = cos(gDir.w), sr = sin(gDir.w);
    float3 ro = gCam.xyz;
    float3 rd = normalize(fw + (uv.x * (rt * cr + up * sr) +
                                uv.y * (up * cr - rt * sr)) * gCam.w);

    float tm = gTime.x;

    float t    = 0.0;
    float haze = 0.0;
    bool  hit  = false;

    // 100 steps. Down the axis the field is bounded by the eye's height off
    // the floor, so a step is about 1.3 m and 100 of them run past the fog;
    // the steps are spent on rays that graze the floor near the vanishing
    // point, which converge geometrically. The hit epsilon opens up with
    // distance for the same reason - a 25 mm error at 10 m is a tenth of a
    // virtual pixel.
    [loop] for (int k = 0; k < 100; k++) {
        float3 p = ro + rd * t;
        float3 b = bendSpace(p);
        float  h = mapQ(b);

        // Air glow along the run of tubes. In bent space the run is a single
        // straight line at x = 0 just under the ceiling, so the radius is
        // simply how far off that line this sample sits. It is the one thing
        // that makes the corridor read as full of air rather than vacuum,
        // and it costs a dot and a reciprocal per step.
        //
        // The height is taken at the CAMERA rather than at the sample, which
        // is wrong by up to 0.6 m where the section changes and costs a
        // smoothstep a step to fix. It is a Lorentzian a metre and a half
        // across; being half a metre off centre at thirty metres moves it by
        // a fifth of a virtual pixel.
        float2 rv = float2(b.x, b.y - (vH0 - 0.06));
        haze += (1.0 / (1.0 + dot(rv, rv) * 1.4)) * min(h, 0.9)
                     / (1.0 + t * 0.06);

        if (h < 0.0025 * t + 0.0015) {
            hit = true;
            // ray length projected onto the forward axis: view depth, not
            // distance. The difference only shows at the edges of frame,
            // which is exactly where it would be noticed.
            depth = saturate(0.05 / max(t * dot(rd, fw), 0.001));
            break;
        }
        t += h * STEP;
        if (t > 95.0) break;
    }

    float3 col = float3(0.0, 0.0, 0.0);

    if (hit) {
        float3 p  = ro + rd * t;
        float3 q  = bendSpace(p);
        float3 n  = mapNormal(p);
        float  ao = occlusion(p, n);

        float W = corrW(q.z);
        float H = corrH(q.z);

        // The two filter widths, in metres at the shading point.
        //
        // pw is the width of one virtual pixel measured ACROSS the ray, and
        // it is the honest width for any feature whose cross section lies in
        // the plane the ray is not foreshortening - a horizontal band on a
        // side wall, or the short axis of a ceiling fitting.
        //
        // pwz is that same pixel projected ONTO the surface along the ray,
        // which blows up as the surface turns edge on. It is the width for
        // anything measured down the corridor: floor seams, the long axis of
        // a fitting, the jamb-to-jamb width of a vision slot. Using pw for
        // those would leave the far half of the floor drawn with a filter
        // ten times too narrow, which is exactly where a dither crawls.
        float pw  = max(t * gCam.w * (1.0 / LINES_HALF), 0.0015);
        float pwz = min(pw / max(abs(dot(n, rd)), 0.05), 6.0);

        float3 alb   = float3(0.5, 0.5, 0.5);
        float3 emis  = float3(0.0, 0.0, 0.0);
        float3 spec  = float3(0.0, 0.0, 0.0);
        float3 spill = float3(0.0, 0.0, 0.0);

        bool inReveal = abs(q.x) > W + 0.006;

        if (n.y > 0.5) {
            // What the floor is made of. Three kits, and they are chosen
            // for what they do to the BOTTOM THIRD of the frame rather than
            // for the pattern: tiles put a grid under the perspective,
            // strips put four hard converging lines under it, and welded
            // sheet puts nothing under it at all but comes up two stops
            // lighter, which turns the darkest part of the picture into the
            // second lightest. That last one is also the kindest floor to
            // have a black cat running across.
            float3 base, dk;
            float  seam;
            if (vFloor < 0.5) {
                // Vinyl tile. Big enough that the seams survive a few
                // metres, small enough to read as a floor rather than as
                // flagstones.
                seam = max(gridCov(q.x, vTileP, 0.010, pw),
                           gridCov(q.z, vTileP, 0.010, pwz));
                base = float3(0.178, 0.194, 0.230);
                dk   = float3(0.094, 0.106, 0.132);
            } else if (vFloor < 1.5) {
                // Strip flooring laid down the length of the corridor. No
                // cross seams at all, so the floor gains the same hard
                // convergence the dado and the ceiling grid already have.
                seam = gridCov(q.x, 0.305, 0.011, pw);
                base = float3(0.252, 0.268, 0.300);
                dk   = float3(0.128, 0.140, 0.170);
            } else {
                // Welded sheet, seams every 1.9 m, and PALE - the point of
                // this kit is not the pattern, it is that it lifts the whole
                // bottom third of the frame by two stops. In the other two
                // kits the floor is the darkest block in the picture and it
                // is the darkest block in every other appearance too, which
                // makes it worth nothing at all; here it is the second
                // lightest. It is also much the kindest floor to have a
                // black cat run across.
                seam = gridCov(q.x, 1.90, 0.013, pw) * 0.75;
                base = float3(0.480, 0.492, 0.508);
                dk   = float3(0.352, 0.364, 0.386);
            }
            alb = lerp(base, dk, seam);

            if (vInlay > 0.5) {
                // A contrasting band down the centre line, with a light
                // edging either side of it. One more converging line, and
                // the only one that runs through the vanishing point rather
                // than towards it.
                float bnd = bandCov(q.x, 0.46, pw);
                float edg = saturate(bandCov(q.x, 0.505, pw) - bnd);
                alb = lerp(alb, alb * 0.58, bnd);
                alb = lerp(alb, alb * 1.55, edg);
            }

            // ---- the only mirror in the building -------------------------
            //
            // The floor's shine cannot come out of the five nearest tubes,
            // and this is worth being explicit about because trying it that
            // way is the obvious thing and it produces nothing at all. A
            // floor point D metres ahead of a camera at 1.55 m mirrors the
            // fitting 2.3 D metres FURTHER down the corridor - ten metres
            // out in front of you, you are looking at the reflection of a
            // tube twenty three metres away. No local window of lights
            // contains it, so a Blinn lobe over the neighbours returns two
            // percent of nothing and the bottom third of the frame stays a
            // dead black block.
            //
            // So take the reflection directly: bounce the view ray off the
            // floor, run it up to the height of the tubes, and ask which
            // fitting is standing there. One extra field-free bend and a
            // pair of box filters, and the floor carries the whole ladder
            // again, smeared, dimming with distance, and flickering in step
            // with the tube that is failing.
            if (!inReveal) {
                float3 rr = float3(rd.x, -rd.y, rd.z);
                float  s  = (H - 0.07 - p.y) / max(rr.y, 0.02);
                float3 qm = bendSpace(p + rr * s);
                float  cm = floor(qm.z / vFixP + 0.5);
                // Vinyl is not a mirror, it is a polished floor, so the
                // reflected fitting is smeared - and the two axes of that
                // smear have to be treated completely differently or the
                // whole thing evaporates.
                //
                // ACROSS the corridor the smear is narrow and IS allowed to
                // dim, because that is what sets how wide the band of light
                // on the floor is and how it softens with distance.
                //
                // ALONG the corridor the smear runs to metres, and there it
                // must NOT dim - the whole point is that the separate
                // fittings run together into one continuous streak pointing
                // at the vanishing point. Two things follow. The smear is
                // capped so it never much exceeds the fitting pitch, and
                // THREE cells are summed rather than the nearest one,
                // because a filter wider than half the pitch straddles a
                // cell boundary and a one-cell answer steps visibly as it
                // crosses - which draws a hard horizontal seam straight
                // across the middle of the streak.
                //
                // The sum is then split: the total coverage says how much
                // light lands here, and the coverage-weighted mean of the
                // tube levels says what fraction of it is lit. That keeps
                // the streak continuous while a dead bay still puts a real
                // gap in it, and the failing tube still flickers in it.
                float bwz = min(0.60 + 0.52 * s, vFixP * 0.65);
                float zl  = qm.z - cm * vFixP;
                float c0  = bandCov(zl,           vFixHZ, bwz);
                float c1  = bandCov(zl - vFixP,   vFixHZ, bwz);
                float c2  = bandCov(zl + vFixP,   vFixHZ, bwz);
                float wsum = c0 + c1 + c2;
                float lsum = c0 * tubeLevel(cm,       tm)
                           + c1 * tubeLevel(cm + 1.0, tm)
                           + c2 * tubeLevel(cm - 1.0, tm);
                // Across the corridor the smear is a Lorentzian, not another
                // box. A box filter is the right answer for a pixel, which
                // genuinely is a box; it is the wrong answer for a
                // reflection lobe, because its linear shoulder puts a kink
                // at each edge and the streak comes out as a hard sided
                // wedge lying on the floor. This has no edge at all, which
                // costs one more multiply and is the difference between a
                // reflection and a decal.
                float xw = 0.30 + 0.115 * s;
                float rx = lobeX(qm.x, xw);

                float ref = rx * saturate(wsum * bwz * 1.35)
                               * (lsum / max(wsum, 1e-4));

                // A Fresnel curve, near enough. Nearly nothing straight down
                // at your feet, most of the way to a mirror out where the
                // floor turns edge on - so the streak is faint at the bottom
                // of the frame and brightest running up towards the
                // vanishing point, which is the direction it needs to lead
                // the eye in anyway.
                float ct = saturate(1.0 - abs(rd.y));
                float f  = 0.05 + 0.95 * ct * ct * ct * ct;
                spec = TUBE_COL * ref * f * 0.95 * min(vGloss, 1.15)
                                * (0.6 + 0.4 * vExpo);
            }

            spill = openSpill(q, tm) * 0.42;
        } else if (!inReveal && n.y < -0.5) {
            // Suspended ceiling on a module the variant picks, and the
            // fittings painted onto it. A recessed troffer would be one more
            // box in the field for something that is two pixels tall by the
            // third bay.
            float bar = max(gridCov(q.x, vCeilG, 0.017, pw),
                            gridCov(q.z, vCeilG, 0.017, pwz));
            alb = lerp(float3(0.660, 0.680, 0.630),
                       float3(0.300, 0.320, 0.305), bar);

            float cn  = floor(q.z / vFixP + 0.5);
            float lvl = tubeLevel(cn, tm);
            float ins = fitCov(q.xz, cn, 0.000, pw, pwz);
            float sur = fitCov(q.xz, cn, 0.085, pw, pwz);
            float frm = saturate(sur - ins);

            // A dead tube is still a white plastic diffuser, so the albedo
            // goes light inside the rectangle whether or not it is lit.
            alb = lerp(alb, float3(0.80, 0.84, 0.80), ins);
            alb = lerp(alb, float3(0.11, 0.12, 0.12), frm);

            // The far fittings are rolled off, which is a lie about how
            // light works and an anti-aliasing measure - but it has to be a
            // steep enough lie to actually work. The post pass quantises
            // luminance into ten steps with no gamma, so anything leaving
            // here above 1.0 is the top step and nothing else; a roll-off
            // that only reaches 1.4 at sixty metres has not rolled off at
            // all, it has drawn the entire ladder as clipped white dashes
            // one pixel tall, and one-pixel clipped white is precisely what
            // the dither grid crawls on. exp(-0.055 t) puts the tenth bay in
            // the midtones and the fifteenth in the shadows, so the ladder
            // recedes into the dark instead of fizzing at the end of it.
            // The fittings take only half of the exposure spread. They are
            // already at the top of a ten step ramp, so a shot lit at 1.4
            // would gain nothing up here and only lose the frame around the
            // rectangle; a shot lit at 0.6 needs its tubes to still read as
            // tubes rather than as grey plastic.
            emis = TUBE_COL * 3.6 * vFixGain * (0.52 + 0.48 * vExpo)
                            * lvl * ins * exp(-t * 0.055);

            // A cove strip is not a slab of white paint. It is 340 mm of
            // opal running the length of the corridor, and at the top of
            // the frame it is metres of it seen nearly edge on - so a flat
            // emissive across its full width hands the post pass a solid
            // clipped band along the top edge, which is exactly the shape
            // its chromatic aberration turns into a rainbow. Rolling the
            // cross section off like a real diffuser keeps the centre of
            // the strip at full and takes the edges below the clip, and
            // the band stops fringing.
            if (vStyle > 2.5) {
                float u = saturate(1.0 - abs(q.x) / (vFixHX + 0.001));
                emis *= 0.38 + 0.62 * u * u;
            }
        } else if (inReveal) {
            // Inside a door reveal. The leaf is the face pointing back down
            // the corridor; the jambs and the head are everything else, and
            // they are a shade lighter, so a doorway reads as a shallow box
            // rather than a black rectangle stuck on the wall. All of it is
            // dark - see below - and the door gets its shape from the lit
            // wall around it rather than from anything inside the recess.
            float lz   = doorLocalZ(q);
            bool  open = isOpenDoor(q);
            bool  back = open && (abs(q.x) > W + 0.62);

            if (back) {
                // The back wall of the open alcove, a metre in. Whatever is
                // through there - a north window, a lamp somebody left on -
                // is the only other light in the building, and it is the one
                // thing in this scene that is not the corridor. It is soft,
                // low, and slightly unsteady, which is what makes it read as
                // a room rather than as a hole with a colour in it.
                alb  = float3(0.30, 0.31, 0.32);
                float fl = 0.86 + 0.10 * sin(tm * 2.3)
                                + 0.04 * sin(tm * 5.7 + 1.1);
                float pn = bandCov(q.y - 1.30, 0.72, pw) *
                           bandCov(lz, vDoorHZ * 0.80, pwz);
                emis = vOpenCol * (0.55 + 0.85 * pn) * fl
                                * exp(-t * 0.045);
            } else if (abs(n.x) > 0.5) {
                // Warm, against the green grey of the walls. A recess lit
                // only from an overhead line four metres away is genuinely
                // dark, and that is fine - a row of near black doorways down
                // a dim corridor is the boldest shape in the scene and the
                // one that survives the dither best. The albedo is lifted
                // only far enough to keep it a door rather than a hole.
                alb = float3(0.46, 0.40, 0.34);
                float slot = bandCov(q.y - 1.58, 0.21, pw) *
                             bandCov(lz,         0.15, pwz);
                alb = lerp(alb, float3(0.035, 0.045, 0.050), slot);
            } else {
                alb = float3(0.52, 0.53, 0.49);
                // The jambs of the open one catch the light from inside it,
                // which is what actually sells the depth of the alcove.
                if (open) emis = vOpenCol * 0.16 * exp(-t * 0.045);
            }

            // Past about fifteen metres a doorway is a couple of pixels
            // wide, and its silhouette is geometry - the march resolves it,
            // no filter here can. What CAN be taken away is the contrast:
            // a two pixel near-black bar against a lit wall is the worst
            // thing in this scene to hand an ordered dither, so far reveals
            // are lifted towards the wall they are cut into and become soft
            // dark smudges instead of crawling bars.
            alb = lerp(alb, float3(0.40, 0.42, 0.40),
                       saturate(t * 0.045 - 0.68));
        } else {
            // Two tone, the way every corridor of this kind is painted: dark
            // dado to waist height, off white above, a thin line where they
            // meet, and a skirting. Those horizontals converge on the
            // vanishing point and are most of what gives the shot its depth.
            //
            // WHERE that line sits is a per shot choice now, and it is the
            // cheapest large change in the file: at 0.92 m the frame divides
            // low and the corridor reads tall and institutional, at 1.36 m
            // it divides near the middle and reads squat and much more
            // oppressive. Same corridor, different building.
            //
            // The dado is a MID value, not a dark one, and that is a
            // calibration decision rather than a taste one. There are ten
            // luminance steps in the whole picture. The floor spends steps
            // 1-3 and the upper wall spends 5-7; a dado painted at 0.17
            // albedo lands on the floor's steps, the two merge into one dark
            // L around the bottom of the frame, and the three converging
            // horizontals the shot is built on collapse into one. At 0.34 it
            // sits on step 4, between them, and all three lines are there.
            float dado = stepCov(q.y - vDado, pw);
            alb = lerp(float3(0.335, 0.375, 0.345),
                       float3(0.620, 0.635, 0.590), dado);

            float rail = bandCov(q.y - vDado - 0.005, 0.026, pw);
            alb = lerp(alb, float3(0.055, 0.070, 0.070), rail);

            float skirt = bandCov(q.y - 0.065, 0.065, pw);
            alb = lerp(alb, float3(0.085, 0.095, 0.105), skirt);

            // Vertical joints in a 1.2 m wall panel system. Thin, low
            // contrast, and the only lines in the scene that do NOT converge
            // - which is exactly why they are worth having: they give the
            // eye a ruler to measure the convergence against.
            if (vPanel > 0.5) {
                float j = gridCov(q.z, 1.20, 0.011, pwz);
                alb = lerp(alb, alb * 0.74, j);
            }

            // A handrail on brackets, 900 mm up both sides, with the shadow
            // it throws on the wall under it. Two more converging lines and
            // a repeat down the corridor at a pitch that is nothing like the
            // doors or the lights.
            if (vRail > 0.5) {
                float sh = bandCov(q.y - 0.822, 0.036, pw);
                alb = lerp(alb, alb * 0.58, sh * 0.75);
                float br = bandCov(q.y - 0.858, 0.070, pw) *
                           gridCov(q.z, 1.50, 0.030, pwz);
                alb = lerp(alb, float3(0.130, 0.140, 0.140), br);
                float hr = bandCov(q.y - 0.900, 0.038, pw);
                alb = lerp(alb, float3(0.520, 0.540, 0.520), hr);
            }

            // A run of internal glazing above the dado on one side: windows
            // into a room nobody has turned the lights on in. These are the
            // largest dark shapes in the scene after the doorways, they sit
            // high enough not to fight an actor on the floor, and they only
            // exist on one wall - so the frame stops being symmetrical,
            // which by itself moves the picture more than a hue would.
            if (vGlaz > 0.5 && q.x * vGlazS > 0.0) {
                float gz = q.z - floor(q.z / vDoorP + 0.78) * vDoorP;
                float gy = q.y - (vDado + 0.62);
                float pane = bandCov(gz, 0.74, pwz) * bandCov(gy, 0.46, pw);
                float fram = saturate(bandCov(gz, 0.81, pwz) *
                                      bandCov(gy, 0.53, pw) - pane);
                float mull = bandCov(gz, 0.022, pwz) * bandCov(gy, 0.46, pw);
                alb = lerp(alb, float3(0.075, 0.090, 0.100), pane);
                alb = lerp(alb, float3(0.185, 0.195, 0.190), max(fram, mull));
                // Glass at a grazing angle is a mirror, and down a corridor
                // every pane past the first few IS at a grazing angle - so
                // the run of windows brightens with distance while the wall
                // around it darkens. That inversion is the tell that says
                // glass rather than a painted panel, and it costs three
                // multiplies.
                float gr = saturate(1.0 - abs(dot(n, rd)));
                spec += TUBE_COL * pane * gr * gr * gr * 0.55;
            }

            if (gCaption.y > 0.0 && q.x * vGlazS < 0.0 && abs(n.x) > 0.7) {
                float side = -vGlazS;
                float centerZ = vDoorP * 0.5 - (side < 0.0 ? vDoorP * vDoorO : 0.0);
                float2 textSize = float2(gCaption.x < 1.5 ? 2.275 : 2.485, 0.245);
                float2 uv = float2((centerZ - q.z) * side, vDado + 0.52 - q.y) / textSize + 0.5;
                float ink = inscriptionMask(uv, float2(pwz, pw) / textSize, gCaption.x);
                alb = lerp(alb, float3(0.080, 0.095, 0.085), ink * saturate(gCaption.y));
            }

            spill = openSpill(q, tm) * 0.30 *
                    saturate(1.0 - (q.y - 0.2) * 0.5);
        }

        // The five nearest fittings, treated as short line sources. Beyond
        // two cells either way a tube contributes under two percent and the
        // ambient term below covers the rest of the corridor.
        //
        // There is no specular in this loop. A Blinn lobe here bought the
        // walls an eggshell sheen nobody could see at ten percent gloss, and
        // it could never buy the floor the one highlight that matters - see
        // the mirror above. Five normalizes and five pows, deleted.
        float3 lit = float3(0.0, 0.0, 0.0);
        float  amb = 0.0;
        float  cnc = floor(q.z / vFixP + 0.5);
        bool   cross_ = (vStyle > 1.5 && vStyle < 2.5);

        [loop] for (int j = -2; j <= 2; j++) {
            float cn  = cnc + float(j);
            float cz  = cn * vFixP;
            float lvl = tubeLevel(cn, tm);

            // Nearest point on this tube. This is a bent space vector, but
            // the shading point carries almost exactly the same bend offset
            // as the ceiling directly above it, so the two offsets cancel to
            // first order and the result is already a world space direction -
            // which is the space the normal is in. Unbending it explicitly
            // would cost six more sines to move the light by centimetres.
            //
            // A cross batten is a line running ACROSS the corridor, not
            // along it, and that is not a cosmetic difference: it lights the
            // two walls of a bay evenly and leaves a dark scallop halfway
            // between bays, where a lengthwise troffer does the opposite.
            // The shading pattern down the corridor changes completely.
            float3 lp = cross_
                ? float3(clamp(q.x, -vBatW, vBatW), H - 0.07, cz)
                : float3(0.0, H - 0.07, clamp(q.z, cz - vFixHZ, cz + vFixHZ));
            float3 dv = lp - q;
            float  dd = dot(dv, dv);
            float3 ld = dv * rsqrt(max(dd, 1e-4));
            float  at = lvl * vFixGain / (1.0 + dd * 0.42);

            lit += TUBE_COL * saturate(dot(n, ld)) * at;
            amb += at;
        }
        // Calibrated against the post pass, which quantises LUMINANCE into
        // ten steps with no gamma anywhere: whatever leaves here above 1.0 is
        // simply the top step. The upper wall has to land near 0.6 or the
        // dado, the rail and the door reveals all clip into one white field
        // and the corridor loses every line it had.
        lit *= 2.2 * vExpo;

        // A corridor is a white box, so the bounce is not a rounding error -
        // it is what stops the bottom half of the frame going to one dead
        // black block, which with only ten value steps to spend is the
        // easiest way to lose the shot.
        //
        // Occlusion goes on the bounce, which is the term it actually models,
        // and only very gently on anything else. Multiplying the direct light
        // by it as well - the usual shortcut - took the whole lower half of
        // the frame to the zeroth step of the ramp and turned the doorways
        // into flat holes.
        col  = alb * lit;
        col += alb * float3(0.62, 0.76, 0.70) * amb * 1.85 * vExpo * ao
                   * (0.55 + 0.45 * saturate(n.y));
        col *= 0.72 + 0.28 * ao;
        col += emis + spec + alb * spill * (0.6 + 0.4 * ao);
    }

    // Near black, slightly blue, and thick enough that the corridor is gone
    // by about sixty metres. Between this and the bend, there is no end.
    float fog = exp(-t * 0.017);
    col = col * fog + float3(0.020, 0.024, 0.034) * (1.0 - fog);

    // The haze goes on after the fog because it is air in front of the
    // geometry, not behind it. It leans on the organ, gently: base * (1+k*s),
    // so on a held shot the air itself is doing something.
    col += float3(0.62, 0.80, 0.70) * haze * 0.030 * vExpo
                 * (1.0 + 0.30 * gVoice.z + 0.18 * gSync.y);

    // ---- dust ----------------------------------------------------------
    //
    // Six specks in the near air, drifting on nothing, lit by the run
    // overhead and DEPTH TESTED against the geometry - so one passes in
    // front of a doorway and vanishes behind a wall, which is the whole
    // reason to do it in world space instead of over the top as grain.
    //
    // They are anchored to a coarse grid of the camera's own z rather than
    // to the camera, so a pushing shot moves past them instead of dragging
    // them along; the cells that come and go as it does are twenty metres
    // out and under the distance falloff by then.
    //
    // This is the one thing in the frame that is not architecture, and it is
    // what tells you the corridor has air in it rather than being a picture
    // of one.
    float2 cbo = bendOffset(gCam.z) * saturate(gTune.z);
    float  zc  = floor(gCam.z * 0.25);
    [loop] for (int m = 0; m < 6; m++) {
        // One hash, three numbers off it. A speck of dust does not need
        // three independent random variables, and the two sines saved here
        // are worth more than the correlation costs.
        float fm = float(m);
        float hh = hash11(fm * 2.13 + zc * 0.71 + 3.10);
        float ax = frac(hh * 7.13);
        float ay = frac(hh * 3.71 + 0.37);
        float az = frac(hh * 11.9 + 0.61);

        float3 mp;
        mp.z = gCam.z + 1.9 + (fm + az) * 2.9;
        mp.x = (ax * 2.0 - 1.0) * vW0 * 0.86;
        mp.y = 0.40 + ay * (vH0 - 1.05) - tm * 0.05;
        mp.xy += bendOffset(mp.z) * saturate(gTune.z) - cbo;

        float3 wv = mp - ro;
        float  s  = dot(wv, rd);
        if (s > 0.9 && s < t) {
            float3 pr = wv - rd * s;
            float  rr = 0.0072 + 0.0016 * s;
            float  g  = (rr * rr) / (rr * rr + dot(pr, pr));
            // Dust is only visible where the light is, so it brightens as it
            // drifts up under a fitting and dies out near the floor.
            float  dy = mp.y - (vH0 - 0.85);
            float  ll = 1.0 / (1.0 + mp.x * mp.x * 0.45 + dy * dy * 0.11);
            col += TUBE_COL * (g * g * ll * 0.60 / (1.0 + s * 0.40))
                            * exp(-s * 0.017);
        }
    }

    return float4(col * gTime.z, 1.0);
}
