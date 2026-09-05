// SC_LOGO: one solid CRTKAFA sculpture, then a flight into its conduit.
// Scene layout: word centred at (0,0,0), width 11.6, height 2.2,
// depth 1.1. Tunnel axis +Z, inner radius approximately 8.
// gTime.x is absolute intro seconds, 0..7.25; no modulo / logo repeats.
// gTune = (twist adjustment, metal warmth, emission adjustment, camera mode).
// Recommended (0,0,0,0). w < .5 uses introCamera below; w >= .5 uses
// gCam.xyz/gDir verbatim. gCam.w remains tan(vertical FOV/2) in BOTH modes;
// recommend .48, with .48 fallback for an unset value. gTime.w = aspect.
// For CPU meshes/depth compositing, mirror introCamera on CPU or use w=1.
// All other Scene fields have the same layout as scene.hlsl.
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
    float2 uv : TEXCOORD0;
};

float segment(float2 p, float2 a, float2 b)
{
    float2 v = b - a;
    return length(p - a - v * saturate(dot(p - a, v) / dot(v, v)));
}

// Stroke centre lines, NOT a bitmap: closed contours have real open counters.
// Each glyph is subsequently extruded, including the counter walls.
float glyph(float2 p, int id)
{
    float d = 100.0;
    if (id == 0) // C: chamfered bowl, right side visibly open.
    {
        d = segment(p, float2(.52,.84), float2(.25,1.0));
        d = min(d, segment(p, float2(.25,1), float2(-.35,1)));
        d = min(d, segment(p, float2(-.35,1), float2(-.58,.72)));
        d = min(d, segment(p, float2(-.58,.72), float2(-.58,-.72)));
        d = min(d, segment(p, float2(-.58,-.72), float2(-.35,-1)));
        d = min(d, segment(p, float2(-.35,-1), float2(.25,-1)));
        d = min(d, segment(p, float2(.25,-1), float2(.52,-.84)));
    }
    else if (id == 1) // R: closed upper bowl AND a diagonal lower leg.
    {
        d = segment(p, float2(-.55,-1), float2(-.55,1));
        d = min(d, segment(p, float2(-.55,1), float2(.28,1)));
        d = min(d, segment(p, float2(.28,1), float2(.55,.76)));
        d = min(d, segment(p, float2(.55,.76), float2(.55,.30)));
        d = min(d, segment(p, float2(.55,.30), float2(.28,.08)));
        d = min(d, segment(p, float2(.28,.08), float2(-.55,.08)));
        d = min(d, segment(p, float2(-.08,.08), float2(.60,-1)));
    }
    else if (id == 2) // T
    {
        d = segment(p, float2(-.60,1), float2(.60,1));
        d = min(d, segment(p, float2(0,1), float2(0,-1)));
    }
    else if (id == 3) // K: two diagonals meet the upright at its middle.
    {
        d = segment(p, float2(-.55,-1), float2(-.55,1));
        d = min(d, segment(p, float2(-.55,-.08), float2(.55,1)));
        d = min(d, segment(p, float2(-.25,.23), float2(.60,-1)));
    }
    else if (id == 5) // F: no lower arm, unlike the R bowl.
    {
        d = segment(p, float2(-.55,-1), float2(-.55,1));
        d = min(d, segment(p, float2(-.55,1), float2(.58,1)));
        d = min(d, segment(p, float2(-.55,.12), float2(.35,.12)));
    }
    else // A, at indices 4 and 6; triangular open counter.
    {
        d = segment(p, float2(-.62,-1), float2(0,1));
        d = min(d, segment(p, float2(0,1), float2(.62,-1)));
        d = min(d, segment(p, float2(-.38,-.24), float2(.38,-.24)));
    }
    return d - .125;
}

float box3(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0);
}

float word(float3 p)
{
    // Bounding box is a conservative step outside the glyph neighbourhood.
    float bound = box3(p, float3(5.91,1.19,.57));
    if (bound > .65) return bound;
    // Evaluate adjacent cells too: nearest-centre alone can skip a thinner
    // glyph at cell boundaries. There is NO repetition in world Z.
    int cell = (int)clamp(floor(p.x / 1.70 + 3.5),0.0,6.0);
    float d = 100.0;
    [loop] for (int j = -1; j <= 1; ++j)
    {
        int id = cell + j;
        if (id < 0 || id > 6) continue;
        float2 q = p.xy - float2((id - 3) * 1.70,0);
        float2 e = float2(glyph(q,id),abs(p.z) - .49);
        // Minkowski bevel gives lit edge curvature and .55 half thickness.
        float solid = min(max(e.x,e.y),0.0) + length(max(e,0.0)) - .06;
        d = min(d,solid);
    }
    return d;
}

