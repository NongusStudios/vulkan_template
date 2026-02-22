struct VSInput {
    [vk_location(0)]
    float2 position : POSITION;
    [vk_location(1)]
    float3 color : COLOR;
}

struct VSOutput {
    float4 position: SV_Position;
    [vk_location(0)] 
    float3 color : COLOR;
}

[shader("vertex")]
VSOutput main(VSInput input) {
    VSOutput output;
    
    output.position = float4(input.position*0.5, 0.0, 1.0);
    output.color    = input.color;
    
    return output;
}
