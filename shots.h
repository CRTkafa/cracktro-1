/* ==========================================================================
   T H E   E D I T
   --------------------------------------------------------------------------
   The old demo had one continuous camera integral and decorated it. That is
   why 85% of it was a single shot: there was nowhere for a cut to live.

   Here a shot is data. Once that is true, jump cuts, match cuts, holds,
   reverses, whip pans and aspect changes are all just fields in a row, and
   the edit becomes something you write rather than something that falls out
   of a sine wave.

   Time is addressed in ROWS - one sixteenth note - never in seconds, so no
   cut can land off the music:

       row     = 5000 samples @ 44100     = 0.113378 s
       beat    = 4 rows                   = 0.453515 s
       bar     = 16 rows                  = 1.814059 s
       pattern = 32 rows                  = 3.628118 s
       song    = 96 bars = 1536 rows      = 174.15 s   (132.30 BPM)

   `eye` is where the camera is. `at` is ALWAYS a point in the world that it
   looks at - never a direction. Motion behaviours take their axis from
   (at - eye), so aiming a shot is one idea rather than two.

   FIXED 48-ORDER MUSIC MAP (32 rows/order):
       orders  0-1   rows    0-63    intro: Commodore tube, then CRTKAFA (7.256 s)
       orders  2-7   rows   64-255   synthwave
       orders  8-11  rows  256-383   single metal verse
       orders 12-15  rows  384-511   single chorus
       orders 16-39  rows  512-1279  evolving solo (87.075 s)
       orders 40-45  rows 1280-1471  arrival
       orders 46-47  rows 1472-1535  outro

   All runtime scenes are spatial. Legacy shader IDs remain stable; LOGO is
   appended for the parent's shader registration. Its shader owns the actual
   flypast and tune interpretation; this edit supplies one 32-row slot.
   No flash transitions, stutter or matte pumping. Two isolated one-beat
   bursts join phrases; other shots last two to four bars except the final
   three-beat solo pickup. Reactor camera distances stay outside radius six.
   ========================================================================== */

#define ROWS_PER_BEAT 4
#define ROWS_PER_BAR  16
#define SONG_ROWS     1536

/* BAR(n) is one-based, the way a musician counts. */
#define BAR(n)          (((n) - 1) * ROWS_PER_BAR)
#define BEAT(n, b)      (BAR(n) + ((b) - 1) * ROWS_PER_BEAT)
#define ROWAT(n, b, r)  (BEAT(n, b) + (r))

/* ---- which pixel shader draws this shot -------------------------------- */
enum {
    SC_EYE = 0,        /* macro cat eye                                     */
    SC_CATHEDRAL,      /* the organ hall                                    */
    SC_VOID,           /* monolith in the white void                        */
    SC_HORIZON,        /* synthwave: grid, banded sun, ridge, slabs         */
    SC_KALEIDO,        /* kaleidoscopic IFS tunnel - the acid trip.        */
                       /* travels along its axis only: a crane or a track  */
                       /* walks the camera out of the tunnel and the frame */
                       /* goes black.                                      */
    SC_FRAMES,         /* flat 2D design frames: rules, blocks, big type    */
    SC_PLINTH,         /* vaporwave plinth room lit by a wall of CRTs       */
    SC_DRIVE,          /* the road at night, from inside the car            */
    SC_CORRIDOR,       /* the liminal corridor that never arrives           */
    SC_POWEROFF,       /* the tube collapsing to a line, then a point       */
    SC_BURST,          /* streaks past the camera at the fastest passage    */
    SC_C64,            /* the original boot text inside a spatial CRT      */
    SC_SIGNOFF,        /* crt.fyi and hi@crt.fyi, small, once              */
    SC_LOGO,          /* one spatial CRTKAFA flypast, intro only          */
    SC_REACTOR,       /* finite porous core, broken rings and shards      */
    SC_ORBITAL,       /* gas giant, eclipse and luminous filaments        */
    SC_COUNT
};

