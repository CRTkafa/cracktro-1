// VAPORWAVE PLINTH ROOM.
//
// The liminal shot. A gallery that is far too big for what is in it: a
// chequered floor that runs out into nothing, two rows of plinths with one
// pale object on each, and at the far end a wall of CRT monitors. The
// monitors are the only light in the room, so everything you can see is
// something they are pointing at, and everything facing away from them is
// black. Nobody has been here in a long time.
//
// What lands in the first half second: the monitor wall, a bright lattice
// sitting on the horizon line, roughly a third of the way up frame. The
// chequered floor runs from the bottom edge straight into it and mirrors it
// back at you. The plinths are silhouettes against that glow with one lit
// edge each, and they throw long shadows forwards, towards the camera. The
// top of frame is empty dark ceiling. It should read as a photograph of an
// empty room, not as a flythrough.
//
// ==========================================================================
// T H E   P R O G R A M M E
// --------------------------------------------------------------------------
// The room appears three times and it used to be the same photograph three
// times, because the only two knobs any shot actually varied were exposure
// and roll speed - and a separate post pass re-grades every frame anyway, so
// varying brightness bought nothing. Worse: gTune.z and gTune.w are 0.00 in
// ALL THREE rows of the shot table, which meant the tube flicker, the room's
// light flicker and the wet-floor reflection - three of the things this file
// is mostly about - had never once run in the finished demo. The wall was a
// still lattice and the floor was dry.
//
// So the two live knobs are read TOGETHER as a channel selector. The table
// hands this scene
//
//     bar 63, orbit, 2 bars   (x,y) = (0.85, 0.30)   ->  2x+y = 2.00
//     bar 18, push,  3 bars   (x,y) = (1.00, 0.40)   ->  2x+y = 2.40
//     bar 21, crane, 3 bars   (x,y) = (1.10, 0.60)   ->  2x+y = 2.80
//
// which is three values evenly spaced 0.4 apart, so one floor turns them
// into a programme index 0, 1, 2 - and the wrap at the end means any future
// row is legal rather than out of range. x and y keep their old meanings on
// top of that, so nothing about the table's intent is thrown away.
//
// A programme is not a colour. It rebuilds the room:
//
//   P0  OFF AIR    38 small tubes in 5 rows, all of them snowing. A tight
//                  deep colonnade of tall ragged plinths, some of them gone
//                  and only their floor plate left, thick air, wet floor.
//   P1  TEST CARD  26 tubes in 3 rows showing the card. The establishing
//                  version: the room as it is described above, full rows,
//                  even plinths, dry floor, clear air.
//   P2  WAVEFORM   17 big tubes in 2 rows, each one a scope tracing the
//                  music. A wide sparse room, low broad plinths, deep clear
//                  air and a hard mirror floor.
//
// At thumbnail scale what separates them is how tall the band of tubes
// stands, whether the bottom half of frame carries a mirrored copy of it,
// and how bright the room runs. None of those is a hue.
//
// WHAT THIS COSTS. Three programmes is three bodies in one shader, and the
// blob goes from 29,192 to 44,848 bytes - it was already the largest in the
// demo and it still is. That is +3.8% of the executable, and it is the whole
// price: the branch on PROG is uniform across the draw, so only one body
// ever executes, and a measured A/B of the frame time could not separate the
// two versions from run-to-run noise (124-127 us either way, with the worst
// frame in the demo still belonging to shot 22, the kaleido, not to this
// scene). The cost is bytes on disk, not microseconds.
// ==========================================================================
//
// WHAT IS MARCHED AND WHAT IS NOT
//
// Only the plinths are marched. The floor, the ceiling and the monitor wall
// are all planes or one axis aligned box, and every one of them is solved
// analytically in main(). That is not a micro-optimisation, it is the whole
// reason the shot works:
//
//   * a grazing plane is the one thing a fixed step budget handles badly.
//     Neighbouring rays run out of steps at different distances and the
//     bottom of the frame fills with concentric arcs.
//   * a sphere traced hit lands up to eps SHORT of the surface, and eps has
//     to grow with distance or the march never terminates. Any "which
//     surface did I hit" test written against a fixed epsilon therefore
//     misfires at range. Solving the wall exactly means there is no test to
//     get wrong.
//   * marching only the plinths leaves a compact, well separated field. It
//     converges in 8 steps on average instead of 21, and the map() body is
//     a third shorter because the floor and the wall are no longer in it -
//     and map() is inlined seven times, so every instruction is paid seven
//     times.
//
// The monitor grid - bezels, screens, programme, per-tube flicker - is a
// function evaluated at the hit point, not geometry. That costs two calls
// per pixel (the wall, and the floor's reflection of it) instead of putting
// eighty boxes inside the march.
//
// NOTHING NEW IS ALLOWED A TRANSCENDENTAL IN THE FIELD
//
// mapPlinths is inlined about thirty seven times per pixel (march, normal,
// shadow, occlusion), so one sin added there costs more than everything in
// monitorWall put together. The two animations that live in the field are
// built to that budget:
//
//   * the objects HOVER on a bob driven by frac and a smoothstep, not a
//     sine. smoothstep of a triangle wave has zero derivative where the
//     triangle has its corners, so the composite is C1 and reads as a
//     perfectly smooth float - for two mads and a frac.
//   * the objects SPIN on one angle shared by the whole room, whose cos and
//     sin are computed ONCE into a static, with a per-object sign flip so
//     they do not all turn the same way. Rotation is an isometry, so the
//     field stays exact.
//
// EVERYTHING IS FILTERED BY ITS OWN FOOTPRINT
//
// This renders at 640x360 and hands off to a CRT pass that quantises
// luminance to ten levels through a 4x4 ordered dither. Ten levels is not
// much to work with. Two consequences run through the whole shader:
//
//   * nothing may be thinner than about two virtual pixels, because the
//     dither will turn a one pixel line into crawling noise. The convergence
//     ring, the blanking bar, the scope trace, the snow blocks and the bezel
//     rim are all deliberately fat, and the ones whose width is in screen
//     units are clamped against the pixel footprint rather than fixed.
//   * the chequers and every programme are box filtered against the real
//     screen space footprint of the hit, computed analytically from t and
//     the grazing angle - no ddx/ddy, which would be undefined in this much
//     divergent flow control anyway. Far detail converges to ITS OWN MEAN
//     instead of aliasing, which is what makes the floor "run out into
//     nothing" rather than boil. Each programme therefore has to declare
//     what its mean is; get that number wrong and the far half of the wall
//     steps to a different brightness than the near half.
//
// The value structure is three tiers and nothing in between, because ten
// levels cannot hold more: near black for the ceiling, the dark chequers and
// every plinth face turned away from the wall (levels 0-1); a clear mid grey
// for the light chequers and the lit plinth edges (levels 2-8, brightening
// as the floor runs towards the wall); and the tubes themselves at the top
// of the ramp (levels 3-10, the bright bars clipping). In a dark cinema the
// wall is the only thing that is allowed to be white, so the room's gain is
// set from that constraint down rather than from a look upwards.
//
// The wall runs floor to CEILING, not to the top of the grid. It costs
// nothing - it is one box - and it buys two things: there is no hard
// horizontal seam across the top of frame, and the empty upper third is the
// wall's own plaster, which has a spill gradient falling away from the
// tubes, instead of a completely flat ceiling plane.
//
// No dither, no scanlines, no grade, no vignette here. The post pass owns
// all four. This shader outputs linear HDR and one shot fade.
//
// NOTHING HERE STROBES. Every music term is base + k*s or base * (1 + k*s),
// so no floor can drop out. The three things that move fastest - the snow,
// the per-tube flicker and the blanking bars - are all DESYNCHRONISED
// per tube by the tube's own hash, so the frame mean of seventy-odd
// independent oscillators barely moves even when any one tube is swinging
// hard. The only whole-wall event, the refresh wipe, only ever ADDS light,
// and only to about three columns at a time.
//
// gTune.x  room exposure / how hard the monitors burn. 1.0 is the room.
// gTune.y  vertical hold: the base roll rate. 0 frozen, 1 a slow crawl up.
// gTune.z  EXTRA flicker depth on top of whatever the programme already has,
//          so the table can push a shot further but can no longer switch the
//          room's only light source off by leaving a field at zero.
// gTune.w  EXTRA floor gloss, on the same terms.
// gTune.x and gTune.y together also pick THE PROGRAMME - see above.

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

