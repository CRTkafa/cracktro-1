// Shot 01 - COLD OPEN: CAT EYE MACRO. And ten more after it.
//
// The demo opens on an eye that fills the frame, close enough that you read
// it as a landscape before you read it as an eye. No geometry: this is a
// two dimensional field, which is the point - not every shot has to be a
// space you fly through, and the cheapest shot in the demo is also the one
// that has to earn the first ten seconds.
//
// It is also the scene the edit leans on hardest: ELEVEN appearances, more
// than any other. That was fine as a plan and a disaster as a picture,
// because the first version of this file read gTune for a pupil width, a
// rotation and a glow, and drew the same photograph eleven times. Measured
// pairwise as luminance thumbnails the eleven shots sat 12.7 apart - the
// second most repetitive scene in the production.
//
// gTune.x  pupil width      (0 = a slit, 1 = fully round and blown)
// gTune.y  lid closure      (0 = open, 1 = shut) - arms the blink
// gTune.z  iris rotation
// gTune.w  glow strength
//
// Those four now carry a fifth thing nobody asked them for: an IDENTITY.
// The shot table hands eleven distinct (x, z, w) triples, so seven decorrelated
// hashes of them give every appearance a stable fingerprint, and the fingerprint
// decides the things a photographer decides - how tight the crop is, where the
// eye sits in frame, how far the lids are apart, what shape the eye is, how
// dense the veins are, and, most of all, WHAT THE CORNEA IS REFLECTING. The
// multipliers below are not decoration: they were solved so that across the
// eleven real triples every seed lands at least 0.056 from its nearest
// neighbour, against a theoretical best of 0.1, with a worst pairwise
// correlation of 0.02. That is what stops two appearances colliding.
//
// Nothing here is on a wall clock that outlives a shot. Every animation reads
// gTime.x, which restarts at each cut, so a four bar hold plays a saccade
// pattern, a dilation and a lid settle instead of being a still frame.

cbuffer Scene : register(b0)
{
    float4 gTime;   // x time, y beat, z shot fade, w aspect
    float4 gCam;    // xyz eye, w tan(vfov/2)
    float4 gDir;    // xyz look, w roll
    float4 gTune;
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

float hash12(float2 p)
{
    float3 q = frac(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return frac((q.x + q.y) * q.z);
}

float hash11(float n)
{
    n = frac(n * 0.1031);
    n *= n + 33.33;
    n *= n + n;
    return frac(n);
}

float noise2(float2 p)
{
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash12(i), hash12(i + float2(1, 0)), f.x),
                lerp(hash12(i + float2(0, 1)), hash12(i + float2(1, 1)), f.x), f.y);
}

// Value noise whose X axis is genuinely periodic, for anything wrapped around
// a circle.
//
// The version above is not, and the comment further down used to claim it was
// enough to use an integer number of cells around the turn. An integer count
// does make the INTERPOLATION parameter meet itself at the atan2 +-pi line -
// frac() lands on the same value from both sides - but hash12(i) and
// hash12(i + period) are unrelated numbers, so the VALUE still jumps.
//
// Measured before this existed, by reimplementing hash12 and noise2 exactly
// and evaluating across the seam: the iris fibre field jumped 0.18 to 0.20 of
// its 0..1 range across a single pixel boundary, against 0.004 to 0.008 for a
// typical neighbouring pixel. A 23x to 49x discontinuity - a hard radial tear
// running from the pupil to the limbus, in all ten appearances of the eye.
//
// The fix is to wrap the lattice INDEX too, so the cell after the last one is
// the first one again. period must be a whole number.
float noise2p(float2 p, float period)
{
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0 - 2.0 * f);

    float x0 = i.x - period * floor(i.x / period);
    x0 = (x0 >= period) ? 0.0 : x0;              // guard the rounding case
    float x1 = x0 + 1.0;
    x1 = (x1 >= period) ? 0.0 : x1;

    return lerp(lerp(hash12(float2(x0, i.y)),
                     hash12(float2(x1, i.y)), f.x),
                lerp(hash12(float2(x0, i.y + 1.0)),
                     hash12(float2(x1, i.y + 1.0)), f.x), f.y);
}

