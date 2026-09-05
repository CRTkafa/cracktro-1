// Shot 40 - DESIGN FRAME SUITE.
//
// No 3D at all. This is the shot that says the demo was made this decade:
// everything else here is a raymarched space with a light in it, and then it
// cuts to a page. Flat blocks of colour, hard edges, a twelve column grid,
// crop marks and colour bars - the language of print and broadcast rather
// than of a demo. A retro pastiche never does this, because in 1996 nobody
// could put a clean vector edge on a screen. That is exactly why it reads as
// contemporary now.
//
// What the viewer sees in the first half second is one very large field of
// flat colour arriving against near black. Everything else in the layout is
// smaller than that field and lands after it. There is no light in this scene
// and no shading - value contrast IS the lighting.
//
// The one number that decides whether any of that survives is the floor. The
// post pass dithers luminance through a 4x4 ordered matrix at amplitude 0.85
// into ten steps, so a flat 0.02 ground does not arrive as 0.02: it arrives
// as a tile spread across the bottom four steps, averaging about 0.09 and
// carrying visible texture. Anything below roughly 0.20 luminance therefore
// does not read as an object sitting on the ground - it reads as more ground.
// Every dark value in this shader is placed above that line, and the ones
// that were not (the test card's black chip at 0.10, the wedge's darkest step
// at 0.07, the twelve column grid at 0.12) simply disappeared. The ladder now
// runs 0.90 paper down to 0.21, and the ground is the only thing below it.
//
// Four layouts live in here, chosen by a knob:
//   0  EDITORIAL   a full height colour plate down the right, a white
//                  headline plate top left, a rule, five runs of body text
//                  abstracted to bars, a knockout well with its caption, a
//                  running head, a folio, and a lot of air.
//   1  TEST CARD   seven colour bars, a greyscale wedge, a pair of mirrored
//                  level meters, two corner resolution wedges, the centre
//                  circle arriving on a clock wipe with a hand that ticks the
//                  beat round it, a crosshair, an ident plate, and a hum bar
//                  rolling slowly up the whole thing.
//   2  POSTER      one diagonal colour field that sweeps in along its own
//                  normal and then keeps breathing, an offset stroke inside
//                  it, a disc that knocks out where it crosses onto the
//                  colour, a knocked out caption stack and three knocked out
//                  squares, a rule ladder stepping into the empty corner with
//                  an accent rung walking down it on the beat.
//   3  MODULES     eighteen modules on a 6x3 grid, each filled, outlined or
//                  left empty by a hand written pattern, landing in reading
//                  order - and then re-setting to a second and a third hand
//                  written pattern, one module at a time, as a flip board.
//
// WHY THIS SCENE VARIES AND THE OTHERS DO NOT. gTune.x here is not a
// parameter, it is a SELECTOR: the four appearances are four different
// compositions, not one composition with four different numbers. A knob that
// only scales a thing you were going to draw anyway can never buy more than a
// variant of the same picture. A knob that chooses which picture buys a cut.
//
// gTune.x  layout        0..3, rounded
// gTune.y  assemble rate in pages-per-second. 0 means "already built", so a
//          hard graphic cut can land on a finished page. gTune is constant
//          for the whole shot and cannot animate, so the knob has to be a
//          rate and the shader has to run the build itself - the same reason
//          the eye's blink is armed rather than held. gTime.x is the shot's
//          own clock, so the build restarts on every cut.
// gTune.z  accent        0 amber, 0.5 phosphor green, 1 cold blue
// gTune.w  furniture     0 clean page, 1 full technical overlay: grid, crop
//          marks, foot ruler, and a head margin slug line of registration
//          target plus colour chips - along with the one pixel
//          misregistration that belongs with them.
//
// WHAT HAPPENS AFTER THE BUILD. The build finishes in the first second or two
// and every one of these shots runs for three and a half, so until now the
// back half of each appearance was a still frame. It is not any more, and the
// rule for what moves is narrow on purpose: a design frame that DRIFTS looks
// like a screensaver, and a design frame that SNAPS looks like it was cut. So
// the page holds a layout for a whole number of beats and then re-sets to
// another one - a second right answer, not a smeared version of the first.
// The song is 132.3 BPM and every shot in this scene starts on a bar line, so
// beats-since-the-cut is just the shot clock times BPS, and every ratchet in
// here is therefore locked to the music without ever having been told what
// the music is doing.
//
// The two things that are allowed to move continuously are the two that a
// still frame of this material would actually have: the poster's edge, which
// is the one gesture the poster is made of, and the test card's hum bar,
// which is an artefact of the medium the test card is pretending to be
// transmitted through.
//
// gSync and gVoice only ever LENGTHEN things here - a meter, a stripe, a
// square - or add to a brightness that already has a floor. Nothing in this
// shader multiplies a picture by an envelope, because the page is made of
// flat fields and a flat field scaled by audio is a flash.

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

// ---------------------------------------------------------------------------
// Page space. x runs -W/2..W/2, y runs -0.5 at the top to +0.5 at the bottom,
// and one unit is one screen height BEFORE the shot's fov scales it.
//
// PX is the design unit - one nominal line of a 360 line frame - and every
// thickness in the layout is written in it, so the proportions of the page
// hold whatever the frame is.
//
// PXU is the measured one: page units per real output pixel, taken from a
// single ddy() at the top of main. It is what every antialiasing ramp is
// built from, and it is the reason this shader stays correct at a fov other
// than 0.62 and in the WARP fallback, where the scene target is 180 lines
// rather than 360 and a nominal PX would be half a pixel wide - which is not
// a fainter hairline, it is a shimmering one. That derivative is taken in
// uniform flow before any branch, which is the only place a design frame -
// and a design frame is nothing but branches - can legally take one.
// ---------------------------------------------------------------------------
static const float  PX    = 1.0 / 360.0;
static const float3 INK   = float3(0.020, 0.024, 0.034);   // near black, blue
static const float3 PAPER = float3(0.910, 0.905, 0.880);   // warm white
static const float3 GREY  = float3(0.400, 0.415, 0.445);
static const float3 GRID  = float3(0.155, 0.170, 0.205);   // 0.17 lum: above
                                                           // the dither floor

// 132.3 BPM in beats per second. Every SC_FRAMES shot in the edit starts on a
// bar line, so gTime.x * BPS is beats since the cut with no phase to carry
// and nothing to look up.
static const float BPS = 2.205;

// Set once, in main, before anything is drawn.
static float PXU = PX;   // page units per output pixel
static float PW  = 1.0;  // page width in units, guarded against a zero aspect

float hash11(float n) { return frac(sin(n) * 43758.5453); }

// 1 inside, 0 outside, with a one pixel ramp across the edge: crisp enough to
// stay a hard edge under the dither, soft enough that the diagonals do not
// crawl when the camera rolls.
float fill(float d)             { return saturate(0.5 - d / (1.1 * PXU)); }
float outline(float d, float t) { return fill(abs(d) - t); }

// A hairline that is never thinner than a pixel. Written in PX so it stays a
// design decision, floored in PXU so it is never a shimmer.
float hair(float t) { return max(t, 0.62 * PXU); }

float3 over(float3 c, float3 t, float m) { return lerp(c, t, saturate(m)); }

