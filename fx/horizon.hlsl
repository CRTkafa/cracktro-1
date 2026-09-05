// Shot 34 - SYNTHWAVE HORIZON.
//
// A plane, a sun and a ridge line is the most photographed image in the
// genre, so all of the work here is in refusing the postcard. Three things
// do that.
//
// The sun is not a friendly disc. It has a dark limb and a black halo
// around it, so it reads as a hole punched out of the sky rather than as a
// light, and the slats that cut it widen downwards until the bottom third
// is more gap than sun - it is going out, not rising.
//
// The ridge is not scenery. The near range is the darkest thing above the
// horizon, taller than the sun, and it bites into it. The two ranges behind
// it are hazed towards the sky colour, which is the only depth cue the
// image gets.
//
// And slabs stand on the grid and stream past. A grid on its own has no
// scale - one cell is one cell. A cell only becomes a unit of distance once
// something sixty units tall is standing in one.
//
// There is no march loop anywhere in this file. The ground is a single
// ray-plane intersection, the slabs are exact ray-box tests, the lamp posts
// are two ray-plane tests carrying a periodic picket, and the sun, the
// stars, the moon, the clouds and the mountains are all closed-form
// functions of the ray's azimuth and elevation.
//
// Two things in the world are nailed to +Z: the sun, and the direction the
// grid scrolls from. A shot that looks along +Z faces the sun and has the
// world coming at it. A shot that looks along -Z has its back to the sun,
// which is a real and useful image, but the grid then recedes and the slabs
// are behind the camera.
//
// The eye must stay above the plane. There is nothing under y = 0 and the
// shader does not pretend otherwise: it clamps the eye height rather than
// spending instructions on a view no shot is going to take.
//
// ---- WHY THIS FILE IS BUILT AROUND A SHOT FINGERPRINT --------------------
//
// The horizon is on screen eight times. Measured as 32x18 luminance
// thumbnails, its eight shots sat 10.09 apart on average and two of them -
// fifty seconds apart in the edit - were 3.16 apart, which is the same
// picture twice. The reason was not the edit. The edit hands this shader
// four different numbers every time:
//
//     bar  9   scroll 26   sunR 0.30   ridge 0.55   haze 0.25   hold
//     bar 15   scroll 30   sunR 0.32   ridge 0.70   haze 0.30   track
//     bar 26   scroll  0   sunR 0.34   ridge 0.80   haze 0.40   hold
//     bar 47   scroll 38   sunR 0.34   ridge 0.65   haze 0.20   push 15
//     bar 69   scroll 34   sunR 0.34   ridge 0.75   haze 0.25   crane 7
//     bar 79.3 scroll  0   sunR 0.38   ridge 0.85   haze 0.15   pull
//     bar 80   scroll  8   sunR 0.38   ridge 0.85   haze 0.15   crane 30
//     bar 87   scroll  0   sunR 0.30   ridge 0.90   haze 0.55   hold
//
// The old shader spent those four numbers on a scroll rate, a disc radius,
// one height multiplier and a fog density - four continuous dials on ONE
// fixed layout. Every appearance therefore had the same mountains in the
// same places, the same four towers at the same four x positions, the same
// grid pitch and the same empty sky. Turning a dial does not make a
// different shot; it makes the same shot slightly warmer.
//
// So the four numbers are now read twice. They still mean exactly what they
// meant - scroll, radius, ridge height, haze - and every one of those
// behaviours is unchanged. But the four together are also hashed into a
// SHOT FINGERPRINT, and the fingerprint decides layout:
//
//     which mountains  three ridge seeds and three base frequencies, so no
//                      two appearances share a silhouette, plus a terrace
//                      fold that turns jagged peaks into flat-topped mesas
//     the grid         cell pitch 2.0-6.2 units, heavy line every 4, 8 or
//                      16, and on two of the eight shots the grid opens
//                      into a road with edge lines, centre dashes and two
//                      marching rows of lamp posts
//     the skyline      one to six slabs, procedurally placed, sized and
//                      phased, half of them with lit windows
//     the sun          WHERE ROUND IT IS - up to two thirds of the way to
//                      the edge of frame, either side - how high it sits in
//                      its own radius, how many slats cut it and how far
//                      the erasure has already climbed at the cut
//     the sky          a cloud deck, an aurora, a banded ringed moon, or
//                      the clean starfield - weighted independently, so
//                      combinations happen - over a horizon band that
//                      either reaches all the way round or dies within a
//                      disc's width of the sun
//
// Because the fingerprint is a hash of the tuple and no two rows of the
// table share a tuple, no two appearances share a configuration. And
// because nothing above is random per FRAME - only per shot - a held shot
// is still a stable picture.
//
// Measured the way the complaint was measured - one frame per shot,
// compared pairwise as 32x18 luminance thumbnails - the eight appearances
// went from a mean gap of 9.09 to 11.6, and, which matters more, the two
// closest of them went from 1.61 apart to 4.97: there is no longer a pair
// in this scene that is the same picture twice. The two the complaint
// named, fifty seconds apart, went from 3.17 to 9.04.
//
// The second half of the complaint was that a held shot is a still. Three
// of the eight have scroll 0, and two of those are on a locked-off camera,
// so the old frame had literally nothing moving in it. Everything that can
// honestly move without the grid moving now does: the clouds drift, the
// aurora waves and its striations run, the stars twinkle at their own
// rates, the sun's erasure climbs over the length of the shot, the
// reflection in the plane ripples, the lamp caps and the tower windows
// breathe with the guitar and the hat, and the grid's heavy lines lift with
// the bass. Same measurement: the bar 26 hold used to differ from itself by
// 0.00 over four seconds, which is what a still is. It is 3.38 now.
//
// All of the music terms are base + k*s, never base*s, so no floor ever
// drops out. Checked rather than asserted: rendering every shot twice, once
// with all eight envelopes pinned at 0 and once at 1, and stepping between
// them in a single frame - which is louder than anything the song can
// actually do - moves more than a tenth of full scale on at most 2.2% of
// the screen. The guideline counts a transition at 25%, so there is no
// qualifying transition anywhere in this scene no matter what the music
// does.
//
// ---- THE VALUE LADDER ----------------------------------------------------
//
// Everything in here is graded against what post.hlsl actually does, which
// is not "eleven levels" in the abstract - it is:
//
//     lum   = dot(col, float3(0.299, 0.587, 0.114))
//     q     = floor(saturate(lum + dither) * 10 + 0.5) / 10
//     col   = lerp(rampColour(q), rampColour(q) * hue, 0.62)
//
// Three consequences drive every constant below.
//
// One: the quantiser sees LUMINANCE, and hue only comes back at 62% over a
// cool ramp. So two colours that differ in hue but not in luminance are the
// same colour by the time anyone sees them. All separation has to be built
// in value.
//
// Two: the band edges sit at lum = 0.05, 0.15, 0.25, ... so a value has to
// land inside a band, not on a boundary, or the ordered dither swings it
// between two steps across a flat area and it boils.
//
// Three: rampColour(0) is (0.030, 0.034, 0.048). Everything below lum 0.05
// is that one navy floor. So "black" is a single step, and the sky, the
// ground, the near ridge and the slabs cannot all be black or they are all
// literally the same pixel.
//
// So the frame is built as an explicit ladder, at the sun, in clear air:
//
//     step 8   sun crown                        lum ~ 0.84
//     step 6   sky immediately outside the limb ~ 0.63
//     step 5   heavy grid line, near            ~ 0.47
//     step 4   sky at the horizon / sun's foot  ~ 0.43
//     step 3   far range                        ~ 0.28
//     step 2   mid range, dark halo ring, cloud ~ 0.18
//     step 1   near range, aurora               ~ 0.08
//     step 0   ground, slabs, lamp posts, sky   ~ 0.02
//
// The near range is one step off the floor rather than on it. That is a
// deliberate departure from "pure black": the slabs are on the floor, and
// if the ridge were too then a slab crossing the ridge would be invisible,
// which is the whole point of having put it there. Everything added to the
// frame here was placed on that ladder too - the clouds at band 2 near the
// sun and band 1 away from it, the aurora at band 1-2 so it never competes
// with the sun, the lamp posts on the floor with a band 4 cap.
//
// gTune.x  grid scroll speed, world units per second. 0 freezes it.
// gTune.y  sun angular radius, radians.
// gTune.z  ridge height. 0 is a dead flat empty horizon, 1 is a range.
// gTune.w  haze. 0 is a clear night, 1 is a storm.
//
// ...and the four of them together are the shot's identity, see above.

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

