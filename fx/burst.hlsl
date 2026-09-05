// THE BURST.
//
// The fastest passage in the demo, under the second solo. Matter tearing
// past the camera at a speed nothing else in the demo goes.
//
// What the viewer sees in the first half second: a black frame with the
// direction of travel somewhere in it, and everything else in the shot flying
// out of that point. Near it the particles are end-on and read as dots; the
// further from it they get the longer they stretch, until at the corners they
// are streaks a third of the screen long leaving frame. There is no lighting
// model here at all. Depth is carried entirely by brightness, because that is
// the only channel the ten step quantiser in the post pass still has left.
//
// gTune.x  speed, world units per second. 40 is a drift, 130 is the solo.
// gTune.y  density, 0..1 - how full the field is. 1 is as busy as this scene
//          is allowed to get, not as busy as the lattice could be; see below.
// gTune.z  colour temperature, 0 cold blue .. 0.5 amber .. 1 phosphor green
// gTune.w  EXTRA flare at the vanishing point, 0..1.5, on top of the shot's
//          own. Every burst row in the edit passes 0 here.
//
// ===========================================================================
//  F I V E   B U R S T S ,   N O T   O N E   B U R S T   F I V E   T I M E S
//
//  The edit cuts here five times: bars 31, 45, 67, 73 and 78. Those rows
//  differ only in speed (45, 90, 100, 110, 118), density (0.30 .. 0.42) and
//  temperature - and post.hlsl regrades every frame through a per section
//  palette, so temperature buys nothing at all. Speed alone is not a shot.
//  Measured pairwise as luminance thumbnails, the five appearances were the
//  most repetitive multi appearance scene in the demo: five near identical
//  fields of streaks at five brightnesses.
//
//  So the three knobs the table does vary are hashed into a SIGNATURE, and
//  the signature decides what SHAPE the field is - not what colour it is.
//  Five topologies, one per appearance as the table stands:
//
//      OPEN    the full isotropic field. The scene as it was.
//      TUNNEL  the throat is cleared. A dark aperture with a thin rim of
//              light around it and the debris ripping past outside.
//      SHEET   the field collapses into one band through the axis: a bar of
//              streaks across black, turning as the field rolls.
//      ARMS    three or six vanes, twisted along the depth axis, so the
//              matter arrives in wedges with clean gaps between them.
//      SHOAL   occupancy clumped into blocks a dozen cells across and ten
//              planes deep, which sweep past as gusts with holes in.
//
//  Every appearance also gets its own roll rate and direction, its own drift
//  of the vanishing point off frame centre, its own surge in the flow so a
//  held shot is not a constant blur, its own lattice scale, streak length,
//  streak width, hero/dust balance, and a shock ring on its own period that
//  crosses the frame outward through the debris. Behind all of it, a fixed
//  far field of pinpoints that does NOT flow, which is the only thing in a
//  scene of streaks that can give it parallax.
//
//  THE HASH IS NOT CHAINED. s2 is not hash(s1): four separate calls on four
//  well conditioned inputs. Chaining costs everything - the last frac() in
//  the hash works on products around 5000, which in fp32 leaves about 5e-4 of
//  output precision, and feeding that back in amplifies it until the answer
//  depends on the driver. Unchained, the fp32 and fp64 selectors agree to
//  4e-3 while the nearest shot sits 0.2 of a bucket from an edge, so which
//  shape a row gets is a property of the row, not of the machine.
//
//  Change a row in shots.h and that appearance is reshuffled to another
//  shape. It is still a shape, and the five are still five pictures.
// ===========================================================================

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

// ---- the signature, decoded once per pixel into these --------------------
// Per SHOT, not per pixel: every pixel derives the same values from the same
// gTune, so every branch on gMode below is uniform across the whole draw and
// costs a branch rather than a mask.
static int    gMode;        // 0 open, 1 tunnel, 2 sheet, 3 arms, 4 shoal
static float  gCoreR;       // TUNNEL: cleared radius, tan units
static float  gSheetHW;     // SHEET:  half width of the band, tan units
static float2 gSheetN;      // SHEET:  band normal in the lattice frame
static float  gTwist;       // ARMS:   radians of twist per world unit of depth
static float  gArmPh;       // ARMS:   phase, spins over the shot
static float  gArm6;        // ARMS:   0 -> three vanes, 1 -> six
static float  gBlockS;      // SHOAL:  1/clump size across, in cells
static float  gBlockZ;      // SHOAL:  1/clump size along, in planes
static float  gBlockT;      // SHOAL:  how much of the field a clump keeps

