package main

import "base:runtime"
import "core:log"

import sdl "vendor:sdl3"
import vk  "vendor:vulkan"
import vkb "../lib/vkb"
import vma "../lib/vma"

PRESENT_MODE  :: vk.PresentModeKHR.FIFO_RELAXED
FRAME_OVERLAP :: 2

// Vulkan 1.2 features
DEVICE_FEATURES_12 :: vk.PhysicalDeviceVulkan12Features {
    // Allows shaders to directly access buffer memory using GPU addresses
    bufferDeviceAddress = true,
    // Enables dynamic indexing of descriptors and more flexible descriptor usage
    descriptorIndexing  = true,
}

// Vulkan 1.3 features
DEVICE_FEATURES_13 :: vk.PhysicalDeviceVulkan13Features {
    // Eliminates the need for render pass objects, simplifying rendering setup
    dynamicRendering = true,
    // Provides improved synchronization primitives with simpler usage patterns
    synchronization2 = true,
}

// Enabled extensions
DEVICE_EXTENSIONS :: []string{}

Swapchain :: struct {
    swapchain:          vk.SwapchainKHR,
    extent:             vk.Extent2D,
    format:             vk.Format,
    images:             []vk.Image,
    image_views:        []vk.ImageView,
    present_semaphores: []vk.Semaphore,
}

Queue :: struct {
    queue:  vk.Queue,
    family: u32,
}

Frame_Data :: struct {
    acquire_next_semaphore: vk.Semaphore,
    render_fence:        vk.Fence,
    image_index:         u32,

    command_pool:   vk.CommandPool, // Each frame has a seperate command pool to allow for multi-threaded frame recording, if desired.
    command_buffer: vk.CommandBuffer,

    resource_tracker: Resource_Tracker,
}

Vk_State :: struct {
    instance:        vk.Instance,
    surface:         vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    device:          vk.Device,
    graphics:        Queue,
    transfer:        Queue,
    
    swapchain:   Swapchain,

    frames:    [FRAME_OVERLAP]Frame_Data,
    current_frame: u32,
    
    vkb: struct {
        instance:        ^vkb.Instance,
        physical_device: ^vkb.Physical_Device,
        device:          ^vkb.Device,
        swapchain:       ^vkb.Swapchain,
    },
    
    // Global command pool, created with the TRANSIENT flag, should be only used for one time commands outside the render loop.
    transfer_command_pool: vk.CommandPool,
    one_time_fence: vk.Fence, // This fence is used to wait for one time commands to finish before continuing.
                              // Note: This is fine because one time commands should only be used at initialisation,
                              // before the render loop.

    global_resource_tracker: Resource_Tracker,
    global_allocator:       vma.Allocator,
}

@(private="file")
self: Vk_State
get_vk_state :: proc() -> ^Vk_State {
    return &self
}

get_device :: proc() -> vk.Device {
    return self.device
}

get_swapchain :: proc() -> ^Swapchain {
    return &self.swapchain
}

get_current_frame :: #force_inline proc() -> ^Frame_Data #no_bounds_check {
    return &self.frames[self.current_frame % FRAME_OVERLAP]
}

// Adds resource to the global tracker 
track_resource :: proc(res: Resource) {
    resource_tracker_push(&self.global_resource_tracker, res)
}

start_frame :: proc() -> (frame: ^Frame_Data, ok: bool) {
    frame = get_current_frame()

    vk_check(vk.WaitForFences(self.device, 1, &frame.render_fence, true, 1e9)) or_return
    vk_check(vk.ResetFences(self.device, 1, &frame.render_fence)) or_return

    resource_tracker_flush(&frame.resource_tracker)

    // Request image from the swapchain
    result := vk.AcquireNextImageKHR(
        self.device,
        self.swapchain.swapchain,
        max(u64),
        frame.acquire_next_semaphore,
        0,
        &frame.image_index,
    )

    if result == .ERROR_OUT_OF_DATE_KHR {
        resize_swapchain() or_return
        return nil, false
    } else if result != .SUBOPTIMAL_KHR {
        vk_check(result) or_return
    }

    // Start current command buffer
    cmd := frame.command_buffer
    vk_check(vk.ResetCommandBuffer(cmd, {})) or_return
    
    begin_info := command_buffer_begin_info()
    vk_check(vk.BeginCommandBuffer(cmd, &begin_info)) or_return 

    return frame, true
}