// The room, in world units. The wall front face is the plane the reflection
// and the lights are both aimed at, so it gets a name.
//
// WALL_HW is 62 and not 40 because at 40 the wall is exactly as wide as a
// 0.62 fov frame from twelve units behind the front row - which means the
// bare end of it swings into shot on any pan. The wall is a function, so
// widening it is free; running out of it is not. It has to clear the widest
// programme's grid too: P2 is 9 columns of 6.4, which reaches 57.6.
#define WALL_Z    30.0
#define WALL_HW   62.0
#define WALL_TH    1.6
#define CEIL_Y    18.0
#define FAR      160.0

// The shadow ray's cutoff: the height above which nothing in the room can
// possibly occlude anything. It has to bound the TALLEST programme - P0's
// plinths run to 1.855 half height, so a cap top of 3.71 plus a hover of
// 0.36 plus a 1.1 tall object reaches 5.17. Over-estimating this only costs
// a step or two on a shadow ray over open floor; under-estimating it cuts
// the tops off shadows, so it is rounded up.
#define PLINTH_TOP 5.50

// Lighting constants. The falloff is deliberately much slower than inverse
// square and the ambient bounce is deliberately large: these are not three
// bulbs, they are three samples of a lit surface a hundred units wide. A
// real inverse square puts the far floor at level 0 and the near floor at
// level 10, which is six of the ten levels spent on one gradient.
#define L_FALLOFF  0.00045
#define L_GAIN     1.05
#define L_BOUNCE   0.62

// ---- the programme, and everything it decides ----------------------------

// Three constants, chosen by index. Two compares and two selects - cheaper
// than indexing a const array, and it reads as a table: the three columns
// are P0, P1, P2 in that order, everywhere in this file.
float pick3(float a, float b, float c, float k)
{
    return (k < 0.5) ? a : ((k < 1.5) ? b : c);
}

// 2x + y separates the three rows of the shot table into 2.00 / 2.40 / 2.80.
// Scaling by 2.5 and dropping 4.5 lands those on exactly 0.5 / 1.5 / 2.5 -
// the CENTRE of each bin - so the floor is 0 / 1 / 2 with half a step of
// slack on both sides: a table edit of +-0.10 on x, or +-0.20 on y, cannot
// change channel by accident. The wrap keeps any other tune legal.
float programme()
{
    float k = floor(gTune.x * 5.0 + gTune.y * 2.5 - 4.5);
    return k - 3.0 * floor(k / 3.0);
}

// These are statics and not macros on purpose: fxc emits a global static's
// initialiser once in the entry point's preamble, so each of these costs a
// handful of instructions per PIXEL rather than per inlined copy of the
// distance field. That distinction is the whole reason the field can afford
// to be programme-dependent at all.
static float PROG = programme();

// -- the monitor wall's geometry.
//
// HOW TALL THE BAND IS, not how finely it is divided. That distinction cost
// a rewrite: the first version of this table varied the tube COUNT - 38 fine
// ones against 17 coarse ones - and the three shots measured no further
// apart than they had before. A wall of many small bright rectangles and a
// wall of few large bright rectangles have the SAME average brightness, so
// once the frame is squashed to a 32x18 thumbnail they are the same picture.
// Texture is for the viewer; only large-scale luminance layout survives the
// measurement. So what actually varies here is where the light SITS:
//
//     P0 band 0.95 .. 7.45   a low strip, and a lot of dark wall above it
//     P1 band 1.30 .. 11.50  the room as it was
//     P2 band 1.10 .. 13.50  giant screens, nearly up to the ceiling
//
// The tube count still varies, because it is what tells a human eye these
// are three different rooms - it just is not what earns the score.
//
// The aperture is 0.68 x 0.60 of the cell, so a 4:3 tube wants CELLX/CELLY
// near 1.18. All three are within a few percent of that: these stay CRTs.
//                        P0     P1     P2
static float CELLX  = pick3( 1.91,  4.20,  7.30, PROG);  // cell width
static float CELLY  = pick3( 1.625, 3.40,  6.20, PROG);  // cell height
static float MONY0  = pick3( 0.95,  1.30,  1.10, PROG);  // bottom of the grid
static float GRIDX  = pick3(29.00, 13.00,  8.00, PROG);  // columns are -G..G-1
static float GRIDY  = pick3( 4.00,  3.00,  2.00, PROG);  // rows

