package main

import "core:log"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

import im "../lib/imgui"

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
    self.draw_image = create_image(
        .R16G16B16A16_SFLOAT,
        {
            width = u32(max_w),
            height = u32(max_h),
            depth = 1
        },
        {
            .TRANSFER_SRC,
            .TRANSFER_DST,
            .STORAGE,
            .COLOR_ATTACHMENT,
        },
        .D2, {.COLOR},
        allocation_create_info(.Gpu_Only, { .DEVICE_LOCAL })
    ) or_return

    self.draw_extent = get_window_extent()

    /*
        Create Buffers
    */
    vertices := [?]f32 {
        // Position - Color
         0.0, -1.0,    1.0, 0.0, 0.0,
         1.0,  1.0,    0.0, 1.0, 0.0,
        -1.0,  1.0,    0.0, 0.0, 1.0,
    }

    self.vertex_buffer = create_buffer(
        len(vertices) * size_of(f32),
        {.VERTEX_BUFFER, .TRANSFER_DST},
        allocation_create_info(.Gpu_Only, {.DEVICE_LOCAL})
    ) or_return

    staging_buffer := create_staging_buffer(self.vertex_buffer) or_return
    defer destroy_buffer(staging_buffer)

    buffer_write_mapped_memory(staging_buffer, vertices[:])
    
    onetime_cmd := start_one_time_commands() or_return
    cmd_copy_buffer(onetime_cmd, staging_buffer.buffer, self.vertex_buffer.buffer, 0, self.vertex_buffer.size)
    submit_one_time_commands(&onetime_cmd)

    builder := create_pipeline_builder(); defer destroy_pipeline_builder(&builder)

    pipeline_builder_add_shader_stage(&builder, .VERTEX,   "shaders/vert.spv")
    pipeline_builder_add_shader_stage(&builder, .FRAGMENT, "shaders/frag.spv")

    pipeline_builder_add_color_attachment(&builder, self.draw_image.format)
    pipeline_builder_add_blend_attachment_default(&builder)

    pipeline_builder_set_cull_mode(&builder, {.BACK}, .CLOCKWISE)

    pipeline_builder_add_vertex_binding(&builder, size_of(f32) * 5)
    pipeline_builder_add_vertex_attribute(&builder, .R32G32_SFLOAT, 0)
    pipeline_builder_add_vertex_attribute(&builder, .R32G32B32_SFLOAT, size_of(f32) * 2)

    self.pipeline = pipeline_builder_build(&builder) or_return

    track_resources(
        self.draw_image,
        self.vertex_buffer,
        self.pipeline,
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

            offset: vk.DeviceSize = 0
            vk.CmdBindVertexBuffers(cmd, 0, 1, &self.vertex_buffer.buffer, &offset)
            vk.CmdDraw(cmd, 3, 1, 0, 0)

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
                {.COLOR},
            )

            draw_imgui_and_present_frame(frame,
                {.COPY}, {.MEMORY_WRITE},
                .TRANSFER_DST_OPTIMAL)
        }
    }
}
