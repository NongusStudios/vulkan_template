package main

import "core:log"
import "core:os"
import "core:mem"
import sa "core:container/small_array"

import vk  "vendor:vulkan"
import vma "../lib/vma"

/*
    Buffer 
*/
Buffer :: struct {
    buffer:     vk.Buffer,
    allocation: vma.Allocation,
    size:       vk.DeviceSize,
}

create_buffer :: proc(
    size:  vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    allocation: vma.Allocation_Create_Info,
    flags := vk.BufferCreateFlags{}
) -> (buffer: Buffer, ok: bool){
    state := get_vk_state()

    info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = size,
        usage = usage,
        flags = flags,
        sharingMode = .EXCLUSIVE,
    }

    vk_check(
        vma.create_buffer(
            state.global_allocator,
            info, allocation,
            &buffer.buffer, &buffer.allocation, nil),
    ) or_return
    
    buffer.size = size

    return buffer, true
}

create_staging_buffer :: proc(dst: Buffer) -> (staging_buffer: Buffer, ok: bool) {
    staging_buffer = create_buffer(
        dst.size, 
        { .TRANSFER_SRC }, 
        allocation_create_info(.Cpu_Only, { .HOST_VISIBLE, .HOST_COHERENT })
    ) or_return 

    return staging_buffer, true
}

destroy_buffer :: proc(self: Buffer) {
    state := get_vk_state()
    vma.destroy_buffer(state.global_allocator, self.buffer, self.allocation)
}

/*
    Writes to a CPU accessible buffer with data. offset is by element not bytes. 
    NOTE: Buffer should have HOST_COHERENT flag or memory will not be flushed
*/
buffer_write_mapped_memory :: proc(self: Buffer, data: []$T, offset: int = 0) -> (ok: bool) {
    ensure(self.size >= vk.DeviceSize((len(data) + offset) * size_of(T)))

    state := get_vk_state()

    mapped_memory: rawptr
    vk_check(
        vma.map_memory(state.global_allocator, self.allocation, &mapped_memory)
    ) or_return
    
    if offset > 0 {
        dst := mem.ptr_offset((^T)(mapped_memory), offset)
        mem.copy_non_overlapping(rawptr(dst), raw_data(data[:]), len(data) * size_of(T))
    } else {
        mem.copy_non_overlapping(mapped_memory, raw_data(data[:]), len(data) * size_of(T))
    }

    vma.unmap_memory(state.global_allocator, self.allocation)
    
    return true
}

/*
    Image
*/
Image :: struct {
    image: vk.Image,
    view: vk.ImageView,
    extent: vk.Extent3D,
    format: vk.Format,
    allocation: vma.Allocation,
}

create_image :: proc(
    format: vk.Format,
    extent: vk.Extent3D,
    usage_flags: vk.ImageUsageFlags,
    view_type: vk.ImageViewType,
    view_aspect_flags: vk.ImageAspectFlags,
    allocation_info: vma.Allocation_Create_Info,
    tiling := vk.ImageTiling.OPTIMAL,
) -> (image: Image, ok: bool) {
    state := get_vk_state()

    image_info := image_create_info(
        format,
        usage_flags,
        extent,
        tiling,
    )

    vk_check(
        vma.create_image(
            state.global_allocator,
            image_info,
            allocation_info,
            &image.image, &image.allocation,
            nil
        )
    ) or_return
    defer if !ok {
        vma.destroy_image(state.global_allocator, image.image, image.allocation)
    }
    
    view_info := imageview_create_info(
        image.image,
        format,
        view_aspect_flags,
        view_type,
    )
    vk_check(
        vk.CreateImageView(state.device, &view_info, nil, &image.view)
    ) or_return
    
    image.extent = extent
    image.format = format

    return image, true
}

destroy_image :: proc(self: Image) {
    state := get_vk_state()
    vk.DestroyImageView(state.device, self.view, nil)
    vma.destroy_image(state.global_allocator, self.image, self.allocation)
}

/*
    Descriptor Group
*/
Descriptor_Group :: struct {
    pool:    vk.DescriptorPool,
    sets:    []vk.DescriptorSet,
    layouts: []vk.DescriptorSetLayout,
}

destroy_descriptor_group :: proc(self: Descriptor_Group) {
    vk.DestroyDescriptorPool(get_device(), self.pool, nil)
    for layout in self.layouts {
        vk.DestroyDescriptorSetLayout(get_device(), layout, nil)
    }

    delete(self.sets)
    delete(self.layouts)
}