float sq(float x) { return x * x; }

// Hoskins' three-in three-out hash. No texture, and stable: a cell keeps the
// same particle for as long as it is on screen, which matters more than it
// sounds. A particle that re-rolls its seed does not move, it flickers, and
// against the ordered dither flicker turns into crawling grain.
float3 hash33(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.xxy + p.yxx) * p.zyx);
}

// The palette knob. Three anchors, because these are the three the demo
// actually lives in: cold blue, warm amber, phosphor green.
float3 tempColour(float t)
{
    float3 cold  = float3(0.34, 0.62, 1.00);
    float3 amber = float3(1.00, 0.66, 0.26);
    float3 green = float3(0.36, 1.00, 0.48);
    return t < 0.5 ? lerp(cold,  amber, t * 2.0)
                   : lerp(amber, green, t * 2.0 - 1.0);
}

// Complex multiply, used to advance an angle without a transcendental.
float2 cmul(float2 a, float2 b)
{
    return float2(a.x * b.x - a.y * b.y, a.y * b.x + a.x * b.y);
}

// ---------------------------------------------------------------------------
//  W H A T   S H A P E   T H E   F I E L D   I S
//
//  Asked once per cell per depth plane, BEFORE the cell is hashed, and from
//  the cell's own centre rather than from the particle inside it. That
//  ordering is the whole reason this is affordable: a cleared cell costs a
//  dot product and returns, and never pays for the hash or the segment solve.
//  SHEET throws away three quarters of the lattice, so at the shot level the
//  shaped modes are CHEAPER than the open one, not dearer.
//
//  The answer is a weight, not a yes. It multiplies the streak's amplitude,
//  so a particle near the edge of the shape fades as the shape turns.
//  Thresholding the occupancy instead would be cheaper and would pop: the
//  cell hash is fixed, so a particle crossing the boundary would blink rather
//  than dim, and forty of them blinking is the lattice announcing itself.
//
//  `rot` is (cos, sin) of the ARMS phase at this depth, advanced by the
//  caller with a complex multiply so the loop never touches a sine.
// ---------------------------------------------------------------------------
float fieldMask(float2 ci, float pn, float cell, float zc, float2 rot)
{
    if (gMode == 0) return 1.0;                 // OPEN: the whole lattice

    float2 cc = (ci + 0.5) * cell;              // cell centre, camera space
    float  iz = 1.0 / zc;                       // ...read as an angle off axis

    if (gMode == 1)                             // TUNNEL
        return smoothstep(gCoreR * 0.42, gCoreR, length(cc) * iz);

    if (gMode == 2)                             // SHEET
        return 1.0 - smoothstep(gSheetHW * 0.52, gSheetHW,
                                abs(dot(cc, gSheetN)) * iz);

    if (gMode == 3)                             // ARMS
    {
        // cos/sin of N.theta straight out of the cell direction. Chebyshev
        // for three, one doubling for six. atan2 in here would be fifty
        // transcendentals a pixel; this is four multiplies.
        float2 d  = cc * rsqrt(dot(cc, cc) + 1.0e-6);
        float  c3 = d.x * (4.0 * d.x * d.x - 3.0);
        float  s3 = d.y * (3.0 - 4.0 * d.y * d.y);
        float  ca = lerp(c3, 2.0 * c3 * c3 - 1.0, gArm6);
        float  sa = lerp(s3, 2.0 * s3 * c3,       gArm6);
        return smoothstep(-0.35, 0.40, ca * rot.x - sa * rot.y);
    }

    // SHOAL. A second hash on a COARSE index - twenty cells across, a dozen
    // planes deep. Big and deep on purpose: a ray crosses thirty six cells,
    // so clumps smaller than this average out along it and the shot looks
    // exactly like the open field. The index is absolute - the plane NUMBER,
    // not its depth - so the clumps are nailed to the field and sweep past
    // the camera instead of sitting still in front of it.
    float3 b = hash33(float3(floor(ci.x * gBlockS), floor(ci.y * gBlockS),
                             floor(pn * gBlockZ)) + 3.1);
    return smoothstep(gBlockT, gBlockT + 0.35, b.x);
}