present_frame :: proc(frame: ^Frame_Data, previous_swapchain_image_layout: vk.ImageLayout) {
    cmd := frame.command_buffer  

    // TODO: Draw imgui ontop of swapchain image

    // Transition current swapchain image into present mode
    barrier: Pipeline_Barrier
    pipeline_barrier_add_image_barrier(&barrier,
        {.ALL_COMMANDS}, {},
        {.ALL_COMMANDS}, {},
        previous_swapchain_image_layout,
        .PRESENT_SRC_KHR,
        self.swapchain.images[frame.image_index],
        image_subresource_range({.COLOR})
    )

    cmd_pipeline_barrier(cmd, &barrier)

    vk.EndCommandBuffer(cmd)
    
    // Submit commands
    cmd_info := command_buffer_submit_info(cmd)
    signal_info := semaphore_submit_info({.ALL_GRAPHICS}, self.swapchain.present_semaphores[frame.image_index])
    wait_info := semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT_KHR}, frame.acquire_next_semaphore)
    submit := submit_info(&cmd_info, &signal_info, &wait_info)

    vk.QueueSubmit2(self.graphics.queue, 1, &submit, frame.render_fence)

    // Present rendered image
    present_info := vk.PresentInfoKHR {
        sType              = .PRESENT_INFO_KHR,
        pSwapchains        = &self.swapchain.swapchain,
        swapchainCount     = 1,
        pWaitSemaphores    = &self.swapchain.present_semaphores[frame.image_index],
        waitSemaphoreCount = 1,
        
        pImageIndices      = &frame.image_index,
    }

    result := vk.QueuePresentKHR(self.graphics.queue, &present_info)  
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        resize_swapchain()
    }

    self.current_frame += 1
}