// ---------------------------------------------------------------------------
// The ratchet. A number that HOLDS for a whole number of beats and then SNAPS
// to a new one over an eighth of a beat - 57ms, smoothstepped, so it is a
// move and not a jump cut but is over before the eye can follow it.
//
// This is the entire animation model of the page after it has built. It is
// the only way a layout is allowed to change: a rectangle that slides is a
// demo effect, a rectangle that is somewhere else on the next bar is a second
// layout. And because the hold is measured in beats it lands with the music
// for free.
//
// Two flavours. ratchet() picks anywhere in a range and is for the things
// where a continuum is honest - the ragged right edge of a run of text, which
// really can be any length. ratchet2() picks between exactly two authored
// values and is for structure, because a column is either the narrow one or
// the wide one and the halfway house is neither.
// ---------------------------------------------------------------------------
float ratchet(float bt, float per, float seed, float lo, float hi)
{
    float k = floor(bt / per);
    float f = saturate((bt - k * per) / 0.125);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(lo, hi, hash11(k * 1.31 + seed)),
                lerp(lo, hi, hash11(k * 1.31 + 1.31 + seed)), f);
}
float ratchet2(float bt, float per, float seed, float v0, float v1)
{
    float k = floor(bt / per);
    float f = saturate((bt - k * per) / 0.125);
    f = f * f * (3.0 - 2.0 * f);
    float a = (hash11(k * 1.31 + seed)        > 0.5) ? v1 : v0;
    float b = (hash11(k * 1.31 + 1.31 + seed) > 0.5) ? v1 : v0;
    return lerp(a, b, f);
}

// The Chebyshev box, not the euclidean one: max() of the two slabs instead of
// length(max(q,0)). It is exact inside the rect and wrong only outside it, by
// at most the corner mitre - and since the only thing that ever reads this
// distance is a one pixel antialiasing ramp, the error is never visible. It
// also saves a square root on every rectangle in the shader, and there are
// about forty of them.
float sdBox2(float2 p, float2 c, float2 h)
{
    float2 q = abs(p - c) - h;
    return max(q.x, q.y);
}
float sdRectAB(float2 p, float2 a, float2 b)
{
    return sdBox2(p, (a + b) * 0.5, abs(b - a) * 0.5);
}

// A point from page fractions: u across, v down, both 0..1. Positions are
// written as fractions so the composition fills 16:9 and 32:9 alike instead
// of floating in the middle of an ultrawide; thicknesses are written in
// height units so a hairline stays a hairline at any aspect.
float2 pg(float u, float v) { return float2((u - 0.5) * PW, v - 0.5); }

// The build. Elements land one after another in numbered slots, each taking
// about a quarter of a slot to arrive, so the page snaps together rather than
// fading up. A fade would be a demo effect, and this shot is pretending not
// to be a demo.
float cue(float a, float slot, float n)
{
    return saturate((a * (n + 1.0) - slot) * 3.5);
}

// Elements arrive as wipes, the way a title card does: an edge travels across
// the element instead of the whole thing appearing at once. Two directions,
// so a page assembling itself is not one big curtain.
//
// These are deliberately NOT gated on c > 0, and that was measured rather
// than assumed. At c = 0 the reveal edge sits exactly on the element's own
// leading edge, so the two one pixel ramps cross at half each and multiply to
// a quarter alpha hairline: every element on the page draws a one pixel line
// along its own edge from the first frame of the shot until its slot opens.
// It looks like a bug written down. It is invisible in this engine, because
// the scene target is 640x360 into a 1920x1080 output and one scene pixel at
// 25% survives that upscale and the post pass as nothing at all - gating it
// changed exactly zero pixels across eight sampled frames of all four
// layouts. So the guard is not here, and this paragraph is, because the next
// person to notice the arithmetic should not have to measure it twice.
float wipeRight(float2 q, float u0, float u1, float c)
{
    return fill(q.x - (lerp(u0, u1, c) - 0.5) * PW);
}
float wipeLeft(float2 q, float u0, float u1, float c)
{
    return fill((lerp(u1, u0, c) - 0.5) * PW - q.x);
}
float wipeDown(float2 q, float v0, float v1, float c)
{
    return fill(q.y - (lerp(v0, v1, c) - 0.5));
}

// Three stops: the demo's warm amber, the cat's phosphor green, and one cold
// blue that belongs to the synthwave half. All three land between 0.57 and
// 0.74 luminance - clear of both the ground and the paper, so the ten step
// dither puts every one of them in a bucket of its own.
float3 accentOf(float k)
{
    float3 a = float3(1.00, 0.60, 0.14);
    float3 b = float3(0.34, 1.00, 0.46);
    float3 c = float3(0.22, 0.66, 1.00);
    float  t = saturate(k) * 2.0;
    return (t < 1.0) ? lerp(a, b, t) : lerp(b, c, t - 1.0);
}

