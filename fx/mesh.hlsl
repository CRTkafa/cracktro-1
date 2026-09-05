// Meshes, pulled rather than fed.
//
// Nothing is bound to the input assembler - no vertex buffer, no index
// buffer, no input layout. The vertex shader reads straight out of two typed
// buffers laid over the `const short` arrays in cats_mesh.h, and the draw is
// Draw(NT*3, 0) with the index fetched here.
//
// That is not stylistic. Three things fall out of it:
//
//   There is no DXGI_FORMAT_R16G16B16_SINT, so an input layout would have to
//   pad the 6-byte vertices to 8 - about 19 KB on the run cat alone, in an
//   executable where the shader blobs are already the biggest thing.
//
//   A typed R16_SINT buffer has a 2-byte stride, so the baked arrays upload
//   verbatim. pSysMem points at the header array: no copy, no allocation,
//   nothing a C runtime would have to be present for.
//
//   Drawing non-indexed means the triangle id is just vid/3, so a per-triangle
//   flat colour needs no vertex duplication, and the barycentric is
//   float3(vid%3 == 0, 1, 2) - which is a wireframe-to-solid morph for free.
//
// The cost is one dependent load per vertex on a 790-triangle mesh.
//
// ---------------------------------------------------------------------------
// W H Y   T H E R E   I S   A   R I G   D O W N   T H E R E
//
// The 24 baked frames are the whole of the cat's motion, and the rate they
// play at is not free: actRate in the shot table is tuned so a stride covers
// about two body lengths of the from -> to travel, because anything else makes
// the feet skate. Run the numbers on bar 35 - 10.33 units of travel over 32
// rows at 0.63 frames a row - and the cat gets through FOUR FIFTHS of one
// stride in the entire shot. Bar 59 gets through half of one. That is the
// honest reason the cat reads as furniture: not that the animation is bad, but
// that at a skate-free rate there is barely any of it inside a two-bar shot.
//
// The rate cannot go up without the feet sliding. So everything below is
// SECONDARY motion - the parts of an animal that are not carrying its weight
// and are therefore free to move as fast as they like. A tail that lashes, a
// head that turns, ears that flick, a spine that flexes, a ribcage that
// breathes, and a body that sinks into its knees when the kick lands. The legs
// are deliberately left alone: they are doing the one job the baked frames
// already do well, and anything added to a planted paw is a skate.
//
// The rig weights are plain thresholds in the mesh's own baked integer space,
// which is why fetchVert no longer applies gAnim.z - the quantiser scale is
// applied once, at the end, and until then a number in this file can be read
// straight against cats_mesh.h. Measured off the array: the cat faces +X, the
// animation is entirely in XY (z is constant per vertex to within a unit or
// two, which is what a sagittal run cycle looks like), the tail runs from
// x=-9800 out to x=-15200, the paws bottom out around y=-6400, and the head is
// everything past x=+6600.
//
// THE THRESHOLDS CANNOT BE TAKEN OFF THE ANIMATED POSE. A paw swings 8500
// units of x during a stride - a front paw reaches x=+8800, which is deeper
// into head territory than the head is, and a rear paw reaches x=-11600, which
// is halfway down the tail. Segment on that and the rig grabs a foot. So the
// weights are read off `rf`: the midpoint of the current frame and the one
// half a cycle away. A pair of legs is in antiphase, so the midpoint very
// nearly cancels the swing - it drops the worst per-vertex x wander over the
// cycle from 15387 units to 3169, and the median from 2643 to 599 - and what
// is left is a bind pose in all but name. Three extra loads, and after it the
// paws never once cross a threshold: they stay inside x = [-9740, +6515] while
// the tail sits below -9770 and the head above +6680.
//
// Four appearances, all ACT_CAT_RUN in the corridor, and gTune.z happens to
// track the energy of each one exactly: 0.20 at bar 59 (the sparse solo
// entry, the slowest gait in the demo), 0.30 at bar 35, 0.50 at bar 43, 0.60
// at bar 77 (the tension phase, the fastest). So gTune.z is read here as
// AGITATION and it drives every amplitude in the rig. The bar 59 cat prowls;
// the bar 77 cat is coming apart. That is one animal with four moods rather
// than the same silhouette pasted in four times.
// ---------------------------------------------------------------------------

