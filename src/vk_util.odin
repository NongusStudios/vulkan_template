package main

import "core:mem"
// Core
import intr "base:intrinsics"
import "base:runtime"
import "core:log"

// Vendor
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import vkb "../lib/vkb"
import vma "../lib/vma"

// Resource Tracker, used for keeping track and deletion of user allocated vulkan resources
Resource :: union {
    // Cleanup procedures
    proc "c" (),

    // Pipeline objects
    vk.Pipeline,
    vk.PipelineLayout,

    // Descriptor-related objects
    vk.DescriptorPool,
    vk.DescriptorSetLayout,

    // Resource views and samplers
    vk.ImageView,
    vk.Sampler,

    // Command-related objects
    vk.CommandPool,

    // Synchronization primitives
    vk.Fence,
    vk.Semaphore,

    // Core memory resources
    vk.Buffer,
    vk.DeviceMemory,

    // Memory allocator
    vma.Allocator,
    
    // objects
    Image,
    Buffer,
}

Resource_Tracker :: struct {
    device: vk.Device,
    resources: [dynamic]Resource,
    allocator: mem.Allocator,
}

create_resource_tracker :: proc(
    allocator := context.allocator
) -> Resource_Tracker {
    return Resource_Tracker {
        device = get_vk_state().device,
        resources = make([dynamic]Resource, allocator),
        allocator = allocator,
    }
}

destroy_resource_tracker :: proc(self: ^Resource_Tracker) {
    assert(self != nil)

    context.allocator = self.allocator
    
    resource_tracker_flush(self)
    delete(self.resources)
}

resource_tracker_push :: proc(self: ^Resource_Tracker, resource: Resource) {
    assert(self != nil)

    append(&self.resources, resource)
}

resource_tracker_flush :: proc(self: ^Resource_Tracker) {
    assert(self != nil)

    if len(self.resources) == 0 {
        return
    }

    // Process resources in reverse order (LIFO)
    #reverse for &resource in self.resources {
        switch &res in resource {
        // Cleanup procedures
        case proc "c" (): res()

        // Pipeline objects
        case vk.Pipeline: vk.DestroyPipeline(self.device, res, nil)
        case vk.PipelineLayout: vk.DestroyPipelineLayout(self.device, res, nil)

        // Descriptor-related objects
        case vk.DescriptorPool: vk.DestroyDescriptorPool(self.device, res, nil)
        case vk.DescriptorSetLayout: vk.DestroyDescriptorSetLayout(self.device, res, nil)

        // Resource views and samplers
        case vk.ImageView: vk.DestroyImageView(self.device, res, nil)
        case vk.Sampler: vk.DestroySampler(self.device, res, nil)

        // Command-related objects
        case vk.CommandPool: vk.DestroyCommandPool(self.device, res, nil)

        // Synchronization primitives
        case vk.Fence: vk.DestroyFence(self.device, res, nil)
        case vk.Semaphore: vk.DestroySemaphore(self.device, res, nil)

        // Core memory resources
        case vk.Buffer: vk.DestroyBuffer(self.device, res, nil)
        case vk.DeviceMemory: vk.FreeMemory(self.device, res, nil)

        // Memory allocator
        case vma.Allocator: vma.destroy_allocator(res)
        
        // Objects
        case Image: destroy_image(res)
        case Buffer: destroy_buffer(res)
        }
    }

    clear(&self.resources)
}

// Error handling
@(require_results)
vk_check :: #force_inline proc(
    res: vk.Result,
    message := "Detected Vulkan error",
    loc := #caller_location,
) -> bool {
    if intr.expect(res, vk.Result.SUCCESS) == .SUCCESS {
        return true
    }
    log.errorf("[Vulkan Error] %s: %v", message, res)
    runtime.print_caller_location(loc)
    return false
}

@(require_results)
check_vkb_error :: #force_inline proc(err: vkb.Error) -> bool {
    if err != nil {
        log.errorf("[Vulkan Error]: %#v", err)
        return false
    }
    return true
}