float2 conduit(float3 p)
{
    float radius = length(p.xy);
    float twist = .115 + .035 * clamp(gTune.x,-1.0,1.0);
    float a = twist * p.z + .10 * sin(gTime.x * .40);
    float2 q = float2(cos(a)*p.x-sin(a)*p.y,
                      sin(a)*p.x+cos(a)*p.y);
    // Four solid helical rails inside a continuous enclosing wall.
    float rail = length(float2(abs(q.x)-7.65,q.y)) - .24;
    rail = min(rail,length(float2(q.x,abs(q.y)-7.65))-.24);
    // Twist metric bound for r <= 9; wall dominates outside that radius.
    rail *= .57;
    float wall = 8.55 - radius;
    float ringZ = (frac((p.z-2.5)/5.0+.5)-.5)*5.0;
    float ring = length(float2(radius-8.08,ringZ))-.30;
    float d = min(wall,ring);
    float material = 2.0;
    if (rail < d) { d = rail; material = 3.0; }
    return float2(d,material);
}

/* Small, diegetic title stamped into the lower lip of the conduit. This is
   intentionally a bitmap-sized mark rather than another giant overlay: the
   opening names itself once, then the journey owns the frame. */
static const uint titleRows[56] = {
    14,17,16,16,16,17,14, 30,17,17,30,20,18,17,
    4,10,17,17,31,17,17, 17,18,20,24,20,18,17,
    31,4,4,4,4,4,4, 14,17,17,17,17,17,14,
    10,10,31,10,31,10,10, 4,12,4,4,4,4,14
};
uint tinyRow(int id, int y) { return titleRows[clamp(id,0,7)*7+clamp(y,0,6)]; }

float tinyTitle(float2 p)
{
    // A finite luminous label on the z=-.65 face. Rows go DOWN the page.
    float2 q = float2(p.x + 3.465, -1.55-p.y) / .105;
    if (q.x < 0 || q.y < 0 || q.x >= 66 || q.y >= 7) return 0;
    int ci = (int)floor(q.x / 6);
    int co = (int)floor(q.x) - ci*6;
    int ro = clamp((int)floor(q.y),0,6);
    if (ci == 8 || co >= 5) return 0;
    int id = ci == 0 ? 0 : ci == 1 ? 1 : ci == 2 ? 2 :
             ci == 3 ? 0 : ci == 4 ? 3 : ci == 5 ? 4 :
             ci == 6 ? 1 : ci == 7 ? 5 : ci == 9 ? 6 : 7;
    uint bits = tinyRow(id,ro);
    return float((bits >> (4-co)) & 1u);
}

float2 scene(float3 p)
{
    float2 h = conduit(p);
    float w = word(p);
    if (w < h.x) h = float2(w,1.0);
    return h;
}

float3 normalAt(float3 p, float eps)
{
    float2 e = float2(1,-1)*eps;
    float3 n = e.xyy*scene(p+e.xyy).x + e.yyx*scene(p+e.yyx).x
             + e.yxy*scene(p+e.yxy).x + e.xxx*scene(p+e.xxx).x;
    return n * rsqrt(max(dot(n,n),1e-12));
}

float ambientOcclusion(float3 p, float3 n)
{
    float occ = 0.0;
    float weight = 1.0;
    [loop] for (int k=0; k<4; ++k)
    {
        float r = .09 + .18*k;
        occ += max(r-scene(p+n*r).x,0.0)*weight;
        weight *= .55;
    }
    return saturate(1.0-1.5*occ);
}

float shadow(float3 p, float3 l)
{
    float visibility = 1.0;
    float t = .035;
    [loop] for (int k=0; k<16; ++k)
    {
        float h = scene(p+l*t).x;
        visibility = min(visibility,12.0*max(h,0.0)/t);
        if (h < .002 || t > 7.0) break;
        t += clamp(h,.025,.85);
    }
    return saturate(visibility);
}

void introCamera(out float3 ro, out float3 fw, out float roll)
{
    // Read for 1.5 seconds, then pass the word before the 3.63s cut.
    float t = min(gTime.x,1.5)*.60 + max(gTime.x-1.5,0.0)*3.0;
    float rush = max(t-2.0,0.0);
    float lift = smoothstep(1.9,3.35,t);
    float settle = smoothstep(4.3,6.4,t);
    ro = float3(1.5*cos(t*.60)*(1.0-settle),
                .35 + 2.45*lift*(1.0-settle),
                -14.0+1.1*t+2.4*rush*rush);
    // Aim at word first, then turn forward BEFORE crossing its plane.
    float3 aim = float3(0,0,0)-ro;
    float3 readDir = normalize(float3(aim.xy,max(aim.z,3.0)));
    fw = normalize(lerp(readDir,float3(0,0,1),smoothstep(2.4,3.65,t)));
    roll = .025*sin(t*.9) + .12*settle;
}

