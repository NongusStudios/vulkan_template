package main

import "core:image/png"
import "core:image"

import "core:log"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

import im "../lib/imgui"

import stb_image "vendor:stb/image"

WIDTH  :: 1600
HEIGHT :: 900
TITLE  : cstring : "vulkan_template"

App :: struct {
    window:   ^sdl.Window,
    running:   bool,
    minimized: bool,
    
    draw_image: Image,
    draw_extent: vk.Extent2D,
    
    pipeline:      Pipeline,
    vertex_buffer: Buffer,
    index_buffer:  Buffer,

    descriptor_group: Descriptor_Group,
    push_constants: Push_Constants,

    texture: Image,
    sampler: vk.Sampler,
}

Vertex :: struct {
    pos: [2]f32,
    uv:  [2]f32,
}

Push_Constants :: struct {
    vertex_buffer: vk.DeviceAddress,
}

@(private="file")
self: ^App
get_app :: proc() -> ^App { return self }

get_window_extent :: proc() -> vk.Extent2D {
    w, h: i32
    sdl.GetWindowSizeInPixels(get_app().window, &w, &h)
    return vk.Extent2D {
        width  = u32(w),
        height = u32(h),
    }
}

init_app :: proc() -> (ok: bool) {
    self = new(App)
    defer if !ok { free(self) }

    if !sdl.Init({.VIDEO, .AUDIO}) {
        log.errorf("failed to initialise sdl3:\n%s", sdl.GetError())
        return false
    }

    self.window = sdl.CreateWindow(TITLE, WIDTH, HEIGHT, {.VULKAN})
    if self.window == nil {
        log.errorf("failed to create a window:\n%s", sdl.GetError())
        return false
    }
    
    init_vulkan() or_return
    init_imgui()  or_return

    // Create viewport
    display_count: i32 = 0
    display_ids := sdl.GetDisplays(&display_count)
    
    // Get dimension of largest display
    bounds: sdl.Rect
    max_w: i32 = 0
    max_h: i32 = 0
    for i in 0..<display_count {
        sdl.GetDisplayBounds(display_ids[i], &bounds)
        
        if bounds.w > max_w {
            max_w = bounds.w
        }

        if bounds.h > max_h {
            max_h = bounds.h
        }
    }

    // Setup viewport
    // viewport images share the same size as the largest monitor on the users computer, so it doesn't need
    // to be recreated when the window is resized.
    image_builder := init_image_builder(.R16G16B16A16_SFLOAT, u32(max_w), u32(max_h))
    image_builder_set_usage(&image_builder, {
        .TRANSFER_SRC,
        .TRANSFER_DST,
        .STORAGE,
        .COLOR_ATTACHMENT,
    })

    self.draw_image = image_builder_build(&image_builder, allocation_info(.Gpu_Only, { .DEVICE_LOCAL })) or_return
    self.draw_extent = get_window_extent()

    /*
        Create Buffers
    */
    vertices := [?]Vertex {
        { pos = {-1.0, -1.0}, uv = {0.0, 0.0} }, // Top Left
        { pos = { 1.0, -1.0}, uv = {1.0, 0.0} }, // Top Right
        { pos = { 1.0,  1.0}, uv = {1.0, 1.0} }, // Bottom Right
        { pos = {-1.0,  1.0}, uv = {0.0, 1.0} }, // Bottom Left
    }

    indices := [?]u32 {
        0, 1, 2,
        0, 2, 3,
    }

    self.vertex_buffer = create_buffer(
        len(vertices) * size_of(Vertex),
        {.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only, {.DEVICE_LOCAL})
    ) or_return

    self.index_buffer = create_buffer(
        len(indices) * size_of(u32),
        {.INDEX_BUFFER, .TRANSFER_DST},
        allocation_info(.Gpu_Only, {.DEVICE_LOCAL})
    ) or_return

    staging_buffer := create_staging_buffer(self.vertex_buffer.size + self.index_buffer.size) or_return
    defer destroy_buffer(staging_buffer)

    buffer_write_mapped_memory(&staging_buffer, vertices[:])
    buffer_write_mapped_memory(&staging_buffer, indices[:], len(vertices) * size_of(Vertex)) 

    self.push_constants.vertex_buffer = buffer_get_device_address(&self.vertex_buffer)

    /*
        Create Descriptors
    */
    group_builder := create_descriptor_group_builder(); destroy_descriptor_group_builder(group_builder)
    descriptor_group_builder_add_set(&group_builder)
    
    // set 0, binding 0
    descriptor_group_builder_add_binding(&group_builder, .COMBINED_IMAGE_SAMPLER, {.FRAGMENT})
    
    self.descriptor_group = descriptor_group_builder_build(&group_builder) or_return
    
    /*
        Create Pipleine
    */
    module := create_shader_module(#load("../shaders/texture.spv")) or_return
    defer vk.DestroyShaderModule(get_device(), module, nil)

    pipeline_builder := create_pipeline_builder(); defer destroy_pipeline_builder(&pipeline_builder)

    pipeline_builder_add_shader_stage(&pipeline_builder, .VERTEX,   module, "vertex_main")
    pipeline_builder_add_shader_stage(&pipeline_builder, .FRAGMENT, module, "fragment_main")

    pipeline_builder_add_color_attachment(&pipeline_builder, self.draw_image.format)
    pipeline_builder_add_blend_attachment_default(&pipeline_builder)

    pipeline_builder_add_push_constant_range(&pipeline_builder, {
        stageFlags = {.VERTEX},
        offset = 0,
        size   = size_of(Push_Constants),
    })
    pipeline_builder_add_descriptor_layout(&pipeline_builder, self.descriptor_group.layouts[0])

    self.pipeline = pipeline_builder_build(&pipeline_builder) or_return
    
    /*
        Create Texture
    */
    img, err := image.load_from_file("texture.png", {.alpha_add_if_missing})
    if err != nil {
        log.error(err)
        return false
    }

    image_builder_reset(&image_builder, .R8G8B8A8_SRGB, u32(img.width), u32(img.height))
    image_builder_set_pixels(&image_builder, img.pixels.buf[:])
    image_builder_set_usage(&image_builder, {.SAMPLED})
    image_builder_build(&image_builder, allocation_info(.Gpu_Only, {.DEVICE_LOCAL}))

    sampler_builder := init_sampler_builder()
    sampler_builder_set_filter(&sampler_builder, .LINEAR, .LINEAR)
    self.sampler = sampler_builder_build(&sampler_builder) or_return

    writer := create_descriptor_writer(); defer destroy_descriptor_writer(&writer)
    descriptor_writer_add_single_image_write(&writer, .COMBINED_IMAGE_SAMPLER, {
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        imageView   = self.texture.view,
        sampler     = self.sampler,
    }) // binding 0 
    descriptor_writer_write_set(&writer, self.descriptor_group.sets[0])

    onetime_cmd := start_one_time_commands() or_return
        cmd_copy_buffer(onetime_cmd, staging_buffer.buffer, self.vertex_buffer.buffer, self.vertex_buffer.size)
        cmd_copy_buffer(onetime_cmd, staging_buffer.buffer, self.index_buffer.buffer, self.index_buffer.size, self.vertex_buffer.size)

        barrier: Pipeline_Barrier
        pipeline_barrier_add_image_barrier(&barrier,
            {.ALL_COMMANDS}, {},
            {.ALL_COMMANDS}, {.SHADER_SAMPLED_READ},
            .UNDEFINED,
            .SHADER_READ_ONLY_OPTIMAL,
            self.texture.image,
            image_subresource_range({.COLOR})
        )
        cmd_pipeline_barrier(onetime_cmd, &barrier)
    submit_one_time_commands(&onetime_cmd)

    track_resources(
        self.draw_image,
        self.vertex_buffer,
        self.index_buffer,
        self.pipeline,
        self.descriptor_group,
        self.texture,
        self.sampler,
    )


    self.running = true
    return true
}

destroy_app :: proc() {
    cleanup_vulkan()

    sdl.DestroyWindow(self.window)
    sdl.Quit()
    
    free(self)
}

app_handle_resize :: proc() {
    resize_swapchain()
    self.draw_extent = get_window_extent()
    self.draw_extent.width = min(self.draw_extent.width, self.draw_image.extent.width)
    self.draw_extent.height = min(self.draw_extent.height, self.draw_image.extent.height)
}

app_handle_event :: proc(event: sdl.Event) {
    #partial switch event.type {
    case .QUIT: self.running = false
    case .WINDOW_MINIMIZED: self.minimized = true
    case .WINDOW_RESIZED:   app_handle_resize()
    }
}