cbuffer Scene : register(b0)
{
    float4 gTime;   // x time, y beat, z shot fade, w aspect
    float4 gCam;    // xyz eye, w tan(vfov/2)
    float4 gDir;    // xyz look direction, w roll
    float4 gTune;
    float4 gSync;   // x low, y mid, z high, w master peak
    float4 gVoice;  // x guitar, y solo, z organ, w hat
};

cbuffer Mesh : register(b1)
{
    float4 gModel;  // xyz world position, w uniform scale
    float4 gAnim;   // x fractional frame, y frame count (1 = rigid), z quant scale, w yaw
    float4 gMisc;   // x vertices per frame, y wireframe 0..1, z shatter, w tint
};

Buffer<int>  gPos : register(t0);
Buffer<uint> gIdx : register(t1);

struct VSOut
{
    float4 pos  : SV_Position;
    float3 wp   : TEXCOORD0;   // world position, for the face normal
    float3 bary : TEXCOORD1;
    float  vz   : TEXCOORD2;   // view depth, for the fog
};

// Raw baked units. gAnim.z is deliberately NOT applied here - see above.
float3 fetchVert(uint vtx, uint frame)
{
    uint o = (frame * (uint)gMisc.x + vtx) * 3u;
    return float3(gPos.Load((int)o), gPos.Load((int)(o + 1u)),
                  gPos.Load((int)(o + 2u)));
}

