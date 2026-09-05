// The only text in the demo.
//
//     crt.fyi
//     hi@crt.fyi
//
// Two lines, small, once. The author was explicit about that and it is the
// right call: a demo that tells you who made it in forty-point letters is
// advertising, and a demo that puts it in the corner once at the end is a
// signature. So this file is not allowed to grow the type or centre it. What
// it IS allowed to do is make the eleven seconds it owns worth watching:
// the line writes itself, character by character, with a caret ahead of it
// and the phosphor still hot behind it.
//
// No glyph atlas. Between them these two lines use eleven distinct
// characters, and a monoline stroke distance field draws them from about
// thirty line segments - less code than the loader for an atlas would be,
// and it stays sharp at any size because it is analytic. The strokes are
// deliberately even-weight and slightly wide: at 360 lines a typographic
// contrast would just alias into mush.
//
// gTune.x  typing speed, 1.0 = the tuned default (about eleven glyphs a
//          second). The reveal used to be an absolute 0..1 fed from the shot
//          table, and the shot table fed it a constant 1.0 - so the "typing"
//          the comment promised never happened once. It is derived from
//          gTime.x now, and gTune.x only scales the rate.
// gTune.y  size
// gTune.z  which line: 0 both, 1 only the address
// gTune.w  the matte, as a fraction of the height hidden at each edge

cbuffer Scene : register(b0)
{
    float4 gTime;
    float4 gCam;
    float4 gDir;
    float4 gTune;
    float4 gSync;
    float4 gVoice;
};

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

// distance to a line segment, the primitive everything here is built from
float sdSeg(float2 p, float2 a, float2 b)
{
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}

// distance to an arc of a circle, for the round letters. a0..a1 in radians.
float sdArc(float2 p, float2 c, float r, float a0, float a1)
{
    float2 q = p - c;
    float  a = atan2(q.y, q.x);
    // wrap the angle into [a0, a0+2pi) so the comparison is unambiguous
    float  w = a - a0;
    w -= 6.28318530718 * floor(w / 6.28318530718);
    if (w <= a1 - a0) return abs(length(q) - r);
    // outside the sweep: the nearer of the two end points
    float2 e0 = c + float2(cos(a0), sin(a0)) * r;
    float2 e1 = c + float2(cos(a1), sin(a1)) * r;
    return min(length(p - e0), length(p - e1));
}

