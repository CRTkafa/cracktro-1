// Threshold/downsample -> bloom[0], vertical -> bloom[1], horizontal -> bloom[0].
// Blur offsets are half-resolution texels and are ONLY used on half-res inputs.
cbuffer Bloom : register(b0) { float4 gStep; float4 gParam; };
Texture2D gSrc : register(t0);
SamplerState gLin : register(s1);
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
static const float VOFF[2] = { 1.3730788, 3.2295113 };
static const float VW[2] = { 0.3171515, 0.0646567 };
static const float VC = 0.2363835;
static const float HOFF[4] = { 1.4415567, 3.3767077, 5.3550101, 7.3868203 };
static const float HW[4] = { 0.2503180, 0.1212263, 0.0394885, 0.0133097 };
static const float HC = 0.1513151;

float3 knee(float3 c)
{
    c = min(max(c, 0.0), 32.0);
    float l = max(c.r, max(c.g, c.b));
    float t = gParam.x, k = max(gParam.y, 1e-4);
    float s = clamp(l - t + k, 0.0, 2.0 * k);
    s = s * s / (4.0 * k + 1e-6);
    return c * (max(s, l - t) / max(l, 1e-4));
}
float3 brightPass(float2 uv)
{
    // Threshold four full-res texel centres BEFORE averaging: retain thin light.
    float2 d = gStep.xy * 0.5;
    return (knee(gSrc.Sample(gLin, uv + float2(-d.x, -d.y)).rgb)
          + knee(gSrc.Sample(gLin, uv + float2( d.x, -d.y)).rgb)
          + knee(gSrc.Sample(gLin, uv + float2(-d.x,  d.y)).rgb)
          + knee(gSrc.Sample(gLin, uv + float2( d.x,  d.y)).rgb)) * 0.25;
}
float3 blurV(float2 uv)
{
    float3 c = gSrc.Sample(gLin, uv).rgb * VC;
    [unroll] for (int j = 0; j < 2; j++) {
        float2 d = float2(0.0, VOFF[j] * gStep.y);
        c += (gSrc.Sample(gLin, uv + d).rgb + gSrc.Sample(gLin, uv - d).rgb) * VW[j];
    }
    return c;
}
float3 blurH(float2 uv)
{
    float3 c = gSrc.Sample(gLin, uv).rgb * HC;
    [unroll] for (int j = 0; j < 4; j++) {
        float2 d = float2(HOFF[j] * gStep.x, 0.0);
        c += (gSrc.Sample(gLin, uv + d).rgb + gSrc.Sample(gLin, uv - d).rgb) * HW[j];
    }
    return c;
}
float4 main(VSOut i) : SV_Target
{
    float3 c;
    if (gParam.w < 0.5) c = brightPass(i.uv);
    else if (gParam.w < 1.5) c = blurV(i.uv);
    else c = blurH(i.uv);
    return float4(c, 1.0);
}