descriptor_group_allocate_sets :: proc(self: ^Descriptor_Group) -> (ok: bool) {
    alloc_info := vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = self.pool,
        descriptorSetCount = u32(len(self.sets)),
        pSetLayouts = raw_data(self.layouts[:])
    }

    vk_check(vk.AllocateDescriptorSets(
        get_device(),
        &alloc_info, raw_data(self.sets[:])
    )) or_return

    return true
}

// Resets and reallocates sets in the group
descriptor_group_reset :: proc(self: ^Descriptor_Group) -> (ok: bool) {
    vk.ResetDescriptorPool(get_device(), self.pool, {})
    descriptor_group_allocate_sets(self)
    return true
}

MAX_DESCRIPTOR_LAYOUT_BINDINGS :: 16
Descriptor_Layout_Bindings :: sa.Small_Array(MAX_DESCRIPTOR_LAYOUT_BINDINGS, vk.DescriptorSetLayoutBinding)
Descriptor_Layout_Info :: struct {
    bindings: Descriptor_Layout_Bindings,
    flags: vk.DescriptorSetLayoutCreateFlags,
}

Descriptor_Group_Builder :: struct {
    layout_bindings: [dynamic]Descriptor_Layout_Info,
    pool_sizes: map[vk.DescriptorType]u32,
    max_sets: u32,
}

create_descriptor_group_builder :: proc() -> Descriptor_Group_Builder {
    return {
        layout_bindings = make([dynamic]Descriptor_Layout_Info),
        pool_sizes = make(map[vk.DescriptorType]u32),
    }
}

destroy_descriptor_group_builder :: proc(self: Descriptor_Group_Builder) {
    delete(self.layout_bindings)
    delete(self.pool_sizes)
}

// Adds a new set to the group and makes it the current one to be worked on
descriptor_group_builder_add_set :: proc(self: ^Descriptor_Group_Builder, layout_flags := vk.DescriptorSetLayoutCreateFlags{}) {
    append(&self.layout_bindings, Descriptor_Layout_Info{ flags = layout_flags })
    self.max_sets += 1
}

// Adds a binding to the current set. The binding index starts at 0 and is incremented for each added binding
descriptor_group_builder_add_binding :: proc(self: ^Descriptor_Group_Builder,
    type: vk.DescriptorType,
    stage: vk.ShaderStageFlags,
    count: u32 = 1,
) {
    current := len(self.layout_bindings)-1
    assert(current >= 0, "No active set - call descriptor_group_builder_add_set first")

    layout_info := &self.layout_bindings[current]
    assert(sa.len(layout_info.bindings) < MAX_DESCRIPTOR_LAYOUT_BINDINGS, "Too many bindings in set")

    sa.push_back(&layout_info.bindings, vk.DescriptorSetLayoutBinding{
        binding = u32(sa.len(layout_info.bindings)),
        descriptorType = type,
        stageFlags = stage,
        descriptorCount = count,
    })

    self.pool_sizes[type] += count
}

descriptor_group_builder_build :: proc(self: ^Descriptor_Group_Builder, pool_flags: vk.DescriptorPoolCreateFlags = {}) -> (group: Descriptor_Group, ok: bool) {
    group = Descriptor_Group {
        sets = make([]vk.DescriptorSet, self.max_sets),
        layouts = make([]vk.DescriptorSetLayout, self.max_sets),
    }

    for &layout_info, i in self.layout_bindings {
        create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            flags = layout_info.flags,
            bindingCount = u32(sa.len(layout_info.bindings)),
            pBindings = raw_data(sa.slice(&layout_info.bindings)),
        }

        vk_check(vk.CreateDescriptorSetLayout(
            get_device(), &create_info, nil, &group.layouts[i]
        )) or_return
    }

    sizes := make([]vk.DescriptorPoolSize, len(self.pool_sizes)); defer delete(sizes)
    
    i := 0
    for type, count in self.pool_sizes {
        sizes[i] = {
            type = type,
            descriptorCount = count,
        }
        i += 1
    }

    pool_info := vk.DescriptorPoolCreateInfo {
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets = self.max_sets,
        poolSizeCount = u32(len(sizes)),
        pPoolSizes = raw_data(sizes[:]),
        flags = pool_flags,
    }

    vk_check(vk.CreateDescriptorPool(
        get_device(),
        &pool_info, nil, &group.pool,
    )) or_return

    descriptor_group_allocate_sets(&group) or_return

    return group, true
}

