// The CRT pass. Takes the low resolution scene target and puts it on a tube.
//
// The one thing that matters here and is easy to get wrong: this pass works
// in TWO coordinate spaces at once.
//
//   virtual space  - the low resolution grid the scene was drawn on
//                    (gRes.xy, a fixed 360 lines). Scanlines and the ordered
//                    dither live here, so a scanline is always one virtual
//                    row and the dither is always one virtual pixel. That is
//                    what keeps the look identical from 1366x768 to
//                    5120x1440 instead of turning into fine grey noise on a
//                    big display.
//
//   output space   - real backbuffer pixels (SV_Position). The shadow mask
//                    and the rim of the glass live here, because an aperture
//                    grille is a property of the tube, not of the signal.
//
// Mixing the two up is why most CRT shaders look wrong at some resolution.

cbuffer Post : register(b0)
{
    float4 gRes;    // xy virtual size, zw output size
    float4 gCrt;    // x scanline depth, y mask depth, z aberration, w vignette
    float4 gGrade;  // x dither, y exposure, z dissolve mix, w fade to black
    float4 gFx;     // x flash, y whip smear, z bloom level, w letterbox
    float4 gRamp[4];// the quantiser's four stops. this is the palette.
    float4 gTone;   // x hue kept, y quantiser steps, zw unused
};

Texture2D    gScene : register(t0);
Texture2D    gPrev  : register(t1);   // the outgoing shot, during a dissolve
Texture2D    gBloom : register(t2);   // half res, already blurred
SamplerState gPoint : register(s0);
SamplerState gLinear: register(s1);

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

// 4x4 ordered Bayer, the Marathon look. Values 0..15.
static const float kBayer[16] = {
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0
};

// A narrow cold ramp. Quantising into this rather than into plain grey is
// what makes the dither read as an old shaded renderer instead of noise.
float3 rampColour(float v)
{
    // The four stops come from the section's grade rather than from literals.
    // Changing them changes what the picture is MADE OF - every pixel passes
    // through here - which is a categorically stronger thing than tinting
    // the output. Interpolated in C across a dissolve, so two sections in
    // different palettes cross-fade as grades and not as a colour switch.
    float3 a = gRamp[0].rgb;
    float3 b = gRamp[1].rgb;
    float3 c = gRamp[2].rgb;
    float3 d = gRamp[3].rgb;
    float3 lo = lerp(a, b, saturate(v * 3.0));
    float3 md = lerp(b, c, saturate(v * 3.0 - 1.0));
    float3 hi = lerp(c, d, saturate(v * 3.0 - 2.0));
    return v < 0.3333 ? lo : (v < 0.6666 ? md : hi);
}

