// Shot 39 - CRT POWER-OFF. The last shot of the demo.
//
// Nothing here is marched. This is a two dimensional shader, like the cat eye
// that opens the demo, and for the same reason: the subject is the picture
// itself, so there is no space to fly through. The camera fields are read and
// ignored on purpose - a tube dying is a locked-off frame, and a drifting
// camera would fight it.
//
// The collapse is not a squash, and getting the order right is the whole shot:
//
//   0. Before anything geometric happens the tube is ALREADY failing, and it
//      has to be, or the collapse arrives out of nowhere. The vertical hold
//      lets go first: the frame walks up the glass and wraps, dragging the
//      blanking bar and its retrace streak across the picture. The vertical
//      linearity goes with it, so the top of the frame compresses before the
//      rest of it does. The three guns stop landing on the same spot, which
//      is the red-left/blue-right fringe. That is the anticipation, and it is
//      the difference between inevitable and abrupt.
//
//   1. The high voltage sags. The beam is accelerated less, the yoke
//      therefore deflects it further, and the picture SWELLS a little, goes
//      soft, and brightens before anything else happens. That swell is the
//      detail that says "a tube switched off" rather than "a wipe".
//
//   2. The vertical deflection dies, and it dies far faster than the
//      horizontal. The picture crushes to a full-width line while the width
//      is still untouched. Every scanline in the frame is now landing on top
//      of every other one, so the line carries the whole frame's beam energy
//      in a single row - it is blown out, and it is brightest at the two
//      ends, where the sweep turns around and the beam dwells. Behind it the
//      whole picture is still faintly there in the phosphor, unlit.
//
//   3. Only then does the horizontal go, and the line closes to a point.
//
//   4. The point is not the end. Phosphor keeps glowing after the beam that
//      lit it has stopped, green longest of the three, which is why the last
//      thing left on a dead tube is a small green-white star that takes a
//      second to go out - and a horizontal smear either side of it, where the
//      line was a moment ago and the phosphor has not caught up.
//
// What is on screen when it dies is the cat eye, one last time, already sick
// with tearing and a rolling hum bar. The demo opened on that eye; ending on
// it and then killing the tube under it is the only cut this shot needs.
//
// gTune.x  collapse progress on the FIRST frame of the shot, 0..1
// gTune.y  how fast that progress advances, per second
// gTune.z  signal decay the picture ALREADY had before the switch
// gTune.w  phosphor persistence of the dot afterwards
//
// gTune.x is the driver the edit steers by, and it runs 0 to 1 - but tune is
// constant for the length of a shot, so the shader needs both the value it
// starts at and the rate it moves. x is where the collapse begins and y is
// how long it takes (rate = 1 / seconds).
//
// SELF-TIMED MODE. y = 0 used to mean "freeze at exactly x", and the shot
// this scene is actually cut into passes {1, 0, 0, 0} - which froze it at
// x = 1, i.e. parked the whole final 1.8 seconds of the demo on one static
// frame of an already-dead tube at full flare. Every envelope in here is a
// function of k, k was constant, and so the last thing the audience saw was
// a still. A held pose is worth having; a held pose is not worth having as
// the default that an unfilled tune falls into. So y = 0 now means "time
// yourself", and x becomes a tempo scale on the shader's own schedule:
//
//     rate = 1.14 * x     (x = 0 reads as 1, so {0,0,0,0} works too)
//     k    = (t - 0.62) * rate
//
// which holds the failing picture for the first six tenths, closes the line
// at t = 1.32 and leaves half a second of star. Those numbers are cut against
// what actually reaches the screen: the shot's TR_BLACK fades it up over 14
// rows, so brightness is under 15% for the first six tenths of a second and
// there is no point spending the collapse down there. In self-timed mode w =
// 0 likewise reads as "the usual persistence" rather than "none". Any shot
// that passes a real rate gets the documented behaviour, unchanged, including
// the freeze.
//
// Landmarks on that 0..1 clock, so a cut can be placed on one:
//
//     < 0.00        the pre-roll: rolling frame, tearing, misconvergence
//     0.00 - 0.15   the swell, and the last stretch that is still a picture
//     0.18 - 0.48   the vertical dies (eased, so it is over near 0.36)
//     0.36 - 0.54   the held line, full width. this is the shot
//     0.54 - 0.80   the width closes
//     0.80          the flare, and the point
//     0.80 +        the phosphor, on a clock in SECONDS, not in k
//
// The afterglow is deliberately NOT on the k clock. Held there it could never
// outlive k reaching 1, so "a second of glow" was only reachable by making the
// whole collapse four seconds long. It runs on real time now, so the collapse
// is as fast as the edit wants and the star still takes its second.
//
// The yoke ring is a sine in k, and at the rates this shot uses it advances
// most of a radian per frame - so it rings in POSITION, not in height. Height
// feeds the beam-energy gain, which is brightness, and a brightness wobble at
// that rate is a photosensitivity event. A displacement of the same size is
// a shudder, which is what a coil losing its drive actually does.

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

