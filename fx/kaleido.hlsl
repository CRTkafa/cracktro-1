// KALEIDOSCOPIC IFS TUNNEL.
//
// You are falling down a folded throat: a lattice mirrored around the axis
// and repeated down it, streaming past close enough to blur and converging on
// a light you never reach. It belongs under a solo, and it is built so that
// the same shader is several different rooms - a tight four-sided pipe you
// can barely fit through, a twelve-fold cathedral of glass with irises you
// fly through - on the shot knobs alone.
//
// The composition, which is what everything below is in service of: the light
// is a lamp ON THE AXIS, a fixed distance AHEAD of the camera, travelling
// with it. So the far end of the tunnel is blown out, the walls rushing past
// your ear are nearly black, and the relief between the two is raked by a
// light that is always at the vanishing point. That is the entire value
// structure - white core, amber-to-green relief, black near walls - and it
// is the structure that survives a 4x4 Bayer dither at 640x360, where
// anything subtler would not.
//
// ---- WHY THIS FILE IS SHAPED THE WAY IT IS -------------------------------
//
// Eight shots in the edit draw this scene. Measured as thumbnails they were
// too close to each other: the knobs only ever changed the fold ANGLE, the
// IFS scale and the pipe diameter, and at 360 lines through a four-stop ramp
// those three read as the same picture with the contrast nudged. What the
// eye actually sorts a frame by, in the half second a two-bar shot gets, is
// SYMMETRY ORDER and SILHOUETTE - how many arms the star at the vanishing
// point has, and whether the tunnel is a bare pipe or has rings coming at
// you. So the knobs now quantise into a small set of discrete layouts and
// the continuous values ride on top of those.
//
// gTune.x  fold amount   - 0..1. Two jobs. Quantised into five bands it picks
//                          the SYMMETRY ORDER: 4, 6, 8, 10 or 12 sectors
//                          around the axis, and the parity of that band sets
//                          which way the whole thing spins. Continuously it
//                          still drives the IFS rotation between iterations
//                          (blocky and architectural at 0, sheared into
//                          spines at 1), the spin rate, the rate the throat
//                          breathes at, and the colour band spacing.
// gTune.y  IFS scale     - space expansion per iteration, clamped 1.15..2.30.
//                          Low is a dense fine weave, high is a few big
//                          slabs. Its FRACTIONAL part is a second, unrelated
//                          knob: the coarseness floor, which caps how fine
//                          the lattice is allowed to get regardless of how
//                          close it is. A coarse shot is carved out of
//                          slabs, a fine one is filigree.
// gTune.z  openness      - 0 is a tight bore threaded onto the camera, 1
//                          blows the pipe out into a hall and turns on the
//                          glass rim light. Quantised into four bands it also
//                          decides whether the tunnel carries IRIS PLATES -
//                          annular bulkheads rushing past with a hole in the
//                          middle - and how close together they sit.
//                          Continuously it sets cell length down the axis,
//                          rail thickness, twist pitch and fog density.
// gTune.w  hurtle        - EXTRA units per second the structure flows toward
//                          you, on top of a baseline the shot always gets.
//                          The baseline exists because half these shots are
//                          held or whip-panned cameras: with a still camera
//                          and no flow the shot is a photograph, and this is
//                          the scene under the solo.
//
// The eight rows in the table land on eight different (symmetry, structure)
// pairs, which is the point: no two appearances are the same room.
//
// ---- OFF-AXIS SAFETY -----------------------------------------------------
//
// The tunnel used to be nailed to the world axis, so any shot that walked the
// camera sideways buried the lens in solid lattice and the frame went black.
// The axis now follows the camera once the camera has used up its clearance
// inside the bore - free parallax within the throat, and a tow after that.
// It is a translation that depends only on the constant buffer, so it costs
// nothing per step and every argument below about toTube being a pure
// translation still holds.
//
// ---- THE THING THAT MAKES THIS SHADER WORK AT 360 LINES ------------------
//
// A five level IFS with a scale of 2.3 puts its finest strut at th/2.3^5, a
// hair over seven thousandths of a unit. At the demo's fixed 360 virtual
// lines that is sub-pixel from about four units out - which is to say, over
// essentially the whole frame. Rendered flat, that detail does not read as
// detail. It reads as a boiling stipple that the post pass's ordered dither
// then latches onto and amplifies, and in a dark cinema it is the only thing
// anybody sees.
//
// So the field is CONE AWARE. The march carries the radius of the pixel
// footprint at the current depth, and the IFS uses it twice: any level whose
// struts are thinner than one pixel is fattened out to a pixel, and once a
// level falls below that it stops iterating entirely. Fattening keeps the
// strut visible instead of stippling; stopping keeps the compiler from
// spending five iterations resolving something that lands inside one sample.
// The normal and the occlusion are handed the same radius, so all three agree
// on which surface they are looking at. The per-shot coarseness floor rides
// in through exactly the same door - it is a minimum footprint - so it costs
// nothing and it saves iterations on the shots that use it hardest.
//
// Cost: up to 56 march steps, a four tap normal and a five tap occlusion at
// the hit, so 65 distance field evaluations for a pixel that hits and fewer
// for one that does not. Each evaluation is two to five IFS iterations after
// the cone cutoff, plus a rail, plus - on the shots that turn them on - one
// iris plate. No shadow rays: the only real light sits on the axis at the
// vanishing point, so a shadow ray from any visible surface would trace back
// along the camera's own sightline and buy almost nothing off the most
// expensive map in the demo. Occlusion does that job instead, and in a folded
// lattice it is doing most of the shaping.
//
// In wall clock, at the 640x360 the scene target actually runs at: order of
// a millisecond on a mid-range discrete part, a few tenths on a fast one,
// and several milliseconds on integrated graphics.

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