// ---------------------------------------------------------------------------
//  ONE LATTICE OF STREAKS
//
//  This is the whole trick, and it is the non-obvious part, so at length.
//
//  There is no particle system. There is an infinite lattice of cells, each
//  holding at most one particle at a hashed position inside itself, and the
//  pixel shader asks: which of those particles does MY ray pass close to?
//
//  Everything below is in the camera's own frame - x right, y up, z forward -
//  so the ray starts at the origin and the camera's motion is straight down
//  +z. That choice is what nails the expansion centre to the direction of
//  travel, which is the whole composition. Main tilts that frame off the
//  optical axis before handing it over, which is how the vanishing point gets
//  to sit somewhere other than the middle of the picture.
//
//  Cells are addressed as (lateral cell, depth plane). Depth planes sit every
//  `cell` units along z and slide towards the camera as `flow` grows, so the
//  particles are what is standing still and the camera is what is moving -
//  which is also why the lattice never has to be updated or stored.
//
//  The ray crosses each depth plane at exactly one point, so there is a
//  single lateral cell per plane to test, and the loop is one particle per
//  step with no traversal and no misses. That is the reason for slicing the
//  grid into planes rather than marching it: a fixed step through a 3D grid
//  skips cells and visits others twice.
//
//  A STREAK, not a point. During the time the shutter is open the camera
//  travels forward, so relative to the camera the particle sweeps a segment -
//  and since the camera only moves along +z, that segment runs from the
//  particle straight out along +z, away from us, for `len` units. Projected,
//  that is a line pointing back at the vanishing point, which is exactly what
//  a radial motion streak looks like. So the shading question is the distance
//  from the view ray to a segment, in closed form:
//
//      ray      P(s) = e * s               e unit, s >= 0
//      streak   Q(u) = (px, py, z0 + u)    u in [0, len]
//
//  Setting the connecting vector perpendicular to both and using the fact
//  that the segment is axis aligned along z, nearly all of the usual algebra
//  cancels and the closest point on the streak is just
//
//      u = e.z * (e.x*px + e.y*py) / (e.x^2 + e.y^2) - z0
//
//  clamped to [0, len]. The closest point on the ray is then the projection
//  of Q(u) onto e, and the distance between the two falls straight out.
// ---------------------------------------------------------------------------

