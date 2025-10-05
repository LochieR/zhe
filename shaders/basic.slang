module basic;

struct VertexInput
{
    float4 Position : POSITION;
    float4 Color : COLOR;
};

struct VertexOutput
{
    float4 Position : SV_Position;
    float4 Color : COLOR;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input)
{
    VertexOutput output;

    output.Position = input.Position;
    output.Color = input.Color;

    return output;
}

[shader("pixel")]
float4 pixelMain(VertexOutput input) : SV_Target
{
    return input.Color;
}