// ---------------------------------------------------------------------------
// 0  EDITORIAL SPREAD
//
// The static composition is the same one it always was and the elements are
// in the same places. What is new is that the page is TYPESET rather than
// printed: the column measure has two settings and takes one of them per bar,
// the right edge of every run of text re-measures on the beat the way ragged
// setting does when the copy changes, the well moves within the plate, and
// there are two more runs, a caption, a running head and a folio - because
// the thing that was wrong with the back half of this shot was not that it
// was still, it was that there was not enough on it to be still ABOUT.
// ---------------------------------------------------------------------------
float3 layoutEditorial(float2 q, float a, float3 col, float3 acc)
{
    float mu = 0.055 / PW, mv = 0.055;
    float n  = 13.0;
    float bt = gTime.x * BPS;
    float c, d;

    // The measure. Two columns are right for this page - a narrow plate with
    // a wide text measure, and a wide plate with a narrow one - and the page
    // takes one of them for four beats at a time. It is the single largest
    // area in the frame, so this one number re-proportions the whole shot
    // once, halfway through, on the bar.
    float pl = ratchet2(bt, 4.0, 0.0, 0.615, 0.532);

    // The plate. Full height, right hand column, and it is first in the shot
    // because it is the largest area of the strongest colour - the frame is
    // already committed before any of the small parts arrive.
    c = cue(a, 0.0, n);
    d = sdRectAB(q, pg(pl, mv), pg(1.0 - mu, 1.0 - mv));
    col = over(col, acc, fill(d) * wipeDown(q, mv, 1.0 - mv, c));

    // A hairline standing the plate off the page. Built as a box rather than
    // a corner pair so the one pixel floor has somewhere to apply, and it
    // follows the measure so the stand off is a constant and not an accident.
    c = cue(a, 1.0, n);
    d = sdBox2(q, pg(pl - 0.027, 0.5), float2(hair(0.7 * PX), 0.5 - mv));
    col = over(col, GREY * 0.8, fill(d) * wipeDown(q, mv, 1.0 - mv, c));

    // The running head. One short grey bar above everything, in the head
    // margin, where a section title sits.
    c = cue(a, 11.0, n);
    d = sdRectAB(q, pg(mu, 0.062), pg(0.190, 0.062 + 3.0 * PX));
    col = over(col, GREY * 1.2, fill(d) * wipeRight(q, mu, 0.190, c));

    // The headline plate. Near black to near white across one hard edge, in
    // the top left where a reader starts. The composition is that jump, and
    // then a great deal of air underneath it.
    c = cue(a, 2.0, n);
    d = sdRectAB(q, pg(mu, 0.105), pg(0.395, 0.300));
    col = over(col, PAPER, fill(d) * wipeRight(q, mu, 0.395, c));

    // The rule that closes the head and opens the measure. It is the one
    // element that reaches far enough right to care which measure is running:
    // at 0.560 it stopped twenty eight thousandths short of the plate's wide
    // setting, and it has to stop the same distance short of the narrow one
    // or it strikes across the stand off hairline and lands on the colour.
    // A rule that runs into the plate is not a rule, it is a scratch.
    float re = min(0.560, pl - 0.055);
    c = cue(a, 3.0, n);
    d = sdRectAB(q, pg(mu, 0.392), pg(re, 0.392 + 1.8 * PX));
    col = over(col, GREY * 1.5, fill(d) * wipeRight(q, mu, re, c));

    // Five runs of body text. At 360 lines a real glyph is mud, so the design
    // says "text" with a rectangle and means it - and a rectangle that says
    // "text" has to behave like text, so the ragged right edge re-measures
    // every beat inside a thirty five thousandth of the page. Small enough
    // that it never reads as a rectangle sliding, large enough that the block
    // is never twice the same shape.
    //
    // The widest run reaches 0.455 and the narrowest measure puts the plate
    // at 0.532, so the copy can never run into the colour.
    float w1 = 0.300 + ratchet(bt, 1.0, 1.0, -0.035, 0.035);
    float w2 = 0.420 + ratchet(bt, 1.0, 2.0, -0.035, 0.035);
    float w3 = 0.255 + ratchet(bt, 1.0, 3.0, -0.035, 0.035);
    float w4 = 0.360 + ratchet(bt, 1.0, 4.0, -0.035, 0.035);
    float w5 = 0.210 + ratchet(bt, 1.0, 5.0, -0.035, 0.035);

    c = cue(a, 4.0, n);
    d = sdRectAB(q, pg(mu, 0.462), pg(w1, 0.462 + 6.0 * PX));
    col = over(col, GREY, fill(d) * wipeRight(q, mu, w1, c));

    c = cue(a, 5.0, n);
    d = sdRectAB(q, pg(mu, 0.516), pg(w2, 0.516 + 6.0 * PX));
    col = over(col, GREY, fill(d) * wipeRight(q, mu, w2, c));

    c = cue(a, 6.0, n);
    d = sdRectAB(q, pg(mu, 0.570), pg(w3, 0.570 + 6.0 * PX));
    col = over(col, GREY, fill(d) * wipeRight(q, mu, w3, c));

    c = cue(a, 7.0, n);
    d = sdRectAB(q, pg(mu, 0.624), pg(w4, 0.624 + 6.0 * PX));
    col = over(col, GREY, fill(d) * wipeRight(q, mu, w4, c));

    c = cue(a, 8.0, n);
    d = sdRectAB(q, pg(mu, 0.678), pg(w5, 0.678 + 6.0 * PX));
    col = over(col, GREY, fill(d) * wipeRight(q, mu, w5, c));

    // A well knocked out of the plate, where a photograph would sit. It is
    // drawn in the ground colour, because that is what a knockout is: not a
    // dark rectangle laid on top, but a hole. This is the one place INK is
    // allowed to be that dark, because it is read against the accent all
    // round it and not against the ground.
    //
    // It sits at one of two heights and changes on a three beat hold, so it
    // is never in step with the measure changing on a four - two elements
    // that always move together read as one element.
    float wv = ratchet2(bt, 3.0, 2.0, 0.500, 0.548);
    c = cue(a, 9.0, n);
    d = sdRectAB(q, pg(0.660, wv), pg(0.945, wv + 0.315));
    col = over(col, INK, fill(d) * wipeDown(q, wv, wv + 0.315, c));

    // Its caption, above it and set short, in the ground colour for the same
    // reason the well is: it is knocked out of the plate, not printed on it.
    c = cue(a, 10.0, n);
    d = sdRectAB(q, pg(0.660, wv - 0.030), pg(0.820, wv - 0.030 + 3.0 * PX));
    col = over(col, INK, fill(d) * wipeRight(q, 0.660, 0.820, c));

    // The folio, bottom of the measure, hard right where a page number goes.
    c = cue(a, 11.0, n);
    d = sdRectAB(q, pg(0.300, 0.900), pg(0.395, 0.900 + 4.0 * PX));
    col = over(col, GREY * 1.3, fill(d) * wipeRight(q, 0.300, 0.395, c));

    // One small accent square, low left. It is the only large object in the
    // bottom half of the page and it is there to stop the air reading as an
    // accident. It takes its size from the guitar - the run of text above it
    // is fixed furniture, so the one free element on the page is the one that
    // gets to know what the band is doing. Base plus a fraction: it grows,
    // it never goes out.
    c = cue(a, 12.0, n);
    float ss = 0.030 * (1.0 + 0.28 * saturate(gVoice.x));
    d = sdBox2(q, pg(0.105, 0.845), float2(ss, ss));
    col = over(col, acc, fill(d) * c);

    // And a second, much smaller one that hops between two stops on every
    // other beat - a cursor sitting in all that air, so the bottom of the
    // page has a pulse without having a gradient.
    float hx = ratchet2(bt, 2.0, 7.0, 0.195, 0.262);
    d = sdBox2(q, pg(hx, 0.845), float2(0.014, 0.014));
    col = over(col, acc * 0.7, fill(d) * c);

    return col;
}

// ---------------------------------------------------------------------------
// 1  TEST CARD
// ---------------------------------------------------------------------------

// The bar ladder, pulled out so the boundaries can be antialiased with two
// taps instead of left as six hard vertical seams. Not SMPTE primaries: this
// demo has a palette, and a test card that ignored it would look like it came
// from another programme. Paper and accent alternate so that neighbouring
// bars differ in hue as well as in value - which is what keeps the card
// legible for the cold blue accent, whose luminance ladder is not monotone.
// The last bar is the card's black chip. On a real card it IS black; here the
// dithered ground is effectively 0.09, so a black chip is a hole rather than
// an object. GREY*0.55 puts it at 0.23, two quantiser steps clear.
float3 barOf(float i, float3 acc)
{
    float3 c = PAPER;
    if (i > 0.5) c = acc;
    if (i > 1.5) c = PAPER * 0.66;
    if (i > 2.5) c = acc   * 0.66;
    if (i > 3.5) c = PAPER * 0.42;
    if (i > 4.5) c = acc   * 0.42;
    if (i > 5.5) c = GREY  * 0.55;
    return c;
}

