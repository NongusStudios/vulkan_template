package main

import "core:math"
import "core:log"
import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

WIDTH  :: 800
HEIGHT :: 600
TITLE  : cstring : "vulkan_template"

App :: struct {
    window:   ^sdl.Window,
    running:   bool,
    
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
    state := get_vk_state()

    // Demo Code
    desc_builder := create_descriptor_group_builder(); defer destroy_descriptor_group_builder(desc_builder)
    descriptor_group_builder_add_set(&desc_builder)
    descriptor_group_builder_add_binding(&desc_builder, .STORAGE_IMAGE, {.COMPUTE})
    self.gradient_group = descriptor_group_builder_build(&desc_builder) or_return
    track_resource(self.gradient_group)

    writer := create_descriptor_writer(); defer destroy_descriptor_writer(&writer)
    descriptor_writer_add_single_image_write(&writer, .STORAGE_IMAGE, {
        imageView = state.viewport.color_attachment.view,
        imageLayout = .GENERAL,
    })
    descriptor_writer_write_set(&writer, self.gradient_group.sets[0])

    self.running = true
    return true
}

destroy_app :: proc() {
    cleanup_vulkan()

    sdl.DestroyWindow(self.window)
    sdl.Quit()
    
    free(self)
}

app_handle_event :: proc(event: sdl.Event) {
    #partial switch event.type {
        case .QUIT: self.running = false
    }
}

app_run :: proc() {
    event: sdl.Event

    for self.running {
        for sdl.PollEvent(&event) {
            app_handle_event(event)
        }
        
        flash := abs(math.sin(f32(sdl.GetTicks()) / 1000.0))
        clear_value := vk.ClearColorValue {
            float32 = {0.0, 0.0, flash, 1.0},
        }

        if frame, ok := start_frame(&clear_value); ok {
            end_frame(frame)
        }
    }
}
