# Vulkan Template
Minimal Vulkan template for the Odin Programming Language, including ImGui, and a list of helpers for easier Vulkan object creation.

## Table Of Content
1. [Getting Started](#getting-started)
    1. [Compiling](#compiling)
2. [Features](#features)
    1. [Resource Tracker](#resource-tracker)
    2. [Utility Functions](#utility-functions)
    3. [Helper Functions](#helper-functions)
        1. [Buffers](#buffers)
        2. [Commands](#commands)
    4. [Builders](#builders)
        1. [Image Builder](#image-builder)
        2. [Sampler Builder](#sampler-builder)
        3. [Descriptor Group Builder](#descriptor-group-builder)
        4. [Descriptor Writer](#descriptor-writer)
        5. [Pipelines](#pipelines)
    5. [ImGui](#imgui)
3. [Dependencies](#dependencies)

## Getting Started

### Compiling
Make sure submodules have been cloned before building. You will need the following to compile this template:
1. Odin Compiler
2. C++ Compiler and libc++
3. premake5
4. Shader Slang: This is optional but the makefile is already setup to compile slang shaders.
5. Vulkan Devel

**NOTE**: At the moment the makefile is only setup for Linux compilation. If you're on a different platform you should only need to modify how vma and imgui bindings are built (find more on their github repos, linked in [Dependencies](#dependencies).

### Notable Template Features

This template uses Vulkan 1.3, and expects usage with multiple device features by default. Required features include:
- `bufferDeviceAddressing`: allows passing a `vk.DeviceAddress` to a shader to reference a buffer without descriptors.
- `dynamicRendering`: removes the need for render passes, instead use [`vk.CmdBeginRendering`](https://docs.vulkan.org/spec/latest/chapters/renderpass.html#vkCmdBeginRendering) (Pipeline builder is setup to expect this).

Validation layers are automatically loaded when `ODIN_DEBUG` is set.

### Directory Structure
- lib: contains dependencies.
- bin: contains compiled application binaries.
- src:
    - main.odin: Initialises the `App`, sets up a tracking allocator when `ODIN_DEBUG` is set.
    - app.odin: Defines the application structure, initialises the window; start writing your code here.
    - vulkan.odin: Initialises Vulkan and handles the swapchain. Modify device features and add extensions here.
    - code.odin: Contains builders and other helper functions.
    - cmds.odin: Contains helper functions for common Vulkan commands.
    - util.odin: Utility functions and types.
- shaders: contains compiled shader binaries
    - src: contains shader source code; makefile is set up to compile [Slang](https://shader-slang.org/) files (*.slang)

## Features

### Resource Tracker
A resource tracker is a structure that tracks Vulkan resources and destroys them when the tracker is flushed or destroyed.
`Vulkan_State` creates a global tracker that is flushed in `cleanup_vulkan`. `Resource` is a union of all the objects that a tracker can track.

```odin
create_resource_tracker :: proc(
    allocator := context.allocator
) -> Resource_Tracker
```
Creates a resource tracker.

```odin
destroy_resource_tracker :: proc(self: ^Resource_Tracker)
```
Flushes and destroys the tracker.

```odin
resource_tracker_push :: proc(self: ^Resource_Tracker, resource: Resource)
```
Pushes a new resource to the tracker.

```odin
resource_tracker_flush :: proc(self: ^Resource_Tracker)
```
Destroys and clears the tracked resources.

```odin
track_resources :: proc(args: ..Resource)
```
Pushes the provided Vulkan resources to the global resource tracker.

### Utility Functions
```odin
vk_check :: #force_inline proc(
    res: vk.Result,
    message := "Detected Vulkan error",
    loc := #caller_location,
) -> bool
```
Checks Vulkan results returning `true` for success. Error results are logged, `false` returned.

#### Create Info Shorthands
The utility file contains multiple create info functions that help reduce boilerplate by only including the most relevant fields. Sets other fields to sane defaults that are used in the majority of cases. \
**For Example:**
```odin
image_subresource_range :: proc(aspectMask: vk.ImageAspectFlags) -> vk.ImageSubresourceRange {
    return {
        aspectMask = aspectMask,
        levelCount = vk.REMAINING_MIP_LEVELS,
        layerCount = vk.REMAINING_ARRAY_LAYERS,
    }
}
```

### Helper Functions

#### Buffers
```odin
create_buffer :: proc(
    size:  vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    allocation: vma.Allocation_Create_Info,
    flags := vk.BufferCreateFlags{}
) -> (buffer: Buffer, ok: bool)
```
Creates a buffer with the global vma allocator.

```odin
create_staging_buffer :: proc(size: vk.DeviceSize) -> (staging_buffer: Buffer, ok: bool)
```
Creates a `Cpu_Only` buffer setup for use with copy commands.

```odin
destroy_buffer :: proc(self: Buffer)
```
Destroys a buffer allocated with the global vma allocator.

```odin
buffer_write_mapped_memory :: proc(self: Buffer, data: []$T, offset: int = 0)
```
Writes to a CPU accessible buffer using the passed `data` slice. The buffer needs to be created with the `Mapped` vma allocation flag.

```odin
buffer_get_device_address :: proc(self: Buffer) -> vk.DeviceAddress
```
Returns the buffers device address.

#### Commands

##### One-Time Commands
```odin
start_one_time_commands :: proc() -> (cmd: vk.CommandBuffer, ok: bool)
submit_one_time_commands :: proc(cmd: ^vk.CommandBuffer)
```
Used to allocate and submit a one-time command buffer. The command buffer is on the graphics queue family.

##### Copy Commands
```odin
cmd_copy_buffer :: proc(
    cmd: vk.CommandBuffer,
    src: vk.Buffer,
    dst: vk.Buffer,
    size: vk.DeviceSize,
    src_offset: vk.DeviceSize = 0,
    dst_offset: vk.DeviceSize = 0,
)

cmd_copy_image :: proc(
    cmd: vk.CommandBuffer,
    src: vk.Image,
    dst: vk.Image,
    src_size: vk.Extent2D,
    dst_size: vk.Extent2D,
    src_subresource: vk.ImageSubresourceLayers,
    dst_subresource: vk.ImageSubresourceLayers,
    src_layout := vk.ImageLayout.TRANSFER_SRC_OPTIMAL,
    dst_layout := vk.ImageLayout.TRANSFER_DST_OPTIMAL,
)

cmd_copy_buffer_to_image :: proc(
    cmd: vk.CommandBuffer,
    src: vk.Buffer,
    dst: vk.Image,
    extent: vk.Extent3D,
    image_subresource: vk.ImageSubresourceLayers,
    dst_layout := vk.ImageLayout.TRANSFER_DST_OPTIMAL,
    src_offset := vk.DeviceSize(0),
    dst_offset := vk.Offset3D{0, 0, 0},
)
```
Use these to simplify copy commands.

##### Pipeline Barriers
`Pipeline_Barrier` uses stack memory and should be zero initialised.
```odin
pipeline_barrier_add_barrier :: proc{
    pipeline_barrier_add_memory_barrier,
    pipeline_barrier_add_buffer_barrier,
    pipeline_barrier_add_image_barrier,
}

pipeline_barrier_add_memory_barrier :: proc(self: ^Pipeline_Barrier,
    src_stage:  vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage:  vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
)

pipeline_barrier_add_buffer_barrier :: proc(self: ^Pipeline_Barrier,
    src_stage:  vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage:  vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
    buffer: vk.Buffer,
    offset := vk.DeviceSize(0),
    size   := vk.DeviceSize(vk.WHOLE_SIZE),
)

pipeline_barrier_add_image_barrier :: proc(self: ^Pipeline_Barrier,
    src_stage:  vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage:  vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    image: vk.Image,
    subresource_range: vk.ImageSubresourceRange,
)
```
This set of functions is used to add specific barriers to the `Pipeline_Barrier`. A `Pipeline_Barrier` can hold up to 16 barriers of each type.

```odin
pipeline_barrier_set_queue_transfer :: proc(self: ^Pipeline_Barrier,
    src_family: u32,
    dst_family: u32,
)
```
Defines a queue transfer when the barrier is executed with `cmd_pipeline_barrier`. Only use this when you're actually transferring to a different queue family, when src and dst are both zero no transfer occurs.

```odin
cmd_pipeline_barrier :: proc(cmd: vk.CommandBuffer,
    barrier: ^Pipeline_Barrier,
    flags := vk.DependencyFlags {},
    reset := true
)
```
Executes the barriers stored by the `Pipeline_Barrier`. By default the `Pipeline_Barrier` is reset afterward, so it can be reused for the next barrier. If you don't want to reset it, change `reset = false`.

```odin
pipeline_barrier_reset :: proc(self: ^Pipeline_Barrier)
```
Clears stored barriers in the `Pipeline_Barrier`.

### Builders
**NOTE**: If a builder initialisation allocates memory and has a deletion method, the initialisation method is prefixed with `create`, otherwise prefixed with `init`.

#### Image Builder
```odin
init_image_builder :: proc(format: vk.Format, width: u32, height: u32, depth: u32 = 1) -> Image_Builder
image_builder_reset :: proc(self: ^Image_Builder, format: vk.Format, width: u32, height: u32, depth: u32 = 1)
image_builder_set_type :: proc(self: ^Image_Builder, image_type: vk.ImageType, view_type: vk.ImageViewType)
image_builder_set_mip_levels :: proc(self: ^Image_Builder, levels := u32(0))
image_builder_set_array_layers :: proc(self: ^Image_Builder, layers: u32)
image_builder_set_samples :: proc(self: ^Image_Builder, samples: vk.SampleCountFlag)
image_builder_set_tiling :: proc(self: ^Image_Builder, tiling: vk.ImageTiling)
image_builder_set_usage :: proc(self: ^Image_Builder, usage: vk.ImageUsageFlags)
image_builder_set_view_components :: proc(self: ^Image_Builder,
    r: vk.ComponentSwizzle,
    g: vk.ComponentSwizzle,
    b: vk.ComponentSwizzle,
    a: vk.ComponentSwizzle,
)
image_builder_set_view_subresource_range :: proc(self: ^Image_Builder, mask: vk.ImageAspectFlags)
image_builder_build :: proc(self: ^Image_Builder,
    allocation: vma.Allocation_Create_Info,
    image_flags: vk.ImageCreateFlags = {},
    view_flags: vk.ImageViewCreateFlags = {},
)
```

**Default Options**
```odin
image_info = {
    imageType = .D2,
    samples = {._1},
    mipLevels   = 1,
    arrayLayers = 1,
    tiling = .OPTIMAL,
    initialLayout = .UNDEFINED,
}
view_info = {
    viewType = .D2,
    subresourceRange = image_subresource_range({.COLOR}),
}
```

#### Sampler Builder

```odin
init_sampler_builder :: proc() -> Sampler_Builder
sampler_builder_reset :: proc(self: ^Sampler_Builder)
sampler_builder_set_filter :: proc(self: ^Sampler_Builder,
    mag_filter: vk.Filter, min_filter: vk.Filter
)
sampler_builder_set_address_mode :: proc(self: ^Sampler_Builder,
    U: vk.SamplerAddressMode,
    V: vk.SamplerAddressMode,
    W: vk.SamplerAddressMode,
)
sampler_builder_set_mip_map :: proc(self: ^Sampler_Builder,
    mode: vk.SamplerMipmapMode,
    lod_bias: f32,
    min_lod: f32,
    max_lod: f32,
)
sampler_builder_enable_anisotropy :: proc(self: ^Sampler_Builder, max_anisotropy: f32)
sampler_builder_enable_compare :: proc(self: ^Sampler_Builder, op: vk.CompareOp)
sampler_builder_set_border_color :: proc(self: ^Sampler_Builder, color: vk.BorderColor)
sampler_builder_enable_unnormalised_coordinates :: proc(self: ^Sampler_Builder)
sampler_builder_build :: proc(self: ^Sampler_Builder) -> (sampler: vk.Sampler, ok: bool)
```

**Default Options**
```odin
{
    magFilter =  .LINEAR,
    minFilter =  .LINEAR,
    mipmapMode = .LINEAR,
    addressModeU = .REPEAT,
    addressModeV = .REPEAT,
    addressModeW = .REPEAT,
    minLod = 0.0,
    maxLod = 1.0,
    borderColor = .FLOAT_TRANSPARENT_BLACK,
}
```

#### Descriptor Group Builder
A `Descriptor_Group` creates a descriptor pool and a collections of descriptor sets and layouts. The pool is initialised to perfectly fit the required amount of sets and bindings.
```odin
Descriptor_Group :: struct {
    pool:    vk.DescriptorPool,
    sets:    []vk.DescriptorSet,
    layouts: []vk.DescriptorSetLayout,
}

destroy_descriptor_group :: proc(self: Descriptor_Group)
descriptor_group_allocate_sets :: proc(self: ^Descriptor_Group) -> (ok: bool)
descriptor_group_reset :: proc(self: ^Descriptor_Group) -> (ok: bool)
```
A set's layout matches their index in the group. `descriptor_group_reset` resets the pool and reallocates sets.
\
A descriptor group is initialised using the `Descriptor_Group_Builder`:
```odin
create_descriptor_group_builder :: proc() -> Descriptor_Group_Builder
destroy_descriptor_group_builder :: proc(self: Descriptor_Group_Builder)
descriptor_group_builder_add_set :: proc(self: ^Descriptor_Group_Builder, layout_flags := vk.DescriptorSetLayoutCreateFlags{})
descriptor_group_builder_add_binding :: proc(self: ^Descriptor_Group_Builder,
    type: vk.DescriptorType,
    stage: vk.ShaderStageFlags,
    count: u32 = 1,
)
descriptor_group_builder_build :: proc(self: ^Descriptor_Group_Builder, pool_flags: vk.DescriptorPoolCreateFlags = {}) -> (
    group: Descriptor_Group,
    ok: bool
)
```
Use `descriptor_group_builder_add_set` to add a descriptor set to the group. Following calls to `descriptor_group_builder_add_binding` will add bindings to the last added set. The indices of each set and binding are defined by the order they're added to the builder. \
Sets are allocated for you when `descriptor_group_builder_build` is called.

#### Descriptor Writer
```odin
create_descriptor_writer :: proc() -> Descriptor_Writer
destroy_descriptor_writer :: proc(self: ^Descriptor_Writer)
descriptor_writer_reset :: proc(self: ^Descriptor_Writer)
descriptor_writer_write :: proc(self: ^Descriptor_Writer, reset := true)
```
By default the writer is reset after writing, set `reset = false` to reuse the same writes.

```odin
descriptor_writer_target_set :: proc(self: ^Descriptor_Writer, set: vk.DescriptorSet)
```
Targets the passed set for following writes. Must be called before `add_single_image_write`, `add_single_buffer_write`, `add_images_write`,  or `add_buffers_write`. Allows for writing to multiple sets with one writer.

```odin
descriptor_writer_add_single_image_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType, image: vk.DescriptorImageInfo)
descriptor_writer_add_single_buffer_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType, buffer: vk.DescriptorBufferInfo)
```
These functions are used to add writes for singular buffers and images, this is what you'll want to use in the majority of cases. Again the destination binding is defined by the order these writes are added.

```odin
descriptor_writer_add_images_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType)
descriptor_writer_add_buffers_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType)

descriptor_writer_append_write_info :: proc{
    descriptor_writer_append_image_write_info,
    descriptor_writer_append_buffer_write_info,
}
descriptor_writer_append_image_write_info :: proc(self: ^Descriptor_Writer, image: vk.DescriptorImageInfo)
descriptor_writer_append_buffer_write_info :: proc(self: ^Descriptor_Writer, buffer: vk.DescriptorBufferInfo)
```
These functions are used to define bindings with multiple descriptors (indexed with an array in the shader). First call `add_images_write` or `add_buffers_write` followed with `append_image_write_info` or `append_buffer_write_info` to addindividual resource information.

#### Pipelines
```odin
create_shader_module :: proc(code: []byte) -> (module: vk.ShaderModule, ok: bool)
destroy_pipeline :: proc(self: Pipeline)
```

##### Compute Pipelines
```odin
init_compute_pipeline_builder :: proc() -> Compute_Pipeline_Builder
compute_pipeline_builder_add_descriptor_layout :: proc(self: ^Compute_Pipeline_Builder, layout: vk.DescriptorSetLayout)
compute_pipeline_builder_add_push_constant_range :: proc(self: ^Compute_Pipeline_Builder, range: vk.PushConstantRange)
compute_pipeline_builder_set_shader_module :: proc(self: ^Compute_Pipeline_Builder, module: vk.ShaderModule)
compute_pipeline_builder_build :: proc(self: ^Compute_Pipeline_Builder, entry: cstring = "main", flags := vk.PipelineCreateFlags {}) -> (
    pipeline: Pipeline,
    ok: bool,
)
```

##### Graphics Pipelines
```odin
create_pipeline_builder :: proc() -> Pipeline_Builder
destroy_pipeline_builder :: proc(self: ^Pipeline_Builder)
pipeline_builder_default :: proc(self: ^Pipeline_Builder)
```
`create_pipeline_builder` calls `pipeline_builder_default` on the returned builder.

```odin
pipeline_builder_add_shader_stage :: proc(self: ^Pipeline_Builder, stage: vk.ShaderStageFlag, module: vk.ShaderModule, entry: cstring = "main")
pipeline_builder_add_vertex_binding :: proc(self: ^Pipeline_Builder, stride: u32, input_rate: vk.VertexInputRate = .VERTEX)
pipeline_builder_add_vertex_attribute :: proc(self: ^Pipeline_Builder, format: vk.Format, offset: u32)
pipeline_builder_set_topology :: proc(self: ^Pipeline_Builder, topology: vk.PrimitiveTopology, primitive_restart_enable := b32(false))
pipeline_builder_set_tesselation_patch_control_point_count :: proc(self: ^Pipeline_Builder, count: u32)
pipeline_builder_set_polygon_mode :: proc(self: ^Pipeline_Builder, mode: vk.PolygonMode)
pipeline_builder_set_cull_mode :: proc(self: ^Pipeline_Builder, mode: vk.CullModeFlags, front_face: vk.FrontFace)
pipeline_builder_enable_depth_bias :: proc(self: ^Pipeline_Builder, constant_factor: f32, bias_clamp: f32, slope_factor: f32)
pipeline_builder_set_multisampling :: proc(self: ^Pipeline_Builder,
    samples: vk.SampleCountFlag,
    min_sample_shading := f32(1.0),
    sample_mask: ^vk.SampleMask = nil,
    alpha_to_coverage_enable := b32(false),
    alpha_to_one_enable := b32(false),
)
pipeline_builder_enable_depth_test :: proc(self: ^Pipeline_Builder,
    compare: vk.CompareOp = .LESS,
    write_enabled := b32(true),
)
pipeline_builder_enable_depth_bounds_test :: proc(self: ^Pipeline_Builder, min_bounds: f32 = 0.0, max_bounds: f32 = 1.0)
pipeline_builder_enable_stencil_test :: proc(self: ^Pipeline_Builder,
    front: vk.StencilOpState,
    back:  vk.StencilOpState,
)
pipeline_builder_add_blend_attachment :: proc(self: ^Pipeline_Builder,
    blend_enable: b32,
    src_color_factor: vk.BlendFactor,
    dst_color_factor: vk.BlendFactor,
    color_blend_op:   vk.BlendOp,
    src_alpha_factor: vk.BlendFactor,
    dst_alpha_factor: vk.BlendFactor,
    alpha_blend_op:   vk.BlendOp,
    color_write_mask: vk.ColorComponentFlags = {.R, .G, .B,. A},
)
pipeline_builder_set_blend_logic_op :: proc(self: ^Pipeline_Builder, op: vk.LogicOp)
pipeline_builder_add_color_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format)
pipeline_builder_set_depth_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format)
pipeline_builder_set_stencil_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format)
pipeline_builder_add_descriptor_layout :: proc(self: ^Pipeline_Builder, layout: vk.DescriptorSetLayout)
pipeline_builder_add_push_constant_range :: proc(self: ^Pipeline_Builder, range: vk.PushConstantRange)
pipeline_builder_add_dynamic_state :: proc(self: ^Pipeline_Builder, args: ..vk.DynamicState)
pipeline_builder_build :: proc(self: ^Pipeline_Builder) -> (pipeline: Pipeline, ok: bool)
```
Adding vertex bindings and attributes follows the same logic of indices following call order.
\
The pipeline builder also includes additive and alpha blend setups:
```odin
pipeline_builder_add_blend_attachment_additive :: proc(self: ^Pipeline_Builder)
pipeline_builder_add_blend_attachment_alphablend :: proc(self: ^Pipeline_Builder)
```
**Default Options**
```odin
self.input_assembly = {
    topology = .TRIANGLE_LIST,
}

self.rasterisation = {
    polygonMode = .FILL,
    cullMode    = vk.CullModeFlags_NONE,
    frontFace   = .CLOCKWISE,
    lineWidth   = 1.0,
}

self.multisample = {
    rasterizationSamples = {._1},
}

self.depth_stencil = {
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
```

### ImGui
```odin
init_imgui :: proc() -> (ok: bool)
```
Initialises ImGui backend - call after `init_vulkan`.

```odin
imgui_process_event :: proc(event: ^sdl.Event)
```
Passes the provided sdl event to ImGui backend.

```odin
imgui_new_frame :: proc()
```
Creates a new ImGui frame, still use `im.render` after drawing your widgets.

```odin
draw_imgui_and_present_frame :: proc(frame: ^Frame_Data,
    previous_swapchain_image_stage:  vk.PipelineStageFlags2,
    previous_swapchain_image_access: vk.AccessFlags2,
    previous_swapchain_image_layout: vk.ImageLayout
)
```
Draws ImGui on top of the current swapchain image before calling `present_frame`.

## Dependencies
- [Simple DirectMedia Layer](https://libsdl.org/)
- [odin-vk-bootstrap](https://github.com/Capati/odin-vk-bootstrap) Vulkan initialisation utility
- [odin-imgui](https://github.com/Capati/odin-imgui) imgui Odin bindings
- [odin-vma](https://github.com/Capati/odin-vma): Vulkan Memory Allocator Odin bindings