// One segmented meter, drawn from its own outer end inward. `s` is what it is
// reading and it only ever sets a LENGTH - the trough, the segments and the
// fill are all constant colours, so an audio envelope in here can never
// change the brightness of anything, only how much of the card is bright.
// That is the whole reason the meters are meters and not glowing blocks.
//
// Its corners arrive in page UNITS rather than page fractions, because this
// is a piece of furniture that has to be READ and the shot it appears in is
// punched in to fov 0.48. See the note at the call site.
float3 meter(float2 q, float x0, float x1, float y0, float y1, float s,
             float mirror, float3 col, float c)
{
    float lvl = 0.10 + 0.82 * saturate(s);
    float tro = fill(sdRectAB(q, float2(x0, y0), float2(x1, y1)));
    col = over(col, GREY * 0.55, tro * c);

    float f0 = (mirror > 0.5) ? lerp(x1, x0, lvl) : x0;
    float f1 = (mirror > 0.5) ? x1 : lerp(x0, x1, lvl);
    col = over(col, PAPER,
               fill(sdRectAB(q, float2(f0, y0), float2(f1, y1))) * c);

    // Eight divisions struck through the whole trough in the ground colour,
    // so the meter reads as a scale and not as a growing rectangle. They are
    // drawn over the fill, which is exactly how a real segmented meter works.
    float lu = (q.x - x0) / (x1 - x0);
    float dv = abs(frac(lu * 8.0) - 0.5) / 8.0 * (x1 - x0);
    col = over(col, INK, fill(dv - hair(0.7 * PX)) * tro * c);

    return col;
}

float3 layoutTestCard(float2 q, float a, float3 col, float3 acc, float fit)
{
    float mu = 0.055 / PW, mv = 0.055;
    float n  = 8.0;
    float u  = q.x / PW + 0.5;
    float bt = gTime.x * BPS;
    float meas = 1.0 - 2.0 * mu;          // the live measure, in u
    float c, d;

    // Seven bars. The index is a floor(), so the six internal edges carry no
    // geometry and would be raw stair steps - invisible while the frame is
    // upright and crawling the moment the shot rolls, which is exactly the
    // detail the dither then amplifies. So the boundary is found first and
    // the two bars either side of it are mixed across one pixel: the nearest
    // boundary is round(t), and the ramp is centred on it rather than run off
    // one side, so a bar edge sits where the arithmetic says it does.
    c = cue(a, 0.0, n);
    d = sdRectAB(q, pg(mu, mv), pg(1.0 - mu, 0.545));
    float bt2 = saturate((u - mu) / meas) * 7.0;
    float baa = max(7.0 * PXU / (meas * PW), 1e-5);
    float bC  = round(bt2);
    float bm  = saturate((bt2 - bC) / baa + 0.5);
    float3 bc = lerp(barOf(clamp(bC - 1.0, 0.0, 6.0), acc),
                     barOf(clamp(bC,       0.0, 6.0), acc), bm);
    col = over(col, bc, fill(d) * wipeRight(q, mu, 1.0 - mu, c));

    // WHERE THE LOWER BAND LIVES, and this is the one measurement on the card
    // that cannot be written as a page fraction.
    //
    // Everything else here is placed off the trim, which is right for things
    // that BLEED: the bars and the wedge run off both edges of this shot and
    // that is what a full bleed card does. But a meter is a scale, it fills
    // from its outer end inward, and this card is the one shot in the scene
    // that is punched in - fov 0.48, so the visible page is only u 0.113 to
    // 0.887 and the whole 0.055 margin is off the frame. A meter placed on
    // the trim therefore reads zero at every level, because the reading end
    // of it is outside the picture. That is the same failure the ruler and
    // the registration target have, and it has the same answer: place it off
    // the SMALLER of the trim and the visible extent.
    //
    // At fov 0.62 and wider the min() picks the trim and these land exactly
    // where a page design would put them; only punching in moves them.
    float kzv = max(gCam.w, 0.08) / (0.62 * fit);
    // PW already includes 1/fit; do not apply the horizontal fit twice.
    float mx  = min((0.5 - 0.055) * PW, 0.5 * PW * kzv * fit - 0.030);
    float my  = min(0.445,             0.5      * kzv - 0.028);
    float mw  = mx * 0.62;

    // A pair of mirrored level meters, low band on the left and high band on
    // the right, filling from the edges toward the middle, so the card
    // carries the same two channel furniture a real one does and so that the
    // only element on this page that answers to the music is the element
    // whose job that is.
    //
    // This is slot 1, which was empty. That matters more here than anywhere
    // else in the shader: this shot is the VOID, its assemble rate is 0.15,
    // and in three and a half seconds the build only ever reaches a = 0.55.
    // Anything hung past slot 4 never arrives at all in the shipped edit, so
    // the two new elements are put in the two low slots that were free.
    c = cue(a, 1.0, n);
    col = meter(q, -mx, -mx + mw, my - 0.176, my - 0.130,
                gSync.x, 0.0, col, c);
    col = meter(q,  mx - mw,  mx, my - 0.176, my - 0.130,
                gSync.z, 1.0, col, c);

    // The greyscale wedge under it, which is the thing a monitor is actually
    // lined up against. It wipes the other way so the card does not read as
    // one curtain coming across. The ladder is linear here, so the same
    // boundary trick costs one lerp on the index rather than two on colour.
    // It bottoms out at GREY*0.5 and not at black for the same reason the
    // black chip does: eight steps of which the first three are the ground is
    // a five step wedge.
    c = cue(a, 2.0, n);
    d = sdRectAB(q, pg(mu, 0.545), pg(1.0 - mu, 0.660));
    float st  = saturate((u - mu) / meas) * 8.0;
    float saa = max(8.0 * PXU / (meas * PW), 1e-5);
    float sC  = round(st);
    float si  = clamp(sC - 1.0 + saturate((st - sC) / saa + 0.5), 0.0, 7.0);
    col = over(col, lerp(GREY * 0.50, PAPER, si / 7.0),
               fill(d) * wipeLeft(q, mu, 1.0 - mu, c));

    // Two converging line bursts in the bottom corners - the resolution
    // wedge every card has, and the one piece of the layout that is there to
    // be looked AT rather than measured against. abs() on x buys both for the
    // price of one, and mirroring is what a corner pair wants anyway.
    //
    // Radial lines at a constant angle converge on the apex, so the pitch
    // falls as you go in; the burst is cut off at r = 0.075 because inside
    // that the pitch is under four pixels and a resolution wedge that has
    // itself aliased is a joke told at its own expense.
    // Pinned to the same mx and my as the meters, and for the same reason:
    // a burst whose apex is off the frame is a handful of stray diagonals.
    c = cue(a, 3.0, n);
    float2 W  = float2(abs(q.x) - mx, q.y - (my - 0.061));
    float  wr = length(W);
    float  wg = atan2(W.y, -W.x);
    float  wl = abs(frac(wg * 5.0 + 0.5) - 0.5) / 5.0 * wr;
    float  wm = fill(wl - hair(0.6 * PX));
    wm *= fill(max(abs(W.y) - 0.055, abs(W.x + 0.165) - 0.085));
    wm *= fill(0.075 - wr);
    col = over(col, GREY * 1.2, wm * c);

    // The circle. Every test card has one, and this one is also a match cut:
    // a bright ring dead centre is the same shape as the blown pupil in the
    // cold open, so a hard cut either way lands on a shape and not a change.
    //
    // The radius is 0.270 and not 0.335 because at 0.335 the bottom of the
    // ring landed at y = +0.335 and the top of the ident plate at +0.290, so
    // the ring cut straight through the plate. Two elements crossing turns a
    // composition into a tangle - the rule this shader applies to the poster's
    // vertical rule, and it applies here too.
    //
    // It arrives on a clock wipe, which is the only correct way for a circle
    // to arrive - antialiased, because a raw step() here is a hard radial
    // edge sweeping the whole frame, and it is moving, which is the one thing
    // that makes an aliased edge impossible to miss. The threshold is pushed
    // a hair past 1 so the leading edge closes cleanly on the twelve o'clock
    // seam instead of leaving a half lit pixel there for the rest of the shot.
    c = cue(a, 4.0, n);
    float rr  = length(q);
    float ang = frac(atan2(q.x, -q.y) * 0.15915494);   // 0 at twelve o'clock
    float caa = max(PXU / (6.2831853 * 0.270), 1e-5);  // one pixel, in turns
    float clk = saturate((c * (1.0 + 3.0 * caa) - ang) / caa + 0.5);
    col = over(col, PAPER, outline(rr - 0.270, hair(1.3 * PX)) * clk);

    // And then the card becomes a clock, which is what the ring on a card is
    // FOR: eight marks inside it and a hand that steps one mark per beat, so
    // the two bars of near silence this shot occupies are not a still frame,
    // they are a shot of something keeping time. The hand takes exactly one
    // turn over the two bars and we cut away as it closes - the only piece of
    // animation in the demo that is finished at the same instant its shot is.
    //
    // It ticks rather than sweeps, over a tenth of a beat, because a second
    // hand that glides is a quartz movement and a card is not a wristwatch.
    float tk = abs(frac(ang * 8.0 + 0.5) - 0.5) / 8.0 * 6.2831853;
    col = over(col, GREY * 1.4,
               fill(tk * rr - hair(0.9 * PX))
             * fill(abs(rr - 0.243) - 0.017) * c);

    float kt = floor(bt);
    float tf = saturate((bt - kt) / 0.10);
    tf = tf * tf * (3.0 - 2.0 * tf);
    float  th  = (kt + tf) * 0.78539816;             // an eighth turn a beat
    float2 hd  = float2(sin(th), -cos(th));
    float  al  = dot(q, hd);
    float  ax  = dot(q, float2(hd.y, -hd.x));
    float  hm  = fill(max(abs(ax) - hair(1.2 * PX),
                          abs(al - 0.100) - 0.140));
    hm = max(hm, fill(rr - 0.020));
    col = over(col, PAPER, hm * c);

    // Crosshair, full measure both ways.
    c = cue(a, 5.0, n);
    float hx = hair(0.6 * PX);
    float cw = fill(max(abs(q.y) - hx, abs(q.x) - (0.5 - mu) * PW));
    cw = max(cw, fill(max(abs(q.x) - hx, abs(q.y) - (0.5 - mv))));
    col = over(col, GREY * 1.2, cw * c);

    // Five small crosses on a line across the lower band. frac() gives all
    // five from one test, the same way abs() gives four crop marks from one -
    // but frac() also repeats forever, and at a fov wider than 0.62 the page
    // is smaller than the frame, so the sixth and seventh crosses would march
    // out into the margin. The whole row is clipped back to the measure.
    c = cue(a, 6.0, n);
    float2 X  = float2((frac(u * 5.0) - 0.5) / 5.0 * PW, q.y - 0.200);
    float  hc = hair(0.7 * PX);
    float  xm = fill(max(abs(X.x) - 0.020, abs(X.y) - hc));
    xm = max(xm, fill(max(abs(X.x) - hc, abs(X.y) - 0.020)));
    xm *= fill(abs(q.x) - (0.5 - mu) * PW);
    col = over(col, GREY * 1.3, xm * c);

    // The ident plate at the foot: a white block with the accent struck
    // through it, where a station logo would go. It sits below the ring with
    // eleven pixels of air and above the trim with seven. The strike grows
    // upward off the organ, which is the voice that owns the section this
    // card is cut into - again a height and not a brightness.
    c = cue(a, 7.0, n);
    d = sdRectAB(q, pg(0.415, 0.800), pg(0.585, 0.925));
    col = over(col, PAPER, fill(d) * wipeDown(q, 0.800, 0.925, c));
    float sh = 0.040 + 0.028 * saturate(gVoice.z);
    d = sdRectAB(q, pg(0.415, 0.925 - sh), pg(0.585, 0.925));
    col = over(col, acc, fill(d) * wipeDown(q, 0.800, 0.925, c));

    // The hum bar. A band of mains frequency beat rolling slowly up the
    // picture, which is what an analogue card transmitted down a cable with a
    // ground loop on it actually does, and the one thing in this shader
    // allowed to move continuously rather than on the beat - because it does
    // not belong to the design, it belongs to the medium.
    //
    // It is a five per cent swell on a band a third of the frame tall taking
    // six seconds to cross, so the fastest change any pixel sees is under one
    // per cent of full scale per frame. It multiplies, but it multiplies a
    // shape, not a clock: there is no term in here that an audio envelope can
    // reach, and a hum bar that flashed would not be a hum bar.
    float hy = frac((q.y + 0.5) + gTime.x * 0.17);
    col *= 1.0 + 0.052 * smoothstep(0.0, 0.18, hy)
                       * smoothstep(0.36, 0.18, hy);

    return col;
}