/*
    Descriptor Writer
*/
Descriptor_Write_Image_Single :: struct {
    type:   vk.DescriptorType,
    image: vk.DescriptorImageInfo,
}

Descriptor_Write_Buffer_Single :: struct {
    type:    vk.DescriptorType,
    buffer: vk.DescriptorBufferInfo,
}

Descriptor_Write_Images :: struct {
    type:   vk.DescriptorType,
    images: [dynamic]vk.DescriptorImageInfo,
}

Descriptor_Write_Buffers :: struct {
    type:    vk.DescriptorType,
    buffers: [dynamic]vk.DescriptorBufferInfo,
}

Descriptor_Write :: union {
    Descriptor_Write_Image_Single,
    Descriptor_Write_Buffer_Single,
    Descriptor_Write_Images,
    Descriptor_Write_Buffers,
}

Descriptor_Writer :: struct {
    writes: [dynamic]Descriptor_Write,
}

create_descriptor_writer :: proc() -> Descriptor_Writer {
    return {
        writes = make([dynamic]Descriptor_Write),
    }
}

destroy_descriptor_writer :: proc(self: ^Descriptor_Writer) {
    descriptor_writer_reset(self)
    delete(self.writes)
}

descriptor_writer_reset :: proc(self: ^Descriptor_Writer) {
    for &write in self.writes {
        #partial switch w in write {
        case Descriptor_Write_Images: delete(w.images)
        case Descriptor_Write_Buffers: delete(w.buffers)
        }
    }
    clear(&self.writes)
}

// Add a multi image write that can be written to with append_write_info
descriptor_writer_add_images_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType) {
    append(&self.writes, Descriptor_Write_Images {
        type = type,
        images = make([dynamic]vk.DescriptorImageInfo),
    })
}

// Add a multi buffer write that can be written to with append_write_info
descriptor_writer_add_buffers_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType) {
    append(&self.writes, Descriptor_Write_Buffers {
        type = type,
        buffers = make([dynamic]vk.DescriptorBufferInfo),
    })
}

descriptor_writer_append_write_info :: proc{
    descriptor_writer_append_image_write_info,
    descriptor_writer_append_buffer_write_info,
}

// Append image info to current images write
descriptor_writer_append_image_write_info :: proc(self: ^Descriptor_Writer, image: vk.DescriptorImageInfo) {
    current := len(self.writes)-1

    assert(current >= 0, "No active write - call add_images_write first")
    write, ok := self.writes[current].(Descriptor_Write_Images)
    assert(ok, "Active write is not the correct type - call add_images_write first")

    append(&write.images, image)
}

// Append buffer info to current buffers write
descriptor_writer_append_buffer_write_info :: proc(self: ^Descriptor_Writer, buffer: vk.DescriptorBufferInfo) {
    current := len(self.writes)-1

    assert(current >= 0, "No active write - call add_buffers_write first")
    write, ok := self.writes[current].(Descriptor_Write_Buffers)
    assert(ok, "Active write is not the correct type - call add_buffers_write first")
    
    append(&write.buffers, buffer)
}

descriptor_writer_add_single_image_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType, image: vk.DescriptorImageInfo) {
    append(&self.writes, Descriptor_Write_Image_Single {
        type = type,
        image = image,
    })
}

descriptor_writer_add_single_buffer_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType, buffer: vk.DescriptorBufferInfo) {
    append(&self.writes, Descriptor_Write_Buffer_Single {
        type = type,
        buffer = buffer,
    })
}

// Applies queued writes to a set. dstBinding is in the order of writes
descriptor_writer_write_set :: proc(self: ^Descriptor_Writer, set: vk.DescriptorSet) {
    write_infos := make([]vk.WriteDescriptorSet, len(self.writes)); defer delete(write_infos)

    for &write, binding in self.writes {
        write_info := &write_infos[binding]
        write_info.sType  = .WRITE_DESCRIPTOR_SET
        write_info.dstSet = set
        write_info.dstBinding = u32(binding)

        switch &w in write {
        case Descriptor_Write_Image_Single:
            write_info.descriptorType = w.type
            write_info.descriptorCount = 1
            write_info.pImageInfo = &w.image
        case Descriptor_Write_Buffer_Single:
            write_info.descriptorType = w.type
            write_info.descriptorCount = 1
            write_info.pBufferInfo = &w.buffer
        case Descriptor_Write_Images:
            write_info.descriptorType = w.type
            write_info.descriptorCount = u32(len(w.images))
            write_info.pImageInfo = raw_data(w.images[:])
        case Descriptor_Write_Buffers:
            write_info.descriptorType = w.type
            write_info.descriptorCount = u32(len(w.buffers))
            write_info.pBufferInfo = raw_data(w.buffers[:])
        }
    }

    vk.UpdateDescriptorSets(get_device(), u32(len(write_infos)), raw_data(write_infos[:]), 0, nil)
}