/* ---- what the camera does ---------------------------------------------- */
enum {
    CAM_HOLD = 0,   /* completely still. the demo has never had one of these */
    CAM_PUSH,       /* forward, towards `at`                                 */
    CAM_PULL,       /* backwards, away from it - a reveal                    */
    CAM_TRACK,      /* lateral dolly across the look axis                    */
    CAM_CRANE,      /* vertical                                              */
    CAM_ORBIT,      /* around `at`                                           */
    CAM_WHIP,       /* the look sweeps fast across the shot                  */
    CAM_DRIFT       /* held, but breathing                                   */
};

/* ---- what, if anything, is IN the shot --------------------------------- */
enum {
    ACT_NONE = 0,
    ACT_CAT_RUN,        /* the black cat, running. 24 baked frames          */
    ACT_CAT_STILL,      /* the same mesh, held on one frame                 */
    ACT_CAT_SWARM,      /* several of them, instanced across the frame      */
    ACT_TARDIS,         /* single-frame blue-box callback                   */
    ACT_SPIN_CAT        /* one short spinning meme cut                      */
};

/* ==========================================================================
   T H E   G R A D E
   --------------------------------------------------------------------------
   The CRT pass quantises luminance into a four-stop ramp, so the ramp is
   what the picture is built out of: every pixel is re-coloured through it,
   and then the scene's own hue is mixed back on top by hueKeep - which is
   why the stops are felt everywhere without flattening the scenes to four
   literal colours. Changing them is still a far stronger instrument than
   multiplying the output by a tint, and it makes the step count the single biggest lever in the
   renderer: at seven steps the picture is a woodcut, at twelve it is nearly
   continuous. Both were hardcoded until now, which is why 174 seconds of
   demo all looked like the same afternoon.

   A grade belongs to the SECTION, not to the shot. The music is what changes
   colour; the camera just happens to be pointing somewhere while it does.
   So this is a schedule in rows, exactly like the arrangement it follows,
   and not a field in the shot table.
   ========================================================================== */
enum { GR_COLD = 0, GR_WARM, GR_NEON, GR_BLEACH, GR_PHOSPHOR, GR_COUNT };

typedef struct {
    float ramp[4][4];   /* the four stops. this is the whole palette         */
    /* How much of the SOURCE hue is allowed back on top of the ramp. Read it
       backwards from how it sounds: 1.0 means the scene's own colour wins and
       the palette is barely felt, 0.0 means the frame is made of nothing but
       the four stops. So the grades that exist to be noticed sit low. */
    float hueKeep;
    float steps;        /* quantiser levels                                  */
    float dither;
    float exposure;
} Grade;

static const Grade g_grades[GR_COUNT] = {
    /* COLD - the metal, the breakdown, the corridors. A blue black, neutral
       midtones, a slightly warm white. This is the look the whole demo had. */
    { { {0.030f,0.034f,0.048f,0.0f}, {0.150f,0.180f,0.235f,0.0f},
        {0.520f,0.545f,0.585f,0.0f}, {0.980f,0.965f,0.940f,0.0f} },
      0.62f, 10.0f, 0.85f, 1.00f },

    /* WARM - the turn, the chorus, and the arrival: everywhere the music is
       at its biggest. Amber shadows, and the ramp opens up a step. */
    { { {0.042f,0.031f,0.030f,0.0f}, {0.205f,0.150f,0.120f,0.0f},
        {0.600f,0.530f,0.430f,0.0f}, {1.000f,0.960f,0.880f,0.0f} },
      0.50f, 11.0f, 0.82f, 1.05f },

    /* NEON - the synthwave half and the solo. A magenta-leaning shadow and a
       cyan white is most of the genre in two numbers. Measured at hueKeep
       0.78 this came out plain red: the horizon and the drive are both lit
       by an orange sun, and at that setting their own hue simply overrode
       the palette. Half is where the magenta survives contact with them. */
    { { {0.048f,0.026f,0.062f,0.0f}, {0.210f,0.115f,0.250f,0.0f},
        {0.510f,0.470f,0.690f,0.0f}, {0.890f,0.980f,1.000f,0.0f} },
      0.50f, 12.0f, 0.90f, 1.06f },

    /* BLEACH - the void, and the design frames. Almost no shadow at all and
       few enough steps that the dither stops being texture and becomes the
       subject. Two bars of this is why the solo lands. */
    { { {0.125f,0.128f,0.138f,0.0f}, {0.430f,0.435f,0.450f,0.0f},
        {0.765f,0.770f,0.780f,0.0f}, {1.000f,1.000f,0.995f,0.0f} },
      0.35f,  7.0f, 1.00f, 1.00f },

    /* PHOSPHOR - the eye, the C64 screen, the power-off, the sign-off. One
       hue and eight steps: it should read as a tube, not as a render. */
    { { {0.018f,0.030f,0.022f,0.0f}, {0.085f,0.225f,0.115f,0.0f},
        {0.350f,0.645f,0.395f,0.0f}, {0.870f,1.000f,0.895f,0.0f} },
      0.30f,  8.0f, 0.95f, 1.02f },
};

