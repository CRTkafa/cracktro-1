// The pixel half of the mesh path.
//
// No baked normals are read. The face normal comes from the screen-space
// derivatives of the world position, which is exact for a flat triangle and
// costs two instructions - and it means the 900-odd bytes of baked normals in
// the mesh headers never have to be uploaded at all.
//
// The lighting deliberately matches what the distance-field scenes do: one
// warm key, a cool fill from above, and the same exponential fog. A mesh that
// is lit by different rules than the space it is standing in reads as a
// sticker on the frame, however good it looks on its own.
//
// ---------------------------------------------------------------------------
// W H Y   T H I S   F I L E   S H A D E S   I N   B O D Y   S P A C E
//
// Every appearance of the cat is a broadside pass across a corridor. Yaw is 0
// in all four shots, the mesh's long axis is world X, and the camera sits near
// the middle of the corridor looking down Z - so what reaches the screen is
// the animal's FLANK, nearly face on. A flat-shaded flank is one continuous
// surface whose face normal barely moves across it, so ANYTHING BUILT OUT OF N
// IS VERY NEARLY A CONSTANT over the two thousand-odd pixels that matter. That
// is the exact mechanism by which a cat becomes a black lozenge with a green
// edge on it, and no amount of relighting fixes it.
//
// It is also physically true rather than a rendering accident: the only lights
// in a corridor are the ceiling tubes and the two side walls, and all three
// are edge-on to a vertical flank. A real cat crossing a real corridor really
// is nearly unlit on the side we can see. So the form cannot be lit into
// existence - it has to be DRAWN, out of where a point sits in the animal.
//
// Which meant measuring the animal. The 24 baked frames were dumped and
// rasterised offline; the cycle turned out to be in place (mean X moves 0.118
// over the whole cycle), so a body-space constant stays put on the body. The
// landmarks below are the same ones the rig in mesh.hlsl weights against -
// same numbers, converted out of baked integer space - so the two halves of
// the mesh path cannot drift apart about where the cat's parts are:
//
//        x  -0.96 ....................................... +0.77   (mesh units)
//           |<-- tail, -0.89 to -0.56 -->|
//                     haunch -0.44   waist -0.12   shoulder +0.30
//                                            head, +0.39 to +0.59 and beyond
//        y  -0.41 paws/floor ... 0 spine ... +0.24 ear roots ... +0.33 arch
//        z  +-0.15 flanks
//
// P E R   A P P E A R A N C E. The cat runs four times, always inside
// SC_CORRIDOR, so gTune is the corridor's own knob set and the honest thing is
// to obey it rather than invent a second, disagreeing one:
//
//   gTune.x  corridor width  -> how much the two side walls bounce back on it
//   gTune.y  ceiling height  -> how high the fitting that lights it hangs
//   gTune.z  bend            -> the coat: band count, contrast, edge width
//
// gTune.z is 0.30 / 0.50 / 0.20 / 0.60 across the four, which is the widest
// spread on offer, and mesh.hlsl already reads it as the animal's AGITATION.
// This file reads the same axis as how GRAPHIC the animal is: four wide soft
// bands and a thin hard edge at the calm end, ten fine bands and a fat edge at
// the frantic one. One quantity, two halves of the same idea, so the bar 59
// cat prowls and looks plain and the bar 77 cat is coming apart and looks it.
//
// Legibility is NOT keyed off gModel.w. It is keyed off fwidth of the body
// coordinate - how many mesh units one pixel is worth on this draw - so a cat
// that is small because it is far away reads the same as one that is small
// because it was scaled down, and neither can be got wrong by the shot table.
//
// Measured against the shader this replaces, on the bar 35 pass at 1080p:
// mean level 0.172 -> 0.182 (the exposure is meant to be unchanged), but the
// standard deviation across the animal 0.087 -> 0.118, and the mean pairwise
// gap between the four appearances 17.97 -> 21.90. Wider tonal range on one
// cat, and four cats that no longer look like the same picture.
// ---------------------------------------------------------------------------