/*
    Pipelines
*/

Shader_Stage :: struct {
    stage: vk.ShaderStageFlag,
    code: union {
        []byte, // Raw code
        string, // Path to code
    },
    entry: cstring,
}

create_shader_module :: proc(stage: Shader_Stage) -> (module: vk.ShaderModule, ok: bool) {
    assert(stage.code != nil, "Must provide shader code.")

    code, is_byte_slice := stage.code.([]byte)
    if !is_byte_slice {
        err: os.Error

        code, err = os.read_entire_file(stage.code.(string), context.allocator)
        if err != nil {
            log.errorf("failed to open %s:\n[os.Error]: %#v", err)
            return module, false
        }
    }

    defer if !is_byte_slice {
        delete(code)
    }

    info := vk.ShaderModuleCreateInfo {
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(code),
        pCode = cast(^u32)raw_data(code), 
    }

    vk_check(
        vk.CreateShaderModule(
            get_device(),
            &info, nil, &module,
        )
    ) or_return
    
    return module, true
}

Pipeline :: struct {
    pipeline: vk.Pipeline,
    layout:   vk.PipelineLayout,
}

destroy_pipeline :: proc(self: Pipeline) {
    vk.DestroyPipeline(get_device(), self.pipeline, nil)
    vk.DestroyPipelineLayout(get_device(), self.layout, nil)
}

create_pipeline_layout :: proc(descriptor_layouts: []vk.DescriptorSetLayout, push_constants: []vk.PushConstantRange) -> (
    layout: vk.PipelineLayout,
    ok: bool,
) {
    info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = u32(len(descriptor_layouts)),
        pSetLayouts = raw_data(descriptor_layouts[:]),
        pushConstantRangeCount = u32(len(push_constants)),
        pPushConstantRanges = raw_data(push_constants[:]),
    }

    vk_check(vk.CreatePipelineLayout(
        get_device(),
        &info, nil, &layout,
    )) or_return

    return layout, true
}

/*
    Compute Pipeline Builder
*/
MAX_PIPELINE_DESCRIPTOR_LAYOUTS :: 8
MAX_PIPELINE_PUSH_RANGES :: 8

Pipeline_Descriptor_Layouts :: sa.Small_Array(MAX_PIPELINE_DESCRIPTOR_LAYOUTS, vk.DescriptorSetLayout)
Pipeline_Push_Ranges :: sa.Small_Array(MAX_PIPELINE_PUSH_RANGES, vk.PushConstantRange)

Compute_Pipeline_Builder :: struct {
    descriptor_layouts: Pipeline_Descriptor_Layouts,
    push_constant_ranges: Pipeline_Push_Ranges,
    stage: Shader_Stage,
}

create_compute_pipeline_builder :: proc() -> Compute_Pipeline_Builder {
    return {}
}

compute_pipeline_builder_add_descriptor_layout :: proc(self: ^Compute_Pipeline_Builder, layout: vk.DescriptorSetLayout) {
    sa.push_back(&self.descriptor_layouts, layout)
}

compute_pipeline_builder_add_push_constant_range :: proc(self: ^Compute_Pipeline_Builder, range: vk.PushConstantRange) {
    sa.push_back(&self.push_constant_ranges, range)
}

compute_pipeline_builder_set_shader_module :: proc{
    compute_pipeline_builder_set_shader_module_code,
    compute_pipeline_builder_set_shader_module_code_from_file,
}

compute_pipeline_builder_set_shader_module_code :: proc(self: ^Compute_Pipeline_Builder, code: []byte) {
    self.stage.code = code
}

compute_pipeline_builder_set_shader_module_code_from_file :: proc(self: ^Compute_Pipeline_Builder, path: string) {
    self.stage.code = path 
}

