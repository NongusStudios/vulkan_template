package main

import vk "vendor:vulkan"
import sa "core:container/small_array"

start_one_time_commands :: proc() -> (cmd: vk.CommandBuffer, ok: bool) {
    state := get_vk_state()

    alloc_info := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = state.transfer_command_pool,
        commandBufferCount = 1,
        level = .PRIMARY,
    }

    vk_check(
        vk.AllocateCommandBuffers(state.device, &alloc_info, &cmd)
    ) or_return
    
    begin := command_buffer_begin_info({.ONE_TIME_SUBMIT})

    vk_check(
        vk.BeginCommandBuffer(cmd, &begin)
    ) or_return

    ok = true
    return
}

submit_one_time_commands :: proc(cmd: ^vk.CommandBuffer) {
    state := get_vk_state()

    vk.EndCommandBuffer(cmd^)

    cmd_info := command_buffer_submit_info(cmd^)
    submit := submit_info(&cmd_info, nil, nil)

    vk.QueueSubmit2(state.graphics.queue, 1, &submit, state.one_time_fence)
    
    // Let cpu hang until one time commands are complete
    vk.WaitForFences(state.device, 1, &state.one_time_fence, true, 1e9)
    vk.ResetFences(state.device, 1, &state.one_time_fence)

    vk.FreeCommandBuffers(state.device, state.transfer_command_pool, 1, cmd)
}

cmd_copy_image :: proc(
    cmd: vk.CommandBuffer,
    src: vk.Image,
    dst: vk.Image,
    src_size: vk.Extent2D,
    dst_size: vk.Extent2D,
    aspect_mask: vk.ImageAspectFlags,
) {
    blit_region := vk.ImageBlit2 {
        sType = .IMAGE_BLIT_2,
        pNext = nil,
        srcOffsets = [2]vk.Offset3D {
            {0, 0, 0},
            {x = i32(src_size.width), y = i32(src_size.height), z = 1},
        },
        dstOffsets = [2]vk.Offset3D {
            {0, 0, 0},
            {x = i32(dst_size.width), y = i32(dst_size.height), z = 1},
        },
        srcSubresource = {aspectMask = aspect_mask, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
        dstSubresource = {aspectMask = aspect_mask, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
    }

    blit_info := vk.BlitImageInfo2 {
        sType          = .BLIT_IMAGE_INFO_2,
        srcImage       = src,
        srcImageLayout = .TRANSFER_SRC_OPTIMAL,
        dstImage       = dst,
        dstImageLayout = .TRANSFER_DST_OPTIMAL,
        filter         = .LINEAR,
        regionCount    = 1,
        pRegions       = &blit_region,
    }

    vk.CmdBlitImage2(cmd, &blit_info)
}

cmd_copy_buffer :: proc(
    cmd: vk.CommandBuffer,
    src: vk.Buffer,
    dst: vk.Buffer,
    src_offset: vk.DeviceSize,
    size: vk.DeviceSize,
) {
    region := vk.BufferCopy {
        size = size,
        srcOffset = src_offset,
    }
    vk.CmdCopyBuffer(cmd,
        src, dst,
        1, &region
    )
}

cmd_transition_image :: proc(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    current_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) {
    image_barrier := vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
    }
    
    // .ALL_COMMANDS is inefficient and will be changed in future
    image_barrier.srcStageMask = {.ALL_COMMANDS}
    image_barrier.srcAccessMask = {.MEMORY_WRITE}
    image_barrier.dstStageMask = {.ALL_COMMANDS}
    image_barrier.dstAccessMask = {.MEMORY_WRITE, .MEMORY_READ}

    image_barrier.oldLayout = current_layout
    image_barrier.newLayout = new_layout

    aspect_mask: vk.ImageAspectFlags =
        {.DEPTH} if new_layout == .DEPTH_ATTACHMENT_OPTIMAL else {.COLOR}

    image_barrier.subresourceRange = image_subresource_range(aspect_mask)
    image_barrier.image = image

    dep_info := vk.DependencyInfo {
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers    = &image_barrier,
    }

    vk.CmdPipelineBarrier2(cmd, &dep_info)
}

MAX_MEMORY_BARRIERS :: 32
Memory_Barriers :: sa.Small_Array(MAX_MEMORY_BARRIERS, vk.MemoryBarrier2)
Buffer_Barriers :: sa.Small_Array(MAX_MEMORY_BARRIERS, vk.BufferMemoryBarrier2)
Image_Barriers  :: sa.Small_Array(MAX_MEMORY_BARRIERS, vk.ImageMemoryBarrier2)
Pipeline_Barrier :: struct {
    memory_barriers: Memory_Barriers,
    buffer_barriers: Buffer_Barriers,
    image_barriers:  Image_Barriers,

    src_family: u32,
    dst_family: u32,
}

pipeline_barrier_reset :: proc(self: ^Pipeline_Barrier) {
    sa.clear(&self.memory_barriers)
    sa.clear(&self.buffer_barriers)
    sa.clear(&self.image_barriers)
}

// If setting up a queue transfer call this before adding any relevant barriers
pipeline_barrier_set_queue_transfer :: proc(self: ^Pipeline_Barrier,
    src_family: u32,
    dst_family: u32,
) {
    self.src_family = src_family
    self.dst_family = dst_family
}

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
) {
    assert(sa.len(self.memory_barriers) < MAX_MEMORY_BARRIERS, "Too many memory barriers in pipeline barrier")
    sa.push_back(&self.memory_barriers, vk.MemoryBarrier2 {
        sType = .MEMORY_BARRIER_2,
        srcStageMask  = src_stage,
        srcAccessMask = src_access,
        dstStageMask  = dst_stage,
        dstAccessMask = dst_access,
    })
}