// ---- distance field ------------------------------------------------------

#define LAMP  13.0    // how far ahead of the camera the light sits
#define TAU   6.28318531

// Half the vertical field, in tangent units, divided by half the virtual
// height: the scene target is a fixed 360 lines (gfx.c, VH), so this is the
// tangent subtended by one virtual pixel. Multiplied by depth it is the
// radius of the pixel's footprint out there, which is the only number the
// level-of-detail cutoff needs. It is deliberately biased a little coarse -
// the output is dithered into a narrow ramp, and half a pixel of detail is
// not detail there, it is noise.
#define PIXTAN (1.25 / 180.0)

float2 rot2(float2 v, float a)
{
    float c = cos(a), s = sin(a);
    return float2(v.x * c - v.y * s, v.x * s + v.y * c);
}

// The two radii the tunnel lives between. Shots need the inner one as well -
// it is the safety margin that stops a camera ending up buried in a solid -
// so it is worth having in one place.
float boreRadius(float op) { return 0.80 + 1.70 * op; }
float wallRadius(float op) { return 3.20 + 2.60 * op; }

// ---- the per shot layout -------------------------------------------------
//
// Everything in here reads the constant buffer and nothing else, so it is
// uniform over the whole frame and fxc hoists the lot out of the march. It
// is written as one struct rather than sprinkled through mapT so that the
// eight rows in the table can be read off against it in one place.
struct Cfg
{
    float folds, sec, isec;   // symmetry order and the wedge it implies
    float spin, zTwist;       // rotation in time, and pitch of the spiral
    float cell, coarse;       // axial repeat, and the detail floor
    float boreAmp, boreFrq;   // the throat breathing as it comes at you
    float railGap, railW;     // the spars that ride the lip of the throat
    float ringOn, ringSp, ringISp, ringTh, ringGap;   // the iris plates
    float bandFrq, fogK, flow;
};