// One virtual row, in the [-1,1] units this shader works in. 360 lines, so a
// row is 2/360. Every softness in here is floored at roughly this, because a
// transition narrower than a pixel is not a soft edge, it is a stair that
// crawls - and the post pass dithers on top of it, which makes it worse.
#define ROW 0.00556

float hash12(float2 p)
{
    float3 q = frac(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return frac((q.x + q.y) * q.z);
}

// Everything the tube is doing wrong, gathered into one value. All six fields
// are uniform across the draw - they are functions of the collapse clock and
// nothing else - so this is passed by value into a function called up to
// seven times per pixel and the compiler keeps the whole thing in registers.
struct Fault
{
    float sick;   // how broken the signal is: tearing, hum, speckle
    float hf;     // how much authority per-row detail still has
    float roll;   // vertical hold slip, in picture units
    float nlin;   // vertical linearity error - the top compresses first
    float bar;    // blanking bar and retrace streak, at the wrap seam
    float lift;   // the one voice left in the outro, as a floor-safe lift
};

// The picture the tube is showing, in raster coordinates: x in [-aspect,
// aspect], y in [-1,1], regardless of what the deflection is currently doing
// to it. Everything the collapse does is a coordinate change on top of this.
//
// `hf` is how much authority the per-row detail still has. Once the vertical
// has crushed the picture, one output row is an average of dozens of picture
// rows, and five taps cannot average dozens of independent random rows - it
// samples five of them, which is not a filter, it is noise. Physically the
// tear and the speckle DO average away as the frame folds, so the honest fix
// and the cheap fix are the same one: fade them out with the fold.
float3 signalAt(float2 c, Fault f)
{
    // ---- the vertical hold, which is the first thing to go ----------------
    // The frame walks up the glass and wraps. This is a coordinate change on
    // the PICTURE, not on the raster: the raster is still where it was, which
    // is why the caller's extent test is done before this and not after.
    float wr = frac((c.y - f.roll + 1.0) * 0.5);   // 0..1 across the frame
    float sd = min(wr, 1.0 - wr);                  // 0 at the wrap seam
    float yy = wr * 2.0 - 1.0;

    // Vertical linearity goes before vertical amplitude does: the sawtooth
    // starts from the most depleted part of the supply, so the top of the
    // picture squashes while the bottom is still the right size. Small, but
    // it means the eventual crush is the end of something already happening
    // rather than an event on its own.
    yy += f.nlin * yy * saturate(yy);

    float row  = floor((yy + 1.0) * 180.0);
    float tick = floor(gTime.x * 26.0);

    // Line tearing, in BLOCKS of rows. This was per-row, and per-row tearing
    // does not read as tearing: on the highest contrast edge in the frame -
    // the pupil slit - it reads as a chewed edge, because neighbouring rows
    // land on opposite sides of it. Real tearing displaces a contiguous run
    // of lines, and it is the intact runs in between that make the broken
    // ones read as broken.
    float band = floor(row * 0.125);                    // 8-row blocks
    float pick = hash12(float2(band * 0.37, tick + 7.0));
    float jit  = hash12(float2(band, tick)) - 0.5;
    c.x += jit * 0.17 * f.sick * f.hf * step(0.72, pick);

    // Near-black, slightly blue, a touch heavier at the top and bottom of the
    // frame so the raster has a shape even before anything is drawn in it.
    float3 col = float3(0.016, 0.019, 0.030) * (1.0 - 0.35 * abs(yy));

    // The eye. One bold disc, a hard slit, one small specular - three shapes,
    // which is all that survives a 4x4 dither at 360 lines. It is framed to
    // sit on top of the demo's opening shot: eye.hlsl fills out to r = 0.84,
    // so this does too. It was 0.70 and a quarter smaller, which is enough to
    // break the rhyme with the shot the demo opened on - and a small disc in
    // a black field is not a composition.
    float2 e = float2(c.x, yy) - float2(0.0, 0.03);
    float  r = length(e * float2(1.0, 1.04));

    float3 grn  = lerp(float3(0.34, 0.95, 0.32), float3(0.05, 0.26, 0.09),
                       smoothstep(0.12, 0.92, r));

    // The limbal ring. Without it the iris is one flat value across its whole
    // area and the disc reads as a light bulb rather than as an eye - and a
    // flat disc is also the first thing a ten step dither turns into a
    // poster. One smoothstep buys the shape back.
    grn *= 1.0 - 0.80 * smoothstep(0.60, 0.86, r);

    float  iris = smoothstep(0.95, 0.84, r);
    float2 q    = float2(e.x / 0.112, e.y / 0.62);
    float  pup  = smoothstep(1.06, 0.90, length(q));

    col += grn * iris * (1.0 - 0.94 * pup);

    // The ambient glow is masked by the pupil as well. Added flat over the
    // top it lifted the slit to a third of full green and the eye stopped
    // having a dark centre, which is the one value the composition needs.
    col += float3(0.09, 0.30, 0.11) * exp(-r * 1.55) * (1.0 - 0.45 * pup);

    // The pupil is not a hole. It is glass with something behind it.
    col += pup * float3(0.020, 0.030, 0.034);

    // The wet specular, in the same place the opening shot puts it. This is
    // the brightest thing in the picture and it has to stay that way, or the
    // eye is a flat disc.
    col += float3(0.60, 0.68, 0.63) *
           smoothstep(0.150, 0.040, length(e - float2(-0.220, 0.340)));

    // The hum bar: a soft bright band crawling UP the frame, which is what a
    // failing supply looks like before it stops being a supply at all. It
    // crawls FASTER as the supply gives up, because the ripple is drifting
    // away from the field rate - a hum bar that keeps a constant speed is a
    // hum bar on a tube that is fine.
    float hum = frac(yy * 0.5 + 0.5 + gTime.x * (0.30 + 0.55 * f.sick));
    hum = exp(-(hum - 0.5) * (hum - 0.5) * 26.0);
    col += float3(0.050, 0.056, 0.070) * hum * f.sick * (1.0 + 0.45 * f.lift);

    // Speckle, quantised to pairs of rows so it reads as signal and not as
    // film grain, and so it is coarse enough to survive the box filter
    // instead of turning into a crawl.
    float sp = hash12(float2(floor(row * 0.5) * 1.7, tick * 3.1 + 19.0));
    col += (sp - 0.45) * 0.10 * f.sick * f.hf;

    // The blanking interval, dragged into shot by the roll. This is the one
    // piece of the pre-roll that is unambiguous at a glance: a dark band with
    // a thin bright retrace streak down the middle of it, crossing the frame.
    // Nothing else in the demo looks remotely like it, which is the point -
    // the audience has to be told the tube is going before it goes.
    float blank = exp(-sd * sd * 900.0) * f.bar;
    col *= 1.0 - 0.88 * blank;
    col += float3(0.10, 0.15, 0.11) * exp(-sd * sd * 30000.0) * f.bar * 0.60;

    return max(col, 0.0);
}

float4 main(VSOut i) : SV_Target
{
    float2 p = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
    // y flipped, same reason as every other scene: uv.y = 0 is the
    // top of the screen, and a tube collapses towards its centre
    // line, not away from it.
    p.x *= gTime.w;
    float A = gTime.w;

    // ---- the clock --------------------------------------------------------
    // Written as ku0 + t * rate in BOTH branches, so anything that needs to
    // know "at what time does the clock read v" can invert it: t = (v - ku0)
    // / rate. The roll uses that to stop itself.
    float rate, ku0, persist;
    if (gTune.y > 1e-4) {
        rate    = gTune.y;                       // the edit gave a rate
        ku0     = gTune.x;
        persist = saturate(gTune.w);
    } else {
        rate    = 1.14 * ((gTune.x > 0.01) ? gTune.x : 1.0);
        ku0     = -0.62 * rate;                  // six tenths of failing first
        persist = (gTune.w > 0.001) ? saturate(gTune.w) : 0.60;
    }

    // ku is the collapse clock and it is NOT clamped at either end. The
    // pre-roll needs it negative, so the failure has somewhere to live before
    // the geometry moves; the phosphor after the closure needs it to keep
    // running past 1, or the afterglow plateaus at whatever value it had
    // reached when k hit its ceiling and the tube never actually goes out.
    float ku = ku0 + gTime.x * rate;
    float k  = saturate(ku);

    // How far into the failure we are, before the switch does anything
    // geometric. In authored mode ku starts at gTune.x >= 0, so this is 1
    // from the first frame and the shot behaves exactly as it always did.
    float pre = smoothstep(-0.62, 0.02, ku);

    // ---- the three envelopes ---------------------------------------------
    // The swell is a bump, not a ramp: the picture grows, and then the thing
    // that was making it grow takes the deflection with it.
    float swell = smoothstep(0.00, 0.15, k) * smoothstep(0.32, 0.18, k);

    // Vertical first, and fast. Cubic ease-out, so almost all of the travel
    // happens in the first third of the window and the last sliver of height
    // creeps away - which is what makes the line feel like it snapped shut.
    float vv = smoothstep(0.18, 0.48, k);
    float iv = 1.0 - vv;
    float vc = 1.0 - iv * iv * iv;

    // Horizontal only starts once vertical is done, and the gap between the
    // two is the held line. That hold is the shot. This one is NOT eased out
    // the way the vertical is: the width has to still be visibly closing
    // right up to the last moment, or the point arrives before the line has
    // finished being a line and the collapse loses its ending.
    float hc = smoothstep(0.54, 0.80, k);

    // ---- what is wrong with the signal ------------------------------------
    // gTune.z is how sick the picture ALREADY was when the shot started. The
    // death adds its own on top, and it has to: a tube whose vertical hold
    // has let go is tearing, whatever the edit asked for. It peaks exactly on
    // the switch, which is where the sync loses lock hardest.
    float sick = saturate(gTune.z +
                          pre * (0.55 + 0.45 * smoothstep(0.02, 0.16, k)));

    // The slip, in picture heights, and it STOPS. There is no rolling once
    // there is no vertical sweep left to lose lock on, and a phosphor ghost
    // that keeps sliding is a ghost of nothing. Freeze at k = 0.30, halfway
    // through the crush, by clamping the time the roll integrates over.
    float tStop = max((0.30 - ku0) / rate, 0.0);
    float roll  = 1.90 * pre * pre * min(gTime.x, tStop);

    // ---- the deflection ---------------------------------------------------
    // 0.0030 is roughly half a virtual row at 360 lines, so the line really
    // is one scanline tall rather than a thin rectangle.
    float h = lerp(1.0, 0.0030, vc) * (1.0 + 0.10 * swell);
    float w = lerp(1.0, 0.0026, hc) * (1.0 + 0.06 * swell);

    // The yoke does not stop cleanly, it rings - in POSITION. Peaks in the
    // middle of the collapse and is gone by the time the line settles. The
    // height keeps a much smaller share of the same ring so the line still
    // reads as breathing, held under a tenth so it cannot count as a
    // brightness transition however fast it goes.
    float ringPh = k * 34.0;
    float ringE  = vc * (1.0 - vc);
    float ring   = 0.055 * ringE * sin(ringPh);
    h *= 1.0 + 0.07 * ringE * sin(ringPh + 1.6);

    // The raster centre slips down as the vertical hold goes, and the line
    // keeps a little of the picture's pincushion, so it is not a ruled edge.
    float xn  = p.x / A;
    float yc  = 0.030 * vc * (1.0 - 0.5 * vc) + ring;
    float bow = 0.010 * vc * xn * xn;

    float sy = (p.y - yc - bow) / max(h, 1e-5);
    float sx = p.x / max(w, 1e-5);

    // ---- the raster -------------------------------------------------------
    // One output row now covers 1/h rows of picture, so it has to be a box
    // filter over that span or the collapse turns into aliased stripes
    // instead of the picture folding into itself. Five taps is enough because
    // by the time the span is wide the result is nearly a flat average.
    //
    // The floor on span is the HV sag defocus: less accelerating voltage is a
    // fatter, softer spot, and without an explicit floor that softness never
    // appeared, because span is derived from h and h has barely moved yet.
    float span = min((2.0 / 360.0) / max(h, 1e-5), 2.4);
    span = max(span * (1.0 + 0.8 * swell), 0.030 * swell);

    // How much of the frame is folding into one output row, 0..1. Drives the
    // suppression of per-row detail inside signalAt.
    float fold = saturate((span - 0.010) * 26.0);

    Fault F;
    F.sick = sick;
    F.hf   = 1.0 - 0.92 * fold;
    F.roll = roll;
    F.nlin = 0.42 * pre * (1.0 - vc);
    F.bar  = pre * (1.0 - vc);
    // The outro subtracts a voice a bar until only the organ is left, so the
    // organ is the only thing still moving in the music under this shot. It
    // lifts, it never scales: base + k*s, so no envelope can take the floor
    // out from under the picture.
    F.lift = saturate(gVoice.z);

    // span is a function of h and swell, both uniform, so the tap count below
    // is the same for every pixel in the draw and the branch never diverges:
    // for the first half second, while the picture is still a picture and the
    // span is under a row, one tap IS the filter and the other four are paid
    // for nothing. The count is a variable rather than two copies of the loop
    // because two copies is two copies of signalAt in the blob.
    int   nt  = (span < 1.6 * ROW) ? 1 : 5;
    float ctr = 0.5 * float(nt - 1);
    float stp = 0.25 * span;

    float3 sig = float3(0.0, 0.0, 0.0);
    [loop] for (int t = 0; t < nt; t++) {
        float y = sy + (float(t) - ctr) * stp;
        if (abs(y) <= 1.0) sig += signalAt(float2(sx, y), F);
    }
    sig /= float(nt);

    // Misconvergence. As the high voltage sags the three beams stop landing
    // on the same triad and the guns separate - red short of where it should
    // be, blue past it. It is the single most legible symptom a colour tube
    // has, it is the one the swell shares a cause with, and it is worth two
    // extra taps: about eight pixels of fringe at 1920 at its widest.
    //
    // Gated on a UNIFORM value, so the branch is taken by the whole draw or
    // by none of it. Two things about that gate are load-bearing:
    //
    //  - It is (1 - 14*vc), not (1 - vc). These two taps sit OUTSIDE the box
    //    filter, so they are neither extent-tested nor divided by the tap
    //    count. The moment the fold starts rejecting taps, sig.g is a fifth
    //    of a partly-rejected sum while a raw tap is not, and replacing r and
    //    b with raw taps turns the whole screen magenta - the folded picture
    //    tiling in two channels at full strength behind a dim green one. It
    //    is a real bug and it cost a contact sheet to find. Zero the fringe
    //    before the fold can begin: at 14 it is out by k = 0.21, and the
    //    swell peaks at 0.16, so the widest fringe still lands intact.
    //
    //  - The blend weight, not the sampled value, carries the extent test.
    //    Multiplying the value instead pulls r and b to black in the two or
    //    three percent of rows the raster has already lost, which is a green
    //    seam across the top and bottom of the frame.
    float conv = (0.006 * pre + 0.010 * swell) * saturate(1.0 - 14.0 * vc);
    [branch] if (conv > 0.0005) {
        float  m  = (abs(sy) <= 1.0) ? 0.90 : 0.0;
        float3 lo = signalAt(float2(sx - conv, sy), F);
        float3 hi = signalAt(float2(sx + conv, sy), F);
        sig.r = lerp(sig.r, lo.r, m);
        sig.b = lerp(sig.b, hi.b, m);
    }

    // Overscan: the picture runs past the glass at full width, so no edge is
    // visible until the horizontal actually starts closing. This is measured
    // in SCREEN units with a one-pixel floor on the softness. Written as a
    // smoothstep on sx it was a fixed 4% of a half-width that ends up at
    // 0.0026, i.e. a transition two thousandths of a pixel wide - a hard
    // stair on the two ends of the line, exactly where the eye is looking.
    // ROW is the softness floor in x as well as in y: the engine fixes the
    // height at 360 lines and lets the width follow the aspect, so a virtual
    // pixel is square at every aspect from 4:3 to 32:9 and 2/360 is one of
    // them in either direction.
    float halfW = A * w;
    float xsoft = max(0.02 * halfW, ROW);
    float xin   = 1.0 - smoothstep(halfW - xsoft, halfW + xsoft, abs(p.x));

    // Beam energy is conserved, so brightness goes up exactly as fast as the
    // area goes down. Both gains are capped - the true 1/(h*w) is about six
    // orders of magnitude and there is no point carrying it once the frame
    // has clipped to white.
    float vGain = min(1.0 / max(h, 0.0030), 42.0);
    float hGain = min(1.0 / max(w, 0.0026), 4.5);

    // The ends of a collapsed line are brighter than the middle because the
    // sweep decelerates into the turnaround and the beam sits there longer.
    // The ramp starts further in than it did: at 0.50 the bright part landed
    // under the overscan roll-off and never showed.
    float ax   = abs(p.x) / max(halfW, 1e-5);
    float ends = 1.0 + 2.6 * vc * (1.0 - hc) * smoothstep(0.35, 0.96, ax);

    // The sweep is not steady either - it hunts, and a node travels along the
    // line. Without this the held line is a still frame for a fifth of a
    // second at the loudest moment of the shot. ax is clamped to 1 inside the
    // visible line by xin, so this is always about one cycle across it,
    // whatever the width has got down to.
    ends *= 1.0 + 0.22 * vc * (1.0 - hc) *
            sin(ax * 7.0 - gTime.x * 9.0);

    // The swell is not only bigger, it is brighter: the same beam, less of it
    // being thrown away in the shadow mask. And the sag that causes the swell
    // starts long before the swell does, so the picture is already lifting
    // while it is still a picture - which is also the only reason anything is
    // visible under the shot's fade-up for the first six tenths of a second.
    float lift = 1.0 + 0.45 * swell + 0.75 * pre * (1.0 - vc);
    float3 col = sig * (vGain * hGain * ends * xin * lift);

    // Once the line is carrying the whole frame it is past what any one gun
    // can put out, so the colour walks to neutral - which is also why the
    // classic power-off line is white and not the colour of the picture. Not
    // all the way: the line is a column-average of the picture and holding a
    // little of that is what stops it being a ruled white bar.
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), 0.62 * vc);

    // Bloom off the line. A row this overdriven does not stay inside its row:
    // it blooms into its neighbours, white in the core and green at the
    // edges, because that is the order the phosphors give up in.
    float dl    = abs(p.y - yc - bow);
    float bloom = exp(-dl * 26.0) * vc * (1.0 - 0.85 * hc);
    float bsoft = max(0.06 * halfW, ROW);
    float bx    = 1.0 - smoothstep(halfW - bsoft, halfW + 2.0 * bsoft,
                                   abs(p.x));
    col += lerp(float3(0.30, 0.95, 0.36), float3(1.00, 1.00, 0.95),
                exp(-dl * 90.0)) * bloom * 0.60 * bx;

    // ---- the dot ----------------------------------------------------------
    // Past a certain point the raster is two pixels wide and sampling it is a
    // lottery, so the brightest thing in the last second of the demo is drawn
    // rather than filtered. Hand over, do not add on top.
    //
    // The handover happens LATE. Starting it at hc = 0.80 crossfaded a line
    // still 45 pixels wide into a round dot, and the flare - the single
    // brightest frame of the shot - arrived as a soft green cloud with the
    // line dissolved inside it. At 0.93 the line is a dozen pixels across
    // when the dot takes over and the cut between the two is invisible.
    float dotOn = smoothstep(0.93, 1.00, hc);
    col *= 1.0 - dotOn;

    // 0.80 is where the width actually reaches zero, so both the flare and
    // the decay are measured from the closure rather than from a round
    // number - and they are measured in SECONDS, not in k.
    //
    // In k, the phosphor could never outlive k reaching 1, so "a second of
    // afterglow" was only reachable by making the whole collapse four seconds
    // long. Dividing by the rate decouples the two: the collapse is as fast
    // as the edit wants and the dot still takes its second to go out.
    float tAfter = max(ku - 0.80, 0.0);
    float tSec   = tAfter / rate;

    float glowE = exp(-tSec * lerp(7.0, 1.3, persist));

    // The instant the line closes, everything that was spread across a whole
    // row arrives in one place. That is a flare, and it is over in a few
    // frames - without it the line does not so much close as fade out.
    float flare = exp(-tSec * 22.0) * smoothstep(0.93, 1.00, hc);

    // p is isotropic - x was already scaled by the aspect - so a plain length
    // is a circle on screen. The core shrinks as it fades, the way a real dot
    // does; it does not simply dim in place.
    //
    // The flare widens the CORE, not the halo. Widening the halo made the
    // single brightest frame of the shot a green ball with a pale pip lost
    // inside it; a tube flashing off flashes WHITE, with green only at the
    // fringe. The floor is two virtual rows: below that the gaussian is
    // narrower than the pixel grid and the last image of the demo scintillates
    // on and off as the dot lands between sample points.
    float coreR = max(lerp(0.030, 0.0075, hc) * (0.55 + 0.45 * glowE)
                      + 0.055 * flare, 2.0 * ROW);
    float rd    = length(p - float2(0.0, yc));
    float cq    = rd / coreR;
    float core  = exp(-cq * cq);

    // The halo is phosphor that was lit a moment ago and is still coming
    // down, so it is not tied to the core's radius - but it was a fixed 0.075
    // wide, which is four times the core for the dot's whole life, and a green
    // cloud that size does not read as a star, it reads as an out of focus
    // smudge. It is tight now, and it comes down on the SLOW clock so the glow
    // does not snap shut the instant the flare ends.
    float halo = exp(-rd / (0.050 + 0.045 * flare + 0.030 * glowE));

    // Underneath both, one very wide and very faint field, so the glow still
    // has somewhere to sit rather than ending at the halo's edge.
    float mist = exp(-rd / 0.17);

    // Green longest of the three. The core is white while the beam is still
    // arriving and walks green as it dies, which is what leaves a green-white
    // star rather than a white one that turns off.
    float3 coreC = lerp(float3(0.62, 1.00, 0.66), float3(1.00, 1.00, 0.96),
                        saturate(flare + 0.6 * glowE));

    col += (coreC                     * core * (3.2 + 6.0 * flare) +
            float3(0.24, 0.85, 0.32)  * halo * (0.80 + 1.60 * flare +
                                                0.35 * F.lift) +
            float3(0.16, 0.55, 0.22)  * mist * (0.28 + 0.50 * flare))
           * dotOn * glowE;

    // The line does not vanish when the dot takes over. It was there a
    // hundredth of a second ago and the phosphor it lit is still coming down,
    // so a horizontal smear survives the closure, narrowing and dimming on
    // its own clock - slower than the flare, faster than the star. This is
    // the last thing in the demo that MOVES, and it is what turns the point
    // into the end of a collapse rather than a dot that was always there.
    float trW = A * 0.62 * exp(-tSec * 2.4);
    float trD = p.y - yc;
    float trail = exp(-trD * trD * 5200.0) *
                  (1.0 - smoothstep(trW * 0.55, trW, abs(p.x)));
    col += float3(0.20, 0.62, 0.24) * trail * dotOn * exp(-tSec * 3.0) * 0.85;

    // ---- what is left -----------------------------------------------------
    // Phosphor does not stop glowing because deflection did. For a while
    // after the raster leaves, the whole picture is still faintly there,
    // hanging in the dark behind the line with nothing driving it. The decay
    // was fast enough that it was gone before the line had even settled; it
    // is halved now, so the held line has the ghost of the eye behind it,
    // which is the one moment in the shot where you can see both at once.
    float ghost = vc * exp(-max(k - 0.24, 0.0) * 7.0) * 0.30;
    [branch] if (ghost > 0.002) {
        Fault G = F;
        G.sick = sick * 0.3;
        G.hf   = 1.0;
        G.bar  = F.bar * 0.4;
        col += signalAt(p, G) * ghost;
    }

    // The glass itself, lit by the room. It is almost nothing, but a frame of
    // exactly zero gives the dither nothing to bite on, and the demo should
    // end on a dark tube rather than on a hole.
    // exp, not a linear falloff: at 32:9 the corner is 3.7 units out and a
    // linear term would have gone negative long before it got there.
    col += float3(0.008, 0.010, 0.016) * exp(-length(p) * 0.45);

    return float4(col * gTime.z, 1.0);
}