// ---------------------------------------------------------------------------
// 2  DIAGONAL POSTER
// ---------------------------------------------------------------------------
float3 layoutDiagonal(float2 q, float a, float3 col, float3 acc)
{
    float n = 8.0;
    float v = q.y + 0.5;
    float bt = gTime.x * BPS;
    float c, d;

    // One field, one edge. It sweeps in along its own normal, so the diagonal
    // IS the transition: nothing else has to move for the shot to open, and
    // for the first third of a second the frame is a single travelling edge.
    //
    // And then it does not stop. The edge keeps breathing along its own
    // normal on a twelve beat period - a tenth of the frame over the whole
    // shot, far too slow to read as an object moving and far too large to
    // read as a still. This is the one place a continuous motion is right
    // rather than lazy: the poster is not a page with a diagonal on it, the
    // poster IS the diagonal, so the poster's animation has to be that. The
    // low band adds to it and cannot subtract from it, so the field never
    // retreats on a quiet bar.
    c = cue(a, 0.0, n);
    float2 nrm = normalize(float2(0.58, 0.81));
    float  brk = 0.055 * sin(bt * 0.5236) + 0.018 * saturate(gSync.x);
    float  ed  = lerp(-1.7, 0.06, c) + brk * c;
    float  sd  = dot(q, nrm) - ed;
    float  fld = fill(sd);
    col = over(col, acc, fld);

    // An offset stroke inside the colour, thirty thousandths in and parallel
    // to the edge. It is knocked out, not printed, so it is the same hole the
    // disc is - and because it is pinned to sd it travels with the breath,
    // which is what makes the breath legible at all. A field with no interior
    // mark can move a long way before anyone notices.
    c = cue(a, 1.0, n);
    col = over(col, INK,
               fill(abs(sd + 0.030) - hair(1.1 * PX)) * fill(sd) * c);

    // A caption stack knocked out of the colour, top left, three short rules
    // set to a hanging indent. Three rectangles that say "there is writing
    // here", in the one corner of the poster that had nothing in it.
    c = cue(a, 6.0, n);
    float cm = fill(sdRectAB(q, pg(0.075, 0.085), pg(0.230, 0.085 + 3.0*PX)));
    cm = max(cm, fill(sdRectAB(q, pg(0.075, 0.117),
                                  pg(0.196, 0.117 + 3.0 * PX))));
    cm = max(cm, fill(sdRectAB(q, pg(0.098, 0.149),
                                  pg(0.215, 0.149 + 3.0 * PX))));
    col = over(col, INK, cm * fill(sd) * c);

    // The disc straddles the edge, and where it crosses onto the colour it
    // knocks out to the ground instead of overprinting. That single trick is
    // what makes a two colour poster look like it was paid for - and now that
    // the edge breathes, the split across the disc walks across it for the
    // whole shot, which is the composition changing rather than moving.
    c = cue(a, 2.0, n);
    col = over(col, lerp(PAPER, INK, fld),
               fill(length(q - float2(-0.130, -0.020)) - 0.300 * c));

    // Three small knockout squares stepping diagonally down the colour,
    // clear of the disc and clear of the edge at both ends of its travel -
    // checked at 4:3, 16:9 and 32:9, because the squares are placed in page
    // fractions and the edge is placed in page units, so the two of them
    // close on each other as the frame narrows and the narrow frame is the
    // one that decides where they can go.
    // They answer the disc: one big round hole and three small square ones.
    c = cue(a, 7.0, n);
    float qm = fill(sdBox2(q, pg(0.075, 0.660), float2(0.019, 0.019)));
    qm = max(qm, fill(sdBox2(q, pg(0.120, 0.712), float2(0.019, 0.019))));
    qm = max(qm, fill(sdBox2(q, pg(0.165, 0.764), float2(0.019, 0.019))));
    col = over(col, INK, qm * fill(sd) * c);

    // The only vertical: a thick paper rule out in the dark wedge. Its
    // position is a fraction of the half width so it stays proportionally
    // right on a wide frame, but its thickness is fixed in pixels.
    c = cue(a, 3.0, n);
    float xr = 0.68 * PW * 0.5;
    d = sdBox2(q, float2(xr, 0.0), float2(0.026, 0.435));
    col = over(col, PAPER, fill(d) * wipeDown(q, 0.055, 0.945, c));

    // A ladder of rules stepping down into the empty corner, each shorter
    // than the last and each a beat later. Derived from v with floor() rather
    // than run as a loop - there is no loop anywhere in this shader and there
    // does not need to be. The floor() boundary is put in the middle of a gap
    // so the antialiasing of one rule can never be clipped by the next rule's
    // cell.
    //
    // The ladder is boxed in on three sides and every one of them was a bug
    // the first time. It starts at u = 0.620 because the disc reaches u =
    // 0.596 and the first four rungs used to run straight across it. It ends
    // no further than u = 0.800 because the vertical rule begins at 0.825,
    // and it steps 0.026 and not 0.050 because at 0.050 the sixth rung's end
    // landed exactly on its own start - and a zero width rect is not a short
    // rule, it is a dot with a one pixel ramp on either side of it.
    //
    // Once it has landed, one rung a beat is struck in the accent and walks
    // down the ladder in reading order. Six rungs and six beats to a bar and
    // a half, so the walk is a bar and a half long and lands back at the top
    // as the shot ends. It is the smallest element on the poster and it is
    // the only thing keeping the beat, which is the correct division of
    // labour: the big shape breathes, the small one counts.
    float j = floor((v - 0.640) / 0.045);
    if (j > -0.5 && j < 5.5)
    {
        float yy = 0.655 + j * 0.045;
        float xe = 0.800 - j * 0.026 + ratchet(bt, 2.0, j, -0.014, 0.014);
        c = cue(a, 4.0 + j * 0.15, n);
        d = sdRectAB(q, pg(0.620, yy - 0.004), pg(xe, yy + 0.004));

        float  lit = (abs(fmod(floor(bt), 6.0) - j) < 0.5) ? 1.0 : 0.0;
        float3 rc  = lerp(PAPER * 0.72, acc, lit);
        col = over(col, rc, fill(d) * wipeRight(q, 0.620, xe, c));
    }

    // One small paper square in the top right, off the field, so the dark
    // wedge is composed rather than merely empty. The hat sets its size and
    // only its size - it grows off a floor and never leaves.
    c = cue(a, 5.0, n);
    float sq = 0.024 * (1.0 + 0.30 * saturate(gVoice.w));
    d = sdBox2(q, pg(0.915, 0.130), float2(sq, sq));
    col = over(col, PAPER, fill(d) * c);

    return col;
}