Cfg cfg()
{
    Cfg c;

    float fx = saturate(gTune.x);
    float fz = saturate(gTune.z);
    float fy = clamp(gTune.y, 1.15, 2.30);

    // The two discrete axes. Five symmetry bands against four structure
    // bands is twenty layouts for eight shots, and the table's values land
    // on eight distinct pairs - which is the whole reason the appearances
    // stop looking like each other.
    float vi = min(floor(fx * 5.0), 4.0);   // 0..4
    float ri = min(floor(fz * 4.0), 3.0);   // 0..3

    // Spin direction off the parity of the symmetry band. Two shots that
    // happen to share a fold count will at least be turning opposite ways.
    float par = (frac(vi * 0.5) < 0.25) ? 1.0 : -1.0;

    // Four sectors reads as a square shaft, six as the snowflake everybody
    // already knows as "kaleidoscope", twelve as a rose window. Nothing else
    // in this file changes the frame as hard as this one number.
    c.folds = 4.0 + 2.0 * vi;
    c.sec   = TAU / c.folds;
    c.isec  = c.folds * (1.0 / TAU);

    c.spin   = par * (0.22 + 0.50 * fx);
    c.zTwist = par * (0.018 + 0.045 * fz);

    c.cell   = 2.30 + 2.60 * fz;

    // The coarseness floor. gTune.y's integer part is the IFS scale, which
    // the table sweeps monotonically; its fraction is free, and it is worth
    // more here than anywhere else because it decides whether the wall is a
    // filigree or a set of slabs.
    c.coarse = 0.004 + 0.030 * frac(fy);

    // The throat is not a constant diameter. A long wave travelling with the
    // structure opens and closes the aperture as it comes at you, which is
    // motion the camera cannot supply and which reads even on a shot held
    // dead still. The gSync term pumps it with the kick; it is an addition
    // to a base, never a multiply of the picture.
    c.boreAmp = 0.08 + 0.16 * fz + 0.05 * saturate(gSync.x);
    c.boreFrq = 0.055 + 0.075 * fx;

    // Spars riding the lip of the throat, one per sector, silhouetted
    // against the bright core and converging on it. They are what makes the
    // symmetry order legible at a glance instead of something you have to
    // work out from the relief.
    c.railGap = 0.10 + 0.28 * fz;
    c.railW   = 0.045 + 0.055 * fz;

    // Iris plates: annular bulkheads with a hole in the middle, rushing past.
    // Off for the tightest shots, where the pipe wants to be bare, and
    // getting denser as the room opens up.
    c.ringOn  = (ri >= 1.0) ? 1.0 : 0.0;
    c.ringSp  = 11.0 - 2.2 * ri;
    c.ringISp = 1.0 / c.ringSp;
    c.ringTh  = 0.06 + 0.12 * fz;
    // The hole is only a little wider than the throat, so these read as
    // apertures you fall through rather than as ribs on a distant wall. Any
    // wider and the eye files them as wall detail; the whole reason they are
    // here is to put something between the camera and the vanishing point.
    c.ringGap = 0.06 + 0.26 * fz;

    c.bandFrq = 0.16 + 0.16 * fx;

    // Fog is a composition control, not an atmosphere: it sets how deep the
    // tunnel reads. A tight bore wants to close in a few units, a cathedral
    // wants to run away from you.
    c.fogK = 0.020 + 0.022 * (1.0 - fz);

    // Baseline flow, so a held or whip-panned camera is not a photograph.
    // It is a RATE multiplied by absolute shot time, so nothing audio driven
    // is allowed in it - a rate that changed would jump the phase.
    c.flow = gTune.w + 2.0 + 7.0 * fz;

    return c;
}

// World space into tube space, where the axis of the tunnel is exactly
// x = y = 0. This is a pure translation at every depth - never a rotation -
// so length(q.xy) is a true world distance to the axis and a direction built
// out of q.xy is a true world direction. The lighting leans on both of those,
// which is why the twist lives in mapT and not in here.
float3 toTube(float3 p)
{
    // The structure comes at the camera rather than the other way round, so
    // a shot can hold the camera dead still and still be moving at speed.
    p.z += gTime.x * cfg().flow;

    float op = saturate(gTune.z);

    // The bore is not a straight pipe. A long shallow serpentine drifts the
    // vanishing point off centre and back, which is the whole difference
    // between falling down a hole and riding something.
    //
    // The amplitude is a FRACTION OF THE BORE and not a constant. It used to
    // be a constant 0.60 and 0.48, whose combined swing is 0.77 units - wider
    // than the tightest bore, so a shot that put the camera on the world axis
    // with tune.z at 0 had the tunnel walk over the top of it and bury the
    // lens in solid lattice, on a schedule, some seconds into the shot. At
    // 0.42 of the bore the worst case swing is a little over half the
    // clearance, and it gets grander as the room does, which is also the
    // better look.
    float amp = boreRadius(op) * 0.42;
    p.x -= sin(p.z * 0.021) * amp;
    p.y -= cos(p.z * 0.017) * amp * 0.80;

    // ...and the tunnel is threaded onto the CAMERA, not onto the world
    // origin. A crane or a lateral track used to walk the lens straight into
    // the solid outside the wall and the frame went black; now the camera
    // gets free parallax for the first half of its clearance and tows the
    // axis after that. Depends on gCam alone, so it is a constant offset for
    // the whole frame and the pure-translation argument above survives.
    float2 co   = gCam.xy;
    float  cl   = length(co);
    float  free = boreRadius(op) * 0.50;
    p.xy -= co * (max(cl - free, 0.0) / max(cl, 1e-4));

    return p;
}

