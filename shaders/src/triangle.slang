struct VSInput {
    [vk_location(0)]
    float2 position : POSITION;
    [vk_location(1)]
    float3 color : COLOR;
}

struct VSOutput {
    float4 position: SV_Position;
    [vk_location(1)] 
    float3 color : COLOR;
    [vk_location(0)]
    float2 pos : POSITION;
}

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput output;
    
    output.position = float4(input.position*0.5, 0.0, 1.0);
    output.color    = input.color;
    output.pos      = input.position;

    return output;
}

[shader("fragment")]
float4 fragmentMain(
    VSOutput input, 
): SV_Target {
    return float4(input.color, 1.0);
}
