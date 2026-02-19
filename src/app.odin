package main

import "core:math"
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

    gradient_compute: Pipeline,
    gradient_group: Descriptor_Group,
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

    // Build Descriptor Group
    desc_builder := create_descriptor_group_builder(); defer destroy_descriptor_group_builder(desc_builder)
    descriptor_group_builder_add_set(&desc_builder)
    descriptor_group_builder_add_binding(&desc_builder, .STORAGE_IMAGE, {.COMPUTE})
    self.gradient_group = descriptor_group_builder_build(&desc_builder) or_return

    // Write descriptor set
    writer := create_descriptor_writer(); defer destroy_descriptor_writer(&writer)
    descriptor_writer_add_single_image_write(&writer, .STORAGE_IMAGE, {
        imageView = self.draw_image.view,
        imageLayout = .GENERAL,
    })
    descriptor_writer_write_set(&writer, self.gradient_group.sets[0])

    // Build compute pipeline
    compute_builder := create_compute_pipeline_builder(); defer destroy_compute_pipeline_builder(compute_builder)
    compute_pipeline_builder_add_descriptor_layout(&compute_builder, self.gradient_group.layouts[0])
    compute_pipeline_builder_set_shader_module(&compute_builder, "shaders/gradient.comp.spv")
    self.gradient_compute = compute_pipeline_builder_build(&compute_builder) or_return
    
    track_resources(
        self.draw_image,
        self.gradient_group,
        self.gradient_compute,
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
        
        if frame, ok := start_frame(); ok {
            // ImGui
            imgui_new_frame()
            im.show_demo_window()
            im.render()

            cmd := frame.command_buffer

            // Transition to general
            pipeline_barrier_add_image_barrier(&barrier,
                {.ALL_COMMANDS}, {},
                {.CLEAR}, {.MEMORY_WRITE},
                .UNDEFINED, .GENERAL,
                self.draw_image.image,
                image_subresource_range({.COLOR}),
            )
            
            cmd_pipeline_barrier(cmd, &barrier)

            image_range := image_subresource_range({.COLOR})
            vk.CmdClearColorImage(cmd,
                self.draw_image.image,
                .GENERAL,
                &vk.ClearColorValue {
                    float32 = { 1.0, 0.0, 0.0, 1.0, }
                },
                1, &image_range,
            )

            pipeline_barrier_add_image_barrier(&barrier,
                {.CLEAR},          {.MEMORY_WRITE},
                {.COMPUTE_SHADER}, {.SHADER_WRITE},
                .GENERAL, .GENERAL,
                self.draw_image.image,
                image_subresource_range({.COLOR}),
            )
            
            cmd_pipeline_barrier(cmd, &barrier)

            vk.CmdBindPipeline(cmd, .COMPUTE, self.gradient_compute.pipeline)

            // Bind the descriptor set containing the draw image for the compute pipeline
            vk.CmdBindDescriptorSets(
                cmd,
                .COMPUTE,
                self.gradient_compute.layout,
                0,
                1,
                &self.gradient_group.sets[0],
                0,
                nil,
            )

            // Execute the compute pipeline dispatch. We are using 16x16 workgroup size so
            // we need to divide by it
            vk.CmdDispatch(
                cmd,
                u32(math.ceil(f32(self.draw_extent.width)   / 20.0)),
                u32(math.ceil(f32(self.draw_extent.height)  / 20.0)),
                1,
            )

            swapchain_image := get_swapchain().images[frame.image_index]
            swapchain_extent := get_swapchain().extent

            pipeline_barrier_add_image_barrier(&barrier,
                {.COMPUTE_SHADER},  {.MEMORY_WRITE},
                {.COPY}, {.MEMORY_READ},
                .GENERAL, .TRANSFER_SRC_OPTIMAL,
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