compute_pipeline_builder_build :: proc(self: ^Compute_Pipeline_Builder, entry: cstring = "main", flags := vk.PipelineCreateFlags {}) -> (
    pipeline: Pipeline,
    ok: bool,
) {
    assert(self.stage.code != nil, "Compute Pipeline shader module code not specified - make sure to call compute_pipeline_builder_set_shader_module")
    module := create_shader_module(self.stage) or_return
    defer vk.DestroyShaderModule(get_device(), module, nil)

    pipeline.layout = create_pipeline_layout(
        sa.slice(&self.descriptor_layouts),
        sa.slice(&self.push_constant_ranges),
    ) or_return

    stage_info := vk.PipelineShaderStageCreateInfo {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = { .COMPUTE },
        module = module,
        pName = entry,
    }

    info := vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        stage = stage_info,
        layout = pipeline.layout,
    }

    vk_check(vk.CreateComputePipelines(
        get_device(), 0,
        1, &info, nil, &pipeline.pipeline,
    )) or_return

    return pipeline, true
}

/*
    Graphics Pipeline
*/
MAX_PIPELINE_STAGES :: 8
Pipeline_Stages :: sa.Small_Array(MAX_PIPELINE_STAGES, Shader_Stage)

MAX_VERTEX_BINDINGS   :: 16
MAX_VERTEX_ATTRIBUTES :: 32
Vertex_Binding :: struct {
    binding: vk.VertexInputBindingDescription,
    attributes: sa.Small_Array(MAX_VERTEX_ATTRIBUTES, vk.VertexInputAttributeDescription),
}
Vertex_Bindings :: sa.Small_Array(MAX_VERTEX_BINDINGS, Vertex_Binding)

MAX_PIPELINE_COLOR_ATTACHMENTS :: 16
Color_Attachments :: sa.Small_Array(MAX_PIPELINE_COLOR_ATTACHMENTS, vk.Format)
Blend_Attachments :: sa.Small_Array(MAX_PIPELINE_COLOR_ATTACHMENTS, vk.PipelineColorBlendAttachmentState)

Pipeline_Builder :: struct {
    stages: Pipeline_Stages,
    vertex_bindings: Vertex_Bindings,
    attribute_count: u32,

    input_assembly: vk.PipelineInputAssemblyStateCreateInfo,
    tessellation: vk.PipelineTessellationStateCreateInfo,
    rasterisation: vk.PipelineRasterizationStateCreateInfo,
    multisample: vk.PipelineMultisampleStateCreateInfo,
    depth_stencil: vk.PipelineDepthStencilStateCreateInfo,

    logic_op_enabled: b32,
    logic_op: vk.LogicOp,
    color_blend_attachments: Blend_Attachments,
    color_attachment_formats:  Color_Attachments,
    depth_attachment_format:   vk.Format,
    stencil_attachment_format: vk.Format,

    dynamic_state: map[vk.DynamicState]bool,
    base_pipeline:           vk.Pipeline,
    base_pipeline_index:     i32,

    descriptor_layouts: Pipeline_Descriptor_Layouts,
    push_constant_ranges: Pipeline_Push_Ranges,
}

create_pipeline_builder :: proc() -> Pipeline_Builder {
    builder: Pipeline_Builder
    builder.dynamic_state = make(map[vk.DynamicState]bool)

    pipeline_builder_default(&builder)
    return builder
}

destroy_pipeline_builder :: proc(self: ^Pipeline_Builder) {
    delete(self.dynamic_state)
}

pipeline_builder_default :: proc(self: ^Pipeline_Builder) {
    sa.clear(&self.stages)
    sa.clear(&self.vertex_bindings)
    sa.clear(&self.color_blend_attachments)
    sa.clear(&self.color_attachment_formats)
    sa.clear(&self.descriptor_layouts)
    sa.clear(&self.push_constant_ranges)
    clear(&self.dynamic_state)

    self.attribute_count = 0

    self.input_assembly = {
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }

    self.tessellation = {
        sType = .PIPELINE_TESSELLATION_STATE_CREATE_INFO,
    }

    self.rasterisation = {
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode    = vk.CullModeFlags_NONE,
        frontFace   = .CLOCKWISE,
        lineWidth   = 1.0,
    }

    self.multisample = {
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }

    self.depth_stencil = {
        sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable = false,
        depthWriteEnable = false,
        depthCompareOp = .NEVER,
        front = {},
        back  = {},
        minDepthBounds = 0.0,
        maxDepthBounds = 1.0,
    }

    self.depth_attachment_format = .UNDEFINED
    self.stencil_attachment_format = .UNDEFINED

    self.dynamic_state[.VIEWPORT] = true
    self.dynamic_state[.SCISSOR]  = true

    self.base_pipeline = {}
    self.base_pipeline_index = -1
}