// Initialisers
image_subresource_range :: proc(aspectMask: vk.ImageAspectFlags) -> vk.ImageSubresourceRange {
    return {
        aspectMask = aspectMask,
        levelCount = vk.REMAINING_MIP_LEVELS,
        layerCount = vk.REMAINING_ARRAY_LAYERS,
    }
}

fence_create_info :: proc(flags: vk.FenceCreateFlags = {}) -> vk.FenceCreateInfo {
    info := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        flags = flags,
    }
    return info
}

semaphore_create_info :: proc(flags: vk.SemaphoreCreateFlags = {}) -> vk.SemaphoreCreateInfo {
    info := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
        flags = flags,
    }
    return info
}

command_buffer_begin_info :: proc(
    flags: vk.CommandBufferUsageFlags = {},
) -> vk.CommandBufferBeginInfo {
    info := vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = flags,
    }
    return info
}

semaphore_submit_info :: proc(
    stageMask: vk.PipelineStageFlags2,
    semaphore: vk.Semaphore,
) -> vk.SemaphoreSubmitInfo {
    submitInfo := vk.SemaphoreSubmitInfo {
        sType     = .SEMAPHORE_SUBMIT_INFO,
        semaphore = semaphore,
        stageMask = stageMask,
        value     = 1,
    }
    return submitInfo
}

command_buffer_submit_info :: proc(cmd: vk.CommandBuffer) -> vk.CommandBufferSubmitInfo {
    info := vk.CommandBufferSubmitInfo {
        sType         = .COMMAND_BUFFER_SUBMIT_INFO,
        commandBuffer = cmd,
    }
    return info
}

submit_info :: proc(
    cmd: ^vk.CommandBufferSubmitInfo,
    signalSemaphoreInfo: ^vk.SemaphoreSubmitInfo,
    waitSemaphoreInfo: ^vk.SemaphoreSubmitInfo,
) -> vk.SubmitInfo2 {
    info := vk.SubmitInfo2 {
        sType                    = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount   = waitSemaphoreInfo == nil ? 0 : 1,
        pWaitSemaphoreInfos      = waitSemaphoreInfo,
        signalSemaphoreInfoCount = signalSemaphoreInfo == nil ? 0 : 1,
        pSignalSemaphoreInfos    = signalSemaphoreInfo,
        commandBufferInfoCount   = 1,
        pCommandBufferInfos      = cmd,
    }
    return info
}

image_create_info :: proc(
    format: vk.Format,
    usageFlags: vk.ImageUsageFlags,
    extent: vk.Extent3D,
    tiling := vk.ImageTiling.OPTIMAL
) -> vk.ImageCreateInfo {
    info := vk.ImageCreateInfo {
        sType       = .IMAGE_CREATE_INFO,
        imageType   = .D2,
        format      = format,
        extent      = extent,
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = {._1},
        tiling      = tiling,
        usage       = usageFlags,
        sharingMode = .EXCLUSIVE,
    }
    return info
}

imageview_create_info :: proc(
    image: vk.Image,
    format: vk.Format,
    aspectFlags: vk.ImageAspectFlags,
    viewType: vk.ImageViewType,
) -> vk.ImageViewCreateInfo {
    info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = image,
        viewType = .D2,
        format = format,
        subresourceRange = {levelCount = 1, layerCount = 1, aspectMask = aspectFlags},
    }
    return info
}

buffer_create_info :: proc(
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    flags := vk.BufferCreateFlags{}
) -> vk.BufferCreateInfo {
    return {
        sType = .BUFFER_CREATE_INFO,
        size  = size,
        usage = usage,
        flags = flags,
        sharingMode = .EXCLUSIVE,
    }
}

allocation_create_info :: proc(
    usage: vma.Memory_Usage,
    memory_flags: vk.MemoryPropertyFlags,
    flags: vma.Allocation_Create_Flags = {},
) -> vma.Allocation_Create_Info {
    return {
        usage = usage,
        required_flags = memory_flags,
        flags = flags,
    }
}
