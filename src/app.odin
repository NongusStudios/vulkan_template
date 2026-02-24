package main

import "core:image/png"
import "core:image"

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
    //init_imgui()  or_return

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
            app_handle_resize()
            self.minimized = false
        }
    }
}

app_run :: proc() {
    event: sdl.Event
    barrier: Pipeline_Barrier

    for self.running { 
        app_wait_if_minimized()
        for sdl.PollEvent(&event) {
            //imgui_process_event(&event)
            app_handle_event(event)
        }

        if frame, ok := start_frame(); ok {
            cmd := frame.command_buffer

            present_frame(frame,
                {.ALL_COMMANDS}, {},
                .UNDEFINED)
        }
    }
}