float4 main(VSOut input, out float depth : SV_Depth) : SV_Target
{
    float3 ro, fw;
    float roll;
    introCamera(ro,fw,roll);
    if (gTune.w >= .5)
    {
        ro = gCam.xyz;
        fw = gDir.xyz * rsqrt(max(dot(gDir.xyz,gDir.xyz),1e-10));
        if (dot(fw,fw) < .5) fw = float3(0,0,1);
        roll = gDir.w;
    }
    float3 upHint = abs(fw.y) > .98 ? float3(0,0,1) : float3(0,1,0);
    float3 rt = normalize(cross(upHint,fw));
    float3 up = cross(fw,rt);
    float2 uv = float2(input.uv.x*2-1,1-input.uv.y*2);
    uv.x *= max(gTime.w,.1);
    float fov = max(gCam.w > .01 ? gCam.w : .48, .55/max(gTime.w,.25));
    float3 rd = normalize(fw + fov*(uv.x*(rt*cos(roll)+up*sin(roll))
                                             +uv.y*(up*cos(roll)-rt*sin(roll))));
    float t = .05;
    float material = 0.0;
    bool hit = false;
    depth = 0.0;
    [loop] for (int k=0; k<112; ++k)
    {
        float2 h = scene(ro+rd*t);
        if (h.x < max(.0015,t*.00055))
        {
            hit = true;
            material = h.y;
            break;
        }
        t += max(h.x*.82,.001);
        if (t > 145.0) break;
    }
    float3 deep = float3(.009,.017,.026);
    float3 col = deep;
    if (hit)
    {
        float3 p = ro+rd*t;
        depth = saturate(.05/max(t*dot(rd,fw),.001));
        float3 n = normalAt(p,max(.002,t*.00022));
        float ao = ambientOcclusion(p,n);
        float3 key = normalize(float3(-.45,.65,-.75));
        float diffuse = saturate(dot(n,key));
        float shade = shadow(p+n*.018,key);
        float fresnel = pow(1.0-saturate(dot(n,-rd)),3.0);
        float spec = pow(saturate(dot(n,normalize(key-rd))),48.0);
        float3 phosphor = lerp(float3(.35,.95,.69),float3(1,.65,.29),
                               saturate(.20+gTune.y));
        float pulse = 1.0+.12*saturate(gSync.x)+.07*saturate(gVoice.z);
        if (material < 1.5)
        {
            // Front and side are different alloys; bevel joins them visibly.
            float front = smoothstep(.65,.97,abs(n.z));
            float3 metal = lerp(float3(.12,.23,.26),float3(.65,.77,.71),front);
            col = metal*(.15*ao+1.05*diffuse*shade);
            col += float3(.65,.79,1)*spec*.75*shade;
            col += phosphor*fresnel*.38*ao;
            col += phosphor*front*(.08+.09*saturate(gTune.z))*pulse;
            col += float3(.16,.28,.42)*saturate(dot(n,normalize(float3(1,-.1,.5))))*.32*ao;
        }
        else
        {
            float3 lamp = float3(0,0,ro.z+16.0)-p;
            float lampDist = length(lamp);
            float lit = saturate(dot(n,lamp/max(lampDist,.001)));
            float band = .5+.5*sin(p.z*.19);
            float3 tint = lerp(float3(.21,.57,.48),float3(.61,.36,.16),band);
            col = tint*(.12+lit*2.2/(1.0+lampDist*lampDist*.008))*ao;
            col += float3(.20,.30,.42)*diffuse*.18;
            col += tint*fresnel*.18*ao;
            if (material > 2.5)
                col += phosphor*(.36+.18*saturate(gTune.z))*pulse;
        }
        col = lerp(deep,col,exp(-t*.010));
    }
    // Ray/plane hit is bounded in X, Y AND depth. No infinite extrusion.
    if (rd.z > .001 && ro.z < -.65) {
        float labelT = (-.65-ro.z)/rd.z;
        float2 xy = (ro+rd*labelT).xy;
        if (labelT > .05 && (!hit || labelT < t) &&
            abs(xy.x) < 3.7 && xy.y < -1.37 && xy.y > -2.48) {
            float ink = tinyTitle(xy);
            col = lerp(float3(.018,.038,.047),float3(.48,.91,.79),ink);
            depth = saturate(.05/(labelT*dot(rd,fw)));
        }
    }
    return float4(max(col,0.0)*saturate(gTime.z),1.0);
}
