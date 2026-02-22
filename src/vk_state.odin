package main

import "core:flags"
import "base:runtime"
import "core:log"

import sdl "vendor:sdl3"
import vk  "vendor:vulkan"
import vkb "../lib/vkb"
import vma "../lib/vma"

import im     "../lib/imgui"
import im_sdl "../lib/imgui/imgui_impl_sdl3"
import im_vk  "../lib/imgui/imgui_impl_vulkan"

PRESENT_MODE  :: vk.PresentModeKHR.FIFO_RELAXED
FRAME_OVERLAP :: 2

// Vulkan 1.1 features
DEVICE_FEATURES_11 :: vk.PhysicalDeviceVulkan11Features {}

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
track_resources :: proc(args: ..Resource) {
    for res in args {
        resource_tracker_push(&self.global_resource_tracker, res)
    }
}

imgui_new_frame :: proc() {
    im_sdl.new_frame()
    im_vk.new_frame()
    im.new_frame()
}

imgui_process_event :: proc(event: ^sdl.Event) {
    im_sdl.process_event(event)
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

present_frame :: proc(frame: ^Frame_Data,
    previous_swapchain_image_stage:  vk.PipelineStageFlags2,
    previous_swapchain_image_access: vk.AccessFlags2,
    previous_swapchain_image_layout: vk.ImageLayout
) {
    barrier: Pipeline_Barrier
    cmd := frame.command_buffer  

    // Transition current swapchain image into present mode
    pipeline_barrier_add_image_barrier(&barrier,
        previous_swapchain_image_stage, previous_swapchain_image_access,
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

draw_imgui_and_present_frame :: proc(frame: ^Frame_Data,
    previous_swapchain_image_stage:  vk.PipelineStageFlags2,
    previous_swapchain_image_access: vk.AccessFlags2,
    previous_swapchain_image_layout: vk.ImageLayout
) {
    barrier: Pipeline_Barrier
    cmd := frame.command_buffer  
    swapchain_image := self.swapchain.images[frame.image_index]
    swapchain_view  := self.swapchain.image_views[frame.image_index]

    pipeline_barrier_add_image_barrier(&barrier,
        previous_swapchain_image_stage, previous_swapchain_image_access,
        {.ALL_GRAPHICS}, {.SHADER_WRITE},
        previous_swapchain_image_layout,
        .COLOR_ATTACHMENT_OPTIMAL,
        swapchain_image,
        image_subresource_range({.COLOR}),
    )
    cmd_pipeline_barrier(cmd, &barrier)

    color_attachment := attachment_info(
        swapchain_view,
        nil,
        .COLOR_ATTACHMENT_OPTIMAL,
    )

    render_info := rendering_info(self.swapchain.extent, &color_attachment, nil)

    vk.CmdBeginRendering(cmd, &render_info)
    im_vk.render_draw_data(im.get_draw_data(), cmd)
    vk.CmdEndRendering(cmd)

    present_frame(frame,
        {.ALL_GRAPHICS}, {.SHADER_WRITE},
        .COLOR_ATTACHMENT_OPTIMAL)
}

// Initialisation
init_vulkan :: proc(imgui_init := true) -> (ok: bool) {
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
    vkb.physical_device_selector_set_required_features_11(selector, DEVICE_FEATURES_11)
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

    // Create one time fence
    one_time_fence_info := fence_create_info()
    vk_check(
        vk.CreateFence(self.device, &one_time_fence_info, nil, &self.one_time_fence)
    ) or_return

    track_resources(
        self.global_allocator,
        self.transfer_command_pool,
        self.one_time_fence
    )

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

        track_resources(
            frame.command_pool,
            frame.acquire_next_semaphore,
            frame.render_fence,
        )
    } 

    return true
}

init_imgui :: proc() -> (ok: bool) {
    im.CHECKVERSION()

    pool_sizes := []vk.DescriptorPoolSize {
        {.SAMPLER, 1000},
        {.COMBINED_IMAGE_SAMPLER, 1000},
        {.SAMPLED_IMAGE, 1000},
        {.STORAGE_IMAGE, 1000},
        {.UNIFORM_TEXEL_BUFFER, 1000},
        {.STORAGE_TEXEL_BUFFER, 1000},
        {.UNIFORM_BUFFER, 1000},
        {.STORAGE_BUFFER, 1000},
        {.UNIFORM_BUFFER_DYNAMIC, 1000},
        {.STORAGE_BUFFER_DYNAMIC, 1000},
        {.INPUT_ATTACHMENT, 1000},
    }

    pool_info := vk.DescriptorPoolCreateInfo {
        sType         = .DESCRIPTOR_POOL_CREATE_INFO,
        flags         = {.FREE_DESCRIPTOR_SET},
        maxSets       = 1000,
        poolSizeCount = u32(len(pool_sizes)),
        pPoolSizes    = raw_data(pool_sizes),
    }

    imgui_pool: vk.DescriptorPool
    vk_check(vk.CreateDescriptorPool(self.device, &pool_info, nil, &imgui_pool)) or_return

    im.create_context()
    defer if !ok { im.destroy_context() }

    im_sdl.init_for_vulkan(get_app().window)
    defer if !ok { im_sdl.shutdown() }

    init_info := im_vk.Init_Info {
        api_version = self.vkb.instance.api_version,
        instance = self.instance,
        physical_device = self.physical_device,
        device = self.device,
        queue = self.graphics.queue,
        descriptor_pool = imgui_pool,
        min_image_count = 3,
        image_count = 3,
        use_dynamic_rendering = true,
        pipeline_rendering_create_info = {
            sType = .PIPELINE_RENDERING_CREATE_INFO,
            colorAttachmentCount = 1,
            pColorAttachmentFormats = &self.swapchain.format,
        },
        msaa_samples = ._1,
    }

    im_vk.load_functions(
        self.vkb.instance.api_version,
        proc "c" (function_name: cstring, user_data: rawptr) -> vk.ProcVoidFunction {
            state := cast(^Vk_State)user_data
            return vk.GetInstanceProcAddr(state.instance, function_name)
        },
        &self,
    ) or_return

    im_vk.init(&init_info) or_return
    defer if !ok { im_vk.shutdown() }
    
    track_resources(
        imgui_pool,
        im_vk.shutdown,
        im_sdl.shutdown,
    )

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