// `lod` is the radius of the pixel footprint at the point being sampled.
// Pass 0 for the exact field; the march, the normal and the occlusion all
// pass the real thing, and all three must pass the SAME thing at a given
// point or the normal ends up being the gradient of a discontinuity.
float mapT(float3 q, float lod)
{
    Cfg c = cfg();

    float op   = saturate(gTune.z);
    float bore = boreRadius(op);
    float wall = wallRadius(op);
    float mid  = (bore + wall) * 0.5;

    float r = length(q.xy);

    // The breathing throat. Only the CUT is modulated, never `mid` - the
    // lattice stays exactly where it was and the aperture opens over it and
    // closes back, so the wave reveals and hides relief instead of dragging
    // the whole wall around. Amplitude times frequency is under a tenth, so
    // the field stays comfortably Lipschitz and the march does not overstep.
    float bth = bore * (1.0 + c.boreAmp * sin(q.z * c.boreFrq));

    // Twist about the axis. Being a rotation about that axis it leaves r
    // alone, so it is free to happen after the radius has been taken. Rate
    // and sign are both per shot: a spiral climbing left at one pitch and a
    // spiral climbing right at three times that are different rooms.
    float2 tw = rot2(q.xy, q.z * c.zTwist + gTime.x * c.spin);

    // The kaleidoscope. Fold the plane down to one sector, then mirror that
    // wedge about its own centre line. The mirror is the part that matters:
    // it makes the two edges of the wedge identical, so the copies meet with
    // no visible seam no matter what the IFS then does inside.
    //
    // The usual failure of a polar fold is the pinch at the axis, where the
    // sectors converge and the arc length metric collapses to nothing. It
    // cannot happen here: the bore hollows out everything inside the throat,
    // so the pinch is never rendered.
    float a = atan2(tw.y, tw.x);
    a -= c.sec * floor(a * c.isec);
    a  = abs(a - c.sec * 0.5);

    // Arc length around the tunnel. A true world length, which is what makes
    // a box built on it a valid distance estimate.
    float arc = a * r;

    // Unroll the wedge into a flat slab: x is arc length around the tunnel,
    // y is how far out from the middle of the annulus, z is depth, repeated
    // so the tunnel has no end.
    //
    // This unrolling is the fix for the thing that makes a naive version of
    // this shader fail. The attractor of a contracting IFS is COMPACT - a
    // blob a couple of units across - so running one on raw world space
    // gives a small clump of struts floating in an otherwise empty frame.
    // Run it in the slab instead and the fold and the repeat tile that one
    // blob into a relief that covers the whole wall.
    float3 p;
    p.x = arc;
    p.y = r - mid;
    p.z = frac(q.z * (1.0 / c.cell)) * c.cell - c.cell * 0.5;

    // The iterated function system. Fold into the positive octant, rotate,
    // then scale about an offset point - five times. Everything but the
    // scale is an isometry, so working in units of 1/scale is a correct
    // distance estimate for the original point.
    //
    // A shot row that left tune.y at zero would otherwise divide by zero and
    // paint the frame with NaN, so the scale is clamped rather than trusted.
    float s  = clamp(gTune.y, 1.15, 2.30);
    float is = 1.0 / s;

    // The fold angle is taken as a 0..1 amount and remapped onto the band
    // where the lattice actually exists. Past about 1.5 radians the two
    // rotations between them walk the whole structure out of the slab and
    // the shot becomes an empty pipe - a silent, total failure that looks
    // like a bug in the engine rather than a bad number in a row. Rather
    // than leave that trap in the table, the knob only reaches the good band.
    float ang = 0.18 + 1.30 * saturate(gTune.x);
    float ca = cos(ang), sa = sin(ang);

    // Opening the tunnel up moves the IFS fixed point outward with the wall,
    // so the relief keeps hugging the surface instead of being left behind
    // floating in the middle of the new, larger hall.
    float3 off = float3(0.62 + 0.55 * op, 0.48 + 0.75 * op, 0.40);

    // A square tube down the current z at every level of the iteration, all
    // unioned together. Measuring only the LAST iterate is the obvious way to
    // write this and it is a trap: past about a radian of fold angle the
    // rotations walk the attractor clean out of the slab we sample, the
    // union collapses to nothing, and the shot becomes an empty pipe. Taking
    // a primitive at each level instead guarantees material at every scale,
    // so the fold angle is free to sweep its whole range without the
    // structure ever disappearing. Each term is a valid estimate at its own
    // scale, so the minimum of them is still a valid estimate.
    //
    // Square rather than round because at 640x360 a flat face that catches
    // the light in one value beats a cylinder that ramps across four pixels.
    //
    // The strut swells with the solo. It is base * (1 + k * envelope), so the
    // lattice thickens on a peak and never thins away to nothing.
    float th  = (0.45 + 0.25 * op) * (1.0 + 0.20 * saturate(gVoice.y));
    float d   = 1e9;
    float isc = 1.0;                 // 1 / (total scale so far)

    // The footprint the iteration is actually allowed to resolve: the pixel,
    // or the shot's coarseness floor, whichever is blunter.
    float lodI = max(lod, c.coarse);

    [loop] for (int i = 0; i < 5; i++) {
        p = abs(p);
        p.xy = float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
        p = p * s - off * (s - 1.0);
        p.yz = float2(p.y * ca - p.z * sa, p.y * sa + p.z * ca);
        isc *= is;

        // This level's strut half-width, back in world units.
        float w = th * isc;

        // Never let a strut be thinner than the pixel it lands in. Below that
        // width it stops being geometry and starts being a coin flip per
        // frame, and the dither in the post pass turns a coin flip into
        // crawling salt. Fattening it costs nothing - the max() was already
        // there - and it is exactly the original expression when the strut is
        // wider than a pixel, so near geometry is untouched.
        float wf = max(w, lodI);
        d = min(d, max(abs(p.x) * isc - wf, abs(p.y) * isc - wf));

        // ...and once a level is finer than a pixel, nothing below it can be
        // resolved either, because every subsequent level is smaller again.
        // Stop. This is where the cost saving lives: at the far wall this
        // runs twice, not five times.
        if (w < lodI) break;
    }

    // The rails. One square spar per sector, sitting a fixed gap outside the
    // CURRENT throat radius - so they ride the breathing aperture rather than
    // being swallowed by it at the wide phase - and running the length of the
    // tunnel. Because the fold that produced `arc` is taken from the twisted
    // coordinates, they are helices, and their pitch is the shot's.
    //
    // They cost five instructions and they do three jobs: they draw the
    // symmetry order in one unmistakable read, they give the eye something
    // with real speed on it near the camera where the lattice is just a blur,
    // and they guarantee material in the frame for any combination of fold
    // angle and scale.
    float railR = bth + c.railGap;
    float rw    = max(c.railW, lod);
    d = min(d, max(arc - rw, abs(r - railR) - rw));

    // The iris plates. A bulkhead every few units with a hole punched in it
    // just outside the rails, so the shot is a series of apertures you fall
    // through rather than a smooth pipe. Their inner rims face the lamp and
    // catch it, which puts a stack of concentric bright rings down the
    // tunnel - a completely different silhouette from the bare configuration
    // for eight instructions, on the shots that ask for it.
    if (c.ringOn > 0.5) {
        float zr = frac(q.z * c.ringISp + 0.5) * c.ringSp - c.ringSp * 0.5;
        d = min(d, max(abs(zr) - max(c.ringTh, lod),
                       (railR + c.ringGap) - r));
    }

    // The pipe the relief is carved into. Anything past `wall` is solid, so
    // the frame is never black holes with a few struts in them, and rays
    // that would otherwise fly off into nothing terminate - which makes the
    // march cheaper, not more expensive.
    d = min(d, wall - r);

    // Hollow out the throat we fly down. Parts of the lattice that reach too
    // far inward are simply cut off here, so the fold angle and the scale
    // can be pushed hard without ever walling the camera in.
    d = max(d, bth - r);

    return d;
}