// ---------------------------------------------------------------------------
// 3  MODULAR GRID
//
// Eighteen modules, two bits of state each, packed into one constant so that
// the composition is something a person chose rather than something a hash
// produced: 0 empty, 1 outline, 2 accent, 3 paper. There are three of them
// now and the grid flips between them, because the answer to "the same page
// twice" is a second page and not a randomiser - a hash would give an endless
// supply of grids and every one of them would be the average of all the
// others.
//
// Read as three rows of six they come out
//
//   A   paper   -       outline outline -       accent
//       -       accent  accent  -       outline -
//       outline -       -       paper   -       outline
//
//   B   accent  -       -       outline paper   -
//       -       paper   outline -       -       accent
//       outline -       accent  -       outline -
//
//   C   paper   outline -       accent  -       paper
//       -       -       outline -       accent  -
//       -       outline -       -       -       accent
//
// A is the one the grid builds into: a white module top left, the pair of
// accent modules across the middle, a second white one on the opposite
// diagonal to answer it, and eight empties so the grid breathes. B moves the
// weight to the corners and C loads the top row and empties the bottom, so
// the three of them do not average out to a grey rectangle.
// ---------------------------------------------------------------------------
uint moduleState(uint idx, uint g)
{
    uint p0 = 0xc1128853u, p1 = 0x00000004u;
    if (g == 1u) { p0 = 0x2181c342u; p1 = 0x00000001u; }
    if (g == 2u) { p0 = 0x04210c87u; p1 = 0x00000008u; }
    uint pat = (idx < 16u) ? p0 : p1;
    return (pat >> ((idx & 15u) * 2u)) & 3u;
}