app_wait_if_minimized :: proc() {
    if self.minimized { // If minimized wait for RESTORED event
        event: sdl.Event
        for sdl.WaitEvent(&event) {
            if event.type == .WINDOW_RESTORED {
                app_handle_resize()
                self.minimized = false
            }
        }
    }
}

app_run :: proc() {
    event: sdl.Event
    barrier: Pipeline_Barrier

    for self.running { 
        app_wait_if_minimized()
        for sdl.PollEvent(&event) {
            imgui_process_event(&event)
            app_handle_event(event)
        }

        // ImGui
        imgui_new_frame()
        im.render()

        if frame, ok := start_frame(); ok {
            cmd := frame.command_buffer

            pipeline_barrier_add_image_barrier(&barrier,
                {.ALL_COMMANDS}, {},
                {.VERTEX_SHADER, .FRAGMENT_SHADER}, {.SHADER_WRITE},
                .UNDEFINED,
                .COLOR_ATTACHMENT_OPTIMAL,
                self.draw_image.image,
                image_subresource_range({.COLOR})
            )

            cmd_pipeline_barrier(cmd, &barrier)

            clear := vk.ClearValue {
                color = { 
                    float32 = {0.3, 0.3, 0.3, 1.0},
                },
            }
            color_attachment := attachment_info(self.draw_image.view, &clear, .COLOR_ATTACHMENT_OPTIMAL)
            render_info := rendering_info(self.draw_extent, &color_attachment, nil, nil)

            vk.CmdBeginRendering(cmd, &render_info)
            
            vk.CmdBindPipeline(cmd, .GRAPHICS, self.pipeline.pipeline)

            // Configure Viewport
            viewport := vk.Viewport {
                x = 0,
                y = 0,
                width = f32(self.draw_extent.width),
                height = f32(self.draw_extent.height),
                minDepth = 0.0,
                maxDepth = 1.0,
            }

            vk.CmdSetViewport(cmd, 0, 1, &viewport)

            scissor := vk.Rect2D {
                offset = {x = 0, y = 0},
                extent = {width = self.draw_extent.width, height = self.draw_extent.height},
            }

            vk.CmdSetScissor(cmd, 0, 1, &scissor)

            vk.CmdBindIndexBuffer(cmd, self.index_buffer.buffer, 0, .UINT32)
            
            vk.CmdBindDescriptorSets(cmd,
                .GRAPHICS,
                self.pipeline.layout,
                0, 1, &self.descriptor_group.sets[0],
                0, nil,
            )

            vk.CmdPushConstants(cmd,
                self.pipeline.layout, {.VERTEX},
                0, size_of(Push_Constants), &self.push_constants,
            )

            vk.CmdDrawIndexed(cmd, 6, 1, 0, 0, 0)

            vk.CmdEndRendering(cmd)

            swapchain_image := get_swapchain().images[frame.image_index]
            swapchain_extent := get_swapchain().extent

            pipeline_barrier_add_image_barrier(&barrier,
                {.VERTEX_SHADER, .FRAGMENT_SHADER}, {.SHADER_WRITE},
                {.COPY},         {.MEMORY_READ},
                .COLOR_ATTACHMENT_OPTIMAL, .TRANSFER_SRC_OPTIMAL,
                self.draw_image.image,
                image_subresource_range({.COLOR})
            )

            pipeline_barrier_add_image_barrier(&barrier,
                {.ALL_COMMANDS}, {},
                {.COPY}, {.MEMORY_WRITE},
                .UNDEFINED, .TRANSFER_DST_OPTIMAL,
                swapchain_image,
                image_subresource_range({.COLOR})
            )

            cmd_pipeline_barrier(cmd, &barrier)
            
            cmd_copy_image(cmd,
                self.draw_image.image,
                swapchain_image,
                self.draw_extent,
                swapchain_extent,
                image_subresource_layers({.COLOR}),
                image_subresource_layers({.COLOR}),
            )

            draw_imgui_and_present_frame(frame,
                {.COPY}, {.MEMORY_WRITE},
                .TRANSFER_DST_OPTIMAL)
        }
    }
}