/* Section keys follow the fixed 48-order score, including solo chapters. */
typedef struct { short row; unsigned char grade; } GradeKey;

static const GradeKey g_gradeKeys[] = {
    { BAR(1),  GR_COLD },   /* orders 0-1: logo */
    { BAR(5),  GR_NEON },   /* orders 2-7: synthwave */
    { BAR(17), GR_COLD },   /* orders 8-11: single verse */
    { BAR(25), GR_WARM },   /* orders 12-15: single chorus */
    { BAR(33), GR_NEON },   /* solo I: space, clean lead */
    { BAR(45), GR_COLD },   /* solo II: angular, low architecture */
    { BAR(57), GR_WARM },   /* solo III: expansion and ascent */
    { BAR(66), GR_PHOSPHOR }, /* three-bar green iris climax */
    { BAR(69), GR_NEON },   /* solo IV: broad release */
    { BAR(81), GR_WARM },   /* orders 40-45: arrival */
    { BAR(93), GR_COLD },   /* orders 46-47: withdrawal */
};
#define GRADE_KEYS ((int)(sizeof(g_gradeKeys) / sizeof(g_gradeKeys[0])))

/* Some scenes carry their own look wherever they appear. A green cat eye in
   the middle of the synthwave section is a callback rather than a mistake,
   and a C64 screen graded warm would simply be wrong. GR_FOLLOW means "take
   the section's grade", which is what most scenes do. */
#define GR_FOLLOW 0xFF
static const unsigned char g_sceneGrade[SC_COUNT] = {
    GR_PHOSPHOR,   /* SC_EYE       */
    GR_FOLLOW,     /* SC_CATHEDRAL */
    GR_BLEACH,     /* SC_VOID      */
    GR_FOLLOW,     /* SC_HORIZON   */
    GR_FOLLOW,     /* SC_KALEIDO   */
    GR_BLEACH,     /* SC_FRAMES    */
    GR_FOLLOW,     /* SC_PLINTH    */
    GR_FOLLOW,     /* SC_DRIVE     */
    GR_FOLLOW,     /* SC_CORRIDOR  */
    GR_PHOSPHOR,   /* SC_POWEROFF  */
    GR_FOLLOW,     /* SC_BURST     */
    GR_PHOSPHOR,   /* SC_C64       */
    GR_PHOSPHOR,   /* SC_SIGNOFF   */
    GR_FOLLOW,     /* SC_LOGO      */
    GR_FOLLOW,     /* SC_REACTOR   */
    GR_FOLLOW      /* SC_ORBITAL   */
};

/* ==========================================================================
   T H E   M A T T E
   --------------------------------------------------------------------------
   Full frame throughout. The ending withdraws through 3D space; the parent
   renderer supplies the final darkness fade, without an aspect-ratio cue.
   ========================================================================== */
typedef struct {
    short row;      /* when it starts moving                                 */
    short rows;     /* how long it takes. 0 is instant                       */
    float bars;     /* fraction of the height hidden at each edge.
                       0.128 turns 16:9 into 2.39:1, 0.056 into 2.00:1       */
} MatteKey;

static const MatteKey g_mattes[] = {
    { BAR(1), 0, 0.000f },
};
#define MATTE_KEYS ((int)(sizeof(g_mattes) / sizeof(g_mattes[0])))