float4 main(VSOut i) : SV_Target
{
    float2 uv = i.uv;

    // Gentle barrel distortion. Enough to feel like glass, not enough to
    // make anyone think about it.
    float2 cc = uv * 2.0 - 1.0;
    float  r2 = dot(cc, cc);
    uv = (cc * (1.0 + 0.028 * r2)) * 0.5 + 0.5;

    // THE RIM OF THE TUBE, feathered over one OUTPUT pixel instead of being a
    // hard in/out test. The barrel maps a straight screen edge to a shallow
    // curve, and a binary test on a shallow curve is a staircase with steps
    // tens of pixels long - which then crawls, one step at a time, whenever
    // anything behind it moves. Measured in output pixels rather than virtual
    // ones so the feather stays one pixel wide at every resolution instead of
    // becoming a three pixel smear at 1080.
    float2 inPx = min(uv, 1.0 - uv) * gRes.zw;
    float  rim  = saturate(min(inPx.x, inPx.y) + 0.5);
    if (rim <= 0.0)
        return float4(0.0, 0.0, 0.0, 1.0);

    // Chromatic aberration, growing towards the edge of the tube.
    float2 ab = cc * gCrt.z * (0.4 + 0.6 * r2) / gRes.xy;
    float3 col;
    col.r = gScene.Sample(gPoint, uv + ab).r;
    col.g = gScene.Sample(gPoint, uv).g;
    col.b = gScene.Sample(gPoint, uv - ab).b;

    // A whip-in is a lateral smear that settles. It is what lets a fast pan
    // hand off into the next shot instead of just stopping dead.
    if (gFx.y > 0.002) {
        float3 sm = float3(0.0, 0.0, 0.0);
        [unroll] for (int k = 1; k <= 6; k++) {
            float2 o = float2(gFx.y * 0.085 * float(k), 0.0);
            sm += gScene.Sample(gLinear, saturate(uv - o)).rgb;
        }
        col = lerp(col, sm / 6.0, saturate(gFx.y));
    }

    // A dissolve wants the two shots mixed BEFORE the tube, so the dither
    // and the scanlines belong to the composite rather than to each half.
    if (gGrade.z > 0.002)
        col = lerp(col, gPrev.Sample(gPoint, uv).rgb, saturate(gGrade.z));

    // BLOOM, added before the quantiser rather than after it. That order is
    // the whole reason it works here: added afterwards it would sit on top of
    // the dither as a smooth gradient and the two would visibly disagree
    // about what resolution the picture is. Added first, the glow is
    // dithered along with everything else and belongs to the same image.
    col += gBloom.Sample(gLinear, uv).rgb * gFx.z;

    col *= gGrade.y;                                  // exposure

    // --- virtual space: dither -------------------------------------------
    // Quantise the luminance through the ordered matrix, then re-colour
    // through the ramp and keep the original hue on top of it.
    //
    // THE WIDTH OF THE DITHER IS THE ENTIRE ARGUMENT IN THIS BLOCK, and it
    // is measured, not tasted. An ordered dither spends NEIGHBOURING pixels
    // to buy a value that lies between two quantiser levels, so it has to
    // span the gap between two adjacent levels - one step - and the moment
    // it spans more than that it stops carrying information and starts
    // adding noise to a picture that is already quantised.
    //
    // As shipped, the Bayer threshold spans +-0.469 and was multiplied by
    // gGrade.x = 0.85 against steps of 1/10. That is EIGHT levels wide.
    // Two consequences, both of them visible in every single shot:
    //
    //   - at the ends of the range the noise is rectified, because saturate()
    //     throws away the half of the swing that would have gone below black
    //     and keeps the half that goes above it. A scene value of exact black
    //     came off the tube as a 16 cell speckle reaching level 4 of 10;
    //     empty sky measured 4% mean with 20% peaks in a picture whose black
    //     stop is 3%. White was crushed the same way from the other side.
    //
    //   - in the midtones a flat 50% grey became a mosaic running from near
    //     black to near white. Local contrast from the dither was five times
    //     the local contrast of anything the scene had drawn, so every shot
    //     converged on the same grey field and any two of them measured
    //     alike no matter what was in front of the camera.
    //
    // So the width is expressed in QUANTISER STEPS now, and bounded:
    //
    //   one step at either end of the range. That is the mean preserving
    //   minimum, and it is the widest dither that provably cannot lift black
    //   or dirty white: the largest Bayer offset is 0.469 of a step, which
    //   never rounds up to the next level on its own. Black stays exactly on
    //   stop 0, white stays exactly on stop 3, and the dark gradients still
    //   dither rather than band.
    //
    //   about two and a bit steps through the midtones, where a wider dither
    //   IS the texture the look is made of - scaled by the grade's own
    //   dither knob, so bleach (7 steps, dither 1.00) still speckles far
    //   harder than warm (11 steps, 0.82), which is what those numbers were
    //   chosen for.
    //
    // The taper between the two is the shape term, and it is smooth, so a
    // gradient running down into black narrows its own dither on the way.
    float2 vp  = floor(uv * gRes.xy);
    int    bi  = int(fmod(vp.y, 4.0)) * 4 + int(fmod(vp.x, 4.0));
    float  thr = (kBayer[bi] + 0.5) / 16.0 - 0.5;   // +-0.469, evenly spaced

    float lum   = dot(col, float3(0.299, 0.587, 0.114));
    float steps = max(gTone.y, 1.0);

    float shape = smoothstep(0.0, 0.15, lum) * smoothstep(0.0, 0.12, 1.0 - lum);
    float width = (1.0 + 1.30 * gGrade.x * shape) / steps;

    float q = floor(saturate(lum + thr * width) * steps + 0.5) / steps;

    float3 dithered = rampColour(q);
    // The hue divide gets a floor of one 8-bit code rather than 1e-4. The
    // scene target is 16 bit float, so it is full of values below that, and
    // a 1/lum with a 1e-4 floor makes the difference between a pixel at zero
    // and a pixel at one ten-thousandth a factor of 2.6 in the output. That
    // was hidden under the old speckle. With black actually black it would
    // read as an edge between two shades of nothing.
    float3 hue = col / max(lum, 1.0 / 255.0);
    col = lerp(dithered, dithered * hue, gTone.x);

    // --- virtual space: scanlines ----------------------------------------
    float sl = sin(uv.y * gRes.y * 3.14159265);
    col *= 1.0 - gCrt.x * sl * sl;

    // --- output space: aperture grille -----------------------------------
    // Three-phosphor stripe on real pixels. On a small window this is almost
    // invisible, which is correct: so is a real shadow mask.
    float phase = fmod(i.pos.x, 3.0);
    float3 mask = float3(phase < 1.0 ? 1.0 : 0.72,
                         (phase >= 1.0 && phase < 2.0) ? 1.0 : 0.72,
                         phase >= 2.0 ? 1.0 : 0.72);
    col *= lerp(float3(1.0, 1.0, 1.0), mask, gCrt.y);

    // Vignette, then the shot fade, then the flash. The flash is added last
    // and deliberately after the dither: a cut should blow the quantiser
    // out, not be quantised along with everything else. The vignette is
    // clamped because 0.26 * r2 * r2 passes 1.0 in the extreme corners and a
    // negative multiplier there would subtract from the flash instead of
    // being masked by it.
    col *= saturate(1.0 - gCrt.w * r2 * r2);
    col *= gGrade.w;
    col += gFx.x * float3(1.00, 0.97, 0.92);

    // THE MATTE, last, and in the distorted uv rather than in output space:
    // the bars are part of the signal, so they bow with the glass like
    // everything else on the tube. A straight bar over a curved picture is
    // the tell that the letterbox was pasted on afterwards.
    //
    // Softened over one virtual line, because the edge is a curve crossing a
    // pixel grid and a hard threshold on it crawls.
    if (gFx.w > 0.0005)
        col *= smoothstep(0.0, 1.0 / gRes.y,
                          (0.5 - gFx.w) - abs(uv.y - 0.5));

    // The rim goes on after the flash, so a cut blows out the picture and
    // not the frame around it.
    col *= rim;

    return float4(col, 1.0);
}