// Initialisation
init_vulkan :: proc() -> (ok: bool) {
    // Make the vulkan instance, with basic debug features
    instance_builder := vkb.create_instance_builder()

    if instance_builder == nil { return false }
    defer vkb.destroy_instance_builder(instance_builder)

    vkb.instance_builder_set_app_name(instance_builder, string(TITLE))
    vkb.instance_builder_require_api_version(instance_builder, vk.API_VERSION_1_3)
     
    when ODIN_DEBUG {
        vkb.instance_builder_request_validation_layers(instance_builder)

        default_debug_callback :: proc "system" (
            message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
            message_types: vk.DebugUtilsMessageTypeFlagsEXT,
            p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
            p_user_data: rawptr,
        ) -> b32 {
            context = runtime.default_context()
            context.logger = g_logger

            if .WARNING in message_severity {
                log.warnf("[%v]: %s", message_types, p_callback_data.pMessage)
            } else if .ERROR in message_severity {
                log.errorf("[%v]: %s", message_types, p_callback_data.pMessage)
                runtime.debug_trap()
            } else {
                log.infof("[%v]: %s", message_types, p_callback_data.pMessage)
            }

            return false // Applications must return false here
        }

        vkb.instance_builder_set_debug_callback(instance_builder, default_debug_callback)
        vkb.instance_builder_set_debug_callback_user_data_pointer(instance_builder, &self)
    }

    // Enable required extensions
    info, err := vkb.get_system_info()
    check_vkb_error(err) or_return
    defer vkb.destroy_system_info(info)
    
    // Get required extensions
    count: u32
    required_extensions := sdl.Vulkan_GetInstanceExtensions(&count)
    exts := make([]string, count); defer delete(exts)
    for &ext, i in exts {
        ext = string(required_extensions[i])
    }

    vkb.instance_builder_enable_extensions(instance_builder, exts)

    // Create the instance
    self.vkb.instance, err = vkb.instance_builder_build(instance_builder)
    check_vkb_error(err) or_return

    defer if !ok {
        vkb.destroy_instance(self.vkb.instance)
    }

    self.instance = self.vkb.instance.instance
    
    // Create the surface
    if !sdl.Vulkan_CreateSurface(get_app().window, self.instance, nil, &self.surface) {
        log.error("[Vulkan Error] failed to create a window surface")
        return false
    }

    defer if !ok {
        vkb.destroy_surface(self.vkb.instance, self.surface)
    }

    // Fetch physical device 
    selector := vkb.create_physical_device_selector(self.vkb.instance)
    if selector == nil { return false }
    defer vkb.destroy_physical_device_selector(selector)

    vkb.physical_device_selector_set_minimum_version(selector, vk.API_VERSION_1_3)
    vkb.physical_device_selector_set_required_features_12(selector, DEVICE_FEATURES_12)
    vkb.physical_device_selector_set_required_features_13(selector, DEVICE_FEATURES_13)
    vkb.physical_device_selector_add_required_extensions(selector, DEVICE_EXTENSIONS)
    vkb.physical_device_selector_set_surface(selector, self.surface)

    self.vkb.physical_device, err = vkb.physical_device_selector_select(selector)
    check_vkb_error(err) or_return

    defer if !ok {
        vkb.destroy_physical_device(self.vkb.physical_device)
    }
    
    self.physical_device = self.vkb.physical_device.physical_device
    log.infof("selected physical device: %s", self.vkb.physical_device.name)
    
    // Create logical device
    device_builder := vkb.create_device_builder(self.vkb.physical_device)
    if device_builder == nil { return false }
    defer vkb.destroy_device_builder(device_builder)

    self.vkb.device, err = vkb.device_builder_build(device_builder)
    check_vkb_error(err) or_return

    defer if !ok {
        vkb.destroy_device(self.vkb.device)
    }

    self.device = self.vkb.device.device

    // Get graphics queue
    gq := &self.graphics
    
    gq.queue, err = vkb.device_get_queue(self.vkb.device, .Graphics)
    check_vkb_error(err) or_return

    gq.family, err = vkb.device_get_queue_index(self.vkb.device, .Graphics)
    check_vkb_error(err) or_return

    // Get transfer queue
    tq := &self.transfer
    tq.queue, err = vkb.device_get_queue(self.vkb.device, .Transfer)
    check_vkb_error(err) or_return

    tq.family, err = vkb.device_get_queue_index(self.vkb.device, .Transfer)
    check_vkb_error(err) or_return
    
    // Create global resource tracker
    self.global_resource_tracker = create_resource_tracker()
    
    // Create global allocator
    vma_vulkan_functions := vma.create_vulkan_functions()
    allocator_create_info := vma.Allocator_Create_Info {
        flags            = {.Buffer_Device_Address},
        instance         = self.instance,
        physical_device  = self.physical_device,
        device           = self.device,
        vulkan_functions = &vma_vulkan_functions,
    }

    vk_check(
        vma.create_allocator(allocator_create_info, &self.global_allocator),
        "failed to create vulkan memory allocator",
    ) or_return

    track_resource(self.global_allocator)

    // Create global command pool
    transfer_pool_info := vk.CommandPoolCreateInfo {
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.TRANSIENT},
        queueFamilyIndex = self.transfer.family,
    }

    vk_check(
        vk.CreateCommandPool(
            self.device,
            &transfer_pool_info,
            nil,
            &self.transfer_command_pool,
        )
    ) or_return

    track_resource(self.transfer_command_pool)

    // Create one time fence
    one_time_fence_info := fence_create_info()
    vk_check(
        vk.CreateFence(self.device, &one_time_fence_info, nil, &self.one_time_fence)
    ) or_return

    track_resource(self.one_time_fence)

    // Create swapchain and frame data
    create_swapchain(get_window_extent()) or_return
    create_frame_data() or_return

    return true
}

resize_swapchain :: proc() -> (ok: bool) {
    vk_check(vk.DeviceWaitIdle(self.device)) or_return
    create_swapchain(get_window_extent()) or_return

    return true
}

