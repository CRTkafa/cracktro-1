#ifndef INSCRIPTIONS_HLSLI
#define INSCRIPTIONS_HLSLI

uint2 inscriptionGlyph(uint c)
{
    switch (c) {
    case 97u: return uint2(0x83800u, 0x7a3eu);
    case 98u: return uint2(0x8bc21u, 0x3e31u);
    case 100u: return uint2(0x8fa10u, 0x7a31u);
    case 101u: return uint2(0x8b800u, 0x383fu);
    case 102u: return uint2(0x38a4cu, 0x842u);
    case 103u: return uint2(0x8c7c0u, 0x3a1eu);
    case 105u: return uint2(0x21804u, 0x3884u);
    case 108u: return uint2(0x21086u, 0x3884u);
    case 109u: return uint2(0xaac00u, 0x56b5u);
    case 110u: return uint2(0x8bc00u, 0x4631u);
    case 111u: return uint2(0x8b800u, 0x3a31u);
    case 114u: return uint2(0x9b400u, 0x421u);
    case 115u: return uint2(0xf800u, 0x3e0eu);
    case 116u: return uint2(0x11c42u, 0x3242u);
    case 117u: return uint2(0x8c400u, 0x5b31u);
    case 121u: return uint2(0x8c620u, 0x3a1eu);
    case 46u: return uint2(0x0u, 0x1080u);
    default: return uint2(0u, 0u);
    }
}

static const uint inscriptionRemember[12] = {114,101,109,101,109,98,101,114,46,46,46,32};
static const uint inscriptionSignal[12] = {115,105,103,110,97,108,32,102,111,117,110,100};
static const uint inscriptionStrange[12] = {115,116,97,121,32,115,116,114,97,110,103,101};

float inscriptionPixel(int2 p, uint label)
{
    uint count = label == 1u ? 11u : 12u;
    if (p.x < 0 || p.y < 0 || p.x >= int(count * 6u - 1u) || p.y >= 7) return 0.0;
    uint slot = uint(p.x) / 6u;
    uint x = uint(p.x) % 6u;
    if (x == 5u) return 0.0;
    uint c = label == 1u ? inscriptionRemember[slot]
           : label == 2u ? inscriptionSignal[slot] : inscriptionStrange[slot];
    uint2 bits = inscriptionGlyph(c);
    uint row = uint(p.y);
    return float(((row < 4u ? bits.x : bits.y) >> ((row % 4u) * 5u + x)) & 1u);
}

float inscriptionMask(float2 uv, float2 footprint, float selector)
{
    if (selector < 0.5 || selector >= 3.5 || any(uv < 0.0) || any(uv > 1.0)) return 0.0;
    uint label = uint(selector + 0.5);
    float2 size = float2(label == 1u ? 65.0 : 71.0, 7.0);
    float2 p = uv * size;
    float2 fw = max(footprint * size, 0.001);
    float resolved = 1.0 - smoothstep(1.0, 1.8, max(fw.x, fw.y));
    if (resolved <= 0.0) return 0.0;
    int2 base = int2(floor(p));
    float value = 0.0;
    [loop] for (int y = -1; y <= 1; ++y) {
        [loop] for (int x = -1; x <= 1; ++x) {
            int2 cell = base + int2(x, y);
            float2 overlap = max(0.0, min(p + fw * 0.5, float2(cell) + 1.0)
                                     - max(p - fw * 0.5, float2(cell)));
            value += inscriptionPixel(cell, label) * overlap.x * overlap.y;
        }
    }
    return saturate(value / (fw.x * fw.y)) * resolved;
}

#endif