static float matteAt(double row)
{
    int i, k = 0;
    float from, u;
    for (i = 0; i < MATTE_KEYS; i++)
        if ((double)g_mattes[i].row <= row) k = i;

    if (g_mattes[k].rows <= 0) return g_mattes[k].bars;

    u = (float)((row - (double)g_mattes[k].row) / (double)g_mattes[k].rows);
    if (u >= 1.0f) return g_mattes[k].bars;
    if (u < 0.0f)  u = 0.0f;

    /* The one before it is where we are coming from - and for the first key
       that is the LAST one, because the demo loops. The outro closes the
       bars to exactly where the cold open starts them, so the wrap is
       continuous rather than a snap. */
    from = (k > 0) ? g_mattes[k - 1].bars : g_mattes[MATTE_KEYS - 1].bars;
    u = u * u * (3.0f - 2.0f * u);        /* ease, so it reads as a move */
    return from + (g_mattes[k].bars - from) * u;
}

/* ---- how we get INTO this shot ----------------------------------------- */
enum {
    TR_CUT = 0,     /* hard. the default, and it should be                   */
    TR_FLASH,       /* white blown through the cut                           */
    TR_BLACK,       /* up from black                                         */
    TR_DISSOLVE,    /* both shots rendered and crossfaded                    */
    TR_MATCH,       /* a hard cut placed so a shape survives it              */
    TR_WHIPIN       /* smeared in - pairs with CAM_WHIP on the shot before   */
};

typedef struct {
    short         start;    /* first row of the shot                         */
    unsigned char scene;
    unsigned char cam;
    unsigned char trans;    /* transition INTO this shot                     */
    unsigned char transRows;/* how long that transition lasts, in rows       */
    float         eye[3];   /* where the camera is                           */
    float         at[3];    /* the point it looks at                         */
    float         speed;    /* units per second, or radians per second       */
    float         fov;      /* tan(vfov/2)                                   */
    float         roll;
    float         tune[4];  /* handed to the scene shader untouched          */

    /* An actor is a mesh standing in the scene, and it is addressed in the
       same language as everything else here: where it starts, where it ends,
       and how fast its cycle runs in FRAMES PER ROW. Tying the animation to
       the song's row clock rather than to a wall clock is the whole point -
       the old demo stepped the cat against wall-clock seconds and it never
       once landed on the beat. */
    unsigned char actor;
    float         from[3];  /* world position at the start of the shot       */
    float         to[3];    /* and at the end of it                          */
    float         actScale;
    float         actRate;  /* animation frames per row. 3.0 is a lope       */

    /* STUTTER. The clock the picture reads, quantised to this many rows -
       0 is smooth, 1.0 holds each frame for a full sixteenth, 2.0 for an
       eighth note. The edit clock underneath it keeps running, so the cut
       still lands where it was written; only what is inside the frame
       judders.

       It has to be COARSER than the motion it quantises or it does nothing
       at all, which is a thing you cannot see by reading the table - the
       self test measures it per shot.

       Nothing here is decoded video, so there is nothing to datamosh and no
       frame ring worth carrying: freezing a procedural picture means holding
       the time you hand it. Which is also why the actor freezes with the
       scene rather than sliding through a held frame - they read the same
       clock, so they stop together or not at all. */
    float         stutter;
} Shot;

/* --------------------------------------------------------------------------
   The 48-order spatial edit. Start rows determine actual shot durations.
   Cat actors retain four appearances; their from/to paths span the next cut.
   Kaleido moves are strictly axial. Plinth paths stay in the centre aisle.
   Source shaders, C64 prose and music are frozen by this edit.
   -------------------------------------------------------------------------- */