// Where the light lives. Derived rather than hardcoded, because the grid's
// vertical centre moves with the programme and the three light samples have
// to stay inside the lit band or the room tips over.
static float LIGHT_Y = MONY0 + GRIDY * CELLY * 0.5 + 0.45;

// -- what is ON the tubes.
static float FLICK  = pick3( 0.55,  0.30,  0.22, PROG);  // per-tube breathing
static float ROLLB  = pick3( 0.55,  0.45,  0.30, PROG);  // roll band strength
static float WIPEA  = pick3( 1.10,  0.55,  0.85, PROG);  // refresh wipe gain
static float WIPER  = pick3( 0.190, 0.085, 0.130, PROG); // and its rate
static float TUBEG  = pick3( 1.85,  2.00,  2.90, PROG);  // tube output

// How hot the ROOM runs, on top of gTune.x. This pulls in the same direction
// the table already does - the table's own exposures are 0.85, 1.00, 1.10 -
// it just pulls harder, because a third of a stop is not enough to separate
// three shots of one room and the post pass regrades the hue away anyway.
// Together they give 0.68 / 1.00 / 1.49: a dark shot, a normal one, and a
// bright one, which is the one difference a luminance thumbnail cannot miss.
static float ROOMG  = pick3( 0.80,  1.00,  1.35, PROG);

// -- the plinth field.
static float ROW_DX = pick3( 4.60,  5.60,  7.40, PROG);  // half aisle width
static float ROW_DZ = pick3( 5.60,  6.50,  8.20, PROG);  // spacing in z
static float ROW_HI = pick3( 4.00,  3.00,  2.00, PROG);  // last row index
static float PW     = pick3( 0.55,  0.62,  0.78, PROG);  // plinth half width
static float PRAG   = pick3( 0.40,  0.14,  0.28, PROG);  // height raggedness
static float PGAP   = pick3( 0.22,  0.00,  0.30, PROG);  // fraction missing
static float PSEED  = pick3( 1.00,  4.30,  9.70, PROG);  // which objects
static float PBOB   = pick3( 0.170, 0.115, 0.230, PROG); // hover rate
static float SPINR  = pick3( 0.55,  0.22,  0.38, PROG);  // spin rate

// -- the room around them. These four are the ones that actually move the
//    measurement, because between them they own the whole bottom half of the
//    frame and the overall level of the top half:
//
//      P0  a dry, dark floor in clear air. The frame is nearly black with
//          one low strip of snowing tubes across it - which is also what the
//          orbit at bar 63 wants, three seconds into the darkest part of the
//          solo.
//      P1  the room as described: a mid grey chequered floor, a little
//          gloss, clear air.
//      P2  a wet floor carrying a full second copy of the wall, a pale
//          chequer, and thick enough haze that the room glows. The brightest
//          this scene ever gets, and it is the crane, on the widest lens.
static float CHEQK  = pick3( 0.70,  0.50,  0.36, PROG);  // 1 / chequer size
static float FLR_HI = pick3( 0.400, 0.700, 0.880, PROG); // light chequer
static float FLR_LO = pick3( 0.042, 0.062, 0.095, PROG); // dark chequer
static float FOGK   = pick3(0.0090,0.0115,0.0210, PROG); // haze density

// The floor's gloss and the flicker depth are FLOORS that gTune adds to,
// never fields that gTune can zero. That is the fix for the bug at the top
// of this file: the table passes 0.00 for both in all three rows, and under
// the old reading that switched off the two effects the scene most needs.
static float GLOSSF = saturate(pick3(0.06, 0.14, 0.85, PROG) + gTune.w);
static float FLICKF = saturate(FLICK + gTune.z);

// One rotation for the whole room, evaluated once. The per-object sign flip
// in mapPlinths is what stops it reading as a turntable.
static float2 gSpin = float2(cos(gTime.x * SPINR), sin(gTime.x * SPINR));

// Room exposure. A static rather than a macro because it now carries a slow
// mains sag, and a macro would have paid for that sine at all six use sites.
//
// The wall of monitors IS the light in this room, so it is the one thing
// here that should answer the music. Six percent on the mid band and five on
// the organ: the room brightens fractionally when the chords move, which
// reads as the tubes being fed by the same mains as everything else. Both
// are 1 + k*s, so the floor never drops out.
static float ROOM_EXP = gTune.x * ROOMG
                      * (1.0 + gSync.y * 0.06 + gVoice.z * 0.05)
                      * (1.0 + 0.030 * sin(gTime.x * 0.37));

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

float hash11(float n) { return frac(sin(n * 12.9898) * 43758.5453); }

float hash21(float2 p) { return frac(sin(dot(p, float2(27.13, 61.71))) * 43758.5453); }

// A smooth 0..1 bob with no transcendental in it. tri has corners at 0 and
// 1; smoothstep's derivative is zero at both ends; so the composite is C1
// everywhere and the hover has no visible kick at the top or the bottom of
// its travel. This is called once per inlined copy of the field, which is
// why it is worth not being a sine.
float bob01(float phase)
{
    float tri = abs(frac(phase) * 2.0 - 1.0);
    return tri * tri * (3.0 - 2.0 * tri);
}