float3 layoutModules(float2 q, float a, float3 col, float3 acc)
{
    float mu = 0.055 / PW, mv = 0.100;
    float n  = 20.0;
    float u  = q.x / PW + 0.5, v = q.y + 0.5;
    float bt = gTime.x * BPS;
    float c, d;

    // Header and footer, so the modules sit on a page instead of in a void.
    c = cue(a, 0.0, n);
    d = sdRectAB(q, pg(mu, mv - 0.038), pg(1.0 - mu, mv - 0.038 + 1.8 * PX));
    col = over(col, GREY * 1.5, fill(d) * wipeRight(q, mu, 1.0 - mu, c));

    // The footer slug re-measures on the beat, so the one element that is not
    // on the grid is also the one element that never sits still.
    float fe = ratchet(bt, 1.0, 9.0, 0.170, 0.300);
    c = cue(a, 19.0, n);
    d = sdRectAB(q, pg(mu, 1.0 - mv + 0.030),
                    pg(fe, 1.0 - mv + 0.030 + 5.0 * PX));
    col = over(col, acc, fill(d) * wipeRight(q, mu, fe, c));

    float cw = (1.0 - 2.0 * mu) / 6.0;
    float ch = (1.0 - 2.0 * mv) / 3.0;
    float ci = floor((u - mu) / cw);
    float cj = floor((v - mv) / ch);

    // Register crosses at every module corner, under the modules, so the grid
    // is visibly a grid even where three cells in a row are empty. Kept at
    // GREY*0.55 - 0.22 luminance, one step clear of the dithered ground,
    // which is the whole reason the twelve column furniture grid at 0.12 was
    // never visible and this is.
    //
    // Distance to the NEAREST cell boundary, not the offset into the cell:
    // frac() alone puts the whole cross on one side of its own corner, which
    // is not a cross, it is a corner bracket pointing the same way eighteen
    // times. And frac() tiles the plane, so the row is clipped back to the
    // module area plus one arm - far enough out to draw the boundary crosses
    // whole, nowhere near far enough to reach the next line of them.
    float2 G = float2(abs(frac((u - mu) / cw + 0.5) - 0.5) * cw * PW,
                      abs(frac((v - mv) / ch + 0.5) - 0.5) * ch);
    float  ht = hair(0.6 * PX);
    float  xm = max(fill(max(G.x - 0.016, G.y - ht)),
                    fill(max(G.x - ht,    G.y - 0.016)));
    xm *= fill(abs(q.x) - ((0.5 - mu) * PW + 0.016))
        * fill(abs(q.y) - ((0.5 - mv)      + 0.016));
    col = over(col, GREY * 0.55, xm * cue(a, 1.0, n));

    if (ci > -0.5 && ci < 5.5 && cj > -0.5 && cj < 2.5)
    {
        uint idx = (uint)(cj * 6.0 + ci);

        // They land in reading order, which is the only order a grid can
        // assemble in without looking shuffled.
        c = cue(a, 2.0 + float(idx) * 0.85, n);

        // And they re-set in reading order too. Each module holds its state
        // for two beats and then flips, and the flip time is staggered by
        // idx so the change crosses the grid as a wave rather than arriving
        // as one cut - the same reason the build is staggered, applied to the
        // thing the build produced. Eighteen modules at 0.045 of a beat each
        // makes the wave four fifths of a beat wide, so it is a gesture and
        // not a sweep.
        //
        // The flip happens in the last eight per cent of the hold, so the
        // page is stationary for the whole of the beat it lands on and the
        // move belongs to the beat AFTER it. The module collapses to nothing
        // and reopens on the new state, which is a split flap board and not a
        // crossfade: a crossfade between two flat fields is a third flat
        // field, and there is no such colour in this palette.
        //
        // k can be -1 for the last modules in the first fraction of a second,
        // so the composition index is taken with a multiple of three added to
        // it before the fmod - which shifts nothing and makes the cast safe.
        float mbt = bt - float(idx) * 0.045;
        float kk  = floor(mbt / 2.0);
        float ff  = saturate(((mbt - kk * 2.0) / 2.0 - 0.92) / 0.08);
        uint  g   = (uint)fmod(kk + ((ff < 0.5) ? 30.0 : 31.0), 3.0);
        uint  st  = moduleState(idx, g);
        float sq  = abs(cos(ff * 3.14159265));

        // The gutter is a fixed number of pixels rather than a fraction of a
        // cell, so every module keeps the same rhythm when the frame widens.
        float2 ca = pg(mu + ci * cw, mv + cj * ch) + float2(0.013, 0.013);
        float2 cb = pg(mu + (ci + 1.0) * cw, mv + (cj + 1.0) * ch)
                  - float2(0.013, 0.013);
        d = sdBox2(q, (ca + cb) * 0.5,
                      float2((cb.x - ca.x) * 0.5,
                             (cb.y - ca.y) * 0.5 * sq));

        float  wp = wipeDown(q, mv + cj * ch, mv + (cj + 1.0) * ch, c);
        float  m  = 0.0;
        float3 cc = INK;
        if (st == 1u) { m = outline(d, hair(1.3 * PX)) * wp; cc = GREY;  }
        if (st == 2u) { m = fill(d) * wp;
                        cc = acc * (1.0 + 0.20 * saturate(gSync.y)); }
        if (st == 3u) { m = fill(d) * wp;                    cc = PAPER; }
        col = over(col, cc, m);
    }

    return col;
}

// ---------------------------------------------------------------------------
// The technical furniture: a grid under the layout, marks over it.
//
// Two different things live in here and they are pinned to two different
// rectangles. Crop marks belong to the PAGE - they mark its trim, and if a
// shot punches in past the trim then real crop marks leave the frame too. The
// ruler, the registration target and the slug line belong to the FRAME, the
// way a safe area overlay does, so they are placed off the visible half
// extent `he` and cannot be zoomed off the edge by a shot whose fov is
// anything other than 0.62. At fov 0.55 a hard 0.470 is outside the frame and
// all three of them vanish with no warning at all.
//
// NOTE FOR THE EDIT, not for this file: all four SC_FRAMES shots currently
// pass gTune.w = 0, so everything below this line is written, correct, and
// never once seen. It costs nothing at runtime - both functions return on the
// first line - but it is a whole register of variation sitting unspent, and
// spending it is a one character change in shots.h and not a change here.
// ---------------------------------------------------------------------------
float3 gridUnder(float2 f, float amt, float3 col)
{
    if (amt <= 0.001) return col;

    float u = f.x / PW + 0.5, v = f.y + 0.5;

    // Twelve columns and eight rows, one pixel wide. It is not there to be
    // looked at; it is there so the eye believes the blocks were placed on
    // something rather than dropped where they landed. Under the ordered
    // dither it survives as a sparse dotted line, which is exactly right -
    // but only from about 0.16 luminance up. Below that the ground's own
    // dither tile is brighter than the line and it disappears completely.
    float t  = hair(0.55 * PX);
    float dx = abs(frac(u * 12.0 + 0.5) - 0.5) / 12.0 * PW;
    float dy = abs(frac(v *  8.0 + 0.5) - 0.5) /  8.0;
    float g  = max(fill(dx - t), fill(dy - t));

    // frac() tiles the whole plane, so the grid has to be cut back to the
    // page. Without this a wide fov shows ruled lines running out past the
    // crop marks, which does not read as a grid - it reads as a bug.
    g *= fill(abs(f.x) - 0.5 * PW) * fill(abs(f.y) - 0.5);

    return over(col, GRID, g * amt);
}