// Each glyph is drawn in a box 0.62 wide and 1.0 tall, with the baseline at
// y = 0 and the x-height at 0.58 - the proportions of a plain grotesque.
float glyph(float2 p, int c)
{
    float d = 1e9;
    if (c == 0) {           // c
        d = sdArc(p, float2(0.31, 0.31), 0.27, 0.55, 5.73);
    } else if (c == 1) {    // r
        // The arm used to sweep from three o'clock, which hooks it down past
        // the middle of the x-height and makes the r read as a curl. A
        // grotesque r lets go earlier and higher: the shoulder tops out AT
        // the x-height and the terminal stops just under it.
        d = min(sdSeg(p, float2(0.14, 0.0), float2(0.14, 0.58)),
                sdArc(p, float2(0.34, 0.40), 0.19, 0.30, 2.60));
    } else if (c == 2) {    // t
        d = min(sdSeg(p, float2(0.24, 0.10), float2(0.24, 0.86)),
                sdSeg(p, float2(0.06, 0.58), float2(0.44, 0.58)));
        // the tail bottoms out ON the baseline and lifts again, instead of
        // ending nose-down under it
        d = min(d, sdArc(p, float2(0.38, 0.14), 0.14, 3.14, 4.95));
    } else if (c == 3) {    // .
        d = length(p - float2(0.16, 0.065)) - 0.048;
    } else if (c == 4) {    // f
        d = min(sdSeg(p, float2(0.26, 0.0), float2(0.26, 0.72)),
                sdSeg(p, float2(0.08, 0.58), float2(0.46, 0.58)));
        d = min(d, sdArc(p, float2(0.40, 0.72), 0.14, 1.57, 3.14));
    } else if (c == 5) {    // y
        d = min(sdSeg(p, float2(0.08, 0.58), float2(0.30, 0.06)),
                sdSeg(p, float2(0.52, 0.58), float2(0.20, -0.22)));
    } else if (c == 6) {    // i
        d = sdSeg(p, float2(0.16, 0.0), float2(0.16, 0.58));
        // The dot has to clear the STROKE, not the centreline. Ink extends
        // w = 0.070 glyph units past the geometry on both sides, so a dot at
        // 0.775 with r 0.048 left 0.775-0.048-0.070-0.58 = 0.007 units of
        // gap: a sixth of a virtual pixel. The two merged and the demo spelt
        // the author's own domain "crt.fyl". At 0.88 with a slightly smaller
        // dot the gap is 0.120 units, two and a half virtual lines of real
        // dark, and it reads as an i.
        d = min(d, length(p - float2(0.16, 0.88)) - 0.040);
    } else if (c == 7) {    // h
        // shoulder raised so the h reaches the same x-height as the c and
        // the r; it was sitting two hundredths low and the word looked like
        // it had a dip in it
        d = min(sdSeg(p, float2(0.12, 0.0), float2(0.12, 0.90)),
                sdSeg(p, float2(0.44, 0.0), float2(0.44, 0.42)));
        d = min(d, sdArc(p, float2(0.28, 0.42), 0.16, 0.0, 3.14));
    } else if (c == 8) {    // @
        // The inner ring has to clear the outer one by more than the ink
        // reaches, or the counter fills in and the @ reads as a solid disc.
        // The comment that used to sit here claimed this was measured. It was
        // not, and it was wrong: at r 0.095 the annulus is
        //     (0.31 - 0.070) - (0.095 + 0.070) = 0.075 glyph units
        // which at this size is 1.46 virtual pixels - BELOW the threshold the
        // i's dot just established at 2.34. So the c beside it kept its
        // counter and the @ filled in, and the demo signed off with a blob in
        // the middle of the author's email address. 0.05 puts the annulus at
        // 0.120 units, the same gap that works for the i.
        d = sdArc(p, float2(0.31, 0.34), 0.31, 0.60, 6.10);
        d = min(d, sdArc(p, float2(0.31, 0.34), 0.05, 0.0, 6.28));
        d = min(d, sdSeg(p, float2(0.405, 0.34), float2(0.405, 0.15)));
    }
    return d;
}

// crt.fyi        -> c r t . f y i          (index 0,  seven glyphs)
// hi@crt.fyi     -> h i @ c r t . f y i    (index 7,  ten glyphs)
// One table, two offsets, so the loop can only ever index inside it.
static const int kText[17] = { 0, 1, 2, 3, 4, 5, 6,
                               7, 6, 8, 0, 1, 2, 3, 4, 5, 6 };

// METRICS. Every glyph used to advance 0.72 whatever it was, which is a
// teletype and not a grotesque: the period and the i sat in the middle of
// slots twice their width and "crt.fyi" came out with two holes punched in
// it. kLsb pulls each glyph over so its ink starts at the origin, kAdv is
// the ink width plus about 0.30 of tracking - the round letters tucked in by
// the usual optical hundredths, and the i and the @ given back what the ring
// and the bare stem need so "hi@" does not collide. The address ends up
// fifteen percent tighter than it was, which is the opposite of enlarging it.
//                                 c     r     t     .     f     y     i     h     @
static const float kLsb[9] = { 0.04, 0.14, 0.06, 0.112, 0.08, 0.08, 0.16, 0.12, 0.00 };
static const float kAdv[9] = { 0.80, 0.70, 0.68, 0.40,  0.66, 0.70, 0.34, 0.62, 0.94 };