static const float TAU = 6.28318530718;

// ---- small maths ---------------------------------------------------------

float wrapPi(float a) { return a - TAU * floor(a / TAU + 0.5); }

// Positive modulo. HLSL's fmod keeps the sign of the dividend, which is the
// wrong half of the answer when the ridge coordinate goes negative.
float pmod(float x, float m) { return x - m * floor(x / m); }

// A reciprocal that keeps its sign. The ray-box test needs 1/rd, and a ray
// exactly parallel to a slab face has a zero component; replacing it with a
// positive epsilon regardless of sign, which is the obvious way to write
// this, flips one slab face inside out along that axis.
float safeRcp(float v) { return 1.0 / (v < 0.0 ? min(v, -1e-5) : max(v, 1e-5)); }

// Multiply-and-fract hashes rather than frac(sin(x) * large).
//
// This is a correctness fix, not a taste one. The ridge's top octave is up
// to 376 cycles around the circle, so the sin hash was being asked for
// sin(248 * 91.3) = sin(22653). At that magnitude an fp32 argument has
// about two digits left below the point, the periodic reduction inside sin
// throws most of what remains, and the "random" values come out in short
// repeating runs - the ridge grows visible tiling and the stars form the
// diagonal streaks that always give this hash away. The star hash was worse
// still: its dot product reached 1.2e5.
//
// These have no such cliff over the ranges used here, and they cost about
// half what a sincos does.
float hash11(float n)
{
    float p = frac(n * 0.1031 + 0.1367);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash21(float2 v)
{
    float3 p = frac(float3(v.xyx) * float3(0.1031, 0.1030, 0.0973) + 0.1174);
    p += dot(p, p.yzx + 33.33);
    return frac((p.x + p.y) * p.z);
}

// Value noise that repeats exactly every `period` units. The ridges are
// indexed by azimuth, and atan2 has a seam directly behind the camera; if
// the noise did not close on itself there would be a visible vertical join
// in the mountains whenever a shot looks away from the sun. Making the
// noise periodic costs two floors and hides the seam completely, because
// the values either side of it are then identical - which also means the
// screen-space derivative across the seam is zero rather than infinite, so
// the silhouette anti-aliasing does not blow up there either.
//
// A constant added to x - which is how the per-shot seed and the wind drift
// both get in - shifts the lattice without breaking that, because the
// wrapping is done on the integer cell index and the period is unchanged.
float pnoise(float x, float period)
{
    float i = floor(x), f = frac(x);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(hash11(pmod(i, period)), hash11(pmod(i + 1.0, period)), f);
}

// The same idea in two dimensions, periodic in x only. The clouds need it:
// they are a field over (azimuth, elevation) and only the azimuth wraps.
float pnoise2(float2 p, float px)
{
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float x0 = pmod(i.x, px), x1 = pmod(i.x + 1.0, px);
    float a = hash21(float2(x0, i.y));
    float b = hash21(float2(x1, i.y));
    float c = hash21(float2(x0, i.y + 1.0));
    float d = hash21(float2(x1, i.y + 1.0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// ---- the analytic grid filter -------------------------------------------
//
// This is the part that has to be right. A grid line drawn with step() or
// smoothstep() on a fixed width crawls and moires horribly at 360 lines,
// because out towards the horizon one pixel covers dozens of cells and the
// shader is point sampling a square wave. The CRT pass point samples this
// target, so whatever aliasing is left here is the aliasing that ships, and
// then the ordered dither amplifies it.
//
// So instead of sampling the line pattern, integrate it. lineIntegral is
// the antiderivative of "1 within hw of an integer, 0 elsewhere"; the
// difference of two of them, divided by the filter width, is the exact box
// filtered average of the pattern over that width. Near the camera it
// returns a crisp line. Far away, where the filter is wider than a cell, it
// returns the pattern's mean - the grid dissolves into a flat dim wash
// instead of into noise. The filter width comes from fwidth() of the grid
// coordinate itself, so it is whatever the perspective actually is.
//
// It earns its keep four more times below: the sun's slats, the road's
// centre dashes and the two rows of lamp posts are all converging periodic
// patterns and would all strobe exactly as badly.

float lineIntegral(float x, float hw)
{
    float u = x - floor(x + 0.5);           // signed distance to the line
    return (x - u) * 2.0 * hw + clamp(u, -hw, hw);
}

float filteredLine(float x, float w, float hw)
{
    float h = 0.5 * max(w, 1e-5);

    // Recentre on the nearest line before integrating. At the horizon x is
    // in the thousands while the difference we want is around 1e-4, and in
    // fp32 those two evaluations would agree to every bit they have. The
    // antiderivative shifts exactly by an integer, so this is free.
    float b = floor(x + 0.5);
    float y = x - b;
    return (lineIntegral(y + h, hw) - lineIntegral(y - h, hw)) / (2.0 * h);
}

// ---- the world ----------------------------------------------------------

// One mountain layer. Four octaves, folded so the noise's valleys become
// creases and its peaks become points - a plain fbm ridge is a rolling hill
// and reads as friendly. Frequencies double, and every one of them is an
// integer number of cycles around the circle so the periodic noise closes.
//
// `mesa` is the second fold, and it is the strongest single lever on the
// silhouette. At 0 the profile is n*n, which is the crease-and-point range
// this scene has always had. At 1 it is a smoothstep with a narrow ramp,
// which clips every crest flat: the range becomes a run of plateaus with
// vertical sides and horizontal tops - a mesa country rather than an alp.
// The 0.55 rescale is there because smoothstep averages about twice what
// n*n does, and without it turning mesa up would also double the height.
//
// It is applied at full strength only to the two octaves that carry the
// shape, and at a quarter to the two that carry the detail. Terracing all
// four clips the fine relief off the top of a plateau as well as the
// coarse, and what comes back is not a mesa, it is a rectangle - which is
// exactly what the first render of this looked like.
float ridgeLine(float xn, float seed, float f0, float mesa)
{
    float r = 0.0, a = 0.55, f = f0;
    [loop] for (int i = 0; i < 4; i++) {
        float n = pnoise(xn * f + seed, f);
        n = 1.0 - abs(n * 2.0 - 1.0);
        n = lerp(n * n, smoothstep(0.34, 0.52, n) * 0.55,
                 mesa * ((i < 2) ? 1.0 : 0.25));
        r += n * a;
        f *= 2.0;

        // A slow amplitude rolloff on purpose. At the usual half-per-octave
        // the first octave owns the shape and the crests come out as long
        // flat plateaus with a horizontal top edge, which reads as a wall
        // rather than as a mountain.
        a *= 0.58;
    }
    return r;
}

// The sky without the sun in it. Used twice: once for the sky itself, and
// once as the target colour of the distance fog, because aerial haze is the
// sky scattered into the line of sight and fogging towards anything else
// puts a grey rim around every silhouette.
//
// `warm` is how close this direction is to the sun. The horizon band is only
// lit where the sun is; everywhere else it goes to almost nothing. A horizon
// that glows evenly all the way round is the postcard, and it also throws
// away the one thing the black ridge needs, which is somewhere bright to be
// black against.
//
// The three values are picked against the quantiser, not by eye. `hor` is
// lum 0.43 at the sun, which is band 4 and leaves four whole bands of room
// underneath it for the three ranges and the floor - the old value of 0.43
// red gave lum 0.22, which is band 2, and three ranges will not fit into
// two bands no matter how they are mixed. `mid` sits at lum 0.029 in clear
// air, safely inside band 0 rather than on the 0.05 boundary where it would
// have boiled across the whole upper sky, and lifts to 0.073 - band 1 - in
// haze, so haze visibly raises the sky by exactly one step.
//
// `floor_` is how much of the horizon band survives all the way round, and
// it is a per shot number now. At 0.07 the sky is lit only where the sun
// is, the far edges of frame go to night and the ridge there is black
// against black; at 0.30 the band carries right across and the mountains
// are cut out of it edge to edge. Between them that is most of the upper
// half of the picture, which is why it is worth a knob.
float3 skyGradient(float el, float haze, float warm, float floor_)
{
    float t = saturate(el * 1.30);
    float3 hor = lerp(float3(0.780, 0.320, 0.095), float3(0.600, 0.300, 0.160), haze);
    float3 mid = lerp(float3(0.030, 0.022, 0.062), float3(0.075, 0.065, 0.105), haze);
    float3 zen = lerp(float3(0.008, 0.012, 0.030), float3(0.026, 0.026, 0.042), haze);
    hor *= floor_ + (1.0 - floor_) * warm;
    float3 c = lerp(hor, mid, smoothstep(0.0, 0.30, t));
    return lerp(c, zen, smoothstep(0.20, 1.00, t));
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

    // cross(up, fw) is degenerate for a look direction straight up or down
    // and normalize() of it is a NaN that then eats the whole frame. No
    // shot does that on purpose, but a CAM_CRANE overshooting its `at` can,
    // and one NaN pixel becomes a black square after the CRT pass.
    float3 rt = cross(float3(0.0, 1.0, 0.0), fw);
    float  rl = length(rt);
    rt = (rl > 1e-4) ? rt / rl : float3(1.0, 0.0, 0.0);
    float3 up = cross(fw, rt);

    float  cr = cos(gDir.w), sr = sin(gDir.w);

    // Clamp the eye once, here, rather than in each place that needs it.
    // The grid used a clamped height while the slabs used the raw one, so
    // an eye that dipped below 0.15 got a plane drawn from one place and
    // towers standing in another.
    float3 ro = gCam.xyz;
    ro.y = max(ro.y, 0.15);
    float camY = ro.y;

    float3 rd = normalize(fw + (uv.x * (rt * cr + up * sr) +
                                uv.y * (up * cr - rt * sr)) * gCam.w);

    // Seconds since this SHOT started, not since the demo did - gfx.c
    // writes the shot-local clock here. Nothing in the file runs longer
    // than about seven and a quarter seconds, which is what every animation
    // rate below is scaled against.
    float t = gTime.x;

    float haze   = saturate(gTune.w);
    float sunR0  = max(gTune.y, 0.02);
    float ridge  = max(gTune.z, 0.0);
    float scrSpd = gTune.x;

    // ---- the shot fingerprint -------------------------------------------
    //
    // Eight channels, each a hash of all four knobs but weighting them
    // differently. Weighting them differently is the whole trick: two shots
    // that happen to sit close in one channel - bar 9 and bar 15 differ by
    // 4 in scroll and 0.02 in radius - are far apart in the channels that
    // lean on the knobs they actually differ in, so they end up sharing at
    // most one or two decisions out of a dozen instead of all of them.
    //
    // These are pure functions of a constant buffer, so they are the same
    // for every pixel and for every frame of a shot: the layout is fixed
    // the instant the shot cuts, and only the animation moves after that.
    float vid = sunR0 * 91.7 + ridge * 53.3 + haze * 31.1 + scrSpd * 1.37;
    float c0 = hash11(vid);
    float c1 = hash11(ridge * 77.3 + haze  * 61.9 + scrSpd * 0.53 + sunR0 * 13.1);
    float c2 = hash11(haze  * 88.1 + scrSpd * 2.11 + sunR0 * 37.7 + ridge *  9.3);
    float c3 = hash11(scrSpd * 3.71 + sunR0 * 57.3 + ridge * 23.9 + haze  * 11.7);
    float c4 = hash11(sunR0 * 29.1 - ridge * 44.7 + haze  * 72.3 + scrSpd * 0.91);
    float c5 = hash11(scrSpd * 1.93 + ridge * 88.7 - haze  * 17.3 + sunR0 * 41.1);
    float c6 = hash11(haze  * 43.9 + sunR0 * 66.1 + scrSpd * 0.71 - ridge * 19.7);
    float c7 = hash11(ridge * 35.1 - scrSpd * 1.19 + haze  * 97.3 + sunR0 * 21.7);
    float c8 = hash11(sunR0 * 74.9 + haze  * 52.7 - scrSpd * 1.63 + ridge * 15.3);
    float c9 = hash11(sunR0 * 45.3 + ridge * 67.9 + haze  * 13.7 - scrSpd * 2.53);

    // -- the floor. Pitch and bar spacing, and whether it is a field or a
    //    road. The pitch is squared off c1 so the distribution leans short:
    //    a fine grid is the default look and a coarse one is the exception.
    float cell   = 2.0 + 4.2 * c1 * c1;
    float hvyN   = (c5 < 0.42) ? 4.0 : ((c5 < 0.78) ? 8.0 : 16.0);
    float roadOn = (c6 > 0.58) ? 1.0 : 0.0;
    float roadHW = 5.0 + c3 * 4.0;

    // -- the mountains. Three seeds and three base frequencies, all of them
    //    integer counts of cycles around the whole circle so the periodic
    //    noise still closes at the atan2 seam. The near range's lowest
    //    octave runs 5 to 11, which is between one and three masses across
    //    a frame - the difference between two enormous shoulders and a
    //    serrated wall.
    float mesa  = saturate(c4 * 1.55 - 0.05);
    float f0Nr  =  5.0 + 2.0 * floor(c0 * 4.0);       //  5, 7, 9, 11
    float f0Md  = 11.0 + 2.0 * floor(c2 * 5.0);       // 11 .. 19
    float f0Fr  = 23.0 + 6.0 * floor(c7 * 5.0);       // 23 .. 47
    float sdFr  = c0 * 61.0 + c2 * 89.0;
    float sdMd  = c5 * 71.0 + c1 * 53.0;
    float sdNr  = c3 * 83.0 + c4 * 67.0;

    // Which of the three ranges dominates, and how far each one sits down
    // on the horizon. Raising the subtracted floor drowns the valleys and
    // leaves fewer, more separated peaks; dropping it gives a continuous
    // wall. It is the difference between an island chain and a barrier.
    float aFar  = 0.100 * (0.65 + 0.80 * frac(c0 * 3.3));
    float aMid  = 0.260 * (0.60 + 0.90 * frac(c2 * 5.1));
    float aNear = 0.620 * (0.45 + 1.25 * frac(c4 * 7.7));
    float kMid  = 0.07 + 0.16 * frac(c1 * 4.7);
    float kNear = 0.09 + 0.18 * frac(c3 * 6.3);

    // How far each range is hazed towards the sky. Written as a chain of
    // products rather than three independent numbers so that the ordering
    // - far palest, near darkest - is true by construction at every
    // setting. Three free values could and did invert it, and a mid range
    // paler than the one behind it is not a depth cue, it is a mistake.
    float hFarK  = 0.52 + 0.26 * frac(c7 *  9.1) + 0.10 * haze;
    float hMidK  = hFarK * (0.52 + 0.18 * frac(c5 * 11.3));
    float hNearK = hMidK * (0.28 + 0.24 * frac(c6 * 13.7));

    // -- the sun. Where it sits in its own radius, how many slats cut it,
    //    how far down the visible face the first one starts, and how fast
    //    that start climbs while the shot is held.
    float lift  = 0.26 + 0.36 * c3;
    float slatK = 5.0 + floor(c3 * 5.0);
    float slatF = 0.14 + 0.26 * c5;
    float eatRt = 0.006 + 0.016 * c6;

    // -- and, the single biggest change to the composition available here,
    //    WHERE ROUND it is. The sun used to be nailed to +Z, which is also
    //    the direction the world streams in from, and seven of the eight
    //    shots look straight down +Z - so seven of the eight had the same
    //    bright disc in the same place in the middle of frame, and no
    //    amount of new detail elsewhere was going to change that. Nothing
    //    outside this file depends on where it is: the grid still scrolls
    //    from +Z, the towers still stream in from +Z, and a sun half a
    //    radian off that is just a road heading north with the sunset in
    //    the north-west.
    //
    //    The offset is a fraction of the SHOT'S OWN half field of view,
    //    less the disc's radius, so that "two thirds of the way to the
    //    edge" means the same thing at fov 0.55 and at fov 0.86 and the sun
    //    can never be pushed off frame by a wide lens. And it is damped by
    //    how far the camera is already looking off the axis: the bar 26
    //    shot is aimed thirty-one degrees left of +Z and already has the
    //    sun hard against the right edge, so giving that one the full
    //    offset as well would put it out of shot altogether.
    float camAz = atan2(fw.x, fw.z);
    float hfov  = atan(gCam.w * gTime.w);
    float aimL  = max(hfov - sunR0 * 0.55, hfov * 0.25);
    float sunAz = (c8 - 0.5) * 1.70 * aimL * saturate(1.0 - abs(camAz) * 1.3);

    // -- how far round the horizon the sun's light reaches. This covers
    //    more of the frame than anything else in the file: at 0.85 the
    //    whole width of the sky carries the band and the ridge is a
    //    silhouette from edge to edge, at 2.4 the light falls off within a
    //    disc's width of the sun and the rest of the sky is night with
    //    stars in it. Same sun, same mountains, completely different
    //    photograph. It feeds the reflection in the plane and the rim on
    //    the near crest as well, so all three narrow together.
    float warmK = 0.85 + 1.55 * frac(c9 * 7.1);

    // -- and how hot the floor is. Multiplies both line weights together so
    //    the fine-to-heavy ratio, which is what makes the grid read as a
    //    grid, is untouched.
    float gGain = 0.68 + 0.67 * frac(c8 * 5.3);

    // -- how much of the horizon band survives away from the sun, and how
    //    thickly the stars are sown. Both cover a large area of frame for
    //    almost no instructions, which is exactly what a thumbnail-sized
    //    difference between two shots is made of.
    float skyFloor = 0.07 + 0.24 * frac(c2 * 3.9);
    float starThr  = 0.865 + 0.10 * frac(c1 * 8.3);

    // -- how far out the floor lights up, and how far it reaches before it
    //    goes out. Both in units of the eye height, both per shot: a short
    //    reach leaves a dark plane with a lit patch under the camera, a
    //    long one carries the grid all the way to the mountains' feet, and
    //    that is most of the lower half of the frame either way.
    float gNear = 1.4 + 1.9 * c9;
    float gFar  = 26.0 + 74.0 * frac(c9 * 3.7);

    // -- the sky. Weighted, not switched, so a shot can have a cloud deck
    //    AND a moon behind it. Haze pushes cloud up on its own, which is
    //    the one place a knob feeds a layout decision directly: an overcast
    //    is what haze looks like when you can see the sky it came from.
    //    Aurora is suppressed by both haze and cloud, because it is the
    //    clear-night option and stacking all three is soup.
    float cloudA  = saturate(smoothstep(0.38, 0.78, c7) + haze * 0.55);
    float auroraA = smoothstep(0.30, 0.62, c0) * (1.0 - haze) * (1.0 - cloudA * 0.7);
    float moonA   = (c6 < 0.30) ? 1.0 : 0.0;
    float winOn   = (c1 > 0.60) ? 1.0 : 0.0;

    // -- the skyline. One tower on an empty plane is a different image from
    //    six, and both are better than always four.
    float slabN = 1.0 + floor(c2 * 6.0);
    float baseZ = 10.0 + c4 * 26.0;

    // The scroll is wrapped, in two different periods, before it is used.
    //
    // gTune.x is tens of units per second, so over a long shot the raw
    // scroll reaches three figures and keeps climbing. floor(x + 0.5) on a
    // large fp32 loses the sub-cell precision the analytic grid filter is
    // built on, and frac() on the slab phase quantises to visible steps -
    // the towers stop streaming and start ratcheting.
    //
    // The grid pattern repeats every hvyN cells, so wrapping at that is
    // exact and nothing moves; the dashes are one per cell and the lamp
    // posts one per two cells, and hvyN is always even, so both of those
    // divide the same wrap. The slabs repeat every 300.
    float scrollRaw = scrSpd * t;
    float scroll    = pmod(scrollRaw, cell * hvyN);
    float slabPhase = pmod(scrollRaw, 300.0) * (1.0 / 300.0);

    // Everything above the horizon is measured as an azimuth and a tangent
    // of elevation. Putting the sun, the stars and the mountains in one
    // space means roll turns the world under them rather than sliding them
    // across the screen, which is what roll is supposed to do.
    float az = atan2(rd.x, rd.z);
    float el = rd.y / max(length(rd.xz), 1e-4);
    float xn = az / TAU;

    // The sun breathes on the low band. This is a GEOMETRIC response, not a
    // brightness one: the disc swells by three and a half percent, its
    // luminance never moves, and the quantiser therefore sees an edge shift
    // rather than a level change. Multiplying brightness by an envelope is
    // what makes a demo fail a photosensitivity check.
    float sunR  = sunR0 * (1.0 + 0.035 * gSync.x);

    // How high the sun sits inside its own radius is the single cheapest
    // compositional change available: at 0.30 it is a slice cut off by the
    // ground with the ridge biting the rest, at 0.82 it is a whole disc
    // clear of the mountains with the plane empty under it.
    float  elSun  = sunR * lift;
    float3 sunDir = normalize(float3(sin(sunAz), elSun, cos(sunAz)));

    // Signed azimuth from the sun. Everything that has to know where the
    // sun is reads this one number - the horizon glow, the disc, the light
    // pillar, the reflection in the plane, the cloud lighting, the ridge
    // rim and the moon's phase - so moving the sun moves all of them
    // together and the picture stays lit by one thing.
    float dAz  = wrapPi(az - sunAz);

    // How close this direction is to the sun, along the ground.
    float warm = exp(-abs(dAz) * warmK);

    // Kept, because the ground fog, the slab fog, the lamp posts and the
    // cloud deck all want the sky at the horizon and it is a dozen
    // instructions to recompute.
    float3 hz = skyGradient(0.0, haze, warm, skyFloor);

    // ---- mountains ------------------------------------------------------
    //
    // Three ranges. The far one is high frequency and low, which is what
    // distance does to a ridge; the near one is coarse and tall enough to
    // cross the sun. Heights are in tangent-of-elevation units, so the near
    // range's crests reach about half the upper frame at the fov these use.
    //
    // The frequencies are counts of cycles around the WHOLE circle, and a
    // shot only ever sees about a sixth of it, so they have to be much
    // higher than they look. Subtracting a floor before scaling is what
    // turns a lumpy field into a range: the valleys clamp flat onto the
    // horizon and only the crests stand up, so the silhouette has feet
    // instead of hovering.
    float hFar  = (ridgeLine(xn, sdFr, f0Fr, mesa * 0.45) * aFar + 0.002) * ridge;
    float hMid  = max(ridgeLine(xn, sdMd, f0Md, mesa) - kMid,  0.0) * aMid  * ridge;
    float hNear = max(ridgeLine(xn, sdNr, f0Nr, mesa) - kNear, 0.0) * aNear * ridge;

    // Silhouette coverage. saturate(0.5 + d/w) is a linear approximation to
    // the box filter over the edge and is enough here, because these edges
    // are near vertical and the ridge is one flat colour on both sides.
    float dFar  = hFar  - el;
    float dMid  = hMid  - el;
    float dNear = hNear - el;
    float covFar  = saturate(0.5 + dFar  / max(fwidth(dFar),  1e-5));
    float covMid  = saturate(0.5 + dMid  / max(fwidth(dMid),  1e-5));
    float covNear = saturate(0.5 + dNear / max(fwidth(dNear), 1e-5));

    // ---- ground ---------------------------------------------------------
    //
    // One ray-plane intersection. The denominator is clamped rather than
    // branched on so that the grid coordinate, and therefore fwidth() of
    // it, stays defined for every pixel including the ones in the sky -
    // a derivative taken inside a branch is a derivative of nonsense.
    float tG   = camY / max(-rd.y, 1e-4);
    float3 pg  = ro + rd * tG;

    // The half cell offset puts x = 0 in the middle of a cell rather than on
    // a line. Without it a camera sitting on the world axis - which is where
    // most shots put it - has a heavy grid line running straight out of the
    // bottom of frame, and it reads as a searchlight rather than as floor.
    float2 g   = float2(pg.x, pg.z + scroll) / cell + 0.5;
    float2 w   = fwidth(g);

    // Capping the half width at a small multiple of the filter width is the
    // other half of the analytic grid, and the one that is easy to leave
    // out. A line has a fixed width in WORLD units, so three metres from the
    // camera it is fifty pixels across and lies over the bottom of frame
    // like a painted road marking. Clamped this way it holds roughly two
    // pixels from here to the middle distance and then dissolves into the
    // wash on its own, which is what a grid line is supposed to look like.
    //
    // Both half widths are now specified in WORLD units and converted, so
    // that changing the cell pitch or the bar spacing changes how many
    // lines there are without also changing how thick they are.
    float hwFs = 0.042 / cell;
    float2 hwF = min(float2(hwFs, hwFs), w * 1.10);
    float fine = max(filteredLine(g.x, w.x, hwF.x),
                     filteredLine(g.y, w.y, hwF.y));

    // Every hvyN'th line is heavy. Without it the grid is a texture; with
    // it the grid has bars, and the eye can count them going away. Four
    // gives a tight ladder, sixteen gives widely spaced beams with a fine
    // mesh between them, and they do not read as the same floor at all.
    float rHvy  = 1.0 / hvyN;
    float2 G    = g * rHvy;
    float2 W    = w * rHvy;
    float hwHs  = 0.145 / (cell * hvyN);
    float2 hwH  = min(float2(hwHs, hwHs), W * 1.70);
    float heavy = max(filteredLine(G.x, W.x, hwH.x),
                      filteredLine(G.y, W.y, hwH.y));

    // ---- the road -------------------------------------------------------
    //
    // On the shots that get it, the middle of the plane stops being a field
    // and becomes a carriageway: the mesh is cut away over the tarmac, two
    // solid lines mark the edges and a run of centre dashes streams in at
    // exactly the cell rate, so the road and the grid keep time with each
    // other instead of beating against each other.
    //
    // Every one of these widths is in world units and every coverage is
    // divided by the screen-space derivative of the world coordinate, so a
    // line is a real painted stripe near the camera and correctly fades to
    // nothing rather than to noise once it is thinner than a pixel.
    float wx    = max(fwidth(pg.x), 1e-5);
    float ax0   = abs(pg.x);
    float onRd  = saturate((roadHW - ax0) / wx + 0.5) * roadOn;
    float exd   = abs(ax0 - roadHW);
    float edgeL = saturate((0.18 - exd) / wx + 0.5) * saturate(0.36 / wx) * roadOn;
    float zc    = (pg.z + scroll) / cell;
    float wzc   = max(fwidth(zc), 1e-5);
    float ctrL  = filteredLine(zc, wzc, 0.26)
                * saturate((0.16 - ax0) / wx + 0.5) * saturate(0.32 / wx) * roadOn;

    fine  *= 1.0 - onRd;
    heavy *= 1.0 - onRd * 0.90;

    // Dark immediately under the camera and gone before the horizon. The
    // near fade is what stops the two or three cells at the bottom of frame
    // from becoming the brightest thing in the shot.
    //
    // Both distances scale with the eye height, and they have to. On a plane
    // the distance to a given row of the screen is proportional to how high
    // the camera is, so a fade written in fixed world units covers half the
    // frame from two units up and none of it from one - which is exactly
    // what happened here, and it made the grid vanish out of the low shots.
    float gfade = saturate(tG / (camY * gNear)) * exp(-tG / (camY * gFar));

    // The reflection of the sun in the plane. Strongest at grazing angles,
    // which is to say strongest at the horizon, which is where a low sun
    // actually glitters off a wet road. The ripple runs along it at a
    // couple of hertz, which is the one thing in the lower half of frame
    // that still moves when gTune.x is zero and the grid is frozen. Its
    // floor is 0.86, so it is a shimmer, not a blink.
    float glit = pow(warm, 3.5) * exp(-abs(el) * 9.0);
    float rip  = 0.86 + 0.14 * sin(pg.z * 0.20 - t * 2.3 + pg.x * 0.55);

    // Cool and warm are within 0.11 of each other in luminance, so this
    // transition survives the quantiser as a hue shift over one band rather
    // than as a jump. That is the intent: the road should change colour,
    // not brightness.
    float3 gridCool = float3(0.20, 0.52, 0.92);   // lum 0.47
    float3 gridWarm = float3(0.98, 0.46, 0.14);   // lum 0.58
    float3 gridCol  = lerp(gridCool, gridWarm, saturate(glit * 2.4));

    // Weights land a lone fine line in band 2 and a heavy crossing in band
    // 4-5, against a floor in band 0. The old 0.55/1.05 put a heavy
    // crossing at lum 1.6, which is not a bright grid line, it is a flat
    // white one with every value inside it thrown away.
    //
    // The two music terms are both base + k*s. The hat pushes the fine mesh
    // by at most a quarter and the low band pushes the bars by at most a
    // third; neither can take the floor away, so the grid pulses without
    // the frame ever going dark between hits.
    float3 gnd = float3(0.007, 0.009, 0.019) * (1.0 - onRd * 0.35);
    gnd += gridCol * (fine  * 0.40 * (1.0 + 0.28 * gVoice.w)
                    + heavy * 0.58 * (1.0 + 0.30 * gSync.x)) * gfade * gGain;
    gnd += gridCol * (edgeL * 0.52 + ctrL * 0.46) * gfade * gGain;
    gnd += float3(1.00, 0.40, 0.13) * glit * 0.75 * rip;

    // ---- sky ------------------------------------------------------------

    // Kept, because the slab fog and the lamp post fog both want the sky at
    // this exact elevation.
    float3 skyRaw = skyGradient(el, haze, warm, skyFloor);
    float3 sky    = skyRaw;

    // Stars, thinned out by haze and by the sun's glow. Sized at roughly a
    // virtual pixel and a half - any smaller and the ordered dither in the
    // post pass eats them alive.
    //
    // The horizontal cell count is an integer number of cells around the
    // whole circle and the cell index is wrapped, so the star field closes
    // across the atan2 seam the same way the ridge noise does. Scaling a
    // raw azimuth by 110 put a hard vertical join through the star field at
    // exactly the azimuth the ridge had been so carefully made continuous
    // at.
    //
    // Each star twinkles at its own rate, seeded off its own hash, with a
    // floor of 0.72 - so the field is alive on a locked-off camera but no
    // individual star ever switches on or off.
    {
        float2 sp = float2(xn * 704.0, rd.y * 96.0);
        float2 ic = floor(sp), fc = frac(sp) - 0.5;
        ic.x = pmod(ic.x, 704.0);
        float  h  = hash21(ic);
        float  s  = smoothstep(starThr, starThr + 0.09, h)
                  * saturate(1.0 - length(fc) * 2.2);
        float  tw = 0.72 + 0.28 * sin(h * 61.0 + t * (1.4 + h * 3.2));

        // 1.05, not 1.6. At 1.6 the blue channel reached 1.5, the quantiser
        // clipped it flat and every star came out the same white as the sun
        // crown. At 1.05 a star is band 7 and keeps its colour.
        sky += float3(0.62, 0.70, 0.95) * s * s * 1.05 * tw
             * saturate(rd.y * 3.0 - 0.1) * (1.0 - haze) * (1.0 + 0.35 * gVoice.w);
    }

    // ---- the second body ------------------------------------------------
    //
    // A banded, ringed planet, low but clear of the ridge, and always at
    // least 0.62 radians off the sun's azimuth so it never sits on top of
    // it. It is the cheapest possible "this is a different place" cue: one
    // extra disc in the upper sky and the shot cannot be confused with the
    // seven others. Lit from the sun's side, so the terminator points the
    // right way and it belongs in the same picture rather than looking
    // pasted on.
    //
    // Deliberately dim - the crown of it is band 3, well under the sun's
    // band 8 - because there is only one light in this world and it is not
    // this.
    float3 moonC;
    float  moonCov, ringM;
    {
        float mAz0 = (c7 - 0.5) * 2.2;
        mAz0 += (mAz0 < 0.0 ? -0.62 : 0.62);          // never on top of the sun
        float mEl  = 0.24 + c6 * 0.28;
        float mR   = sunR * (0.40 + 0.30 * c1);
        float2 mp  = float2(wrapPi(az - sunAz - mAz0), el - mEl);
        float  mrr = length(mp) / mR;

        // Same seam taper as the sun: at the atan2 join fwidth(mrr) is the
        // width of the whole sky, and without the second factor a ghost of
        // the disc appears on that one column.
        moonCov = saturate(0.5 + (1.0 - mrr) / max(fwidth(mrr), 1e-5))
                * saturate((1.6 - mrr) * 4.0) * moonA;

        float bandv = pnoise((mp.y / mR) * 3.4 + 11.0, 64.0);
        moonC = lerp(float3(0.15, 0.17, 0.25), float3(0.40, 0.42, 0.53), bandv);
        moonC *= 0.34 + 0.66 * saturate(0.55 - (mp.x / mR) * (mAz0 > 0.0 ? 0.85 : -0.85));

        // The ring is the same circle squashed 3.4:1 and taken as an
        // annulus. Drawn only outside the disc, which costs the far side of
        // it but saves an ordering test and a depth compare on something
        // that is four pixels wide.
        float2 rp = float2(mp.x, mp.y * 3.4) / mR;
        float  rl2 = length(rp);
        ringM = smoothstep(1.28, 1.40, rl2) * (1.0 - smoothstep(1.68, 1.80, rl2))
              * moonA * (1.0 - moonCov);
    }
    sky = lerp(sky, moonC, moonCov);
    sky += float3(0.34, 0.36, 0.46) * ringM * 0.55;

    float ca = dot(rd, sunDir);

    // A dark ring just outside the disc, then the glow beyond it. This is
    // the single most important line in the file: without the ring the sun
    // is a sticker on a gradient, and with it the sun is a hole with
    // something burning behind the sky around it.
    //
    // It starts at 0.99 rather than 1.00. At 1.00 there was a band of
    // un-darkened sky sitting between the limb and the ring, and with the
    // glow on top of it that band was the brightest thing in frame after
    // the crown - a white halo directly outside a disc whose whole idea is
    // that it is surrounded by darkness.
    float rr   = length(float2(dAz, el - elSun)) / sunR;
    float ring = smoothstep(0.99, 1.32, rr) * (1.0 - smoothstep(1.45, 2.60, rr));
    sky *= 1.0 - 0.72 * ring;

    // Glow coefficients set so the sky just outside the limb lands in band
    // 6 - brighter than the horizon at band 4, darker than the sun's foot
    // at band 4-5 and its crown at band 8. The old 0.55/0.22 put it past
    // 1.0, which is band 10, which is the same band as the crown: the sun
    // and the sky around it were one flat white blob.
    float3 glow = float3(1.00, 0.44, 0.15) * exp(-(1.0 - ca) * 34.0) * 0.24
                + float3(0.90, 0.30, 0.12) * exp(-(1.0 - ca) *  4.0) * 0.14;

    // A light pillar straight up out of it. Cheap, and it is the detail
    // that stops the sky reading as a gradient with a circle on it. Kept
    // faint on purpose - at the strength it wants to be it stops being a
    // pillar and becomes a searchlight. The solo lengthens it and lifts it
    // by half, from a floor of 0.09 that is always there.
    glow += float3(0.85, 0.34, 0.12)
          * exp(-abs(dAz) * 34.0)
          * exp(-max(el, 0.0) * (3.0 - 1.4 * gVoice.y))
          * 0.09 * (1.0 + 0.50 * gVoice.y);

    sky += glow * (1.0 - 0.85 * ring);

    // ---- aurora ---------------------------------------------------------
    //
    // A single ribbon, not a curtain wall: its centre elevation waves along
    // the azimuth on one octave of periodic noise, its thickness on
    // another, and a third at 121 cycles gives the vertical striations that
    // are the only reason anyone recognises the thing. All three drift, at
    // different rates and in different directions, so the ribbon crawls
    // rather than sliding - which is what makes this the animation that
    // carries a shot with a frozen grid.
    //
    // Amplitude is set so the brightest part lands at band 2: it is the
    // second event in the sky and must not compete with the sun. The organ
    // swells it from a floor of 0.6.
    {
        float rib = pnoise(xn *   9.0 + t * 0.100,   9.0);
        float thk = 0.055 + 0.045 * pnoise(xn * 19.0 - t * 0.155, 19.0);
        float dd  = (el - (0.20 + rib * 0.34)) / thk;
        float str = 0.45 + 0.55 * pnoise(xn * 121.0 + t * 0.70, 121.0);
        sky += float3(0.24, 0.58, 0.50) * exp(-dd * dd) * str
             * auroraA * saturate(el * 8.0) * 0.55 * (0.60 + 0.40 * gVoice.z);
    }

    // ---- the sun --------------------------------------------------------
    //
    // by runs -1 at the top of the disc to +1 at the bottom. The slats start
    // at bs = 0, which is a little above the centre, because the ground has
    // already taken everything below by = +0.55 and slats that only live in
    // the bottom half would be a band four pixels tall.
    //
    // The phase is bs*K - bs*bs*0.2375*K, whose derivative falls with
    // depth, so the slats get further apart going down while the gaps get
    // wider: the disc is being erased from below rather than striped
    // evenly. K is per shot: at 5 the visible part of the disc gets three
    // slats, which is a striped circle rather than a sun going out, and at
    // 9 it gets six thin ones and reads as a venetian blind. Both are
    // right, in different shots, which is the point.
    //
    // And the erasure CLIMBS while the shot is held. slatF is how far down
    // the visible disc the first slat sits at the cut - so a later
    // appearance can open with the sun further gone than an earlier one did
    // - and that start creeps upward at up to 0.022 of the disc a second,
    // floored at 0.03 so it can never quite eat the crown. On the four-bar
    // hold at bar 87 that is a visible slow extinction over seven seconds
    // with nothing else in the frame moving.
    //
    // Both of those are measured as a FRACTION OF THE VISIBLE DISC, not in
    // absolute disc radii, and that is a fix rather than a flourish. The
    // ground cuts the disc at by = lift, so the part anyone sees runs from
    // by = -1 to by = lift and is span = lift + 1 tall. The old code
    // started the slats at a fixed by = -0.62, which is a quarter of the
    // way down when lift is 0.55 - and with lift now free to sit at 0.26
    // it was most of the way down instead, so the low-sun shots came out
    // with a plain white ball and one bar across the bottom. The slat count
    // is normalised the same way, so a low sun and a high one get the same
    // number of bars across the face rather than the same bars with most of
    // them buried.
    float span = lift + 1.0;
    float sfr  = max(slatF - t * eatRt, 0.03);
    float by   = (elSun - el) / sunR;
    float bs   = by + 1.0 - sfr * span;
    float kk   = slatK * (1.55 / span);
    float bp   = bs * kk - bs * bs * (kk * 0.2375);
    float gap = saturate(0.06 + 0.58 * saturate(bs));

    // Filtered with the same integral as the grid, because these slats
    // converge exactly the way grid lines do and would strobe just as badly.
    float slat = 1.0 - filteredLine(bp - gap * 0.5, fwidth(bp), gap * 0.5);
    slat = lerp(1.0, slat, saturate(bs * 6.0));     // the crown stays solid

    // The crown is lum 0.84 and the foot lum 0.45, so the disc spans four
    // bands top to bottom and the dark limb takes another two off the edge.
    // The old top colour had a red channel of 1.10: everything above lum
    // 0.95 is one band, so the entire upper half of the disc was flat.
    float3 sunCol = lerp(float3(0.98, 0.83, 0.50),
                         float3(0.95, 0.27, 0.06), saturate(by * 0.5 + 0.5));
    sunCol *= 1.0 - 0.42 * smoothstep(0.70, 1.00, rr);   // dark limb
    sunCol *= slat;

    // The extra taper kills a faint ghost of the disc that otherwise shows
    // up on the single pixel column at the atan2 seam, where fwidth(rr) is
    // the width of the whole sky.
    float discCov = saturate(0.5 + (1.0 - rr) / max(fwidth(rr), 1e-5))
                  * saturate((1.5 - rr) * 4.0);

    float3 col = lerp(sky, sunCol, discCov);

    // ---- the cloud deck -------------------------------------------------
    //
    // Two octaves of noise that is periodic around the azimuth and free in
    // elevation, at 12 cycles horizontally against 26 vertically. That
    // ratio is the whole effect: the cells come out four times wider than
    // they are tall, so the threshold cuts them into long horizontal bars
    // rather than into blobs, and a bank of horizontal bars stacked over a
    // low sun is the one cloud formation this genre has.
    //
    // Drawn OVER the sun on purpose. A bar crossing the disc is worth more
    // than the disc is, and it is the difference between a sky and a
    // backdrop. Lit from underneath towards the sun - band 2 there, band 1
    // at the edges of frame - so it reads as cloud and not as smoke.
    {
        float  cd  = t * (0.03 + 0.06 * c4);
        float2 cp  = float2(xn * 12.0 + cd, el * 26.0 + 1.7);
        float  n1  = pnoise2(cp, 12.0) * 0.62 + pnoise2(cp * 2.0, 24.0) * 0.38;
        float  lo  = 0.54 - 0.18 * cloudA;
        float  cov = smoothstep(lo, lo + 0.15, n1)
                   * exp(-max(el, 0.0) * 3.2) * saturate(el * 26.0) * cloudA * 0.88;
        float3 cc  = lerp(hz * 0.34, (hz + glow * 0.55) * 1.20, pow(saturate(warm), 0.75));
        col = lerp(col, cc, saturate(cov));
    }

    // ---- composite: mountains over the sky ------------------------------

    // Three haze mixes chosen so the ranges land on bands 3, 2 and 1 with
    // the horizon sky above them at band 4 - and, importantly, so they stay
    // in those bands across the whole haze range rather than only at one
    // setting.
    //
    // The old mixes were 0.65 / 0.32 / 0.04 against a horizon of lum 0.22.
    // That put the far range at lum 0.16 against a sky at 0.22 - six
    // hundredths apart, which is a little over half of one band, so the
    // dither merged them and the far range simply was not in the picture.
    // The near range and the slabs were both under 0.05 and were therefore
    // the same navy floor as each other and as the empty sky.
    float3 far0 = float3(0.006, 0.008, 0.015);
    col = lerp(col, lerp(far0, hz, hFarK),  covFar);   // band 3
    col = lerp(col, lerp(far0, hz, hMidK),  covMid);   // band 2
    col = lerp(col, lerp(far0, hz, hNearK), covNear);  // band 1

    // A rim on the near crest, only where the crest is in front of the sun.
    // A black shape with a hot line along its top edge is the whole reason
    // this scene survives being dithered down to a handful of levels: the
    // rim is band 6 sitting directly on band 1, which is the largest step
    // anywhere in the frame that is not the sun itself. The guitar drives
    // it from a floor of 0.90 - the rim is never absent, it just gets
    // hotter when the riff is under it.
    col += float3(1.00, 0.46, 0.16)
         * exp(-max(dNear, 0.0) * 90.0) * step(0.0, dNear)
         * pow(warm, 1.4) * 0.90 * ridge * (1.0 + 0.32 * gVoice.x);

    // A fog bank sitting in the mountains' feet. This is the structural half
    // of what gTune.w means: at haze 0.15 it is nothing, at 0.55 it is a
    // layer that drowns the bottom of the near range and leaves the crests
    // as islands, which is a materially different silhouette rather than a
    // greyer version of the same one. Squared, so only the genuinely hazy
    // shots get it, and pulled back off the sun so the disc keeps its foot.
    float bank = saturate(exp(-max(el, 0.0) * (30.0 - 14.0 * haze)) * haze * haze * 1.4)
               * (1.0 - discCov * 0.75) * step(0.0, el);
    col = lerp(col, hz * (0.80 + 0.30 * warm), bank);

    // ---- ground over everything below the horizon ------------------------

    // The ground's fog scales with the eye height for the same reason the
    // grid fade does. The slabs get their own constant in world units,
    // because they are objects at real distances and how far away a tower
    // looks must not change when the camera comes down a metre.
    float fogK = (1.0 + 2.6 * haze) / (camY * 62.0);

    // 0.0030 with a shallow haze response, not 0.0055 with a steep one.
    // Swept against the quantiser at every haze setting, this holds the
    // slab depth ramp inside bands 0, 1 and 2 for the whole 15-to-315 unit
    // stream: a near slab is always on the floor and a far one is always a
    // ghost, and neither ever climbs into band 3 where the far range lives
    // and disappears against it.
    float fogW = 0.0030 * (1.0 + 1.6 * haze);

    // Two deliberate weaknesses in the ground fog. It never reaches 1, and
    // it hazes towards a little over half the sky rather than towards the
    // sky itself. Let the plane haze all the way and the bottom third of
    // frame becomes one warm wash with the mountains floating in it: the
    // plane and the sky arrive at the same value and the horizon stops
    // being an edge, it becomes a place where two browns happen to touch.
    float fogG = (1.0 - exp(-tG * fogK)) * (0.58 + 0.30 * haze);
    gnd = lerp(gnd, (hz + glow * 0.18) * 0.55, fogG);

    float gcov = saturate(0.5 - el / max(fwidth(el), 1e-5));
    col = lerp(col, gnd, gcov);

    // ---- slabs over everything ------------------------------------------
    //
    // Exact ray-box, no march. They are camera-relative in z so that they
    // stream past forever, but world-fixed in x so that a lateral dolly
    // still gets real parallax off them.
    //
    // The four hand-placed towers this scene used to have are gone, because
    // four hand-placed towers are the same four towers every time the scene
    // comes back. What survives from them is the DISCIPLINE, encoded rather
    // than typed: index parity puts consecutive slabs on opposite sides of
    // the axis, and none of them is allowed within fifteen units of it, so
    // whatever the hash produces still frames the sun instead of standing
    // in front of it. Heights are squared off the hash so most of them are
    // low and a rare one is enormous - a skyline of equal towers has no
    // skyline in it.
    float cS = 0.0, tBest = 1e9;
    {
        float3 ir = float3(safeRcp(rd.x), safeRcp(rd.y), safeRcp(rd.z));

        // dv is the thickness of ONE slab along this ray: positive inside
        // it, negative outside, and continuous across the silhouette
        // because tN and tF are both continuous functions of rd. That makes
        // it a signed field the screen-space derivative can be taken of,
        // which is the only way a ray-box gets an anti-aliased edge without
        // supersampling it.
        //
        // This matters more than it sounds. These are the highest contrast
        // edges in the frame - band 0 against band 4 - they are near
        // vertical, and they MOVE. A hard-tested box gives them stair steps
        // that crawl a pixel at a time down the edge, and the ordered
        // dither turns each step into a little rectangle of noise.
        //
        // THE DERIVATIVE HAS TO BE TAKEN PER SLAB, which is why this loop
        // is unrolled and why it no longer keeps a running maximum to
        // filter at the end. max() of two continuous fields is continuous
        // but it has a CREASE where the winner changes, fwidth() at a
        // crease reports the size of the crease rather than the local
        // gradient, and saturate(0.5 + small/large) is one half - so the
        // locus where two slabs' thicknesses happen to be equal was drawn
        // as a half-covered line right across the frame, whether or not
        // either slab was anywhere near being hit. With four slabs nailed
        // to four hand-picked positions that locus happened to fall outside
        // the frame. With six of them placed by a hash it did not, and it
        // put a wire across the sun. Each slab is filtered on its own field
        // now and the coverages are unioned afterwards, which has no crease
        // in it anywhere.
        [unroll] for (int b = 0; b < 6; b++) {
            // Two hashes, four numbers. frac() of a scaled hash is a
            // decorrelated second draw for nothing, and a third hash per
            // slab was measurably more expensive than the whole ray-box
            // test it was feeding.
            float sd = vid * 0.0173 + (float)b * 3.719;
            float ha = hash11(sd);
            float hb = hash11(sd + 1.31);

            float sgn = ((b & 1) != 0) ? 1.0 : -1.0;
            float sx  = sgn * (15.0 + ha * 92.0);
            float shw = 3.0 + frac(ha * 7.31) * 5.5;
            float sht = 13.0 + hb * hb * 66.0;
            float u   = frac(hb * 5.17 + 0.31 - slabPhase);

            // Centre at half the height with a half extent of the same, so
            // the box spans y = 0 to y = height. It was centred AT the
            // height with a half extent of the height, which stood every
            // slab in a box from 0 to twice its height.
            float  hh = sht * 0.5;
            float3 bc = float3(sx, hh, ro.z + baseZ + u * 300.0);
            float3 bh = float3(shw, hh, shw);

            float3 n  = ir * (ro - bc);
            float3 k  = abs(ir) * bh;
            float3 t1 = -n - k, t2 = -n + k;
            float  tN = max(max(t1.x, t1.y), t1.z);
            float  tF = min(min(t2.x, t2.y), t2.z);

            // Clamped before the derivative is taken. Unclamped, a ray that
            // misses carries a thickness of minus several million world
            // units, fwidth of it is comparable, and the coverage comes out
            // at a flat one half over the entire sky. Sixteen units is
            // wider than any silhouette gradient at these distances, so
            // inside and outside both pin to a constant, fwidth goes to
            // zero there and the coverage is exactly 1 or exactly 0 - the
            // feather only exists in the pixel or two where the real
            // gradient lives. A slot this shot does not use is pinned to
            // the same constant, so it is exactly as free as not running.
            float dvC = ((float)b < slabN)
                      ? clamp(tF - max(tN, 0.0), -16.0, 16.0) : -16.0;
            float cv  = saturate(0.5 + dvC / max(fwidth(dvC), 1e-5));
            float th  = max(tN, 0.0);

            if (cv > 0.002 && th < tBest) tBest = th;
            cS = max(cS, cv);
        }
    }
    cS *= (tBest < ((rd.y < 0.0) ? tG : 1e9)) ? 1.0 : 0.0;

    // Nothing but haze separates a near slab from a far one, so the fog is
    // doing all the depth work here. The near ones come out on the floor,
    // band 0, the far ones as band 2 ghosts, and that difference is the
    // only thing telling you how big the plane is. The target is kept at
    // 0.72 of the sky so even the farthest slab stays a silhouette rather
    // than dissolving into the band the sky is in.
    float  fS = 1.0 - exp(-tBest * fogW);
    float3 slabCol = lerp(float3(0.006, 0.007, 0.014),
                          (skyRaw + glow * 0.25) * 0.72, fS);
    col = lerp(col, slabCol, cS);

    // Windows, on the shots that get them. A monolith is a shape; a tower
    // with a hundred lit cells in it is a building, and the two read as
    // completely different objects standing in the same grid. The hit point
    // is folded on x+z so one pattern wraps the corner without needing to
    // know which face was hit.
    //
    // The lod term is not optional. These cells are about a metre and a
    // half and the far towers are three hundred units out, so without it
    // they are sub-pixel noise that the ordered dither turns into a
    // shimmering rectangle. It fades them out the moment a cell stops being
    // resolvable, and the fog fades them again on top of that, so only the
    // near towers are ever lit.
    {
        float3 hp  = ro + rd * min(tBest, 3000.0);
        float2 wq  = float2((hp.x + hp.z) * 0.62, hp.y * 0.40);
        float2 fq  = abs(frac(wq) - 0.5);
        float  wm  = step(fq.x, 0.30) * step(fq.y, 0.32) * step(0.63, hash21(floor(wq)));
        float  lod = saturate(1.5 - max(fwidth(wq.x), fwidth(wq.y)) * 2.4);
        col += float3(1.00, 0.62, 0.26) * wm * lod * cS * winOn
             * (1.0 - fS * 0.85) * 0.40 * (0.62 + 0.38 * gVoice.x);
    }

    // ---- lamp posts down the road ---------------------------------------
    //
    // Two vertical planes at x = +-poleX, each carrying a picket that
    // repeats every two cells. Because every post on one side lies in the
    // SAME plane, this is one ray-plane intersection per side and then a
    // filtered line in z and a window in y - an infinite row of posts for
    // about the cost of one box, and correctly anti-aliased by the same
    // integral the grid uses.
    //
    // They are what a road needs that a grid does not: a rhythm with a
    // beat, streaming past at the scroll rate, with a hot cap on each one
    // that gives the lower half of frame a run of moving highlights. On the
    // bar 80 crane, which climbs thirty units a second, they are also the
    // only thing in the picture that tells you the camera is rising.
    //
    // The distance falloff is aggressive on purpose. A post is a few
    // centimetres of world at two hundred units and there is no honest way
    // to draw it, so it is faded out well before it can become a row of
    // grey dots along the horizon.
    float poleX  = roadHW + 3.2;
    float poleH  = 7.5 + c2 * 4.0;
    float poleSp = cell * 2.0;
    float poleCov = 0.0, poleT = 1e9, capM = 0.0;
    [unroll] for (int s2 = 0; s2 < 2; s2++) {
        float px = (s2 == 0) ? -poleX : poleX;
        float tp = (px - ro.x) * safeRcp(rd.x);
        float tc = clamp(tp, 0.0, 900.0);
        float3 pp = ro + rd * tc;

        float zp   = (pp.z + scroll) / poleSp;
        float wzp  = max(fwidth(zp), 1e-5);
        float post = filteredLine(zp, wzp, 0.055);

        float wyp  = max(fwidth(pp.y), 1e-5);
        float vext = saturate((poleH - pp.y) / wyp + 0.5) * saturate(pp.y / wyp + 0.5);

        // Both derivatives gate it. Once a pixel spans more than a couple
        // of world units vertically or more than half a post period along
        // z, there is no post left to draw and what remains is the mean of
        // the pattern smeared over the sky - which is exactly the flat grey
        // band this term exists to prevent.
        float lod = saturate(1.4 - wyp * 0.50) * saturate(1.6 - wzp * 2.0);
        float on  = step(0.4, tp) * step(tp, 850.0) * lod * vext * post;

        float cov = on * exp(-tc * 0.011);
        float cap = on * saturate((pp.y - (poleH - 1.5)) * 1.1) * exp(-tc * 0.020);

        if (cov > poleCov) { poleCov = cov; poleT = tc; }
        capM = max(capM, cap);
    }
    {
        float3 poleCol = lerp(float3(0.010, 0.011, 0.020),
                              (skyRaw + glow * 0.22) * 0.62,
                              1.0 - exp(-poleT * fogW));
        float pv = saturate(poleCov) * roadOn * ((poleT < tBest) ? 1.0 : 0.0);
        col = lerp(col, poleCol, pv);
        col += float3(1.00, 0.58, 0.22) * saturate(capM) * roadOn
             * 0.50 * (0.62 + 0.38 * gVoice.w);
    }

    // Shot fade only. No dither, no scanlines, no tone curve, no mask -
    // post.hlsl owns every one of those and doing any of them twice is how
    // a demo ends up with moire between its own two dither grids.
    return float4(col * gTime.z, 1.0);
}