pipeline_builder_add_shader_stage :: proc{
    pipeline_builder_add_shader_stage_code,
    pipeline_builder_add_shader_stage_file,
}

pipeline_builder_add_shader_stage_code :: proc(self: ^Pipeline_Builder, stage: vk.ShaderStageFlag, code: []byte, entry: cstring = "main") {
    assert(sa.len(self.stages) < MAX_PIPELINE_STAGES, "Reached maximum amount of pipeline stages")
    sa.push_back(&self.stages, Shader_Stage {
        stage = stage,
        entry = entry,
        code  = code,
    })
}
pipeline_builder_add_shader_stage_file :: proc(self: ^Pipeline_Builder, stage: vk.ShaderStageFlag, path: string, entry: cstring = "main") {
    assert(sa.len(self.stages) < MAX_PIPELINE_STAGES, "Reached maximum amount of pipeline stages")
    sa.push_back(&self.stages, Shader_Stage {
        stage = stage,
        entry = entry,
        code  = path,
    })
}

pipeline_builder_add_vertex_binding :: proc(self: ^Pipeline_Builder, stride: u32, input_rate: vk.VertexInputRate = .VERTEX) {
    assert(sa.len(self.vertex_bindings) < MAX_VERTEX_BINDINGS, "Reached maximum amount of vertex bindings")
    sa.push_back(&self.vertex_bindings, Vertex_Binding {
        binding = vk.VertexInputBindingDescription {
            binding = u32(sa.len(self.vertex_bindings)),
            stride  = stride,
            inputRate = input_rate,
        },
        attributes = {},
    })
}

pipeline_builder_add_vertex_attribute :: proc(self: ^Pipeline_Builder, format: vk.Format, offset: u32) {
    assert(sa.len(self.vertex_bindings) > 0, "No vertex bindings - call pipeline_builder_add_vertex_binding first")
    
    binding_index := sa.len(self.vertex_bindings)-1
    binding := sa.get_ptr(&self.vertex_bindings, binding_index)
    assert(sa.len(binding.attributes) < MAX_VERTEX_ATTRIBUTES, "Reached maximum amount of attributes in binding")

    sa.push_back(&binding.attributes, vk.VertexInputAttributeDescription {
        binding  = u32(binding_index),
        location = u32(sa.len(binding.attributes)),
        format   = format,
        offset   = offset,
    })

    self.attribute_count += 1
}

pipeline_builder_set_topology :: proc(self: ^Pipeline_Builder, topology: vk.PrimitiveTopology, primitive_restart_enable := b32(false)) {
    self.input_assembly.topology = topology
    self.input_assembly.primitiveRestartEnable = primitive_restart_enable
}

pipeline_builder_set_tesselation_patch_control_point_count :: proc(self: ^Pipeline_Builder, count: u32) {
    self.tessellation.patchControlPoints = count
}

pipeline_builder_set_polygon_mode :: proc(self: ^Pipeline_Builder, mode: vk.PolygonMode) {
    self.rasterisation.polygonMode = mode
}
pipeline_builder_set_cull_mode :: proc(self: ^Pipeline_Builder, mode: vk.CullModeFlags, front_face: vk.FrontFace) {
    self.rasterisation.cullMode = mode
    self.rasterisation.frontFace = front_face
}

pipeline_builder_enable_depth_bias :: proc(self: ^Pipeline_Builder, constant_factor: f32, bias_clamp: f32, slope_factor: f32) {
    self.rasterisation.depthBiasEnable = true
    self.rasterisation.depthBiasConstantFactor = constant_factor
    self.rasterisation.depthBiasClamp = bias_clamp
    self.rasterisation.depthBiasSlopeFactor = slope_factor
}