// One cell, tested. Split out of the loop because the wide layer walks four
// cells per plane and this is the part that gets done four times.
// Returns (energy, the part of that energy that came from close in).
float2 streakAt(float3 e, float2 ci, float pn, float cell, float len,
                float invLen, float wide, float dens, float3 sofs,
                float zc, float zf, float g, float mk)
{
    float3 h  = hash33(float3(ci.x, ci.y, pn) + sofs);
    // Two more decorrelated numbers out of the same hash, which is a lot
    // cheaper than hashing twice and plenty for a field this busy.
    float  r1 = frac(h.x * 57.31 + h.z * 13.77);   // occupancy roll
    float  r2 = frac(h.y * 91.73 + h.x * 29.31);   // size and brightness

    if (r1 > dens) return float2(0.0, 0.0);        // this cell is empty

    // The particle inside its cell. Kept clear of the cell wall: a particle
    // sitting on a wall would pop in and out as the ray crossed it. 0.62 of a
    // cell of travel leaves a margin wider than the streak everywhere the far
    // fade has not already taken the streak to nothing.
    float2 pxy = (ci + 0.5 + (h.xy - 0.5) * 0.62) * cell;

    // Depth is jittered across a whole cell, not part of one. At less than
    // that the planes still show: the first render of this scene had visible
    // horizontal rows of dashes across the middle of frame, which is the
    // lattice announcing itself. The floor of a third of a unit is not
    // cosmetic - at zero depth the closest point on the ray is the camera
    // itself, every pixel gets the same distance, and one particle flashes
    // the entire frame white.
    float z0 = max(zc + (h.z - 0.5) * cell, 0.33);

    // ---- nearest approach of the ray to this streak ---------------------
    float  m  = e.x * pxy.x + e.y * pxy.y;
    float  u  = clamp(e.z * m / g - z0, 0.0, len);
    float  s  = max(m + e.z * (z0 + u), 0.02);
    float3 d  = float3(e.x * s - pxy.x, e.y * s - pxy.y, e.z * s - z0 - u);
    float  d2 = dot(d, d);

    // Width is an ANGLE, not a world size: the radius grows with distance so
    // every streak is the same handful of pixels wide wherever it is. At 640
    // x360 a streak thinner than a pixel does not get thinner, it gets noisy,
    // and the dither turns that noise into crawling grain. `wide` is a half
    // width in radians; at fov 0.62 the two layers come out 2.8 and 2.3
    // pixels wide at half maximum, which is the floor for a 360 line frame
    // that then goes through a CRT resample.
    float rw = wide * max(s, 0.4);
    float w  = rw * rw / (d2 + rw * rw);
    w *= w;                             // solid core, fast edge

    // Nothing here is lit, so brightness is the only thing separating near
    // from far, and it has to survive ten quantiser steps - hence a steep
    // falloff and a short near fade rather than anything physical.
    float t01  = saturate(z0 / zf);
    float fade = (1.0 - t01 * t01) * smoothstep(0.30, 1.60, z0);

    // A streak has a head and a tail. u = 0 is where the particle is now,
    // u = len is where it was when the shutter opened, so the energy has to
    // fall off along the trail - otherwise a corner streak is a uniform bar
    // as bright at its far end as at its head, the value structure goes flat
    // exactly where the composition wants it steepest, and the ends terminate
    // on a hard edge instead of dissolving.
    float tail = 1.0 - 0.62 * u * invLen;

    // r2 SQUARED, so most streaks are dim and a few are hero bright. A flat
    // spread of brightnesses quantises into one grey band and the whole frame
    // turns into television snow; this keeps a handful of streaks up at the
    // top of the ramp with darkness between them.
    // mk SQUARED for the same reason it exists: the shape's edge wants to be
    // narrow in the picture even though it has to be wide in the maths to
    // stay pop free, and squaring buys that for one multiply.
    float amp = (0.14 + 0.86 * r2 * r2) * fade * tail * mk * mk;

    return float2(w * amp, w * amp * (1.0 - t01));
}