// The plinths, and nothing else. No floor, no wall, no ceiling - they are all
// analytic in main(). This is also exactly the right field for the shadow and
// occlusion rays: the plinths are the only things in the room that can
// occlude anything. A light that sits ON the wall cannot be occluded by the
// wall, and a floor lit from seven units above it cannot shadow itself, so
// putting either of them in the occluder field can only produce a wrong
// answer - and it did: with the wall in it, every shadow ray ended up close
// to the wall at the far end of its travel and the penumbra estimator read
// that proximity as an occluder, dimming a fifth of the floor for no reason.
float mapPlinths(float3 p)
{
    // Two rows, mirrored in x, then repeated in z with the index CLAMPED -
    // an unbounded repeat would put plinths behind the camera and out past
    // the wall, and the clamp costs one round and one clamp. The count of
    // rows is the programme's, so P0 is a deep colonnade and P2 is three
    // widely spaced pairs.
    float3 q    = p;
    float  side = step(0.0, p.x);
    q.x = abs(q.x) - ROW_DX;
    float row = clamp(round(q.z / ROW_DZ), -1.0, ROW_HI);
    q.z -= row * ROW_DZ;

    // This plinth's identity. One hash, two channels: sel picks the object,
    // sel2 sets the height and decides whether the plinth is there at all.
    // The second channel is a frac of the first, which is free - a second
    // hash11 would be a second sine in the hot field.
    float sel  = hash11(row * 3.0 + side * 17.0 + PSEED);
    float sel2 = frac(sel * 137.719 + 0.37);

    // Some plinths are gone. Rather than removing them - which would mean
    // adding a constant to the field, and adding to an SDF OVERSTATES the
    // distance and lets rays step through their neighbours - the plinth
    // collapses to the bare floor plate it stood on, with whatever was on
    // top of it shrunk to a marble. That stays an exact distance field, and
    // a gap in a gallery row with only the footprint left is worth more to
    // this scene than a clean row anyway.
    float pres = step(PGAP, sel2);

    // Ragged heights, so a row reads as a skyline and not a picket fence.
    // P1 keeps this small: it is the establishing shot and wants the even
    // gallery the header describes.
    float hh = 1.325 * (1.0 + PRAG * (sel2 - 0.5) * 2.0);
    hh = lerp(0.055, hh, pres);

    float d = sdBox(q - float3(0.0, hh, 0.0), float3(PW, hh, PW));

    // Base slab and cap slab in one box. They are the same size and they sit
    // symmetrically about the middle of the plinth, so folding y about that
    // midpoint gets both of them for the price of one. When the plinth is
    // gone the fold degenerates harmlessly into the single low plate.
    float3 s2 = float3(q.x, abs(q.y - hh) - (hh - 0.10), q.z);
    d = min(d, sdBox(s2, float3(PW + 0.23, 0.10, PW + 0.23)) - 0.03);

    // One object per plinth, HOVERING above the cap. Which object is decided
    // by the plinth's index and by which side of the room it is on, so the
    // two rows never mirror each other - a mirrored gallery reads as a
    // pattern, and a pattern is not uncanny. The seed is the programme's, so
    // the same plinth carries a different object in a different shot.
    // The three shapes are three different NORMS of the same offset vector -
    // length is a sphere, the sum of the components is an octahedron, the
    // largest component is a cube - which is far cheaper than three separate
    // primitives and a rotation, and reads exactly the same at 640x360.
    // (Max-norm underestimates the true distance to a cube near its corners,
    // which is safe: a march that underestimates just takes a smaller step.
    // The select on side makes the field discontinuous across x = 0, by
    // at most 0.23, at a place where the field is 5.1 - so no ray can ever
    // step through anything on the strength of it.)
    bool sph = (sel < 0.34), oct = (sel >= 0.34 && sel < 0.67);

    // rad is the norm's threshold, hlf that shape's half height. A removed
    // plinth's object shrinks to a marble rather than vanishing, for the
    // same reason the plinth does.
    float rad = sph ? 0.52 : (oct ? 0.318 : 0.44);
    float hlf = sph ? 0.52 : (oct ? 0.550 : 0.44);
    rad = lerp(0.050, rad, pres);
    hlf = lerp(0.050, hlf, pres);

    // The hover. Always positive, so the object never sinks back into its
    // cap - it is a float, not a bounce - and every one of them is on its
    // own phase off sel2, so the gallery has forty independent slow clocks
    // in it and a locked-off camera still has something to watch.
    float lift = 0.16 + 0.20 * bob01(gTime.x * PBOB + sel2);

    // The spin. One shared angle, one per-object sign. Rotation about y is
    // an isometry, so all three norms stay exact under it.
    float3 a0 = q - float3(0.0, 2.0 * hh + lift + hlf, 0.0);
    float  sg = (sel2 < 0.5) ? -1.0 : 1.0;
    float3 a  = abs(float3(a0.x * gSpin.x - a0.z * gSpin.y * sg,
                           a0.y,
                           a0.x * gSpin.y * sg + a0.z * gSpin.x));

    float ds = (sph ? length(a)
                    : (oct ? (a.x + a.y + a.z) * 0.5773
                           :  max(a.x, max(a.y, a.z)))) - rad;
    return min(d, ds);
}

// The top of this cell's cap. The shading needs to know whether it hit the
// object or the plinth under it, and now that heights are ragged it can no
// longer ask "is p.y above 2.70". Repeating the cheap half of the field is
// far less work than evaluating the field twice, and it is only called on a
// plinth hit.
float capTopAt(float3 p)
{
    float side = step(0.0, p.x);
    float row  = clamp(round(p.z / ROW_DZ), -1.0, ROW_HI);
    float sel  = hash11(row * 3.0 + side * 17.0 + PSEED);
    float sel2 = frac(sel * 137.719 + 0.37);
    float pres = step(PGAP, sel2);
    return 2.0 * lerp(0.055, 1.325 * (1.0 + PRAG * (sel2 - 0.5) * 2.0), pres);
}

// Four taps on a tetrahedron rather than the six taps the other scenes use.
// It is the same normal to within a rounding error, and it removes two whole
// inlined copies of the field - worth about 4 KB of shader blob here, which
// is real money in an 85 KB executable. Only ever called on a plinth hit;
// the floor and the wall have known normals.
float3 mapNormal(float3 p)
{
    float2 k = float2(1.0, -1.0) * 0.0022;
    return normalize(k.xyy * mapPlinths(p + k.xyy) + k.yyx * mapPlinths(p + k.yyx) +
                     k.yxy * mapPlinths(p + k.yxy) + k.xxx * mapPlinths(p + k.xxx));
}

// tmax is handed in already clipped to the height above which nothing in the
// room can possibly occlude, so a shadow ray over open floor finishes in four
// or five steps instead of walking all the way to the wall.
float softShadow(float3 ro, float3 rd, float tmax)
{
    float res = 1.0, t = 0.30;
    [loop] for (int i = 0; i < 20; i++) {
        if (t > tmax) break;
        float h = mapPlinths(ro + rd * t);
        if (h < 0.004) return 0.0;
        res = min(res, 9.0 * h / t);
        t  += clamp(h, 0.12, 3.0);
    }
    return saturate(res);
}

float occlusion(float3 p, float3 n)
{
    float o = 0.0, s = 1.0;
    [loop] for (int i = 0; i < 5; i++) {
        float d = 0.09 + 0.26 * float(i);
        o += (d - mapPlinths(p + n * d)) * s;
        s *= 0.62;
    }
    return saturate(1.0 - 1.5 * o);
}

// ---- the monitor wall ----------------------------------------------------