pipeline_builder_set_multisampling :: proc(self: ^Pipeline_Builder,
    samples: vk.SampleCountFlag,
    min_sample_shading := f32(1.0),
    sample_mask: ^vk.SampleMask = nil,
    alpha_to_coverage_enable := b32(false),
    alpha_to_one_enable := b32(false),
) {
    self.multisample.rasterizationSamples = {samples}
    self.multisample.sampleShadingEnable = min_sample_shading < 1.0
    self.multisample.minSampleShading = min_sample_shading
    self.multisample.pSampleMask = sample_mask
    self.multisample.alphaToCoverageEnable = alpha_to_coverage_enable
    self.multisample.alphaToOneEnable = alpha_to_one_enable
}

pipeline_builder_enable_depth_test :: proc(self: ^Pipeline_Builder,
    compare: vk.CompareOp = .LESS,
    write_enabled := b32(true),
) {
    self.depth_stencil.depthTestEnable = true
    self.depth_stencil.depthWriteEnable = write_enabled
    self.depth_stencil.depthCompareOp = compare
}
pipeline_builder_enable_depth_bounds_test :: proc(self: ^Pipeline_Builder, min_bounds: f32 = 0.0, max_bounds: f32 = 1.0) {
    self.depth_stencil.depthBoundsTestEnable = true
    self.depth_stencil.minDepthBounds = min_bounds
    self.depth_stencil.maxDepthBounds = max_bounds
}
pipeline_builder_enable_stencil_test :: proc(self: ^Pipeline_Builder,
    front: vk.StencilOpState,
    back:  vk.StencilOpState,
) {
    self.depth_stencil.stencilTestEnable = true
    self.depth_stencil.front = front
    self.depth_stencil.back  = back
}

pipeline_builder_add_blend_attachment :: proc(self: ^Pipeline_Builder,
    blend_enable: b32,
    src_color_factor: vk.BlendFactor,
    dst_color_factor: vk.BlendFactor,
    color_blend_op:   vk.BlendOp,
    src_alpha_factor: vk.BlendFactor,
    dst_alpha_factor: vk.BlendFactor,
    alpha_blend_op:   vk.BlendOp,
    color_write_mask: vk.ColorComponentFlags = {.R, .G, .B,. A},
) {
    sa.push_back(&self.color_blend_attachments, vk.PipelineColorBlendAttachmentState {
        blendEnable         = blend_enable,
        srcColorBlendFactor = src_color_factor,
        dstColorBlendFactor = dst_color_factor,
        colorBlendOp        = color_blend_op,
        srcAlphaBlendFactor = src_alpha_factor,
        dstAlphaBlendFactor = dst_alpha_factor,
        alphaBlendOp        = alpha_blend_op,
        colorWriteMask      = color_write_mask,
    })
}

pipeline_builder_add_blend_attachment_default :: proc(self: ^Pipeline_Builder) {
    pipeline_builder_add_blend_attachment(self,
        false,
        .ZERO,
        .ZERO,
        .ADD,
        .ZERO,
        .ZERO,
        .ADD,
    )
}

pipeline_builder_add_blend_attachment_additive :: proc(self: ^Pipeline_Builder) {
    pipeline_builder_add_blend_attachment(self,
        true,
        .SRC_ALPHA,
        .ONE,
        .ADD,
        .ONE,
        .ZERO,
        .ADD,
    )
}

pipeline_builder_add_blend_attachment_alphablend :: proc(self: ^Pipeline_Builder) {
    pipeline_builder_add_blend_attachment(self,
        true,
        .SRC_ALPHA,
        .ONE_MINUS_SRC_ALPHA,
        .ADD,
        .ONE,
        .ZERO,
        .ADD,
    )
}

pipeline_builder_set_blend_logic_op :: proc(self: ^Pipeline_Builder, op: vk.LogicOp) {
    self.logic_op_enabled = true
    self.logic_op = op
}

pipeline_builder_add_color_attachment :: proc(self: ^Pipeline_Builder, format: vk.Format) {
    assert(sa.len(self.color_attachment_formats) < MAX_PIPELINE_COLOR_ATTACHMENTS, "Reached maximum number of color attachments")
    sa.push_back(&self.color_attachment_formats, format)
}
pipeline_builder_set_depth_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format) {
    self.depth_attachment_format = format
}
pipeline_builder_set_stencil_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format) {
    self.stencil_attachment_format = format
}

pipeline_builder_add_descriptor_layout :: proc(self: ^Compute_Pipeline_Builder, layout: vk.DescriptorSetLayout) {
    sa.push_back(&self.descriptor_layouts, layout)
}

pipeline_builder_add_push_constant_range :: proc(self: ^Compute_Pipeline_Builder, range: vk.PushConstantRange) {
    sa.push_back(&self.push_constant_ranges, range)
}