VSOut main(uint vid : SV_VertexID)
{
    VSOut o;
    uint  vtx = gIdx.Load((int)vid);

    // The baked run cycle is 24 frames of plain vertex positions, and the
    // frame index is FRACTIONAL because it comes from the song's row clock
    // rather than a wall clock - the old demo stepped them against wall-clock
    // time and the cat never once landed on the beat.
    //
    // It used to lerp two frames. At the skate-free rate the cat is only
    // getting about 5.6 frames a second, so a straight line between them holds
    // each limb at a constant velocity for 180 ms and then turns a corner, and
    // the corner is visible - the legs tick. Catmull-Rom over four frames
    // costs six more loads on a 396-vertex mesh and makes the velocity
    // continuous, which is the difference between a flipbook and an arc. The
    // cycle loops, so the neighbours wrap; at frac == 0 it returns frame f1
    // exactly, which is what ACT_CAT_STILL depends on.
    uint  nf = max((uint)gAnim.y, 1u);
    float3 p;
    if (nf == 1u)
    {
        // Static props have their own proportions: no cat rig or interpolation.
        p = fetchVert(vtx, 0u) * gAnim.z;
    }
    else
    {
    uint  f1 = (uint)gAnim.x % nf;
    uint  f0 = (f1 + nf - 1u) % nf;
    uint  f2 = (f1 + 1u) % nf;
    uint  f3 = (f1 + 2u) % nf;
    float t  = frac(gAnim.x);

    float3 P0 = fetchVert(vtx, f0), P1 = fetchVert(vtx, f1);
    float3 P2 = fetchVert(vtx, f2), P3 = fetchVert(vtx, f3);
    float3 g  = 0.5 * (2.0 * P1
              + (P2 - P0) * t
              + (2.0 * P0 - 5.0 * P1 + 4.0 * P2 - P3) * t * t
              + (3.0 * (P1 - P2) + P3 - P0) * t * t * t);

    // The stand-in bind pose: this frame averaged with its opposite. Nothing
    // below reads a threshold off `g`, only off `rf`. nf>>1 is 0 for a
    // single-frame mesh, which degenerates to the frame itself, correctly.
    float3 rf = 0.5 * (P1 + fetchVert(vtx, (f1 + (nf >> 1)) % nf));

    // ---- the rig -------------------------------------------------------
    // ag  agitation, the one number that separates the four appearances
    // sd  a phase seed, so two cats never start a sway on the same beat
    // st  seconds into THIS shot, for the drifts that must not be periodic
    // gp  gait phase, 2*pi per stride, off the row clock and so beat-locked
    // dr  whichever of the two loud voices is actually playing
    float ag = saturate(gTune.z * 1.6);
    float sd = gTune.x * 31.0 + gTune.y * 17.0 + gTune.z * 57.0;
    float st = gTime.x;
    float gp = 6.2831853 * gAnim.x / (float)nf;
    float dr = gVoice.x * 0.45 + gVoice.y * 0.55;

    // The three weights the whole rig is built out of, all in bind space.
    //   tail  past the root of it, and thin with it - a tail stays inside
    //         |z| = 788 where a hind leg reaches 1578, so the second gate
    //         holds even where the first one is tight
    //   head  starts at 6550, which is 35 units clear of the furthest a paw
    //         ever reaches, so the head rotation can never catch a foot
    //   torso how far above the feet: 0 at every paw (they top out at -1510),
    //         1 through the spine. This is what keeps the legs out of the
    //         weave and turns the body's sink into knee compression.
    float tail = (1.0 - smoothstep(-14800.0, -9755.0, rf.x))
               * (1.0 - smoothstep(900.0, 1400.0, abs(rf.z)));
    float head = smoothstep(6550.0, 9200.0, rf.x);
    float torso = smoothstep(-1400.0, 900.0, rf.y);

    float3 d = float3(0.0, 0.0, 0.0);

    // TAIL. A travelling wave with the phase lagging further the further out
    // along it you go, which is what makes a tail read as a whip rather than a
    // rod, and the lag itself opens up with agitation. Amplitude is
    // base + k*voice, never base*voice: a silent bar still has a moving tail.
    float lag = tail * (2.2 + 1.7 * ag);
    float tp  = gp * 2.0 + sd - lag;
    float ta  = 320.0 + 820.0 * ag + 420.0 * dr;
    d.z += tail * ta * sin(tp);
    d.y += tail * ta * 0.40 * sin(tp * 0.5 + 1.1);
    d.y += tail * (200.0 + 450.0 * ag) * sin(st * 0.55 + sd);

    // SPINE. A lateral S about one wavelength along the body, plus an arch
    // that peaks between the two leg pairs at x = -1750 - the mid-back is the
    // part of a running cat that actually bends.
    d.z += torso * (110.0 + 320.0 * ag) * sin(rf.x * 0.00022 + gp * 2.0 + sd);
    float mid = 1.0 - saturate(abs(rf.x + 1750.0) / 9000.0);
    d.y += torso * mid * (150.0 + 470.0 * ag) * sin(gp * 2.0 + 0.7);

    // The kick lands in the knees. The body sinks and the paws do not, because
    // `torso` is zero down there, so the legs compress instead of the cat
    // teleporting. base + k*s, so muting the drums leaves a deliberate stance.
    d.y -= torso * (0.35 + 0.65 * ag) * (90.0 + 520.0 * gSync.x);

    // BREATHING. Ribcage only - not the head, not the tail, not the legs. It
    // is small on purpose: this is the thing that stops a held frame from
    // being a still, and it should reward a second look rather than announce
    // itself. Proportional to the vertex's own offset, so it is a scale.
    float rib = torso * (1.0 - head) * (1.0 - tail)
              * saturate(1.0 - abs(rf.x + 1000.0) / 8000.0);
    float br  = sin(st * 1.7 + sd * 0.3);
    d.z += rib * g.z * (0.030 + 0.045 * gVoice.z) * br;
    d.y += rib * g.y * (0.020 + 0.030 * gVoice.z) * br;

    // HEAD. Yawed and pitched about the base of the neck, on two slow
    // incommensurable periods so it never repeats inside a shot, and lifted by
    // the guitar. The rotation is applied to the live pose but blended in by a
    // bind-space weight, so the shoulders carry the shear and nothing else in
    // the mesh can wander into it.
    float hyaw = (0.05 + 0.15 * ag) * sin(st * 0.83 + sd)
               + 0.04 * sin(st * 2.70 + sd * 1.7);
    float hpit = (0.04 + 0.10 * ag) * sin(st * 0.61 + sd * 0.5)
               + 0.07 * gVoice.x;
    float3 hv  = g - float3(6550.0, 500.0, 0.0);
    float  cy  = cos(hyaw), sy = sin(hyaw);
    float3 hr  = float3(hv.x * cy - hv.z * sy, hv.y, hv.x * sy + hv.z * cy);
    float  cp  = cos(hpit), sp = sin(hpit);
    hr = float3(hr.x * cp - hr.y * sp, hr.x * sp + hr.y * cp, hr.z);
    d += (hr - hv) * head;

    // EARS. The top of the head only, each one on its own phase, flicking on
    // the hat. Tiny in world units - the ears are tiny - but they are the
    // outermost points of the silhouette and the rim light finds them.
    float ear  = head * smoothstep(1900.0, 3100.0, rf.y);
    float side = rf.z >= 0.0 ? 1.0 : -1.0;
    float fk   = sin(gp * 6.0 + sd + side * 1.9);
    d.z += ear * side * (60.0 + 400.0 * gVoice.w) * fk;
    d.y -= ear * (30.0 + 180.0 * gVoice.w) * (0.5 + 0.5 * fk);

    // WEAVE. The whole body yaws a few degrees as it runs, pinned at the
    // paws again, so head and tail swing opposite ways. This is the one that
    // makes it look like it has mass.
    float wv = (0.015 + 0.045 * ag) * sin(gp + sd * 0.7)
             + 0.020 * sin(st * 0.47 + sd);
    float cw = cos(wv), sw = sin(wv);
    d += (float3(g.x * cw - g.z * sw, g.y, g.x * sw + g.z * cw) - g) * torso;

    // Out of the baked integer space, once.
    p = (g + d) * gAnim.z;
    }

    // Shatter: push each triangle out along its own pseudo-random axis. The
    // seed is the triangle id, so a face stays whole while it flies.
    if (nf > 1u && gMisc.z > 0.001)
    {
        uint  tri = vid / 3u;
        float s   = frac(sin(float(tri) * 12.9898) * 43758.5453);
        float s2  = frac(sin(float(tri) * 78.2330) * 24634.6345);
        float s3  = frac(sin(float(tri) * 39.4260) * 13875.9284);
        p += (float3(s, s2, s3) - 0.5) * gMisc.z * gMisc.z * 14.0;
    }

    float ca = cos(gAnim.w), sa = sin(gAnim.w);
    p = float3(p.x * ca - p.z * sa, p.y, p.x * sa + p.z * ca);
    float3 wp = p * gModel.w + gModel.xyz;

    // The camera basis, built the same way every scene shader builds it, so
    // a mesh and the distance field behind it agree about where things are.
    float3 fw = normalize(gDir.xyz);
    float3 rt = normalize(cross(float3(0.0, 1.0, 0.0), fw));
    float3 up = cross(fw, rt);
    float  cr = cos(gDir.w), sr = sin(gDir.w);
    float3 r2 = rt * cr + up * sr;
    float3 u2 = up * cr - rt * sr;

    float3 dv = wp - gCam.xyz;
    float  z  = dot(dv, fw);

    // Clip space by hand. The scene shaders cast normalize(fw + (uv.x*r2 +
    // uv.y*u2) * gCam.w), so a point lands at uv = (x, y) / (z * gCam.w) -
    // and w = z with 0.05 in the z slot reproduces the SDF passes' own
    // saturate(0.05 / vz), which is what puts them on the same depth scale.
    // Keep signed w: hardware clips at z = 0.05 and rejects geometry behind
    // the eye instead of projecting it onto a tiny positive denominator.
    o.pos  = float4(dot(dv, r2) / (gCam.w * gTime.w),
                    dot(dv, u2) / gCam.w,
                    0.05, z);
    o.wp   = wp;
    o.vz   = z;
    uint c = vid % 3u;
    o.bary = float3(c == 0u ? 1.0 : 0.0, c == 1u ? 1.0 : 0.0, c == 2u ? 1.0 : 0.0);
    return o;
}