pipeline_barrier_add_buffer_barrier :: proc(self: ^Pipeline_Barrier,
    src_stage:  vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage:  vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
    buffer: vk.Buffer,
    offset := vk.DeviceSize(0),
    size   := vk.DeviceSize(vk.WHOLE_SIZE),
) {
    assert(sa.len(self.memory_barriers) < MAX_MEMORY_BARRIERS, "Too many buffer barriers in pipeline barrier")
    sa.push_back(&self.buffer_barriers, vk.BufferMemoryBarrier2 {
        sType = .BUFFER_MEMORY_BARRIER_2,
        srcStageMask  = src_stage,
        srcAccessMask = src_access,
        dstStageMask  = dst_stage,
        dstAccessMask = dst_access,
        buffer = buffer,
        offset = offset,
        size   = size,

        srcQueueFamilyIndex = self.src_family,
        dstQueueFamilyIndex = self.dst_family,
    })
}

pipeline_barrier_add_image_barrier :: proc(self: ^Pipeline_Barrier,
    src_stage:  vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage:  vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    image: vk.Image,
    subresource_range: vk.ImageSubresourceRange,
) {
    assert(sa.len(self.memory_barriers) < MAX_MEMORY_BARRIERS, "Too many image barriers in pipeline barrier")
    sa.push_back(&self.image_barriers, vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = src_stage,
        srcAccessMask = src_access,
        dstStageMask  = dst_stage,
        dstAccessMask = dst_access,
        oldLayout     = old_layout,
        newLayout     = new_layout,
        image            = image,
        subresourceRange = subresource_range,

        srcQueueFamilyIndex = self.src_family,
        dstQueueFamilyIndex = self.dst_family,
    })
}

// Executes a Pipeline_Barrier and resets the structure so it can be used for another barrier
cmd_pipeline_barrier :: proc(cmd: vk.CommandBuffer,
    barrier: ^Pipeline_Barrier,
    flags := vk.DependencyFlags {},
    reset := true
) {
    dep_info := vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        dependencyFlags = flags,
        
        memoryBarrierCount = u32(sa.len(barrier.memory_barriers)),
        pMemoryBarriers    = raw_data(sa.slice(&barrier.memory_barriers)),
        
        bufferMemoryBarrierCount = u32(sa.len(barrier.buffer_barriers)),
        pBufferMemoryBarriers    = raw_data(sa.slice(&barrier.buffer_barriers)),

        imageMemoryBarrierCount = u32(sa.len(barrier.image_barriers)),
        pImageMemoryBarriers    = raw_data(sa.slice(&barrier.image_barriers)),
    }

    vk.CmdPipelineBarrier2(cmd, &dep_info)

    if reset { pipeline_barrier_reset(barrier) }
}
