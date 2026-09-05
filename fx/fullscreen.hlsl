// One triangle that covers the screen, built from the vertex id alone.
// Nothing is bound: no vertex buffer, no input layout, no index buffer.
// Draw(3, 0) with topology TRIANGLELIST is the whole call.

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

VSOut main(uint id : SV_VertexID)
{
    VSOut o;
    o.uv  = float2((id << 1) & 2, id & 2);       // (0,0) (2,0) (0,2)
    o.pos = float4(o.uv.x * 2.0 - 1.0,
                   1.0 - o.uv.y * 2.0, 0.0, 1.0);
    return o;
}