// One line of type, written on. Returns
//   x  ink coverage           0..1
//   y  tight phosphor glow    the beam spot
//   z  halation               light scattered in the glass
//   w  the write head, in glyph units, for the caret
//
// prog is measured in glyph slots: 3.4 means three characters are down and
// the fourth is 40 percent of the way through its slot.
float4 drawLine(float2 p, int base, int n, float prog, float fw, float w)
{
    float ink = 0.0, hot = 0.0, hal = 0.0;
    float x = 0.0, head = 0.0;

    [loop] for (int k = 0; k < 10; k++)
    {
        if (k >= n) break;
        float age = prog - (float)k;
        if (age <= 0.0) break;                  // not typed yet

        int   c  = kText[base + k];
        float d  = glyph(p - float2(x - kLsb[c], 0.0), c) - w;

        // A character does not fade in over a fifth of a second - it is
        // struck. Two frames from nothing to solid, and then the phosphor
        // where it landed stays hot for about a sixth of a second after.
        float f = saturate(age * 3.2);
        float s = exp(-max(age - 1.0, 0.0) * 0.55);

        ink = max(ink, (1.0 - smoothstep(0.0, fw, d)) * f);
        hot = max(hot, exp(-max(d, 0.0) / 0.22) * f * (1.0 + 1.20 * s));
        hal = max(hal, exp(-max(d, 0.0) / 0.45) * f);

        head = x + kAdv[c] * saturate(age * 1.8);
        x   += kAdv[c];
    }
    return float4(ink, hot, hal, head);
}

