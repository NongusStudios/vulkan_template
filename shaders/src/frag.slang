[shader("fragment")]
float4 main(
    [vk_location(0)]
    float3 color : COLOR
): SV_Target {
    return float4(color, 1.0);
}
