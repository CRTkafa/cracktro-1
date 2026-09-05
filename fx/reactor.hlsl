// SOLO orders 16-39. Bounded, opaque sculpture; host owns camera and grading.
// Tune: variant [0,3], motion [0,2], cyan->magenta accent [0,1], deform [0,1].
cbuffer Scene : register(b0)
{
    float4 gTime;
    float4 gCam;
    float4 gDir;
    float4 gTune;
    float4 gSync;
    float4 gVoice;
};

struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

static float sClock, sExpand, sFly, sCollapse, sDeform;
static float2 sCoreSpin;
static float2 sRingSpin[3];
static float2 sRingTilt[3];
static float sRadius[3];
static float sLift[3];

float3 safeUnit(float3 v, float3 fallback)
{
    float d = dot(v, v);
    return d > 1e-10 ? v * rsqrt(max(d, 1e-10)) : fallback;
}

float2 turn(float2 p, float2 cs)
{
    return float2(cs.x*p.x - cs.y*p.y, cs.y*p.x + cs.x*p.y);
}

float box3(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float box2(float2 p, float2 b)
{
    float2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// x conservative distance, y material: porous alloy / mechanical / hot heart.
float2 field(float3 p)
{
    float3 q = p;
    q.xz = turn(q.xz, sCoreSpin);
    q.xy = turn(q.xy, float2(0.9393727, 0.3428978));
    float collapse = 1.0 - 0.48*sCollapse;
    float3 axes = float3(1.85, 1.34, 1.12)
                + sExpand*float3(0.90, 0.66, 0.65);
    axes *= collapse;
    // Ellipsoid bound and gyroid both use lower distance bounds.
    float shell = (length(q / axes) - 1.0) * axes.z;
    float frequency = lerp(2.65, 2.05, sExpand);
    float3 u = q*frequency + float3(0.0, sClock*0.27, 0.0);
    float gy = dot(sin(u), cos(u.yzx));
    // Gradient norm <= 2*sqrt(3)*frequency. No spatial warp hidden in steps.
    float thickness = 0.36 + 0.15*sDeform
                    + 0.08*sin(sClock*1.1);
    float porous = (abs(gy) - thickness) / (3.465*frequency);
    float2 result = float2(max(shell, porous), 0.0);

    // An elongated counter-rotating heart is visible through real holes.
    float3 heart = p;
    heart.yz = turn(heart.yz, sCoreSpin.yx);
    float h = (dot(abs(heart), float3(1.0, 0.72, 1.0))
             - (0.65 - 0.22*sCollapse)) / 1.588;
    if (h < result.x) result = float2(h, 2.0);

    [loop] for (int j = 0; j < 3; ++j)
    {
        float3 r = p;
        r.yz = turn(r.yz, sRingTilt[j]);
        r.xy = turn(r.xy, sRingSpin[j]);
        r.z -= sLift[j];
        float radial = length(r.xy) - sRadius[j];
        // Bevelled rectangular cross-section, open quadrant and severed ends.
        float arc = box2(float2(radial, r.z), float2(0.18, 0.13)) - 0.075;
        arc = max(arc, -max(r.x, r.y));
        arc = max(arc, 0.22 + 0.28*sFly - abs(r.y));
        if (arc < result.x) result = float2(arc, 1.0);

        // Broad pieces at the outer radius cross IN FRONT of the lattice.
        // Opposed pieces are displaced in depth, not camera-facing sprites.
        float3 shard = r;
        float side = r.x < 0.0 ? -1.0 : 1.0;
        shard.x = abs(shard.x) - (sRadius[j] + 0.12);
        shard.y -= side * (0.75 + 0.25*sFly);
        shard.z -= side * (0.25 + 0.38*sFly);
        shard.yz = turn(shard.yz, float2(0.8, 0.6));
        float piece = box3(shard, float3(0.25, 0.55, 0.18)) - 0.075;
        if (piece < result.x) result = float2(piece, 1.0);
    }
    // Hard guarantee for the analytic ray interval, including all tune values.
    result.x = max(result.x, length(p) - 5.95);
    return result;
}

float3 normalAt(float3 p, float e)
{
    float3 a = float3(1.0, -1.0, -1.0);
    float3 b = float3(-1.0, -1.0, 1.0);
    float3 c = float3(-1.0, 1.0, -1.0);
    float3 d = float3(1.0, 1.0, 1.0);
    return safeUnit(a*field(p+a*e).x + b*field(p+b*e).x
                  + c*field(p+c*e).x + d*field(p+d*e).x,
                    float3(0.0, 1.0, 0.0));
}

float4 main(VSOut i, out float depth : SV_Depth) : SV_Target
{
    depth = 0.0;
    float variant = clamp(gTune.x, 0.0, 3.0);
    sExpand = saturate(1.0 - abs(variant - 1.0));
    sFly = saturate(1.0 - abs(variant - 2.0));
    sDeform = saturate(gTune.w);
    sClock = gTime.x * clamp(gTune.y, 0.0, 2.0);
    // Collapse cycles continuously; neither beat resets nor full-frame flashes.
    sCollapse = saturate(variant - 2.0)
              * (0.58 + 0.32*sin(sClock*0.72));
    float angle = sClock*0.29;
    sCoreSpin = float2(cos(angle), sin(angle));
    [loop] for (int j = 0; j < 3; ++j)
    {
        float fj = float(j);
        float a = sClock*(0.22 + fj*0.09)*(j == 1 ? -1.0 : 1.0) + fj*2.1;
        float b = 0.55 + fj*0.83 + (0.22 + 0.40*sFly)*sin(sClock*0.31 + fj);
        sRingSpin[j] = float2(cos(a), sin(a));
        sRingTilt[j] = float2(cos(b), sin(b));
        sRadius[j] = 2.95 + fj*0.39 + 0.48*sFly + 0.22*sExpand
                   - 0.75*sCollapse + (0.10 + 0.12*sDeform)*sin(sClock*0.83 + fj*2.0);
        sLift[j] = (0.18 + 0.38*sFly)*sin(sClock*0.57 + fj*2.3);
    }

    float2 uv = float2(i.uv.x*2.0 - 1.0, 1.0 - i.uv.y*2.0);
    uv.x *= max(gTime.w, 0.01);
    float3 fw = safeUnit(gDir.xyz, float3(0.0, 0.0, 1.0));
    float3 reference = abs(fw.y) > 0.98 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
    float3 rt = safeUnit(cross(reference, fw), float3(1.0, 0.0, 0.0));
    float3 up = cross(fw, rt);
    float cr = cos(gDir.w), sr = sin(gDir.w);
    float3 rd = safeUnit(fw + max(gCam.w, 0.001)
              * (uv.x*(rt*cr + up*sr) + uv.y*(up*cr - rt*sr)), fw);
    float3 ro = gCam.xyz;
    float3 col = float3(0.003, 0.005, 0.012);
    float bRay = dot(ro, rd);
    float discriminant = bRay*bRay - dot(ro, ro) + 36.0;
    if (discriminant < 0.0) return float4(col*gTime.z, 1.0);
    float root = sqrt(max(discriminant, 0.0));
    float t = max(0.0, -bRay - root);
    float end = -bRay + root;
    bool hit = false;
    float2 sampleHit = float2(0.0, 0.0);
    [loop] for (int step = 0; step < 80; ++step)
    {
        if (t > end) break;
        sampleHit = field(ro + rd*t);
        float epsilon = max(0.0025, t*0.00040);
        if (sampleHit.x < epsilon) { hit = true; break; }
        t += max(sampleHit.x*0.88, 0.001);
    }
    if (hit)
    {
        float3 p = ro + rd*t;
        float3 n = normalAt(p, max(0.002, t*0.00022));
        float3 key = safeUnit(float3(-5.0, 7.0, -4.0)-p, fw);
        float3 fill = safeUnit(float3(5.0, 1.0, 4.0)-p, fw);
        // Broad off-axis camera fill keeps lattice faces readable throughout
        // an orbit. World-space key and opposing cyan fill retain modelling.
        float3 cameraFill = safeUnit(ro + rt*4.0 + up*3.0 - p, -rd);
        float3 warm = float3(1.0, 0.52, 0.24);
        float3 cyan = float3(0.08, 0.73, 0.90);
        float3 accent = lerp(cyan, float3(0.91, 0.09, 0.43), saturate(gTune.z));
        float mechanical = sampleHit.y > 0.5 && sampleHit.y < 1.5 ? 1.0 : 0.0;
        float heart = sampleHit.y > 1.5 ? 1.0 : 0.0;
        float ao = 1.0;
        // Conservative field is deliberately scaled; this is contact shading.
        [loop] for (int k = 1; k <= 3; ++k)
        {
            float reach = 0.12*float(k);
            ao -= max(0.0, reach - field(p+n*reach).x)*0.48;
        }
        ao = clamp(ao, 0.35, 1.0);
        float diffuse = saturate(dot(n, key));
        float back = saturate(dot(n, fill));
        float front = saturate(dot(n, cameraFill));
        float fresnel = pow(1.0-saturate(dot(n, -rd)), 3.0);
        float spec = pow(saturate(dot(n, safeUnit(key-rd, n))), 42.0);
        float spec2 = pow(saturate(dot(n, safeUnit(fill-rd, n))), 28.0);
        float3 alloy = lerp(accent*0.66 + float3(0.055, 0.045, 0.06),
                            float3(0.36, 0.43, 0.50), mechanical);
        col = alloy*(0.20 + diffuse*1.80 + front*0.85)*ao;
        col += cyan*back*0.60*ao + warm*spec*0.85 + accent*spec2*0.60;
        col += accent*fresnel*(0.15 + 0.13*saturate(gVoice.y))*ao;
        float flow = 0.5 + 0.5*sin(p.y*3.0 + p.x*1.7 - sClock*2.0);
        col += accent*(1.0-mechanical)*(0.05 + 0.12*flow);
        col += heart*lerp(warm, accent, 0.35)
             * (0.60 + 0.22*saturate(gVoice.y) + 0.10*saturate(gSync.y));
        depth = saturate(0.05 / max(t*dot(rd, fw), 0.001));
    }
    return float4(col*gTime.z, 1.0);
}