float4 main(VSOut i) : SV_Target
{
    float2 uv = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
    uv.x *= gTime.w;

    // Derivatives before any branch: below this point whole waves get thrown
    // away by the bounding box and a gradient taken in there is undefined.
    float px = fwidth(uv.x);

    // 0.055 was chosen on paper and measured wrong on screen: at 360 lines
    // the strokes came out under two pixels and the letterforms turned to
    // mush. Small enough to be a signature, big enough to be legible, is
    // about twice that.
    float sz = 0.115 * max(gTune.y, 0.15);
    // 0.16 of the glyph box is not a monoline, it is a marker pen: adjacent
    // strokes merged and every letter turned into a blob. A real monoline
    // grotesque sits nearer 7 percent, and at that weight the counters in
    // the c, the r and the @ survive.
    float w  = 0.070;                        // stroke half width, glyph units

    // Bottom left, with a margin. Not centred: centred type is a title card,
    // and this is meant to be found rather than presented.
    //
    // TITLE SAFE. The bottom of the PICTURE is not the bottom of the frame:
    // the outro closes a letterbox over this shot, and bars of b hide
    // everything below y = -1 + 2b. Placed at a fixed -0.62 the second line
    // sat at 0.896 in screen uv against a matte cutting at 0.872, so the
    // author's own email address was sliced through the middle. Deriving the
    // position from the matte instead of from a constant means the type
    // stays legible whatever the edit does to the aspect ratio.
    float bottom = -1.0 + gTune.w * 2.0;
    // o0 is the FIRST line, so it clears the edge by the margin, plus the
    // second line's descender, plus the line spacing.
    float2 o0 = float2(-gTime.w + 0.20, bottom + 0.10 + sz * (0.22 + 1.5));
    float2 o1 = o0 - float2(0.0, sz * 1.5);

    // ---- bounding box -----------------------------------------------------
    // Seventeen glyphs were being evaluated at every pixel of a 1920x1080
    // frame to draw two words in one corner. Ninety-odd percent of the frame
    // is nowhere near the type; skipping it there is what pays for the
    // second and third light terms below. The window is smooth to the edge
    // so the halation cannot leave a rectangle behind it.
    float2 imin = float2(o1.x - 0.30 * sz, o1.y - 0.42 * sz);
    float2 imax = float2(o1.x + 6.25 * sz, o0.y + 1.00 * sz);
    // The margin is not slack, it is the only thing standing between the
    // halation and a visible rectangle: the window has to finish its work
    // out where the glow is already under the dither floor, or the place it
    // cuts reads as a straight edge in the dark.
    float  marg = 2.00 * sz;
    float2 dd   = max(imin - uv, uv - imax);
    float  e    = max(max(dd.x, dd.y), 0.0);
    if (e > marg) return float4(0.0, 0.0, 0.0, 1.0);
    float win = 1.0 - smoothstep(marg * 0.55, marg, e);

    // ---- the reveal -------------------------------------------------------
    // Eleven glyphs a second: fast enough that it is a signature being
    // written and not a crawl, slow enough that you can read it happening.
    // The first line clears in nine tenths of a second, the address is down
    // by two, and the rest of the shot is the caret blinking on it.
    float rate = 11.0 * max(gTune.x, 0.20);
    float t    = gTime.x - 0.26;             // let the dissolve land first
    float lead = (gTune.z < 0.5) ? 9.0 : 0.0;// seven slots of line, two of pause
    float p0   = t * rate;
    float p1   = t * rate - lead;

    // one virtual scanline of tracking error, so the type sits IN the signal
    // rather than on top of it. Tenths of a pixel - it must never be legible
    // as a wobble, only as the picture not being perfectly still.
    float2 q = uv;
    q.x += 0.0009 * sin(uv.y * 88.0 + gTime.x * 3.7) * (0.45 + gSync.x);

    float fw  = px * 1.5 / sz;               // one pixel, in glyph units
    float4 L0 = float4(0, 0, 0, 0), L1;
    if (gTune.z < 0.5) L0 = drawLine((q - o0) / sz, 0, 7,  p0, fw, w);
    L1 = drawLine((q - o1) / sz, 7, 10, p1, fw, w);

    float ink = max(L0.x, L1.x);
    float hot = max(L0.y, L1.y);
    float hal = max(L0.z, L1.z);

    // ---- the caret --------------------------------------------------------
    // It leads the writing, drops to the second line at the break, and once
    // the address is down it stays behind it and blinks at one hertz. A
    // secondary element with its own clock, which is what stops the last
    // second of a held shot from being a still.
    bool  onSecond = (p1 > 0.0) || (gTune.z >= 0.5);
    float2 co = onSecond ? o1 : o0;
    float  ch = onSecond ? L1.w : L0.w;
    float  cp = onSecond ? p1  : p0;
    float  done = saturate((p1 - 10.0) * 1.5);
    // solid while it is writing, blinking once it has nothing left to write
    float  blink = lerp(1.0, smoothstep(-0.22, 0.22, cos(gTime.x * 6.28)), done);
    // and it only exists at all once the first character has landed
    float  cOn = saturate(cp * 2.0) * blink;

    float2 cq = (q - co) / sz - float2(ch + 0.13, 0.0);
    float  cd = sdSeg(cq, float2(0.0, -0.02), float2(0.0, 0.60)) - w * 0.85;
    ink = max(ink, (1.0 - smoothstep(0.0, fw, cd)) * cOn * 0.85);
    hot = max(hot, exp(-max(cd, 0.0) / 0.22) * cOn * 0.60);

    // ---- the row the beam is writing --------------------------------------
    // A tube does not draw a letter, it draws a line and turns the beam on
    // in the middle of it. So the row under the active text carries a little
    // warmth, brightest just after a character lands, and it decays once the
    // line is finished. It has to hug the x-height: at a lazier falloff it
    // stops being a scan line and becomes a lit rectangle behind the type,
    // which is a caption box, which is the one thing this must not look like.
    float2 bp = (q - co) / sz;
    float  bx = max(max(-0.20 - bp.x, bp.x - ch - 0.20), 0.0);
    float  bt = saturate(cp * 2.0) * (0.30 + 0.70 * exp(-max(cp - 10.0, 0.0) * 1.2));
    float  band = 0.030 * bt
                * exp(-abs(bp.y - 0.29) / 0.17) * exp(-bx / 0.30)
                * (1.0 + 0.80 * exp(-frac(max(cp, 0.0)) * 6.0));

    // ---- phosphor ---------------------------------------------------------
    // Three terms, not one: the beam spot tight around the stroke, the
    // halation that scatters through the glass and puts a soft field around
    // the whole word, and the ink itself. The glow used to be doing the job
    // of the first two at once, which is why it read as a second, fatter
    // stroke instead of as light. Only the two GLOW terms move with the
    // music - the ink never does, so nothing here can flash.
    float lift = 1.0 + 0.34 * gVoice.z + 0.22 * gSync.w;
    float3 col = float3(0.68, 0.94, 0.72)
               * (ink + (hot * 0.18 + hal * 0.020 + band) * lift) * win;

    return float4(col * gTime.z, 1.0);
}