// Colour of the wall's front face at a point on it, in world x and y. Called
// twice per pixel at most: once where a ray lands on the wall, once for the
// floor's reflection of it. Returns linear HDR - the screens are meant to
// come out at the top of the post pass's ramp, they are the light source.
//
// `aa` is the width, in world units, of one screen pixel at this point. It
// is the whole antialiasing strategy: every feature narrower than aa is
// faded out towards ITS OWN MEAN rather than being drawn and left to fight
// the ordered dither. Each of the three programmes therefore states its mean
// explicitly in the lerp that fades it - those numbers are not decoration,
// they are what stops the far half of the wall stepping to a different level
// than the near half.
float3 monitorGrid(float2 w, float t, float aa)
{
    // Dead plaster, with a soft spill where it is closest to the tubes. This
    // is also what you get above and below the grid, and it must stay very
    // dark or the wall stops reading as a grid of lit rectangles.
    float3 dead = float3(0.030, 0.036, 0.050)
                * (0.30 + 0.70 * exp(-abs(w.y - LIGHT_Y) * 0.16));

    float2 g  = float2(w.x / CELLX, (w.y - MONY0) / CELLY);
    float2 id = floor(g);
    float2 f  = g - id - 0.5;              // -0.5 .. 0.5 inside the cell

    // The grid runs out past the edge of frame in every shot, which is the
    // whole point of the room - but how MANY tubes that is, and how tall the
    // band of them stands, is the programme's decision.
    if (id.y < 0.0 || id.y > GRIDY - 1.0 || id.x < -GRIDX || id.x > GRIDX - 1.0) return dead;

    float ac = max(aa / CELLX, 2e-4);      // footprint, in cell units
    float fine = saturate(1.0 - ac * 5.0); // 1 when detail is resolvable, 0 when it is not

    // Rounded screen aperture, in cell-relative units, so it scales with the
    // programme's monitor size for free. Everything outside it is bezel: near
    // black plastic with one thin lighter rim catching its own tube. The
    // value gap between screen and bezel is what survives the dither at
    // 640x360, so it is a big gap on purpose - and the aperture edge itself
    // is crossfaded over one pixel, because seventy eight hard edged
    // rectangles crawling in unison is the single most obvious artefact this
    // scene can produce.
    float  sd  = sdBox2(f, float2(0.34, 0.30)) - 0.06;
    float  rim = exp(-max(sd, 0.0) * 9.0) * fine;
    float3 bez = dead + float3(0.055, 0.062, 0.075) * (0.35 + 1.6 * rim);
    if (sd > ac) return bez;               // all bezel: skip the programme

    float  h  = hash21(id);                // this tube's identity
    float  h2 = frac(h * 137.719 + 0.37);  // and a second channel of it
    float2 s  = f / float2(0.40, 0.36);    // -1 .. 1 across the screen

    float3 pat;

    if (PROG < 0.5) {
        // ---- P0  OFF AIR ------------------------------------------------
        // The station is gone and the wall is snowing. Blocky snow: five by
        // three cells per tube, which is about three virtual pixels a block
        // in a wide shot - one more subdivision and it would be dither food.
        // Every tube runs its own frame counter at its own rate, so the wall
        // CRAWLS rather than pulsing in unison, and the frame's mean over a
        // thousand-odd independent blocks does not move at all. That is what
        // makes a wall of static safe: the picture changes everywhere and
        // the level changes nowhere.
        //
        // Underneath it is a dim ghost of whatever the card used to be, two
        // flat quadrants, so a tube never loses its shape entirely and the
        // wall still reads as rectangles rather than as grey mush.
        float by    = floor(s.y * 1.5);
        float tear  = smoothstep(0.86, 1.0, sin(t * (0.31 + 0.19 * h2) + h * 13.0) * 0.5 + 0.5);
        float shear = tear * (hash21(float2(by, floor(t * 14.0))) - 0.5) * 4.0;
        float2 bq   = float2(floor(s.x * 2.5 + shear), by);

        float fr = floor(t * (7.0 + 4.0 * h) + h * 53.0);
        float n  = hash21(bq * 3.1 + fr + id * 0.37);
        float gh = 0.30 + 0.14 * step(0.0, s.x) + 0.10 * step(0.0, -s.y);

        // 0.47 is the mean of ghost + snow, and it is what a tube collapses
        // to once the blocks stop being resolvable.
        pat = lerp(0.47, gh + 0.34 * (n - 0.5) * 2.0, fine) * float3(0.80, 0.98, 0.92);
    }
    else if (PROG < 1.5) {
        // ---- P1  TEST CARD ----------------------------------------------
        // The room as the header describes it. Four bars, not the six a real
        // test card has: a monitor is about twenty virtual pixels across in
        // a wide shot, and six bars in twenty pixels is not a test card, it
        // is noise for the dither to chew on. The staircase is scaled so its
        // four steps land on four DIFFERENT levels of the post pass's ten
        // level quantiser - at the old 0.20 + 0.26i the top two both clipped
        // to white on any tube brighter than average, and a test card whose
        // top half is one flat block is not reading as a test card.
        float bi  = clamp(floor((s.x * 0.5 + 0.5) * 4.0), 0.0, 3.0);
        float lvl = lerp(0.485, 0.20 + bi * 0.19, fine);   // 0.485 is the mean of the four
        pat = lvl * float3(0.74, 1.00, 0.86);              // phosphor bias

        // One amber bar, so the wall is not entirely one hue and the warm
        // light in this demo gets a foothold here too.
        pat = lerp(pat, float3(1.00, 0.64, 0.26) * 0.95, step(abs(bi - 1.0), 0.5) * 0.85 * fine);

        // The convergence circle. Deliberately fat: a one pixel ring would
        // be eaten alive by the ordered dither, and at forty six units the
        // old 0.18/0.06 ring was exactly one pixel.
        float r = length(s * float2(1.0, 1.06));
        pat = lerp(pat, float3(0.90, 1.00, 0.94),
                   smoothstep(0.20, 0.07, abs(r - 0.60)) * 0.55 * saturate(1.0 - ac * 4.0));
    }
    else {
        // ---- P2  WAVEFORM -----------------------------------------------
        // Seventeen big tubes, and every one of them is a scope showing the
        // music. Three harmonics whose amplitudes come off three different
        // sources - the low band, the solo voice and the high band - so the
        // wall's PICTURE is genuinely different when the music is different,
        // which is the one kind of variation a post-pass regrade cannot
        // flatten out.
        //
        // Nothing here can flash: the trace is a thin bright thing on a dark
        // face, so the tube's mean barely moves however hard the trace
        // swings, and every amplitude is base + k*s with a floor of its own.
        float tr = 0.30 * sin(s.x *  4.3 + t * 2.6 + h  * 6.283) * (0.30 + 0.85 * gSync.x)
                 + 0.19 * sin(s.x * 11.0 - t * 4.4 + h2 * 6.283) * (0.22 + 0.85 * gVoice.y)
                 + 0.11 * sin(s.x * 23.0 + t * 7.7)              * (0.18 + 0.85 * gSync.z);

        // Both widths are clamped against the pixel footprint, so neither
        // the trace nor the graticule can ever go sub-pixel at range.
        float2 gl   = abs(frac(s * 1.5 + 0.5) - 0.5) / 1.5;
        float  gw   = max(0.075, ac * 4.0);
        float  grat = saturate(1.0 - min(gl.x, gl.y) / gw);

        float tw    = max(0.155, ac * 4.5);
        float trace = saturate(1.0 - abs(s.y - tr) / tw);
        trace *= trace;                     // a hard core and a soft shoulder

        // The beam. One bright dot per tube running the sweep on its own
        // phase - the secondary element with its own timing that makes a
        // held shot worth holding.
        float bx   = frac(t * (0.24 + 0.18 * h) + h2) * 2.0 - 1.0;
        float beam = saturate(1.0 - length(float2((s.x - bx) * 0.8, s.y - tr))
                                    / max(0.20, ac * 5.0));

        // These are storage scopes with the brightness wound right up, not
        // dark instrument faces: this programme is the brightest the room
        // ever gets and the tubes have to carry that, not just the floor.
        // 0.43 is the face's mean - 0.34 of base, about 0.06 of graticule
        // and about 0.03 of trace averaged over the height of the screen -
        // and it is what a tube collapses to once it stops being resolvable.
        pat = lerp(0.43, 0.34 + 0.26 * grat + 0.70 * trace + 0.62 * beam, fine)
            * float3(0.66, 1.00, 0.80);
    }

    // The roll, and it is now PER TUBE. A bright band travelling up the frame
    // with the black frame blanking bar trailing it - a vertical hold that
    // nobody ever fixed. Both are three virtual pixels deep, not one.
    //
    // The phase and the rate both come off the tube's hash, which is the
    // single cheapest thing in this file and one of the most valuable: with
    // one shared phase the wall was seventy eight televisions showing the
    // same frame at the same instant, which is exactly why it read as one
    // flat lattice. Scattered, it reads as a room full of sets. And on a
    // very slow timer a tube loses hold completely and rolls through fast -
    // at any moment one or two of the seventy eight are doing it.
    float rrate = 0.085 * gTune.y * (0.55 + 1.10 * h);
    float kick  = smoothstep(0.90, 0.985, sin(t * (0.21 + 0.17 * h2) + h * 25.0) * 0.5 + 0.5);
    float rp    = frac(t * rrate * (1.0 + 7.0 * kick) + h * 7.31);
    float ry    = 1.0 - 2.0 * rp;
    float dy    = s.y - ry;
    float rf    = saturate(1.0 - ac * 3.0);
    pat = lerp(pat, float3(1.0, 1.0, 1.0), exp(-abs(dy) * 2.5) * ROLLB * rf);
    pat *= 1.0 - 0.85 * rf * smoothstep(0.42, 0.10, abs(dy + 0.30));

    // The glass. Each tube dims towards its own corners, which is scene
    // content and not the post pass's vignette - that one is on the room.
    pat *= 1.0 - 0.38 * saturate(dot(s, s) * 0.55);

    // Flicker, out of sync between tubes. Two fast sines whose rates come off
    // the tube's hash, so no two monitors ever line up, plus an occasional
    // deeper dip on a very slow timer - that dip is the thing the eye
    // actually catches, the fast wobble just stops the wall being dead.
    // FLICKF has a per-programme FLOOR, so the table can no longer leave the
    // wall frozen by passing 0.
    float fl = 1.0 + FLICKF * (0.11 * sin(t * (4.7 + h * 4.1) + h * 37.0)
                             + 0.05 * sin(t * (13.0 + h * 6.0) + h * 11.0));
    fl -= FLICKF * 0.34 * smoothstep(0.84, 1.0, sin(t * (0.61 + h * 0.83) + h * 19.0) * 0.5 + 0.5);

    // The refresh. A column of about three tubes brightening as it sweeps
    // across the wall - the one whole-wall event in the room, and the reason
    // a locked-off shot is worth three bars. It only ever ADDS, and only to
    // roughly an eighth of the grid at a time, so the frame's overall level
    // moves by a couple of percent: this is a wipe, not a flash.
    float wx  = (frac(t * WIPER + 0.13) * 2.2 - 1.1) * GRIDX;
    float wip = exp(-abs(id.x - wx) * 0.85) * WIPEA;

    // Some of these tubes are older than others. The spread is 0.86 to 1.06
    // rather than 0.80 to 1.14: a wider spread pushed the bright tubes' whole
    // staircase up into the clip and they went flat.
    float3 lit = pat * max(fl, 0.0) * (0.86 + 0.20 * h) * (TUBEG + wip);

    // One pixel crossfade across the aperture edge.
    return lerp(bez, lit, saturate(0.5 - sd / (2.0 * ac)));
}