float2 streakLayer(float3 e, float cell, float flow, int slabs, float len,
                   float wide, float dens, float seed, bool pair)
{
    // Streak length is capped against the CELL. A streak is only ever found
    // by rays whose cell is the streak's own cell at one of the depths tested
    // below; let it run much longer than the span those cover and the middle
    // of every long streak falls in cells nobody looks at, and the field
    // turns into rows of dashes with holes in.
    len = min(len, cell * (pair ? 1.35 : 0.95));

    // e.x^2 + e.y^2, since e is unit. It is zero only for the ray that goes
    // exactly down the axis, and the guard keeps that one pixel finite - the
    // clamp on u does the rest.
    float  g    = max(1.0 - e.z * e.z, 1.0e-4);
    float  ez   = max(e.z, 1.0e-3);
    float  zf   = float(slabs) * cell;      // far plane of this lattice
    float  rc   = 1.0 / cell;
    float  invL = 1.0 / max(len, 1.0e-3);
    float3 sofs = float3(seed, seed * 1.7, seed * 0.3);

    // Where the lattice sits right now. n0 is the ABSOLUTE index of the first
    // plane in front of the camera, and carrying it into the hash is what
    // stops the entire field re-rolling every time a plane passes. Without it
    // the shot strobes at the plane crossing rate, which at these speeds is
    // about fifteen times a second.
    float fz = flow / cell;
    float n0 = floor(fz);
    float ph = fz - n0;

    // ARMS advances its phase one step per depth plane and one third of a
    // streak per walk step. Angle addition by complex multiply, seeded by two
    // sincos outside the loop, so a twisted field costs six multiplies a
    // plane instead of two sines a plane.
    float2 rot  = float2(1.0, 0.0);
    float2 drot = float2(1.0, 0.0);     // one plane
    float2 qrot = float2(1.0, 0.0);     // one third of a streak
    if (gMode == 3)
    {
        sincos(gTwist * ((1.0 - ph) * cell) + gArmPh, rot.y,  rot.x);
        sincos(gTwist * cell,                        drot.y, drot.x);
        sincos(gTwist * len * (1.0 / 3.0),           qrot.y, qrot.x);
    }

    float2 acc = float2(0.0, 0.0);

    // [loop], never [unroll]: `slabs` is a literal at both call sites, so an
    // unrolled body would be 36 copies of the body in the blob.
    [loop] for (int k = 0; k < slabs; k++)
    {
        // Depth of this plane in camera space. (1 - ph) slides the whole set
        // towards us as flow grows; k pushes it out towards the far plane.
        float zc = (float(k) + 1.0 - ph) * cell;
        float pn = n0 + float(k);

        // The lateral cell the ray is inside when it crosses that plane.
        float2 ci = floor(e.xy * (zc / ez) * rc);

        float mk = fieldMask(ci, pn, cell, zc, rot);
        if (mk > 0.06)
            acc += streakAt(e, ci, pn, cell, len, invL, wide, dens, sofs,
                            zc, zf, g, mk);

        // ONE CELL PER PLANE IS NOT ENOUGH FOR THE LONG ONES.
        //
        // A streak is only ever found by the rays whose cell at `zc` is the
        // streak's own cell, so it is visible only inside the screen space
        // footprint of that cell - roughly cell/zc radians across, the same
        // angular size everywhere. Its projected LENGTH, on the other hand,
        // grows with distance from the vanishing point: about tan(theta)
        // times len/cell cells. Dead centre that is nothing. At the corner of
        // a 0.8 lens it is close to two cells, and with the vanishing point
        // pushed off centre it is three - so the middle of every corner
        // streak was landing in cells nobody tested. That is what the blocky
        // shearing in the corners of the old renders was: not aliasing, whole
        // streaks chopped into dashes, and chopped at the same radius for
        // every cell, which puts a ring of streak-ends through the frame.
        //
        // So walk the streak instead of sampling its ends: quarter steps from
        // head to tail, each one skipped when it lands in a cell already
        // done, which over most of the frame is all of them. The branch pays
        // for itself everywhere the streaks are short, and the corners - the
        // part of the frame this whole scene exists for - stop shearing.
        if (pair)
        {
            float2 ca = ci, cb = ci;
            float2 rq = rot;
            [unroll] for (int q = 1; q <= 3; q++)
            {
                float  zq = zc + len * (float(q) * (1.0 / 3.0));
                float2 cq = floor(e.xy * (zq / ez) * rc);
                rq = cmul(rq, qrot);
                if ((cq.x != ci.x || cq.y != ci.y) &&
                    (cq.x != ca.x || cq.y != ca.y) &&
                    (cq.x != cb.x || cq.y != cb.y))
                {
                    float mq = fieldMask(cq, pn, cell, zq, rq);
                    if (mq > 0.06)
                        acc += streakAt(e, cq, pn, cell, len, invL, wide,
                                        dens, sofs, zc, zf, g, mq);
                }
                cb = ca; ca = cq;
            }
        }

        if (gMode == 3) rot = cmul(rot, drot);
    }
    return acc;
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

    // The standard setup, so this scene frames identically to every other
    // one. The world-up fallback is not decoration: CAM_CRANE rows aim very
    // close to straight up, and cross((0,1,0), fw) is the zero vector there,
    // which normalize() turns into NaN and NaN painted over the whole frame.
    float3 fw  = normalize(gDir.xyz);
    float3 wup = abs(fw.y) > 0.999 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
    float3 rt  = normalize(cross(wup, fw));
    float3 up  = cross(fw, rt);

    float  cr = cos(gDir.w), sr = sin(gDir.w);
    float3 rx = rt * cr + up * sr;
    float3 ry = up * cr - rt * sr;
    float3 rd = normalize(fw + (uv.x * rx + uv.y * ry) * gCam.w);

    // Straight back into the camera frame, because that is where the lattice
    // lives. (rx, ry, fw) is orthonormal and rd is unit, so e is unit too.
    // gCam.xyz never appears: the field is defined relative to the camera on
    // purpose, so that a shot can orbit or roll through the burst without the
    // expansion centre sliding off the direction it is travelling in.
    float3 e = float3(dot(rd, rx), dot(rd, ry), dot(rd, fw));

    float speed = max(gTune.x, 0.0);
    float flare = max(gTune.w, 0.0);
    float t     = gTime.x;

    // ---- T H E   S H O T   S I G N A T U R E ----------------------------
    // Twelve decorrelated numbers out of the three knobs that actually differ
    // between the five appearances. Four separate hashes, never fed into each
    // other - see the note at the top of the file. All of it is per shot, so
    // every branch below is uniform over the draw.
    float3 kk = float3(gTune.x * 0.089, gTune.y * 11.90, gTune.z * 2.30);
    float3 s1 = hash33(kk + 1.7);
    float3 s2 = hash33(kk.yzx * 2.11 + 5.9);
    float3 s3 = hash33(kk.zxy * 1.37 + 11.7);
    float3 s4 = hash33(kk * 0.83 + 41.3);

    gMode = (int)min(4.0, floor(s1.x * 5.0));

    // How much of the lattice each shape throws away, put back so a shaped
    // shot is not simply an emptier one. Not a full area compensation - the
    // black a shape makes IS the composition and must not be filled in. This
    // restores the density INSIDE the shape to about what the open field has,
    // measured off the mean of the mask over a frame.
    float densK = 1.00;
    if (gMode == 1) densK = 1.10;
    if (gMode == 2) densK = 2.15;
    if (gMode == 3) densK = 1.25;
    if (gMode == 4) densK = 1.90;

    gCoreR   = (0.24 + 0.26 * s2.y) * gCam.w;
    gSheetHW = (0.34 + 0.34 * s2.y) * gCam.w;
    float sang = s4.z * 3.14159;
    gSheetN  = float2(cos(sang), sin(sang));
    float tw = (s4.z - 0.5) * 0.40;
    gTwist   = tw < 0.0 ? min(tw, -0.022) : max(tw, 0.022);
    gArmPh   = t * (s3.y - 0.5) * 2.20;
    gArm6    = s4.y > 0.5 ? 1.0 : 0.0;
    gBlockS  = 0.05 + 0.05 * s4.x;
    gBlockZ  = 0.06 + 0.06 * s4.y;
    gBlockT  = 0.20 + 0.20 * s4.y;

    // A directional shape has to TURN or it is wallpaper, so SHEET and ARMS
    // get a floor under the roll rate; the isotropic shapes do not need one
    // and a rolling isotropic field looks identical to a still one anyway.
    float roll = (s4.z - 0.5) * 1.60;
    if (gMode == 2 || gMode == 3) roll += roll < 0.0 ? -0.30 : 0.30;

    float tiltAmp  = 0.05 + 0.11 * s2.y;            // rad off the optical axis
    float tiltRate = 0.30 + 0.70 * s1.z;
    float lenMul   = 0.55 + 1.10 * s3.x;
    float cellMul  = 0.80 + 0.55 * s3.y;
    float wideMul  = 0.80 + 0.55 * s2.z;
    float heroW    = 0.62 + 0.42 * s2.x;
    float dustW    = 0.50 + 0.62 * s4.x;
    float surgeA   = 0.18 + 0.50 * s3.z;
    float surgeW   = 2.00 + 4.20 * s4.y;
    float ringAmp  = 0.22 + 0.40 * s1.y;
    float ringRate = 0.45 + 0.95 * s4.z;
    float starW    = 0.30 + 0.70 * s1.z;
    float glow     = 0.05 + 0.10 * s3.z;

    // ---- W H E R E   T H E   V A N I S H I N G   P O I N T   S I T S ----
    // The lattice frame is tilted off the optical axis and rolled about it.
    // Both are exact rotations, so e stays unit and every line of the solve
    // is untouched - but the expansion centre moves off the middle of the
    // picture and wanders, and the whole field turns. Three sincos for the
    // frame, and it is the single biggest difference between two appearances.
    //
    // The tilt is capped at 0.16 rad and that ceiling is load bearing. Push
    // the vanishing point further and the far corner passes 70 degrees off
    // axis, where a streak projects longer than the four cells the walk in
    // streakLayer covers and the corner shears into dashes again. Measured:
    // at 0.32 rad the pairwise spread between the five appearances is a fifth
    // better and two of them have a broken corner, which is not a trade.
    float ax = cos(t * tiltRate + s1.y * 6.2832) * tiltAmp;
    float ay = sin(t * tiltRate * 0.73 + 1.7) * tiltAmp;
    float cy, sy, cp, sp, cz, sz;
    sincos(ax, sy, cy);
    sincos(ay, sp, cp);
    sincos(t * roll, sz, cz);
    float3 e1 = float3(cy * e.x - sy * e.z, e.y, sy * e.x + cy * e.z);
    float3 e2 = float3(e1.x, cp * e1.y - sp * e1.z, sp * e1.y + cp * e1.z);
    e = float3(cz * e2.x - sz * e2.y, sz * e2.x + cz * e2.y, e2.z);

    // ---- H O W   F A S T ,   A N D   H O W   S T E A D I L Y ------------
    // How far the camera has flown since the shot began. The scene owns its
    // own speed instead of reading it off the shot's camera, because the
    // burst wants a hundred units a second while the camera itself barely
    // moves. If they were the same number the shot would have to fly a
    // kilometre and every `at` in the row would be nonsense.
    // gTime.x must be SHOT time, not song time: n0 is floor(flow/cell), and
    // at song time with speed 130 that index is in the thousands, where the
    // hash starts to lose its low bits.
    //
    // Not linear any more. This is the integral of speed*(1 + A sin(Wt)), so
    // the field surges and eases instead of running at one rate for the whole
    // shot - two bars of a constant blur is a still frame with noise on it.
    // A is well under one, so the derivative never goes negative and nothing
    // ever runs backwards. The solo envelope shoves a unit or so on top, far
    // too small against a hundred a second to reverse anything.
    float flow = speed * (t + surgeA * (1.0 - cos(surgeW * t)) / surgeW)
               + gVoice.y * 1.2;

    // Streak length is the shutter, exaggerated. The layers clamp it against
    // their own cell size; this is the shot's taste in it - dashes at one end
    // of the knob, threads at the other - and the solo stretches it.
    float baseLen = clamp(speed * 0.032, 0.40, 4.40);
    float len     = baseLen * lenMul * (1.0 + 0.18 * gVoice.y);

    // Distance from the direction of travel, 0 at the vanishing point and 1
    // at the top and bottom of frame. Measured against the TILTED axis, so
    // the flare and the shock ring stay concentric with the burst wherever
    // the burst has drifted to.
    float rn = length(e.xy / max(e.z, 1.0e-3)) / max(gCam.w, 1.0e-3);
    float rr = rn * rn;

    // Two lattices, not one. A single grid at a single scale reads as a grid.
    // A coarse one carrying long bright streaks and a fine one carrying dust
    // gives the frame a bold shape with a texture under it, and bold shape
    // plus texture is the only thing that survives being dithered into ten
    // levels at 360 lines.
    // The occupancy the knob asks for is scaled well down, because the useful
    // range turned out to be far narrower than 0..1: a quarter of the cells
    // carrying a particle already fills the frame, and a field with no black
    // in it has no streaks in it either, only texture.
    // cellMul moves BOTH lattices together, so one appearance is a coarse
    // field of big slow slabs of matter and another is fine grit.
    float hc = 3.40 * cellMul;
    float dc = 1.75 * cellMul;

    // HOW MUCH INK IS ON THE FRAME, held roughly where the shot table asked.
    // Coverage per plane goes as wide * len / cell, so the three knobs above
    // do not just change the SCALE of the streaks, they change how full the
    // frame is - and left alone they compound: the appearance that happened
    // to draw a fine lattice with long fat streaks came out twice as bright
    // as the row asked for, milky instead of streaks on black. The square
    // root is deliberate and is not a rounding: correct it fully and every
    // appearance sits at the same exposure, which throws away variation the
    // edit wants; correct it not at all and one of the five washes out. Half
    // leaves gTune.y in charge of fullness and lets the lattice be felt.
    float inkK = wideMul * (min(len, hc * 1.35) / baseLen) / cellMul;
    float dens = saturate(gTune.y * densK / sqrt(max(inkK, 0.35)));

    float2 hero = streakLayer(e, hc, flow, 20, len,
                              0.0076 * wideMul, dens * 0.28,  0.0, true);
    float2 dust = streakLayer(e, dc, flow, 16, len * 0.35,
                              0.0062 * wideMul, dens * 0.22, 37.0, false);

    float3 tint = tempColour(saturate(gTune.z));
    float3 hot  = float3(1.00, 0.94, 0.86);

    // Near black, slightly blue, so the darkest thing on screen is still the
    // demo's black and not a hole.
    float3 col = float3(0.010, 0.012, 0.024);

    // ---- T H E   S H O C K   R I N G ------------------------------------
    // A ring of extra energy born at the vanishing point and swept out past
    // the corners on its own period, brightening the debris it crosses. It is
    // multiplicative on a base of one, and it is a ring rather than a frame,
    // so the floor never moves and no more than a fifth of the picture is
    // lifted at once - a wave through the field, not a flash. Born and killed
    // at zero by the sine, because a ring that appeared at full strength on
    // the flare would be exactly the pop this is avoiding.
    float rp   = frac(t * ringRate);
    float ring = exp(-sq(rn - rp * 2.40) * 22.0) * sin(rp * 3.14159);
    float lift = 1.0 + ringAmp * ring;

    // Streaks that came from close in go white hot while distant ones keep
    // the tint - acc.y is the share of the energy that arrived from near, so
    // the ratio is the mix, per pixel, for free. The bias on that ratio is
    // there because the near streaks dominate almost every pixel: mapped
    // straight, the whole frame went white and the temperature knob did
    // nothing at all.
    // The two layers carry their own weights now, so one appearance is a
    // handful of big threads over black and another is a sandstorm. Both
    // audio terms are base + k*s and never scale the frame: the floor holds.
    float heroA = heroW * lift * (1.0 + 0.22 * gSync.x);
    float dustA = dustW * lift * (1.0 + 0.45 * gSync.z);
    col += hero.x * lerp(tint, hot, saturate(hero.y / max(hero.x, 1.0e-4) * 1.5 - 0.45)) * 1.75 * heroA;
    col += dust.x * lerp(tint, hot, 0.20) * 0.26 * dustA;

    // ---- T H E   F A R   F I E L D --------------------------------------
    // Pinpoints locked to the lattice frame rather than flowing through it.
    // One hash, no loop, and they buy the one thing a field of streaks cannot
    // give itself: parallax. Everything else in the shot is ripping past;
    // these barely move, and that is what says the streaks are near rather
    // than merely fast. base + k*high, so the hats shimmer them without ever
    // taking them out.
    float2 sptr = e.xy / max(e.z, 0.25) * 7.0;
    float2 scel = floor(sptr);
    float3 hs   = hash33(float3(scel, 11.0));
    float2 sd   = sptr - scel - 0.15 - hs.xy * 0.70;
    float  star = exp(-dot(sd, sd) * 260.0) * step(hs.z, 0.30);
    col += lerp(tint, hot, 0.45) * star * starW * 0.36 * (0.55 + 0.45 * gSync.z);

    // ---- T H E   L I G H T ----------------------------------------------
    // Everything in frame is coming out of one point, so that point is the
    // only thing in the shot allowed to blow out. It is a hard core and
    // nothing else: the wide bloom that used to sit under it is driven by
    // gTune.w alone, which every burst row in the edit sets to zero, and
    // adding one back lifted the black off the middle third of the frame and
    // turned the scene from streaks on black into a smudge. So the shot's own
    // flare is small and tight - an anchor for the eye, about twenty pixels
    // across, not a light source.
    // In TUNNEL it is tighter still and the throat gets a thin rim, so the
    // cleared centre reads as a shaft with something at the end of it rather
    // than as a hole somebody forgot to fill.
    float tight = gMode == 1 ? 210.0 : 130.0;
    col += tint * exp(-rr * 10.0) * 0.40 * flare;
    col += hot  * exp(-rr * tight) * 0.85 * (flare + glow * (1.0 + 0.25 * gSync.w));
    if (gMode == 1)
        col += tint * 0.08 * exp(-sq(rn - gCoreR / max(gCam.w, 1.0e-3)) * 190.0)
                    * (0.70 + 0.50 * gSync.y);

    // Shot fade only. No dither, no scanlines, no ramp, no exposure, no
    // tonemap: post.hlsl owns every one of those and doing any of it twice
    // is how the quantiser ends up with five usable steps instead of ten.
    return float4(col * gTime.z, 1.0);
}