float map(float3 p, float lod) { return mapT(toTube(p), lod); }

// Tetrahedron sampling: four map evaluations rather than the usual six. This
// is the most expensive map in the demo, and at 640x360 through a dithered
// ramp the slightly noisier normal is invisible while the two evaluations it
// saves are not.
//
// The offset grows with the pixel footprint. A fixed 0.0018 is right at two
// units and wrong at forty, where it samples inside one strut of a lattice
// finer than the pixel and returns a normal that changes completely between
// one frame and the next - which is a shimmer no amount of fogging hides.
// Sampling at the scale you can actually see is the whole trick.
float3 mapNormal(float3 p, float lod)
{
    float2 e = float2(1.0, -1.0) * max(0.0018, lod * 0.60);
    float3 g = e.xyy * map(p + e.xyy, lod) + e.yyx * map(p + e.yyx, lod) +
               e.yxy * map(p + e.yxy, lod) + e.xxx * map(p + e.xxx, lod);
    // Safe normalize: four taps of a folded field can in principle cancel,
    // and one NaN pixel here is a NaN the CRT pass then smears across a
    // neighbourhood. Three instructions to never find out.
    return g * rsqrt(max(dot(g, g), 1e-12));
}

// Cheap ambient occlusion: how much of the field crowds in along the normal.
// With one distant lamp doing all the lighting, this is what actually carves
// the relief - without it the wall reads as a smooth painted cylinder.
//
// The probe distances stretch with the footprint for the same reason the
// normal offset does: probing 5 cm into a field that has been coarsened to
// 20 cm measures nothing. The final scale divides the stretch back out so
// the amount of occlusion is the same at every depth.
float occlusion(float3 p, float3 n, float lod)
{
    float sca = 1.0 + lod * 6.0;
    float o = 0.0, s = 1.0;
    [loop] for (int i = 0; i < 5; i++) {
        float d = (0.05 + 0.15 * float(i)) * sca;
        o += (d - map(p + n * d, lod)) * s;
        s *= 0.62;
    }
    return saturate(1.0 - (1.35 / sca) * o);
}

