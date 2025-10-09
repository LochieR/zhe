module basic;

struct PerVertexInput
{
    float4 Position : POSITION;
    float4 Color : COLOR;
    float2 TexCoord : TEXCOORD0;
};

struct VertexOutput
{
    float4 Position : SV_Position;
    float4 Color : COLOR;
    float2 TexCoord : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(PerVertexInput input)
{
    VertexOutput output;

    output.Position = input.Position;
    output.Color = input.Color;
    output.TexCoord = input.TexCoord;

    return output;
}

[[vk::binding(0, 0)]]
Texture2D r_Texture : register(t0);

[[vk::binding(1, 0)]]
SamplerState r_Sampler : register(s0);

[shader("pixel")]
float4 pixelMain(VertexOutput input) : SV_Target
{
    return r_Texture.Sample(r_Sampler, input.TexCoord);
}
