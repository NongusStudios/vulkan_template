package main

import "core:mem"
// Core
import intr "base:intrinsics"
import "base:runtime"
import "core:log"

// Vendor
import vk "vendor:vulkan"
import vkb "../lib/vkb"
import vma "../lib/vma"

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
    Pipeline,
    Descriptor_Group,
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
        case Pipeline: destroy_pipeline(res) 
        case Descriptor_Group: destroy_descriptor_group(res)
        }
    }

    clear(&self.resources)
}

// Initialisers
image_subresource_range :: proc(aspectMask: vk.ImageAspectFlags) -> vk.ImageSubresourceRange {
    return {
        aspectMask = aspectMask,
        levelCount = vk.REMAINING_MIP_LEVELS,
        layerCount = vk.REMAINING_ARRAY_LAYERS,
    }
}

image_subresource_layers :: proc(
    aspect_mask: vk.ImageAspectFlags,
    layer_count := u32(1),
    base_layer := u32(0),
    mip_level := u32(0),
) -> vk.ImageSubresourceLayers {
    return {
        aspectMask = aspect_mask,
        baseArrayLayer = base_layer,
        layerCount = layer_count,
        mipLevel = mip_level,
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

allocation_info :: proc(
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

rendering_info :: proc(
	renderExtent: vk.Extent2D,
	colorAttachment: ^vk.RenderingAttachmentInfo,
	depthAttachment: ^vk.RenderingAttachmentInfo,
    stencilAttachment: ^vk.RenderingAttachmentInfo = nil,
    layerCount := u32(1),
) -> vk.RenderingInfo {
	renderInfo := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = vk.Rect2D{extent = renderExtent},
		layerCount = layerCount,
		colorAttachmentCount = 1,
		pColorAttachments = colorAttachment,
		pDepthAttachment = depthAttachment,
        pStencilAttachment = stencilAttachment,
	}
	return renderInfo
}

attachment_info :: proc(
    view: vk.ImageView,
    clear: ^vk.ClearValue,
    layout: vk.ImageLayout,
) -> vk.RenderingAttachmentInfo {
    colorAttachment := vk.RenderingAttachmentInfo {
        sType       = .RENDERING_ATTACHMENT_INFO,
        imageView   = view,
        imageLayout = layout,
        loadOp      = clear != nil ? .CLEAR : .LOAD,
        storeOp     = .STORE,
    }
    if clear != nil {
        colorAttachment.clearValue = clear^
    }
    return colorAttachment
}