static const Shot g_shots[] = {

/* INTRO: the Commodore tube gets the first bar: short, physical, phosphor-lit
   and already inside the 3D world. It is the threshold, not a waiting room. */
{ BAR(1), SC_C64, CAM_PUSH, TR_CUT, 0,
  {0.0f, 0.0f, -7.0f}, {0.0f, 0.0f, 0.0f}, 0.35f, 0.58f, 0.0f,
  {1.0f, 0.72f, 0.16f, 0.0f} },

/* The spatial CRTKAFA flypast occupies intro bars 3-4.
   The mark appears once and is then left behind for the rest of the run. */
{ BAR(3), SC_LOGO, CAM_HOLD, TR_CUT, 0,
  {0.0f, 0.0f, -12.0f}, {0.0f, 0.0f, 0.0f}, 0.0f, 0.48f, 0.0f,
  {0.0f, 0.0f, 0.0f, 0.0f} },

/* SYNTHWAVE: first a distant TARDIS callback, almost swallowed by the void.
   It is there early, but never becomes a mascot or a repeated prop. */
{ BAR(5), SC_BURST, CAM_HOLD, TR_CUT, 0,
  {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 10.0f}, 0.0f, 0.6f, 0.0f,
  {30.0f, 0.10f, 0.12f, 0.0f},
  ACT_TARDIS, {-2.4f, 0.2f, 8.0f}, {2.9f, 0.6f, 4.4f}, 2.1f, 0.0f },

/* Immediate tunnel acceleration after the one-bar TARDIS crossing. */
{ BAR(6), SC_KALEIDO, CAM_PUSH, TR_CUT, 0,
  {0.15f, -0.1f, 0.0f}, {0.15f, -0.1f, 10.0f}, 7.0f, 0.74f, 0.08f,
  {0.15f, 1.45f, 0.25f, 1.0f} },

/* First running cat, near enough to read during the initial 15 seconds. */
{ BAR(8), SC_CORRIDOR, CAM_TRACK, TR_CUT, 0,
  {-0.8f, 0.9f, 0.0f}, {0.0f, 0.8f, 4.0f}, 0.3f, 0.58f, 0.0f,
  {0.24f, 0.68f, 0.3f, 0.0f},
  ACT_CAT_RUN, {-1.2f, 0.60f, 3.4f}, {1.3f, 0.60f, 3.4f}, 1.35f, 2.5f },

/* Rise over the ridge; small distant sun and deeper haze. */
{ BAR(10), SC_HORIZON, CAM_CRANE, TR_CUT, 0,
  {5.0f, 2.1f, -14.0f}, {0.0f, 4.0f, 40.0f}, 0.45f, 0.58f, 0.0f,
  {58.0f, 0.14f, 0.86f, 0.45f} },

{ BAR(12), SC_REACTOR, CAM_ORBIT, TR_CUT, 0,
  {-5.0f, 2.0f, -10.0f}, {0.0f, 0.0f, 0.0f}, 0.22f, 0.45f, 0.0f,
  {0.0f, 1.0f, 0.15f, 0.3f} },

/* Waveform gallery, high transverse move, mirror floor. */
{ BAR(14), SC_PLINTH, CAM_TRACK, TR_CUT, 0,
  {-2.0f, 6.0f, 8.0f}, {0.0f, 7.2f, 30.0f}, 0.3f, 0.58f, 0.0f,
  {1.1f, 0.6f, 0.2f, 0.65f} },

/* VERSE: low left arcade, rising sightline into the organ rank. */
{ BAR(17), SC_CATHEDRAL, CAM_PUSH, TR_CUT, 0,
  {-6.0f, -3.0f, -22.0f}, {-3.0f, 8.0f, 26.0f}, 2.0f, 0.64f, 0.0f,
  {0.15f, 0.4f, 0.0f, 0.0f} },

/* Cat 1: +X jamb crossing, 32-row run, fixed z matches the mesh facing. */
{ BAR(19), SC_CORRIDOR, CAM_TRACK, TR_CUT, 0,
  {-1.0f, 1.6f, 0.0f}, {1.0f, 1.5f, 8.0f}, 0.18f, 0.62f, 0.0f,
  {0.26f, 0.66f, 0.3f, 0.0f},
  ACT_CAT_RUN, {-0.65f, 0.56f, 5.0f}, {0.65f, 0.56f, 5.0f}, 1.25f, 3.0f },

/* Night drive: close asphalt and distant lamps supply layered parallax. */
{ BAR(21), SC_DRIVE, CAM_HOLD, TR_CUT, 0,
  {0.0f, 1.3f, 0.0f}, {0.0f, 1.3f, 20.0f}, 0.0f, 0.70f, 0.0f,
  {22.0f, 0.25f, 0.05f, 0.65f} },

/* Cat 2: +X floor reflection crossing over 32 rows. */
{ BAR(23), SC_CORRIDOR, CAM_TRACK, TR_CUT, 0,
  {0.5f, 0.55f, 0.0f}, {0.0f, -0.35f, 6.0f}, -0.25f, 0.66f, 0.0f,
  {0.22f, 0.7f, 0.5f, 0.0f},
  ACT_CAT_RUN, {-0.65f, 0.63f, 4.2f}, {0.65f, 0.63f, 4.2f}, 1.4f, 3.0f },

/* CHORUS: crane up through nave, broad organ-and-vault composition. */
{ BAR(25), SC_CATHEDRAL, CAM_CRANE, TR_CUT, 0,
  {3.0f, -2.0f, -16.0f}, {0.0f, 10.0f, 34.0f}, 0.65f, 0.78f, 0.0f,
  {0.55f, 0.35f, -0.1f, 0.2f} },

/* Wide low sun, level travel keeps camera above the grid. */
{ BAR(27), SC_HORIZON, CAM_PUSH, TR_CUT, 0,
  {-5.0f, 3.0f, 0.0f}, {-5.0f, 3.0f, 40.0f}, 5.0f, 0.76f, 0.0f,
  {44.0f, 0.52f, 0.62f, 0.28f} },

/* A luminous filament sculpture turns independently of the lateral camera. */
{ BAR(29), SC_ORBITAL, CAM_TRACK, TR_CUT, 0,
  {0.0f, 1.0f, -11.0f}, {0.0f, 0.0f, 0.0f}, 0.30f, 0.445f, 0.0f,
  {2.0f, 1.0f, 1.0f, 0.15f} },

/* Four-sector entry, axial movement keeps the camera inside the bore. */
{ BAR(31), SC_KALEIDO, CAM_PUSH, TR_CUT, 0,
  {0.2f, -0.16f, 0.0f}, {0.2f, -0.16f, 6.0f}, 4.0f, 0.72f, 0.0f,
  {0.1f, 1.35f, 0.2f, 0.0f} },

/* One beat only, restrained connective accent into the solo. */
{ BEAT(32,4), SC_BURST, CAM_DRIFT, TR_CUT, 0,
  {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 6.0f}, 0.0f, 0.64f, 0.0f,
  {70.0f, 0.3f, 0.55f, 0.12f} },

/* SOLO I: delayed fracture, orbit uncovers suspended slab depth. */
{ BAR(33), SC_VOID, CAM_ORBIT, TR_CUT, 0,
  {-6.0f, 3.0f, -22.0f}, {0.0f, 4.8f, 0.0f}, 0.055f, 0.48f, 0.0f,
  {0.3f, 0.6f, 0.0f, 1.4f} },

/* Compact reactor: close low orbit, radius 12.25, tighter portrait lens. */
{ BAR(36), SC_REACTOR, CAM_ORBIT, TR_CUT, 0,
  {-5.0f, -2.0f, -11.0f}, {0.0f, 0.0f, 0.0f}, 0.12f, 0.38f, 0.05f,
  {0.0f, 0.7f, 0.15f, 0.2f} },

/* Cat 3: 48-row crane, y ends at 2.30; run uses actual shot span. */
{ BAR(39), SC_CORRIDOR, CAM_CRANE, TR_CUT, 0,
  {0.0f, 1.65f, 0.0f}, {0.0f, 2.5f, 8.0f}, 0.12f, 0.65f, 0.0f,
  {0.24f, 0.68f, 0.2f, 0.0f},
  ACT_CAT_RUN, {-0.7f, 0.61f, 5.8f}, {0.7f, 0.61f, 5.8f}, 1.35f, 3.0f },

/* Faster night drive as the solo answers. */
{ BAR(42), SC_DRIVE, CAM_HOLD, TR_CUT, 0,
  {0.0f, 1.3f, 0.0f}, {0.0f, 1.3f, 20.0f}, 0.0f, 0.76f, 0.0f,
  {42.0f, 0.80f, 0.45f, 0.9f} },

/* SOLO II: orbit the eclipse and its intersecting accretion sheets. */
{ BAR(45), SC_ORBITAL, CAM_ORBIT, TR_CUT, 0,
  {0.0f, 2.9f, -13.0f}, {0.0f, 0.0f, 0.0f}, 0.09f, 0.425f, 0.0f,
  {1.0f, 0.8f, 1.0f, -0.18f} },

/* Six-sector reverse passage; axis remains fixed, no sideways wall impact. */
{ BAR(48), SC_KALEIDO, CAM_PULL, TR_CUT, 0,
  {-0.2f, 0.2f, 0.0f}, {-0.2f, 0.2f, 6.0f}, 4.0f, 0.64f, 0.0f,
  {0.35f, 1.5f, 0.4f, 1.0f} },

/* Close moving monitor wall; 'signal found' appears once inside one CRT. */
{ BAR(51), SC_PLINTH, CAM_TRACK, TR_CUT, 0,
  {3.0f, 7.0f, 9.0f}, {0.0f, 7.2f, 30.0f}, -0.4f, 0.58f, 0.0f,
  {1.0f, 0.4f, 0.2f, 0.15f} },

/* Expanded reactor: eye-level lateral reveal, distance 12.33..12.47. */
{ BAR(54), SC_REACTOR, CAM_TRACK, TR_CUT, 0,
  {6.0f, 4.0f, -10.0f}, {0.0f, 0.0f, 0.0f}, -0.35f, 0.42f, 0.0f,
  {1.0f, 1.0f, 0.4f, 0.55f} },

/* SOLO III: organ ascent, eye ends below vault spring. */
{ BAR(57), SC_CATHEDRAL, CAM_CRANE, TR_CUT, 0,
  {-3.0f, -2.0f, -20.0f}, {0.0f, 11.0f, 36.0f}, 0.9f, 0.7f, 0.0f,
  {0.35f, 0.4f, -0.2f, 0.25f} },

/* Accelerating debris passage with restrained warm highlights. */
{ BAR(60), SC_BURST, CAM_DRIFT, TR_CUT, 0,
  {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 10.0f}, 0.0f, 0.78f, -0.15f,
  {105.0f, 0.48f, 0.2f, 0.1f} },

/* The sole gas-giant flyby: a tilted ring plane and a lit atmosphere. */
{ BAR(63), SC_ORBITAL, CAM_TRACK, TR_CUT, 0,
  {0.0f, 3.8f, -12.0f}, {0.0f, 0.0f, 0.0f}, 0.35f, 0.404f, 0.0f,
  {0.0f, 1.0f, 1.0f, 0.22f} },

/* Ten-sector open iris hall; forward travel, wider architecture. */
{ BAR(66), SC_KALEIDO, CAM_PUSH, TR_CUT, 0,
  {0.32f, -0.25f, 0.0f}, {0.32f, -0.25f, 6.0f}, 6.0f, 0.8f, 0.0f,
  {0.65f, 1.85f, 0.7f, 2.0f} },

/* SOLO IV: close collapse study, gentle withdrawal 12.05 -> 12.92 over 64 rows.
   Narrow lens keeps the shrinking core substantial through the whole phrase. */
{ BAR(69), SC_REACTOR, CAM_PULL, TR_CUT, 0,
  {-3.0f, 2.0f, -11.5f}, {0.0f, 0.0f, 0.0f}, 0.12f, 0.35f, 0.0f,
  {3.0f, 1.5f, 0.95f, 1.0f} },

/* Fast axial tunnel passage during the dense solo run. */
{ BAR(73), SC_KALEIDO, CAM_PUSH, TR_CUT, 0,
  {0.1f, 0.1f, 0.0f}, {0.1f, 0.1f, 10.0f}, 10.0f, 0.76f, 0.25f,
  {0.35f, 1.7f, 0.45f, 0.0f} },

/* Lateral +X run over 32 rows, camera tracks beside the cat. */
{ BAR(77), SC_CORRIDOR, CAM_TRACK, TR_CUT, 0,
  {-0.65f, 1.35f, 0.0f}, {0.15f, 1.15f, 6.0f}, 0.12f, 0.7f, 0.0f,
  {0.2f, 0.75f, 0.6f, 0.0f},
  ACT_CAT_RUN, {-0.7f, 0.6f, 4.8f}, {0.7f, 0.6f, 4.8f}, 1.1f, 3.0f },

/* One-bar spinning meme cat, then a short skyline pickup into arrival. */
{ BAR(79), SC_BURST, CAM_HOLD, TR_CUT, 0,
  {0.0f, 0.1f, -4.0f}, {0.0f, 0.1f, 0.0f}, 0.0f, 0.62f, 0.0f,
  {40.0f, 0.15f, 0.2f, 0.0f},
  ACT_SPIN_CAT, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, 1.5f, 0.55f },

{ BAR(80), SC_HORIZON, CAM_CRANE, TR_CUT, 0,
  {-6.0f, 2.5f, -14.0f}, {0.0f, 4.0f, 40.0f}, 0.55f, 0.72f, 0.0f,
  {12.0f, 0.36f, 0.44f, 0.6f} },

/* One beat into arrival, no white-flash transition. */
{ BEAT(80,4), SC_BURST, CAM_DRIFT, TR_CUT, 0,
  {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 6.0f}, 0.0f, 0.64f, 0.0f,
  {84.0f, 0.35f, 0.5f, 0.1f} },

/* ARRIVAL: central nave opens, full rank and stained glass. */
{ BAR(81), SC_CATHEDRAL, CAM_PUSH, TR_CUT, 0,
  {0.0f, -2.0f, -30.0f}, {0.0f, 8.0f, 50.0f}, 1.6f, 0.76f, 0.0f,
  {0.25f, 0.4f, -0.2f, 0.25f} },

{ BAR(83), SC_ORBITAL, CAM_PULL, TR_CUT, 0,
  {4.0f, -1.5f, -10.0f}, {0.0f, 0.0f, 0.0f}, 0.55f, 0.64f, -0.12f,
  {1.0f, 1.5f, 0.9f, 0.65f} },

/* Two-bar monitor-wall inscription: 'stay strange'. */
{ BAR(85), SC_PLINTH, CAM_CRANE, TR_CUT, 0,
  {0.0f, 6.5f, 5.0f}, {0.0f, 7.2f, 30.0f}, 0.18f, 0.60f, 0.0f,
  {1.1f, 0.6f, 0.15f, 0.7f} },

{ BAR(87), SC_VOID, CAM_PULL, TR_CUT, 0,
  {7.0f, 5.0f, -16.0f}, {0.0f, 4.0f, 0.0f}, 0.4f, 0.62f, 0.0f,
  {-0.4f, 0.4f, 0.8f, 0.0f} },

/* Broad sunset release with sustained lateral parallax. */
{ BAR(89), SC_HORIZON, CAM_TRACK, TR_CUT, 0,
  {-5.0f, 3.0f, -10.0f}, {0.0f, 4.0f, 40.0f}, 0.8f, 0.82f, 0.0f,
  {6.0f, 0.6f, 0.72f, 0.34f} },

/* OUTRO: retreat from the filament sculpture. */
{ BAR(93), SC_ORBITAL, CAM_PULL, TR_CUT, 0,
  {3.0f, 2.0f, -12.0f}, {0.0f, 0.0f, 0.0f}, 1.0f, 0.52f, 0.0f,
  {2.0f, 0.45f, 0.7f, -0.40f} },

/* Last two bars: withdraw through the dark nave; parent applies endfade. */
{ BAR(95), SC_CATHEDRAL, CAM_PULL, TR_CUT, 0,
  {0.0f, -1.0f, -26.0f}, {0.0f, 5.0f, 46.0f}, 3.0f, 0.62f, 0.0f,
  {0.3f, -0.7f, 0.35f, -0.7f} },
};

#define NSHOTS ((int)(sizeof(g_shots) / sizeof(g_shots[0])))