// ---- shading -------------------------------------------------------------

float4 main(VSOut i) : SV_Target
{
    Cfg c = cfg();

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

    float op = saturate(gTune.z);

    // Radius of this pixel's footprint per unit of depth. Uniform across the
    // frame, so it costs one multiply and never a derivative.
    float lodRate = gCam.w * PIXTAN;

    // The lamp, in tube space: on the axis, down the tunnel from wherever the
    // camera is. It travels with the shot, so the bright core stays pinned to
    // the vanishing point however the camera moves.
    //
    // Its distance grows as the tunnel opens up. A fixed distance is right for
    // a tight bore and washes a wide one out to flat amber, because an open
    // tunnel puts far more wall within a few units of the lamp; scaling it
    // with the room keeps the lit core about the same size on screen whatever
    // the shot does with tune.z.
    float  lampD = LAMP * (1.0 + 0.45 * op);
    float3 tube0 = toTube(ro);
    float3 lamp  = float3(0.0, 0.0, tube0.z + lampD);

    // The ray, in tube space, as the secant across exactly the distance the
    // lamp sits at. toTube is a translation that varies slowly with depth, so
    // the tube-space ray is not quite the world ray, and over thirteen units
    // the difference is enough to slide the bright core visibly off the hole
    // it is supposed to be sitting in.
    float3 trd = normalize(toTube(ro + rd * lampD) - tube0);

    float  t    = 0.05;
    float  glow = 0.0;
    float3 q    = tube0;
    bool   hit  = false;

    // The march. 0.62 of a step rather than a full one, because a polar fold,
    // a domain repeat and an IFS all overestimate distance near their fold
    // planes, and at a full step they all show up as the same artifact: a
    // hard bitten edge where a strut should be.
    [loop] for (int k = 0; k < 56; k++) {
        q = toTube(ro + rd * t);

        float lod = lodRate * t;
        float h   = mapT(q, lod);

        // Haze around the lamp, accumulated along the ray. This is what fills
        // the throat with air, and it costs no extra map evaluations because
        // the march is already here. It is the AIR, though, not the core -
        // see the core term below for why that distinction is worth the
        // handful of instructions it costs.
        float dl = length(q - lamp);
        glow += min(h, 0.7) * exp(-t * c.fogK) / (1.0 + dl * dl * 0.09);

        // Stop when the remaining distance is under half a pixel. Tying the
        // threshold to the footprint rather than to a hand-tuned slope means
        // it tracks the field of view: a wide shot spends fewer steps
        // resolving something it is going to draw coarsely anyway.
        if (h < lod * 0.45 + 0.0008) { hit = true; break; }
        t += h * 0.62;
        if (t > 80.0) break;
    }

    float lodHit = lodRate * t;

    // Bands of colour sweeping up the tunnel toward the camera. This is the
    // psychedelic half of the brief, and it is deliberately only two hues -
    // the demo's warm amber and its phosphor green - because a full rainbow
    // would fight both the palette and the narrow ramp the post pass dithers
    // into. Banding it along z rather than by time means the colour is
    // attached to the structure and arrives with it.
    //
    // The period is per shot, twenty to thirty-six units, which is one to
    // three bands across the depth the fog leaves visible. At the 0.085 it
    // used to be, the period was seventy-four units - longer than you can
    // see - so there were never any bands, only one slowly changing wash,
    // and the one thing the shot promised the eye it never delivered.
    float  band = sin(q.z * c.bandFrq + gTime.x * 0.7) * 0.5 + 0.5;
    float3 hot  = lerp(float3(1.00, 0.63, 0.26),
                       float3(0.36, 1.00, 0.56),
                       smoothstep(0.28, 0.80, band));
    float3 deep = float3(0.021, 0.027, 0.046);   // near black, slightly blue

    // The air gets its hue from the lamp's depth, not from wherever this
    // pixel's march happened to stop. Sampling the band at the end of the
    // ray means two neighbouring pixels that terminated a step apart pick up
    // different hues, and the throat - which is nothing BUT air - fills with
    // colour noise that the dither then locks into a crawling pattern. One
    // hue for the whole haze, drifting as the structure passes.
    float  bandA = sin(lamp.z * c.bandFrq + gTime.x * 0.7) * 0.5 + 0.5;
    float3 hotA  = lerp(float3(1.00, 0.63, 0.26),
                        float3(0.36, 1.00, 0.56),
                        smoothstep(0.28, 0.80, bandA));

    float3 col = deep;

    if (hit) {
        float3 p = ro + rd * t;
        float3 n = mapNormal(p, lodHit);

        // Toward the lamp. Legal as a world direction only because toTube is
        // a translation at every depth - see the note on it.
        float3 lv = lamp - q;
        float  dl = length(lv);
        float3 ld = lv / max(dl, 0.001);

        // The key. Falloff is gentler than inverse square on purpose: true
        // inverse square over a 60 unit tunnel puts everything past the first
        // few metres into the black, and then there is no relief left to look
        // at, only a bright hole. The master peak lifts it - base * (1 + k),
        // so the floor never drops out from under the picture.
        float key = saturate(dot(n, ld)) * (8.5 / (1.0 + dl * dl * 0.032))
                  * (1.0 + 0.30 * saturate(gSync.w));

        // A dim fill from the axis itself, so the walls sliding past the
        // camera are dark rather than absent. Without it the near field is a
        // black frame around a bright hole and the sense of speed goes.
        // At 0.40 over a 0.30 falloff it was worth about one extra unit of
        // `deep` on the near wall, which is to say it was not doing its job;
        // this reaches the far side of the open configuration as well.
        float ra  = length(q.xy);
        float fil = saturate(dot(n, normalize(float3(-q.x, -q.y, 0.25))))
                  * (0.55 / (1.0 + ra * ra * 0.22));

        float ao  = occlusion(p, n, lodHit);
        float fre = pow(1.0 - saturate(dot(n, -rd)), 3.0);

        // The key is the warm-to-green lamp light; the fill is deliberately
        // COLD. Lighting both with the same hue washes the entire frame one
        // colour and the palette collapses - the walls have to fall back to
        // the demo's blue-black for the amber core to read as warm at all.
        col  = hot * key * ao;
        col += float3(0.30, 0.42, 0.68) * fil * ao;
        col += deep * 1.6 * ao;
        // The glass. Grazing angles pick up the light, which is what turns
        // the open configuration from a dark lattice into something lit from
        // inside. Mostly off when the tunnel is tight, because a tight tunnel
        // wants to be a silhouette.
        col += hot * fre * (0.18 + 1.15 * op) * (1.0 + 0.45 * saturate(gVoice.y)) * ao;

        // A hard specular, off the same lamp. The lattice is glass in the
        // open configuration and stone in the tight one, and one exponent
        // scaled by openness is the whole difference between those two
        // materials. It lands on the flat faces the IFS is built out of, so
        // it reads as facets catching the light rather than as a sheen.
        float3 hv  = normalize(ld - rd);
        float  spe = pow(saturate(dot(n, hv)), 26.0) * (0.20 + 1.30 * op);
        col += hot * spe * (0.40 + 0.60 * ao);
    }

    // Fog the surfaces back into the dark, then add the air on top: the glow
    // IS the depth cue, so it must not be faded by the thing it is cueing.
    float f = exp(-t * c.fogK);
    col = col * f + deep * (1.0 - f);
    col += hotA * glow * 0.13;

    // The lamp itself. The accumulated haze above cannot do this on its own:
    // it is a sum over march steps, so its brightness depends on how many
    // steps a pixel happened to take, and down the middle of a hollow bore
    // that count changes by one between neighbouring pixels. The result is a
    // core that is grey rather than blown out AND that flickers a step at a
    // time. This term is closed form - the perpendicular distance from the
    // ray to the lamp - so it is smooth across the frame and dead steady in
    // time, and it is the white in "white core, amber relief, black walls".
    // Same construction as the source down the nave in scene.hlsl.
    {
        float3 lw   = lamp - tube0;
        float  tc   = max(dot(lw, trd), 0.0);
        float3 pv   = lw - trd * tc;
        float  perp = length(pv);
        float  core = 1.0 / (1.0 + perp * perp * 2.2);

        // ...and it wears the tunnel's own symmetry. The core is the single
        // brightest thing in the frame and it was a featureless dot in every
        // one of the eight appearances; giving it the shot's fold count turns
        // it into a four, six, eight, ten or twelve armed star that turns
        // with the structure. It is a modulation of a small bright region
        // about its own mean, not a gate on it, so nothing here flashes.
        // The 1e-6 is not decoration. pv.xy is exactly zero for the pixel
        // whose ray points straight down the barrel at the lamp, atan2 of
        // (0,0) is not defined, and one NaN in the brightest pixel in the
        // frame is a NaN the CRT pass then smears over a neighbourhood.
        float  pa   = atan2(pv.y + 1e-6, pv.x + 1e-6) + gTime.x * c.spin;
        float  star = 1.0 + 0.45 * cos(pa * c.folds);

        // Squared so it is a small hard core rather than a broad grey wash,
        // and scaled past 1.0 so the middle of it clips to the top of the
        // post pass ramp instead of dithering somewhere in the mid greys.
        col += hotA * core * core * 3.2 * star * (tc < t ? 1.0 : 0.30);
    }

    return float4(col * gTime.z, 1.0);
}