pipeline_builder_add_dynamic_state :: proc(self: ^Pipeline_Builder, args: ..vk.DynamicState) {
    for arg in args {
        self.dynamic_state[arg] = true
    }
}

pipeline_builder_build :: proc(self: ^Pipeline_Builder) -> (pipeline: Pipeline, ok: bool) {
    ensure(sa.len(self.color_attachment_formats) == sa.len(self.color_blend_attachments), "There must be a blend state attachment for each color attachment")

    // Create layout
    pipeline.layout = create_pipeline_layout(
        sa.slice(&self.descriptor_layouts),
        sa.slice(&self.push_constant_ranges),
    ) or_return

    defer if !ok {
        vk.DestroyPipelineLayout(get_device(), pipeline.layout, nil)
    }
    
    // Create shader stages
    shader_stages := make([]vk.PipelineShaderStageCreateInfo, sa.len(self.stages)); defer delete(shader_stages)
    
    failed := false
    for stage, i in sa.slice(&self.stages) {
        module, is_ok := create_shader_module(stage)
        if !is_ok { failed = true; break }

        shader_stages[i] = {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {stage.stage},
            module = module,
            pName = stage.entry,
        }
    }

    defer for module in shader_stages {
        vk.DestroyShaderModule(get_device(), module.module, nil)
    }
    if failed { return pipeline, false }

    // Vertex Input State
    binding_descriptions := make([]vk.VertexInputBindingDescription, sa.len(self.vertex_bindings)); defer delete(binding_descriptions)
    attribute_descriptions := make([]vk.VertexInputAttributeDescription, self.attribute_count);     defer delete(attribute_descriptions)
    current := 0
    for &binding, i in sa.slice(&self.vertex_bindings) {
        binding_descriptions[i] = binding.binding
        for attr in sa.slice(&binding.attributes) {
            attribute_descriptions[current] = attr
            current += 1
        }
    }

    vertex_input_state := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = u32(len(binding_descriptions)),
        pVertexBindingDescriptions    = raw_data(binding_descriptions[:]),
        vertexAttributeDescriptionCount = u32(len(attribute_descriptions)),
        pVertexAttributeDescriptions  = raw_data(attribute_descriptions[:]),
    }

    viewport_state := vk.PipelineViewportStateCreateInfo {
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount  = 1,
    }

    dynamic_state_flags := make([]vk.DynamicState, len(self.dynamic_state)); defer delete(dynamic_state_flags)
    current = 0
    for state, _ in self.dynamic_state {
        dynamic_state_flags[current] = state
        current += 1
    }

    dynamic_state := vk.PipelineDynamicStateCreateInfo {
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamic_state_flags)),
        pDynamicStates = raw_data(dynamic_state_flags[:])
    }

    color_blend_state := vk.PipelineColorBlendStateCreateInfo {
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable = self.logic_op_enabled,
        logicOp = self.logic_op,
        attachmentCount = u32(sa.len(self.color_blend_attachments)),
        pAttachments    = raw_data(sa.slice(&self.color_blend_attachments)),
    }

    pipeline_render_info := vk.PipelineRenderingCreateInfo {
        sType = .PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount = u32(sa.len(self.color_attachment_formats)),
        pColorAttachmentFormats = raw_data(sa.slice(&self.color_attachment_formats)),
        depthAttachmentFormat = self.depth_attachment_format,
        stencilAttachmentFormat = self.stencil_attachment_format,
    }

    create_info := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &pipeline_render_info,
        stageCount = u32(len(shader_stages)),
        pStages = raw_data(shader_stages[:]),
        pVertexInputState = &vertex_input_state,
        pInputAssemblyState = &self.input_assembly,
        pTessellationState = &self.tessellation,
        pViewportState = &viewport_state,
        pRasterizationState = &self.rasterisation,
        pMultisampleState = &self.multisample,
        pDepthStencilState = &self.depth_stencil,
        pColorBlendState = &color_blend_state,
        pDynamicState = &dynamic_state,
    
        layout = pipeline.layout,
        basePipelineHandle = self.base_pipeline,
        basePipelineIndex  = self.base_pipeline_index,
    }

    vk_check(
        vk.CreateGraphicsPipelines(get_device(), 0, 1, &create_info, nil, &pipeline.pipeline)
    ) or_return

    return pipeline, true
}
