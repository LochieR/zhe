module basic;

struct CameraData
{
    matrix<float, 4, 4> ViewProjection;
};

[[vk::binding(0, 0)]]
ConstantBuffer<CameraData> c_Camera : register(b0, space0);

struct PerVertexInput
{
    float4 Position : POSITION;
    float4 Color : COLOR;
    float4 TexCoord : TEXCOORD0;
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

    output.Position = mul(c_Camera.ViewProjection, input.Position);
    output.Color = input.Color;
    output.TexCoord = input.TexCoord.xy;

    return output;
}

[shader("pixel")]
float4 pixelMain(VertexOutput input) : SV_Target
{
    return input.Color;
}