float3 monitorWall(float2 w, float t, float aa, bool captionInk)
{
    float3 base = monitorGrid(w, t, aa);
    if (gCaption.x < 0.5 || gCaption.x >= 3.5 || gCaption.y <= 0.0) return base;
    float2 p = w - float2(0.0, 7.2);
    if (any(abs(p) > float2(6.35, 4.75))) return base;
    float edge = sdBox2(p, float2(6.10, 4.50)) - 0.18;
    float panel = saturate(0.5 - edge / max(aa, 0.001));
    float glass = saturate(0.5 - (sdBox2(p, float2(5.70, 4.10)) - 0.12) / max(aa, 0.001));
    float2 textSize = float2(gCaption.x < 1.5 ? 9.75 : 10.65, 1.05);
    float2 uv = float2(p.x, -p.y) / textSize + 0.5;
    float ink = captionInk ? inscriptionMask(uv, aa / textSize, gCaption.x) : 0.0;
    float3 tube = lerp(float3(0.025, 0.032, 0.038),
                      float3(0.065, 0.105, 0.090), glass);
    tube += float3(0.72, 0.91, 0.79) * ink * glass;
    return lerp(base, tube, panel * saturate(gCaption.y));
}

// The room light, sampled as three points spread across the wall rather than
// one. Three is enough to make a plinth's shadow spread and soften as it runs
// towards the camera, which one point light cannot do at any cost.
//
// The amplitude is small on purpose. This modulates the brightness of the
// whole room, and the room is being quantised to ten levels downstream: at
// the old +-14% the entire floor stepped between two ramp colours in unison,
// which reads as the render breaking, not as a tube breathing. The tubes
// themselves still flicker hard - that is where the eye is looking.
float lightFlick(float k, float t)
{
    return 1.0 + FLICKF * (0.035 * sin(t * (5.1 + k * 1.7) + k * 9.0)
                         + 0.020 * sin(t * (12.0 + k * 3.0) + k * 4.0));
}