create_swapchain :: proc(extent: vk.Extent2D) -> (ok: bool) {
    err: vkb.Error

    self.swapchain.format = .B8G8R8A8_UNORM

    builder := vkb.create_swapchain_builder(self.vkb.device)
    defer vkb.destroy_swapchain_builder(builder)

    vkb.swapchain_builder_set_desired_format(
        builder,
        { format = self.swapchain.format, colorSpace = .SRGB_NONLINEAR },
    )
    vkb.swapchain_builder_set_desired_present_mode(builder, PRESENT_MODE)
    vkb.swapchain_builder_set_desired_extent(builder, extent.width, extent.height)
    vkb.swapchain_builder_add_image_usage_flags(builder, {.TRANSFER_DST})
    vkb.swapchain_builder_set_desired_min_image_count(builder, FRAME_OVERLAP+1)

    if self.vkb.swapchain != nil {
        vkb.swapchain_builder_set_old_swapchain(builder, self.vkb.swapchain)
    }

    swapchain: ^vkb.Swapchain
    swapchain, err = vkb.swapchain_builder_build(builder)
    check_vkb_error(err) or_return

    if self.vkb.swapchain != nil {
        destroy_swapchain()
    }

    self.vkb.swapchain = swapchain
    defer if !ok {
        vkb.destroy_swapchain(self.vkb.swapchain)
    }

    sc := &self.swapchain
    sc.swapchain = self.vkb.swapchain.swapchain
    sc.extent    = self.vkb.swapchain.extent
    
    sc.images, err = vkb.swapchain_get_images(self.vkb.swapchain)
    check_vkb_error(err) or_return

    sc.image_views, err = vkb.swapchain_get_image_views(self.vkb.swapchain)
    check_vkb_error(err) or_return

    // Create swapchain sync objects
    // Need to be created here so they are recreated on resize
    semaphore_create_info := semaphore_create_info()
    self.swapchain.present_semaphores = make([]vk.Semaphore, len(self.swapchain.images))
    defer if !ok {
        delete(self.swapchain.present_semaphores)
    }

    for &present_semaphore in self.swapchain.present_semaphores {
        vk_check(
            vk.CreateSemaphore(
                self.device,
                &semaphore_create_info,
                nil,
                &present_semaphore,
            ),
        ) or_return
    } 

    return true
}

create_frame_data :: proc() -> (ok: bool) {
    fence_create_info := fence_create_info({.SIGNALED})
    semaphore_create_info := semaphore_create_info()

    pool_info := vk.CommandPoolCreateInfo {
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.RESET_COMMAND_BUFFER},
        queueFamilyIndex = self.graphics.family,
    }
    
    for &frame in self.frames {
        frame.resource_tracker = create_resource_tracker()

        // Commands
        vk_check(
            vk.CreateCommandPool(
                self.device,
                &pool_info,
                nil,
                &frame.command_pool,
            ),
        ) or_return

        alloc_info := vk.CommandBufferAllocateInfo {
            sType = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool = frame.command_pool,
            commandBufferCount = 1,
            level = .PRIMARY,
        }
    
        vk_check(
            vk.AllocateCommandBuffers(
                self.device,
                &alloc_info,
                &frame.command_buffer,
            ),
        ) or_return

        // Sync objects
        vk_check(
            vk.CreateFence(self.device, &fence_create_info, nil, &frame.render_fence),
        ) or_return

        vk_check(
            vk.CreateSemaphore(
                self.device,
                &semaphore_create_info,
                nil,
                &frame.acquire_next_semaphore,
            ),
        ) or_return

        track_resource(frame.command_pool)
        track_resource(frame.acquire_next_semaphore)
        track_resource(frame.render_fence)
    } 

    return true
}

destroy_swapchain :: proc() {
    for present_semaphore in self.swapchain.present_semaphores {
        vk.DestroySemaphore(self.device, present_semaphore, nil)
    }
    delete(self.swapchain.present_semaphores)

    vkb.swapchain_destroy_image_views(self.vkb.swapchain, self.swapchain.image_views)
    vkb.destroy_swapchain(self.vkb.swapchain)
    delete(self.swapchain.image_views)
    delete(self.swapchain.images)
}

cleanup_vulkan :: proc() {
    ensure(vk.DeviceWaitIdle(self.device) == .SUCCESS) // Wait for any remaining commands

    for &frame in self.frames {
        //vk.DestroySemaphore(self.device, frame.acquire_next_semaphore, nil)
        //vk.DestroyFence(self.device, frame.render_fence, nil)

        //vk.DestroyCommandPool(self.device, frame.command_pool, nil)

        destroy_resource_tracker(&frame.resource_tracker)
    }
     
    destroy_swapchain()

    destroy_resource_tracker(&self.global_resource_tracker)
    vkb.destroy_device(self.vkb.device)
    vkb.destroy_physical_device(self.vkb.physical_device)
    vkb.destroy_surface(self.vkb.instance, self.surface)
    vkb.destroy_instance(self.vkb.instance)
}
