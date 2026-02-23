struct Vertex {
    float2 pos;
    float2 uv;
}

struct VS_Push_Constants {
    Vertex* vertex_buffer;
}

[vk_push_constant]
VS_Push_Constants push_constants;

struct VS_Output {
    float4 position: SV_Position;
    float2 uv: TEXCOORD;
}

[shader("vertex")]
VS_Output vertex_main(uint vertex_index: SV_VulkanVertexID){
    VS_Output output;
    
    Vertex vertex = push_constants.vertex_buffer[vertex_index];

    output.position = float4(vertex.pos, 0.0, 1.0);
    output.uv = vertex.uv;

    return output;
}


[vk_binding(0, 0)]
Sampler2D sampler;

[shader("fragment")]
float4 fragment_main(float2 uv: TEXCOORD): SV_Target {
    return sampler.Sample(uv);
}