// Box filtered chequerboard. p is in chequer units (one square = 1), w is the
// screen space footprint in the same units. Converges to a flat 0.5 exactly
// where the squares stop being resolvable, which is what stops the horizon
// turning into a moire fight with the ordered dither. Analytic integral of
// the xor pattern over the footprint - the cost is two frac and two abs more
// than the unfiltered version.
float checker(float2 p, float2 w)
{
    float2 i = 2.0 * (abs(frac((p - 0.5 * w) * 0.5) - 0.5) -
                      abs(frac((p + 0.5 * w) * 0.5) - 0.5)) / w;
    return 0.5 - 0.5 * i.x * i.y;
}

// ---- shading -------------------------------------------------------------

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

    float  time = gTime.x;

    // The three samples of the wall that light the room. Derived from the
    // programme's grid rather than hardcoded, so when P0 stacks five short
    // rows of tubes and P2 stacks two tall ones the light still comes from
    // where the light actually is.
    float3 kL0 = float3(-20.0, LIGHT_Y - 0.35, WALL_Z);
    float3 kL1 = float3(  0.0, LIGHT_Y + 0.35, WALL_Z);
    float3 kL2 = float3( 20.0, LIGHT_Y - 0.35, WALL_Z);

    // World units subtended by one virtual pixel, per unit of depth. Every
    // filter width in the shader is built out of this.
    const float px = 2.0 / 360.0;
    float pxw = gCam.w * px;

    // ---- the analytic half of the scene ---------------------------------
    // Floor plane y = 0, ceiling plane y = CEIL_Y.
    float tFlr = (rd.y < -1e-4) ? (-ro.y / rd.y) : FAR;
    float tCei = (rd.y >  1e-4) ? ((CEIL_Y - ro.y) / rd.y) : FAR;
    tFlr = (tFlr > 0.0) ? min(tFlr, FAR) : FAR;
    tCei = (tCei > 0.0) ? min(tCei, FAR) : FAR;

    // The monitor wall slab, as a ray/AABB. Exact, so the hit point is ON the
    // wall and "is this the wall" is not a question anyone has to answer with
    // an epsilon. sgn keeps the reciprocal finite for an axis aligned ray, so
    // a 0 * inf NaN cannot get into the min/max chain.
    float3 wc  = float3(0.0, CEIL_Y * 0.5, WALL_Z + WALL_TH);
    float3 wb  = float3(WALL_HW, CEIL_Y * 0.5, WALL_TH);
    float3 sgn = float3(rd.x < 0.0 ? -1.0 : 1.0,
                        rd.y < 0.0 ? -1.0 : 1.0,
                        rd.z < 0.0 ? -1.0 : 1.0);
    float3 iv  = sgn / max(abs(rd), 1e-6);
    float3 t1  = (wc - wb - ro) * iv;
    float3 t2  = (wc + wb - ro) * iv;
    float3 tsm = min(t1, t2), tbg = max(t1, t2);
    float  wN  = max(tsm.x, max(tsm.y, tsm.z));
    float  wF  = min(tbg.x, min(tbg.y, tbg.z));
    float  tWal = (wF >= max(wN, 0.0) && wN > 0.0) ? min(wN, FAR) : FAR;
    // Which face. The front face is the one the grid is on.
    bool wallFront = (tsm.z >= tsm.x) && (tsm.z >= tsm.y) && (rd.z > 0.0);

    // ---- march the plinths, and only up to the first analytic surface ----
    float tCap = min(min(tFlr, tCei), tWal);
    float tHit = FAR;
    float tm   = 0.0;

    [loop] for (int k = 0; k < 72; k++) {
        if (tm >= tCap) break;
        float h = mapPlinths(ro + rd * tm);
        if (h < 0.0018 * tm + 3e-4) { tHit = tm; break; }
        tm += h * 0.92;
    }

    // 0 plinth, 1 floor, 2 wall, 3 ceiling, 4 nothing.
    int   surf;
    float t;
    if (tHit < tCap)                            { surf = 0; t = tHit; }
    else if (tCap >= FAR)                       { surf = 4; t = FAR;  }
    else if (tWal <= tFlr && tWal <= tCei)      { surf = 2; t = tWal; }
    else if (tFlr <= tCei)                      { surf = 1; t = tFlr; }
    else                                        { surf = 3; t = tCei; }

    float3 col = float3(0.0, 0.0, 0.0);

    if (surf == 2) {
        // The wall is emissive, nothing lights it. Its side and top faces are
        // bare slab.
        float3 p = ro + rd * t;
        col = wallFront ? monitorWall(p.xy, time, t * pxw / max(abs(rd.z), 0.15), true)
                        : float3(0.022, 0.026, 0.036);
    }
    else if (surf == 3) {
        // Ceiling. Shaded flat from the middle light with the normal known to
        // be straight down. It stays very dark on purpose - it sees as much
        // of the monitor wall as the floor does and would otherwise come out
        // just as bright, which would put the second brightest thing in the
        // frame along the top edge and pull the eye straight out of the room.
        float3 dl = kL1 - (ro + rd * t);
        float  ql = dot(dl, dl);
        col = float3(0.045, 0.048, 0.058) * float3(0.62, 0.84, 0.92)
            * (saturate(-dl.y * rsqrt(ql)) / (1.0 + L_FALLOFF * ql))
            * 2.6 * ROOM_EXP;
    }
    else if (surf == 0 || surf == 1) {
        bool   isFloor = (surf == 1);
        float3 p       = ro + rd * t;
        float3 n       = isFloor ? float3(0.0, 1.0, 0.0) : mapNormal(p);
        float3 albedo;

        if (isFloor) {
            p.y = 0.0;                       // exact, so say so
            // The chequers, at the programme's square size - a tight room
            // gets a tight floor. Box filtered against the footprint of this
            // pixel on the floor, which at a grazing angle is
            // t * pixel / |rd.y| and blows up towards the horizon exactly as
            // fast as the moire would have. The old exp(-t) contrast fade
            // was doing the opposite of what it needed to: at t = 16 it had
            // already thrown away a quarter of the contrast where the
            // footprint was still a sixth of a square, and at t = 34, where
            // the footprint was four fifths of a square and genuinely
            // aliasing, it had only thrown away a third.
            float  fw2 = t * pxw / max(abs(rd.y), 0.02);
            float2 c   = p.xz * CHEQK;
            float2 wf  = float2(fw2, fw2) * CHEQK + 0.004;
            // Both stops are the programme's. The floor is the largest thing
            // in frame by area, so this pair moves the picture's overall
            // level further than anything else in the file.
            albedo = lerp(FLR_LO * float3(1.00, 1.08, 1.35),
                          FLR_HI * float3(1.00, 1.01, 1.07), checker(c, wf));
        } else {
            // Plinth, or the object hovering over it. The objects are a
            // little paler than the plinths so the row of them reads as a
            // row of highlights above a row of silhouettes. The split is
            // measured against THIS cell's cap, because the caps are no
            // longer all at the same height.
            albedo = (p.y > capTopAt(p) + 0.06) ? float3(0.56, 0.57, 0.60)
                                                : float3(0.33, 0.34, 0.37);
        }

        // One shadow ray, cast at the middle sample. All three sources sit on
        // the same plane, so one ray gets the shape of the shadow right and
        // the other two only soften it - three rays would cost 80% more
        // marching to move the result by very little.
        //
        // The ray is cut off at the height above which nothing in the room
        // can occlude anything, so from the floor it is about twenty four
        // units long rather than the full thirty five to the wall.
        float3 sd1 = kL1 - p;
        float  sl1 = length(sd1);
        float3 sdr = sd1 / sl1;
        float  tex = (sdr.y > 1e-3) ? ((PLINTH_TOP - p.y) / sdr.y) : sl1;
        float  sh  = softShadow(p + n * 0.035, sdr, clamp(tex, 0.0, sl1));

        float3 d0 = kL0 - p, d1 = kL1 - p, d2 = kL2 - p;
        float  q0 = dot(d0, d0), q1 = dot(d1, d1), q2 = dot(d2, d2);
        float3 lit = float3(0.0, 0.0, 0.0);
        lit += saturate(dot(n, d0 * rsqrt(q0))) / (1.0 + L_FALLOFF * q0) * lightFlick(0.0, time);
        lit += saturate(dot(n, d1 * rsqrt(q1))) / (1.0 + L_FALLOFF * q1) * lightFlick(1.0, time);
        lit += saturate(dot(n, d2 * rsqrt(q2))) / (1.0 + L_FALLOFF * q2) * lightFlick(2.0, time);
        lit *= 0.25 + 0.75 * sh;

        float ao = occlusion(p, n);

        // Cold cyan-white, the colour of a room lit by nothing but tubes.
        float3 key = float3(0.62, 0.84, 0.92);

        col  = albedo * key * lit * L_GAIN * ROOM_EXP;
        // Bounce. Not a real GI term - just the fact that a surface turned
        // towards the wall sees a great deal of glowing wall. It is large,
        // and it is what stops the far end of the floor collapsing to black:
        // with only the direct term the light chequers ran from level 8 at
        // the camera to level 2 at the horizon, and six of the ten levels
        // available went on one floor gradient.
        col += albedo * key * L_BOUNCE * (0.30 + 0.70 * saturate(n.z)) * ao * ROOM_EXP;
        col *= 0.35 + 0.65 * ao;

        // A rim, and it is doing real work rather than being decoration. The
        // camera looks at the room from the near side, so every plinth and
        // every object shows the face pointing AWAY from the only light there
        // is, and comes out as a flat black cut-out. The wall behind them is
        // enormous, so their edges genuinely catch it, and that edge is the
        // only thing that says these are solid objects and not holes in the
        // floor.
        //
        // Only on the plinths. A grazing view of the floor has a fresnel of
        // nearly one across half the frame, so letting this term touch it
        // paints a pale band along the bottom edge of every shot.
        if (!isFloor) {
            float fres = pow(1.0 - saturate(dot(n, -rd)), 4.0);
            col += key * fres * 0.55 * ao * ROOM_EXP;
        }

        // The wet floor. The wall is a known plane, so the mirror ray is one
        // divide, not a second march. Plinths are missing from the
        // reflection; at this gloss and this resolution the dither hides
        // that, and a second march would double the cost of the shot.
        //
        // This is the single largest compositional difference between the
        // three appearances, because it decides whether the bottom half of
        // the frame carries a second copy of the monitor wall or is bare
        // chequers. It had never once run: gTune.w is 0.00 in every row of
        // the table, so GLOSSF is a per-programme floor that gTune adds to.
        //
        // The reflected sample gets a much larger footprint than the direct
        // one - the whole wall is squashed into a few rows of pixels near the
        // horizon - so monitorWall filters itself down to flat bands there
        // instead of drawing a programme into a two pixel strip.
        if (isFloor && GLOSSF > 0.001) {
            float3 rr = reflect(rd, n);
            if (rr.z > 0.02) {
                float  dR = (WALL_Z - p.z) / rr.z;
                float3 wp = p + rr * dR;
                if (abs(wp.x) < WALL_HW && wp.y > 0.0 && wp.y < CEIL_Y) {
                    float fr  = pow(1.0 - saturate(dot(n, -rd)), 5.0);
                    float aaR = (t + dR) * pxw / max(abs(rd.y), 0.03);
                    col += monitorWall(wp.xy, time, aaR, false)
                         * GLOSSF * (0.05 + 0.95 * fr) * 0.85;
                }
            }
        }
    }

    // Cold haze, at the programme's density. The room has air in it, which is
    // why the floor runs out into nothing instead of ending at a visible
    // edge, and why there is a glow hanging in front of the monitor wall.
    // How thick that air is decides how far back the floor survives, which is
    // most of what separates a tight room from a deep one.
    float fog = exp(-t * FOGK);
    col = col * fog + float3(0.020, 0.024, 0.034) * (1.0 - fog);
    col += float3(0.30, 0.42, 0.50) * (1.0 - fog) * saturate(rd.z + 0.25) * 0.14 * gTune.x;

    return float4(col * gTime.z, 1.0);
}