float3 marksOver(float2 f, float2 he, float amt, float3 col, float3 acc)
{
    if (amt <= 0.001) return col;

    // The frame furniture sits just inside the visible edge, top and bottom.
    float fy = he.y - 0.030;

    // The head margin furniture gets its own knocked out ground first. On the
    // editorial and modular pages the margin is already the ground and this
    // does nothing; on the diagonal poster the colour field is full bleed and
    // runs straight through the margin, and without this the registration
    // target and the first two colour chips sit on the accent, where a grey
    // target is invisible and an accent chip on an accent field reads as a
    // printing fault rather than as furniture. A control strip on a real
    // proof has its own white ground for exactly this reason.
    float slug = fill(sdBox2(f, float2(0.0, -fy), float2(0.036, 0.036)));
    slug = max(slug, fill(sdBox2(f, float2(he.x - 0.375 + 0.150, -fy),
                                    float2(0.156, 0.016))));
    col = over(col, INK, slug * amt);

    float m = 0.0;

    // Crop marks at the trim corners. abs() buys all four for the price of
    // one, and they stand off the trim the way real ones do.
    float2 A = abs(f);
    float2 C = float2(0.5 * PW - 0.055, 0.445);
    float  ct = hair(0.0022);
    m = max(m, fill(sdRectAB(A, float2(C.x + 0.012, C.y - ct),
                                float2(C.x + 0.042, C.y + ct))));
    m = max(m, fill(sdRectAB(A, float2(C.x - ct, C.y + 0.012),
                                float2(C.x + ct, C.y + 0.042))));

    // The ruler along the foot: a tick every forty eighth of the frame, tall
    // every sixth, because a scale with no accented divisions is unreadable.
    float ur   = f.x / (2.0 * he.x) + 0.5;
    float t    = ur * 48.0;
    float dt   = abs(frac(t) - 0.5) / 48.0 * (2.0 * he.x);
    float tall = (fmod(floor(t), 6.0) < 0.5) ? 0.020 : 0.009;
    m = max(m, fill(dt - hair(0.6 * PX)) *
               fill(abs(f.y - (fy - tall * 0.5)) - tall * 0.5) *
               fill(abs(f.x) - he.x));

    // A registration target top centre - the one piece of furniture that is a
    // mark rather than a measure.
    float2 R  = f - float2(0.0, -fy);
    float  rt = hair(0.6 * PX);
    m = max(m, outline(length(R) - 0.016, hair(0.7 * PX)));
    m = max(m, fill(max(abs(R.x) - 0.026, abs(R.y) - rt)));
    m = max(m, fill(max(abs(R.x) - rt, abs(R.y) - 0.026)));

    col = over(col, GREY * 1.5, m * amt);

    // A five chip strip out at the right hand end of the head margin, on the
    // same line as the registration target - a slug line. It has to live in
    // the margin and not on the page: the first version put it inside the
    // trim, where it sat on top of the editorial layout's colour plate and
    // read as a mistake rather than as furniture. Each chip is its own
    // antialiased box with a gap either side, so the colour changes happen in
    // the gap and none of the four seams needs filtering. The dark chip is
    // GREY*0.5 rather than INK*3 for the same reason as the card's black bar.
    float sx = (f.x - (he.x - 0.375)) / 0.060;
    float sf = floor(sx);
    if (sf > -0.5 && sf < 4.5)
    {
        float cm = fill(max(abs(frac(sx) - 0.5) * 0.060 - 0.026,
                            abs(f.y + fy) - 0.011));
        float3 chip = PAPER;
        if (sf > 0.5) chip = acc;
        if (sf > 1.5) chip = acc * 0.45;
        if (sf > 2.5) chip = GREY * 0.7;
        if (sf > 3.5) chip = GREY * 0.5;
        col = over(col, chip, cm * amt);
    }

    return col;
}

float4 main(VSOut i) : SV_Target
{
    // No ray is built - this scene is a page, not a space. It still answers
    // to the shot table in the two ways a page can: roll turns the plate, and
    // the shot's fov scales it, with the demo's usual 0.62 meaning one to one.
    float kz = max(gCam.w, 0.08) / 0.62;

    PW = max(gTime.w, 0.5);

    // The one derivative in the shader, taken here, in uniform flow, before a
    // single branch has been entered. uv.y runs 0..1 over the scene target,
    // so ddy(uv.y) is exactly one over its height - 1/360 normally, 1/180 in
    // the WARP fallback - and multiplying by the fov scale converts it into
    // page units per output pixel. Everything downstream antialiases against
    // that constant, which is why there is no gradient instruction inside any
    // of the four layouts.
    PXU = max(abs(ddy(i.uv.y)) * kz, 1e-6);

    float2 P = float2((i.uv.x - 0.5) * PW, i.uv.y - 0.5);
    float  cr = cos(gDir.w), sr = sin(gDir.w);
    P  = float2(P.x * cr - P.y * sr, P.x * sr + P.y * cr);
    P *= kz;

    // The visible half extent, in page units, for the frame pinned furniture.
    float2 he = float2(0.5 * PW, 0.5) * kz;

    float amt = saturate(gTune.w);

    // The build is driven by time, not by the knob, because gTune is constant
    // for the whole shot. So the knob is a rate: 1.5 builds the page in two
    // thirds of a second, 0 means it was already built when we cut to it.
    float asmv = (gTune.y <= 0.0) ? 1.0 : saturate(gTime.x * gTune.y);

    // Once in a while the plate is one pixel out of register against the
    // grid. It is a fault and not an animation, so it fires on an irregular
    // schedule and is gone again inside an eighth of a second, and it turns
    // off with the rest of the furniture. One real pixel, not one nominal
    // one: half a pixel of misregistration is a soft edge, which is a
    // different and much worse looking fault.
    float  h = hash11(floor(gTime.x * 8.0) * 1.37 + 11.0);
    float2 J = (h > 0.94) ? float2(PXU, -PXU) * amt : float2(0.0, 0.0);

    float3 acc = accentOf(gTune.z);
    float3 col = INK;

    col = gridUnder(P, amt, col);

    // A uniform branch on a constant buffer value: all four layouts are in
    // the blob, only one of them runs, and none of them contains a gradient
    // instruction or a loop.
    int L = (int)(gTune.x + 0.5);
    if      (L <= 0) col = layoutEditorial(P + J, asmv, col, acc);
    else if (L == 1) {
        // SceneCB has no matte field. Reserve the test card's BAR(57)
        // matte (0.170 in shots.h) throughout its closing animation.
        // Fit the authored +/-0.445 trim with two scene lines of clearance.
        // Uniform scaling keeps the clock round; PW preserves the full width.
        float fit = min(1.0, max(kz * (0.5 - 0.170) - 2.0 * PXU, PXU) / 0.445);
        float pageWidth = PW, pixelSize = PXU;
        PW /= fit;
        PXU /= fit;
        col = layoutTestCard((P + J) / fit, asmv, col, acc, fit);
        PW = pageWidth;
        PXU = pixelSize;
    }
    else if (L == 2) col = layoutDiagonal (P + J, asmv, col, acc);
    else             col = layoutModules  (P + J, asmv, col, acc);

    col = marksOver(P, he, amt, col, acc);

    // Deliberately no vignette and no falloff, and no dither, no scanlines
    // and no grade: the post pass owns all four and doing any of them twice
    // is what turns a clean page into mud. Every other scene has a light in
    // it and therefore a gradient; the whole point of this one is that its
    // fields are perfectly flat, which is also what gives the ordered dither
    // in the post pass a clean uniform tile to lay down.
    return float4(col * gTime.z, 1.0);
}