cbuffer Scene : register(b0)
{
    float4 gTime;
    float4 gCam;
    float4 gDir;
    float4 gTune;
    float4 gSync;
    float4 gVoice;
};

cbuffer Mesh : register(b1)
{
    float4 gModel;
    float4 gAnim;
    float4 gMisc;   // x verts/frame, y wireframe 0..1, z shatter, w tint
};

struct VSOut
{
    float4 pos  : SV_Position;
    float3 wp   : TEXCOORD0;
    float3 bary : TEXCOORD1;
    float  vz   : TEXCOORD2;
};

// Original per-triangle RGB, expanded to RGBA8_UNORM once at upload.
// Only single-frame models use this resource; the run cat keeps its coat.
Buffer<float4> gFaceColor : register(t2);

// One fitting every four metres, the same spacing corridor.hlsl uses. The two
// files have to agree about this or the cat lights up in the dark half of a
// bay and stops belonging to the room it is running through.
#define FIX_PERIOD 4.0

float bump(float x, float c, float k) { float d = (x - c) * k; return exp(-d * d); }

float4 main(VSOut i, uint tri : SV_PrimitiveID) : SV_Target
{
    float3 n = normalize(cross(ddx(i.wp), ddy(i.wp)));

    // Face the light rather than the camera: a flat-shaded mesh whose normals
    // point away just goes black, and a demo prop is never seen from behind.
    float3 vdir = normalize(gCam.xyz - i.wp);
    if (dot(n, vdir) < 0.0) n = -n;

    if (gAnim.y == 1.0)
    {
        float3 base = gFaceColor.Load((int)tri).rgb;
        float key = saturate(dot(n, normalize(float3(-0.35, 0.80, -0.45))));
        float fill = saturate(dot(n, normalize(float3(0.65, 0.30, 0.55))));
        // Neutral light preserves the blue paint, pale windows and dark trim.
        // Ambient keeps a distant face readable even when the key is behind it.
        float3 col = base * (0.60 + 0.55 * key + 0.15 * fill);
        float fog = exp(-max(i.vz, 0.0) * 0.0075);
        col = col * fog + float3(0.055, 0.050, 0.062) * (1.0 - fog);
        return float4(col * gTime.z, 1.0);
    }

    // ---- body space ------------------------------------------------------
    // Undo the vertex shader exactly: translate, uniform scale, yaw. The yaw
    // is 0 in every shot the cat appears in, but doing it properly costs one
    // sine pair on two thousand pixels and means none of the landmarks below
    // can come adrift if the C side ever turns the animal.
    float  iw = 1.0 / max(gModel.w, 1e-4);
    float3 rp = (i.wp - gModel.xyz) * iw;
    float  cy = cos(gAnim.w), sy = sin(gAnim.w);
    float3 op = float3(rp.x * cy + rp.z * sy, rp.y, rp.z * cy - rp.x * sy);
    float3 on = float3( n.x * cy +  n.z * sy,  n.y,  n.z * cy -  n.x * sy);

    // One pixel, measured in mesh units. Every fine feature below is floored
    // at this, so nothing crawls on the near cat or vanishes on the far one.
    float pw = max(max(fwidth(op.x), fwidth(op.y)), fwidth(op.z));

    // The same three weights the rig in mesh.hlsl deforms by, so the shading
    // and the animation agree about which end of the cat is which.
    float head = smoothstep( 0.3875, 0.5875, op.x);   // 0 shoulders .. 1 head
    float tail = 1.0 - smoothstep(-0.89, -0.56, op.x);// 0 hip .. 1 tail tip
    float hgt  = saturate((op.y + 0.41) * 1.35);      // 0 paws .. 1 crown

    // ---- the light the corridor actually has -----------------------------
    float  ceilH = lerp(2.30, 4.60, saturate(gTune.y));
    float  cn    = floor(i.wp.z / FIX_PERIOD + 0.5);
    float  cz    = cn * FIX_PERIOD;
    float  dz    = max(abs(i.wp.z - cz) - 0.60, 0.0);   // metres to the tube
    float3 lp    = float3(0.0, ceilH - 0.07,
                          clamp(i.wp.z, cz - 0.60, cz + 0.60));
    float3 ld    = normalize(lp - i.wp);

    // Two metres is the darkest a bay gets, and a quarter is as far as the
    // level is allowed to move: base + k*s and never base*s, so the animal
    // dims between fittings instead of blinking out.
    float bay = 1.0 - 0.24 * saturate(dz * dz * 0.52);

    // The demo's standing key, tilted toward whichever fitting is currently
    // overhead. The tilt is most of the animation of a held shot: as the cat
    // crosses a bay the highlight walks along it and the head turns into and
    // out of the light, so two bars on one camera stop being a still.
    float3 kd  = normalize(lerp(normalize(float3(-0.35, 0.80, -0.45)), ld, 0.24));
    float  dif = saturate(dot(n, kd));

    // Both walls, not the nearer one: picking the nearer one puts a seam down
    // the middle of the corridor that the cat pops across at x = 0. A narrow
    // corridor throws a great deal back onto the flanks, a wide one almost
    // nothing, which is one more thing that separates the four passes.
    float  hw  = lerp(1.15, 3.80, saturate(gTune.x));
    float3 wl  = float3(-hw, 1.10, i.wp.z) - i.wp;
    float3 wr  = float3( hw, 1.10, i.wp.z) - i.wp;
    float  wl2 = max(dot(wl, wl), 0.30), wr2 = max(dot(wr, wr), 0.30);
    // Capped, not for the corridor - the widest it gets there is 0.83 - but
    // for the mesh-dump path in gfx.c, which draws the cat at the origin with
    // gTune all zeroes and would otherwise stand it inside both walls at once.
    float  bnc = min(saturate(dot(n, wl * rsqrt(wl2))) * (2.4 / (1.4 + wl2))
                   + saturate(dot(n, wr * rsqrt(wr2))) * (2.4 / (1.4 + wr2)), 1.0);

    // ---- the shape, drawn rather than lit --------------------------------
    // Three masses and the gaps between them, on the landmarks measured off
    // the mesh: the shoulder over the front legs, the haunch over the rear
    // ones, the waist that makes those two read as two, and the head - so the
    // front of the animal is brighter than the back and the silhouette has a
    // direction even when it is sixty pixels long.
    float mass = 1.0
               + 0.28 * bump(op.x,  0.30, 4.0)    // shoulder, over the forelegs
               + 0.24 * bump(op.x, -0.44, 3.6)    // haunch, over the hind legs
               + 0.20 * bump(op.x,  0.60, 5.0)    // head
               - 0.17 * bump(op.x, -0.12, 5.2);   // the tuck between them

    // Back lit, belly not. On a flank that shares one normal this ramp is the
    // whole difference between a cat and a stain.
    float form = (0.55 + 0.85 * pow(max(hgt, 1e-4), 0.70))
               * mass * (1.0 - 0.22 * tail);

    // ...but only where the normal is not already doing the job. An up-facing
    // back under an overhead tube is genuinely lit and does not want drawing
    // on top of; the flank is not lit at all and is nothing else. Without this
    // line the two cues stack and the spine blows out to a white stripe.
    form = lerp(1.0, form, 1.0 - 0.72 * dif);

    // Tabby banding, across the body the way a real one runs. Resolved rather
    // than faded by hand: the amplitude dies the moment a band is thinner than
    // a pixel, so the far cat is plain instead of a field of crawling noise.
    float bands = lerp(4.5, 10.5, saturate(gTune.z));
    float ph    = (op.x + 0.96) * bands + op.y * 1.25;
    float coat  = sin(ph * 6.2831853) * saturate(1.0 - fwidth(ph) * 1.8)
                * (0.55 + 0.45 * saturate(gTune.z)) * (1.0 + 0.30 * gSync.z);

    // The gait, off the same fractional frame the vertex shader poses with, so
    // the ripple down the coat lands on the footfalls and not on a wall clock.
    // Two waves a cycle, which is the two-beat lope.
    float ripp = sin(op.x * 3.2 - (gAnim.x / max(gAnim.y, 1.0)) * 12.566371);

    // ---- assemble --------------------------------------------------------
    // The cat is a silhouette with a rim on it. It is meant to be read as a
    // shape first and a creature second, so the body stays close to black and
    // the light lives on the edge.
    float3 body = lerp(float3(0.020, 0.024, 0.032),
                       float3(0.55, 0.72, 0.42), gMisc.w);

    float lum = (0.20 + 0.80 * dif + 0.16 * bnc) * form * bay * 1.12;
    lum *= 1.0 + 0.20 * coat;
    lum *= 1.0 + 0.09 * ripp;

    float3 col = body * lum;

    // The edge carries the shaping too: fat over the two masses, thin at the
    // waist, and pushed up at the two places a cat is recognised from - the
    // ears and the last hand's width of tail. A cat that lands small on screen
    // gets more of it, because sixty pixels of animal is all outline; one
    // pixel is worth about 0.005 mesh units on the near draw and 0.03 on the
    // far one, which is what the threshold below is set against.
    float small = saturate((pw - 0.008) * 50.0);
    float ears  = head * smoothstep(0.16, 0.244, op.y);
    float rim   = pow(1.0 - saturate(dot(n, vdir)),
                      lerp(4.4, 2.6, saturate(gTune.z)));
    float edge  = rim * (0.70 + 0.30 * mass)
                * (1.0 + 0.45 * ears + 0.45 * tail + 0.45 * small)
                * (1.0 + 0.20 * coat);

    col += float3(0.42, 0.86, 0.46) * edge * (0.35 + 0.65 * gMisc.w) * bay;
    col += float3(0.20, 0.26, 0.38) * saturate(n.y) * 0.15 * (0.60 + 0.40 * form);

    // Two catchlights, at the eyes, measured off the mesh. A black cat at
    // sixty pixels is read from its eyes before it is read from its outline,
    // and this demo has a scene that is nothing but a cat's eye, so a green
    // spark here is a callback and not a decoration. Two per cent of body
    // length is a real cat's eye; the pixel floor under that radius means the
    // spark neither crawls on the near draw nor disappears on the far one.
    // It is gated by the same `head` weight the rig turns the head with, so it
    // can never strand itself on a shoulder, and it holds a base level so the
    // solo lifts it rather than switching it on.
    float3 ep  = float3(0.645, 0.070, 0.098);
    float  ed  = min(length(op - ep), length(op - float3(ep.x, ep.y, -ep.z)));
    float  er  = max(0.038, pw * 1.15);
    float  eye = exp(-(ed * ed) / (er * er)) * head
               * saturate(abs(on.z) * 1.5 + 0.20);
    col += float3(0.58, 1.00, 0.62) * eye
         * (0.55 + 0.40 * gVoice.y + 0.35 * gMisc.w);

    // Wireframe-to-solid, out of the barycentric the vertex shader got for
    // nothing. At gMisc.y = 1 only the edges survive.
    if (gMisc.y > 0.001)
    {
        float3 d   = fwidth(i.bary);
        float3 a   = smoothstep(float3(0,0,0), d * 1.5, i.bary);
        float  wf  = 1.0 - min(min(a.x, a.y), a.z);
        col = lerp(col, float3(0.55, 0.95, 0.60) * wf, gMisc.y);
    }

    float fog = exp(-max(i.vz, 0.0) * 0.0075);
    col = col * fog + float3(0.055, 0.050, 0.062) * (1.0 - fog);

    return float4(col * gTime.z, 1.0);
}