#define TAU  6.28318531
#define ITAU 0.15915494

float4 main(VSOut i) : SV_Target
{
    float2 p = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
    // y flipped: the fullscreen triangle puts uv.y = 0 at the TOP, so
    // without this the catch-light sat below centre and the lids
    // closed the wrong way round.
    p.x *= gTime.w;
    float t = gTime.x;

    // ---- which of the eleven is this? ------------------------------------
    float k0 = frac(gTune.w * 10.00 + gTune.x * 14.20 + gTune.z *  2.60 + 0.143);
    float k1 = frac(gTune.w *  9.50 + gTune.x *  7.10 + gTune.z *  2.80 + 0.083);
    float k2 = frac(gTune.w * 12.50 + gTune.x * 13.10 + gTune.z *  6.10 + 0.587);
    float k3 = frac(gTune.w * 13.60 + gTune.x *  9.40 + gTune.z * 12.20 + 0.959);
    // three more, folded out of the first four rather than out of gTune, so
    // they stay independent of the framing they decorate.
    float k4 = frac(k0 * 3.6 + k2 * 3.2 + 0.415);
    float k5 = frac(k1 * 5.6 + k3 * 1.4 + 0.258);
    float k6 = frac(k0 * 3.5 + k3 * 2.6 + 0.346);

    // ---- the crop --------------------------------------------------------
    // This is the single biggest lever in the file. At mag 0.74 the whole
    // eye sits in the frame with sclera and veins around it; at 1.52 we are
    // inside the iris and the limbus only clips the corners. Eleven shots
    // spread across that range stop being eleven of the same photograph.
    float mag  = 0.72 + 0.80 * k0;
    float2 ctr = float2((k1 - 0.5) * 0.42, (k2 - 0.5) * 0.30);

    // A slow drift, so the eye is alive without ever looking like it is
    // being animated at you. Rate and throw are per appearance now.
    ctr -= float2(sin(t * (0.19 + k4 * 0.17)) * (0.018 + k5 * 0.030),
                  cos(t * (0.13 + k5 * 0.16)) * (0.014 + k4 * 0.026));

    // ---- the gaze --------------------------------------------------------
    // A real eye never holds still: it darts and then sits. Step-and-hold,
    // fast on the way out and long on the hold, with the targets hashed off
    // this appearance's own seed so the pattern is reproducible per shot.
    // This is what makes a CAM_HOLD shot not a freeze frame.
    float sacR = 0.42 + k2 * 1.05;                 // darts per second
    float sacA = 0.015 + k3 * 0.085;               // and how far each one goes
    float sp   = t * sacR + k0 * 13.0;
    float si   = floor(sp);
    float sf   = smoothstep(0.0, 0.13, frac(sp));
    float sd   = k1 * 57.0;
    float2 gA  = float2(hash11(si * 2.13 + sd), hash11(si * 2.13 + sd + 19.7)) - 0.5;
    float2 gB  = float2(hash11(si * 2.13 + 2.13 + sd),
                        hash11(si * 2.13 + 2.13 + sd + 19.7)) - 0.5;
    float2 gaze = lerp(gA, gB, sf) * sacA;

    // Two frames, and the difference between them is the whole trick: the
    // eyeball (sclera, veins, lids, the reflected world) does not move when
    // the eye looks somewhere - only the iris and pupil do.
    float2 eb = (p - ctr) / mag;                   // eyeball
    float2 e  = eb - gaze;                         // iris
    float r   = length(e);
    float rb  = length(eb);
    float rs  = length(p - ctr);                   // screen, for glow and vignette

    // ---- iris ------------------------------------------------------------
    float irisEdge = 0.86;
    float spin = gTune.z + t * ((k3 - 0.45) * 0.16);
    float a01  = (atan2(e.y, e.x) + spin) * ITAU;  // turns, not radians

    // Radial fibres, two scales, so it holds up at this magnification. The
    // counts are INTEGERS in turns AND the noise is wrapped to them, which is
    // what actually closes the seam at the +-pi line - the integer count on
    // its own does not, see noise2p.
    float sect  = floor(7.0  + k4 * 13.0);         //  7..19 coarse spokes
    float fineN = floor(23.0 + k5 * 26.0);         // 23..48 fine ones
    float strc  = 3.6 + k6 * 5.4;                  // how far they smear radially
    float fib = noise2p(float2(a01 * sect,  r * strc),       sect)  * 0.62
              + noise2p(float2(a01 * fineN, r * strc * 2.3), fineN) * 0.38;

    // The collarette: the ruff where the iris changes character, and where
    // the crypts live. Its radius moves per appearance, which redraws the
    // whole interior structure rather than recolouring it.
    float colR = 0.30 + k6 * 0.30;
    float cb   = (r - colR) * 5.5;
    float band = exp(-cb * cb);
    float cryN = floor(5.0 + k5 * 9.0);
    float crypt = smoothstep(0.60, 0.88,
                     noise2p(float2(a01 * cryN, r * 3.0 + 11.0), cryN)) * band;

    float iris = smoothstep(irisEdge + 0.055, irisEdge - 0.02, r);

    // A cat pupil is a vertical slit that opens into an ellipse.
    // The pupil breathes with the low band. 0.045 is a ceiling, not a
    // starting point: it is 2.8% of the iris, and the band's 420 ms release
    // against a 454 ms beat means it is always still falling when the next
    // kick lands. It physically cannot pulse.
    // On top of that it now DILATES OR CONTRACTS across the shot - direction
    // from the seed - so the pupil is a movement and not a setting.
    float dilDir = (k2 < 0.5) ? -1.0 : 1.0;
    float dil = saturate(gTune.x + dilDir * (0.05 + 0.20 * gTune.x)
                                 * smoothstep(0.15, 2.40, t));
    float pw   = max(0.052 + dil * 0.62 + gSync.x * 0.045 + gVoice.y * 0.012, 0.020);
    float ph   = 0.62 + k4 * 0.22;                 // how tall the slit is
    float lean = (k1 - 0.5) * 0.22;                // and how far it leans
    float2 q = float2((e.x - e.y * lean) / pw, e.y / ph);
    // A perfect ellipse reads as vector art, so the rim borrows the iris
    // texture it is cut out of. Free: fib is already in hand.
    // Bounded by the iris mask: a tall slit on a wide seed would otherwise
    // run past the limbus and cut a hole in the sclera, which is an eye
    // with a slot milled through it.
    float pupil = smoothstep(1.04, 0.94, length(q) + (fib - 0.5) * 0.05) * iris;

    float hueK = k2 * 0.55;                        // green cat to amber cat
    float3 dark = lerp(float3(0.10, 0.30, 0.16), float3(0.27, 0.21, 0.07), hueK);
    float3 lite = lerp(float3(0.55, 0.95, 0.40), float3(0.97, 0.82, 0.34), hueK);
    // Contrast of the fibres rides the mid band. base + k*s: the floor is
    // 1.20 and the music can only ever add to it.
    float3 gold = lerp(dark, lite, saturate(fib * (1.20 + gSync.y * 0.18)));
    gold = lerp(gold, lite * 1.15, pow(saturate(1.0 - r / irisEdge), 2.4) * 0.85);
    gold *= 1.0 - 0.55 * crypt;                    // the lacunae, punched dark

    // Flecks. Four of them, at hashed positions in the iris, and only some
    // appearances get any at all - the reward for looking twice.
    float fleckAmt = saturate((k5 - 0.35) / 0.40);
    float fleck = 0.0;
    [unroll] for (int fi = 0; fi < 4; fi++)
    {
        float fh = hash11(float(fi) * 3.7 + k0 * 91.0);
        float fr = 0.26 + hash11(float(fi) * 5.1 + k2 * 77.0) * 0.50;
        float da = a01 - fh;
        da -= floor(da + 0.5);                     // shortest way round
        float2 fd = float2(da * TAU * max(r, 0.12), r - fr);
        fleck += exp(-dot(fd, fd) * 900.0);
    }
    gold += lite * fleck * fleckAmt * 0.55;

    // The limbal ring: the dark edge that makes an iris read as an iris.
    float ringW = 0.13 + k6 * 0.17;
    gold *= 1.0 - (0.62 + 0.28 * k3) * smoothstep(irisEdge - ringW, irisEdge, r);

    float3 col = gold * iris;
    col *= 1.0 - pupil;                               // punch the pupil out

    // ---- the sclera ------------------------------------------------------
    // Only exists in the wider framings, and when it does it brings the veins
    // with it. A whole extra half of the picture that six of the eleven shots
    // have and the other five do not.
    float scl = smoothstep(irisEdge - 0.01, irisEdge + 0.07, rb);
    float3 sclera = float3(0.20, 0.215, 0.205) * (1.0 - 0.62 * smoothstep(0.95, 1.80, rb));
    [branch] if (mag < 1.30)
    {
        float ab  = atan2(eb.y, eb.x) * ITAU;
        float vN  = floor(13.0 + k5 * 17.0);
        float vN2 = floor(vN * 2.4);               // integer, so it can wrap
        float vr  = rb * 2.4 - t * 0.015;
        float vv = noise2p(float2(ab * vN,  vr),              vN)  * 0.68
                 + noise2p(float2(ab * vN2, vr * 2.4 + 7.3),  vN2) * 0.32;
        vv = saturate(1.0 - abs(vv * 2.0 - 1.0));
        vv *= vv; vv *= vv; vv *= vv;              // ridged, ^8, no pow call
        float vmask = smoothstep(irisEdge + 0.02, irisEdge + 0.50, rb);
        sclera += float3(0.26, 0.09, 0.09) * vv * vmask
                * (0.18 + 0.70 * k5) * (1.0 + gSync.x * 0.25);
    }
    col += sclera * scl;

    // ---- what the cornea is reflecting -----------------------------------
    // A cat's eye is a mirror before it is anything else, and the thing in
    // the mirror is the only element that can be a different OBJECT without
    // the shot stopping being an eye. Four of them, chosen by k1.
    float2 rc = eb + gaze * 0.30;                  // the world does not turn with the eye
    rc *= (1.4 + k3 * 1.5) / max(1.0 - 0.55 * dot(rc, rc), 0.30);   // convex: the rim eats the horizon
    float ref = 0.0;
    int variant = min(3, (int)(k1 * 4.0));
    if (variant == 0)
    {
        // a lit window, four panes, drifting
        float2 wp = rc * float2(1.0, 1.30) - float2(sin(t * 0.09) * 0.20, 0.55);
        float pane = smoothstep(1.00, 0.74, max(abs(wp.x), abs(wp.y)));
        float mull = smoothstep(0.05, 0.11, abs(wp.x)) * smoothstep(0.05, 0.11, abs(wp.y));
        ref = pane * (0.30 + 0.70 * mull);
    }
    else if (variant == 1)
    {
        // a low sun over a banded horizon: the demo's own synthwave shot,
        // seen from the wrong side of the glass
        float2 sn = rc - float2(0.0, -0.30 + sin(t * 0.07) * 0.06);
        float sun  = smoothstep(0.46, 0.20, length(sn * float2(1.0, 1.15)));
        float band = 0.5 + 0.5 * sin(sn.y * 26.0 - t * 0.7);
        float hz   = smoothstep(0.06, 0.0, abs(rc.y + 0.64));
        ref = sun * (0.45 + 0.55 * band) + hz * 0.55;
    }
    else if (variant == 2)
    {
        // a tube. scanlines and a roll bar, because of course it is a tube
        float2 sn = rc * float2(0.92, 1.20);
        float scr   = smoothstep(1.05, 0.86, max(abs(sn.x), abs(sn.y)));
        float lines = 0.55 + 0.45 * sin(sn.y * 52.0);
        float roll  = smoothstep(0.30, 0.0, abs(frac(sn.y * 0.4 - t * 0.13) - 0.5));
        ref = scr * (lines * 0.75 + roll * 0.40);
    }
    else
    {
        // doorframes receding: the corridor, six deep, walking outward. The
        // ratio is exactly 2 so the sequence at frac()==1 is the sequence at
        // frac()==0 shifted by one frame, and the loop never pops.
        float s = 1.05 * exp2(frac(t * 0.11));
        [unroll] for (int ai = 0; ai < 6; ai++)
        {
            float dr = max(abs(rc.x) / s, abs(rc.y) / (s * 0.80));
            ref += smoothstep(0.075, 0.0, abs(dr - 1.0));
            s *= 0.5;
        }
        ref *= 0.55;
    }
    ref = saturate(ref);

    // The pupil is not black: it is a hole with the world in it. Over the
    // iris the same reflection sits far fainter, because there is already
    // something under it.
    float corn = smoothstep(irisEdge + 0.16, irisEdge - 0.04, rb);
    col += pupil * float3(0.020, 0.028, 0.034);
    col += ref * corn * float3(0.72, 0.92, 0.85)
         * (pupil * (0.16 + 0.14 * k3) + (0.030 + 0.035 * k6));

    // ---- the wet specular ------------------------------------------------
    // The catchlight is a reflection of the KEY LIGHT, so it barely follows
    // the gaze - which is exactly why it slides across the iris when the eye
    // darts. Three shapes, and its position moves per appearance.
    int cls = min(2, (int)(k2 * 3.0));
    float2 cp = float2(lerp(-0.40, 0.34, k1), lerp(0.14, 0.46, k3))
              + gaze * 0.12 + float2(gSync.z * 0.010, 0.0);
    float2 cd = eb - cp;
    float csz = 0.13 + k6 * 0.17;
    float spec;
    if (cls == 0)
    {
        spec = smoothstep(csz * 2.1, 0.0, length(cd));                  // one soft disc
    }
    else if (cls == 1)
    {
        spec = smoothstep(csz * 1.5, 0.0, length(cd))                   // and a companion
             + smoothstep(csz * 0.85, 0.0, length(cd - float2(0.21, -0.14))) * 0.70;
    }
    else
    {
        float2 wd = cd / csz;                                           // a window, four panes
        float box  = smoothstep(1.65, 1.15, max(abs(wd.x), abs(wd.y * 1.25)));
        float mull = smoothstep(0.10, 0.24, abs(wd.x)) * smoothstep(0.10, 0.24, abs(wd.y));
        spec = box * (0.35 + 0.65 * mull);
    }
    col += spec * float3(0.85, 0.95, 0.90) * (0.42 + 0.20 * k0) * (1.0 + gSync.z * 0.22);
    // the bounce off the wet lower lid
    col += smoothstep(0.28, 0.0, length(eb - float2(cp.x * 0.4, -0.54)))
         * float3(0.30, 0.42, 0.38) * 0.11;

    // ---- glow ------------------------------------------------------------
    // The eye is its own light source. This is the reason the shot works in
    // a black frame. It falls off in SCREEN radius, not eyeball radius, or a
    // tight crop would flood the frame with it.
    float glow = exp(-rs * 1.9) * gTune.w * (1.0 + gVoice.z * 0.10);
    col += float3(0.28, 0.75, 0.34) * glow;
    col += float3(0.10, 0.30, 0.14) * exp(-rs * 0.7) * gTune.w * 0.35;

    // ---- the third eyelid ------------------------------------------------
    // A cat has a nictitating membrane and it sweeps in from the inner
    // corner. Four of the eleven get one, once, early in the shot. It is a
    // film, not a shutter: it lifts the blacks under it and leaves a bright
    // leading edge, and it takes 0.9 s to cross, so nothing about it snaps.
    [branch] if (k6 > 0.62)
    {
        float sweep = sin(saturate((t - 0.55) / 0.90) * 3.14159265);
        float xe = -2.10 + sweep * 2.55;
        float memb = smoothstep(xe, xe - 0.14, p.x);
        float lead = smoothstep(0.10, 0.0, abs(p.x - xe + 0.07)) * sweep;
        col = lerp(col, col * 0.62 + float3(0.09, 0.13, 0.10) * (0.30 + 0.70 * sweep),
                   memb * 0.45);
        col += float3(0.18, 0.26, 0.21) * lead * 0.35;
    }

    // ---- the lid ---------------------------------------------------------
    // Two arcs closing on the eye. A blink is a shape, not a fade - and it
    // is a movement, so the shader plays it from the shot's own clock.
    // gTune.y only arms it; holding the lid shut for a whole shot would just
    // be a shot of black, which is what the first version of this was.
    //
    // The APERTURE is now per appearance, and it is the second biggest lever
    // after the crop: 0.68 is a half lidded stare and 1.37 is wide open, and
    // an eye is a different shape at each end of that. The curve and the
    // slant move with it, so some of the eleven are almonds and some are
    // rounds.
    float apert = (1.38 - 0.70 * k3) + sin(t * 0.7 + k0 * 6.0) * 0.015;
    float cvx   = 0.16 + k6 * 0.30;
    float tilt  = (k4 - 0.5) * 0.30;

    float lid = 0.0;
    if (gTune.y > 0.5) {
        float u = saturate(t / 0.18);              // 180 ms, shut then open
        lid = u < 0.38 ? (u / 0.38) : saturate(1.0 - (u - 0.38) / 0.62);
    }
    // and a settle, on every shot: the lids come the last few percent of the
    // way open over the first second, so frame one is never where we stay.
    lid = saturate(lid + (1.0 - smoothstep(0.0, 1.10, t)) * 0.10 * (0.40 + k5));

    // The lid edge carries fur. Smoothed value noise along x, so the
    // silhouette is a different ragged line in every appearance.
    float2 d = p - ctr * 0.7;
    float lx = d.x * (30.0 + k5 * 34.0);
    float lf = frac(lx); lf = lf * lf * (3.0 - 2.0 * lf);
    float ls = 5.0 + k0 * 9.0;
    float fur = (lerp(hash12(float2(floor(lx), ls)),
                      hash12(float2(floor(lx) + 1.0, ls)), lf) - 0.5) * 0.034;

    float lo = -apert + lid * (apert + 0.30) + cvx * d.x * d.x + tilt * d.x + fur;
    float hi =  apert - lid * (apert + 0.30) - cvx * d.x * d.x + tilt * d.x - fur;
    float open  = smoothstep(lo, lo + 0.045, d.y) * smoothstep(hi, hi - 0.045, d.y);
    // the shadow the lid casts on the globe under it
    float inner = smoothstep(lo + 0.02, lo + 0.17, d.y) * smoothstep(hi - 0.02, hi - 0.17, d.y);
    col *= open * (0.30 + 0.70 * inner);

    // Vignette down to nothing, so the eye floats in the dark.
    col *= 1.0 - 0.55 * smoothstep(0.72, 1.75, rs);

    return float4(col * gTime.z, 1.0);
}
