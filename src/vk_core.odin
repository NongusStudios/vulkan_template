package main

import "core:mem"
import vk  "vendor:vulkan"
import vma "../lib/vma"

/*
    Buffer 
*/
Buffer :: struct {
    buffer:     vk.Buffer,
    allocation: vma.Allocation,
    size:       vk.DeviceSize,
}

create_buffer :: proc(
    size:  vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    allocation: vma.Allocation_Create_Info,
    flags := vk.BufferCreateFlags{}
) -> (buffer: Buffer, ok: bool){
    state := get_vk_state()

    info := buffer_create_info(
        size,
        usage,
        flags
    )

    vk_check(
        vma.create_buffer(
            state.global_allocator,
            info, allocation,
            &buffer.buffer, &buffer.allocation, nil),
    ) or_return
    
    
    buffer.size = size

    ok = true
    return
}

create_staging_buffer :: proc(dst: Buffer, ) -> (staging_buffer: Buffer, ok: bool) {
    staging_buffer = create_buffer(
        dst.size, 
        { .TRANSFER_SRC }, 
        allocation_create_info(.Cpu_Only, { .HOST_VISIBLE, .HOST_COHERENT })
    ) or_return 

    ok = true
    return
}

destroy_buffer :: proc(self: Buffer) {
    state := get_vk_state()
    vma.destroy_buffer(state.global_allocator, self.buffer, self.allocation)
}

/*
    Writes to a CPU accessible buffer with data. 
    NOTE: Buffer should have HOST_COHERENT flag or memory will not be flushed
    SECOND NOTE: Not sure if the offset logic works, will come back to this
*/
buffer_write :: proc(self: Buffer, data: []$T, offset: int = 0) -> (ok: bool) {
    ensure(self.size >= vk.DeviceSize((len(data) + offset) * size_of(T)))

    state := get_vk_state()

    mapped_memory: rawptr
    vk_check(
        vma.map_memory(state.global_allocator, self.allocation, &mapped_memory)
    ) or_return
    
    if offset > 0 {
        dst := mem.ptr_offset((^T)(mapped_memory), offset)
        mem.copy_non_overlapping(rawptr(dst), raw_data(data[:]), len(data) * size_of(T))
    } else {
        mem.copy_non_overlapping(mapped_memory, raw_data(data[:]), len(data) * size_of(T))
    }

    vma.unmap_memory(state.global_allocator, self.allocation)
    
    ok = true
    return
}

/*
    Image
*/
Image :: struct {
    image: vk.Image,
    view: vk.ImageView,
    extent: vk.Extent3D,
    format: vk.Format,
    allocation: vma.Allocation,
}

create_image :: proc(
    format: vk.Format,
    extent: vk.Extent3D,
    usage_flags: vk.ImageUsageFlags,
    view_type: vk.ImageViewType,
    view_aspect_flags: vk.ImageAspectFlags,
    allocation_info: vma.Allocation_Create_Info,
    tiling := vk.ImageTiling.OPTIMAL,
) -> (image: Image, ok: bool) {
    state := get_vk_state()

    image_info := image_create_info(
        format,
        usage_flags,
        extent,
        tiling,
    )

    vk_check(
        vma.create_image(
            state.global_allocator,
            image_info,
            allocation_info,
            &image.image, &image.allocation,
            nil
        )
    ) or_return
    defer if !ok {
        vma.destroy_image(state.global_allocator, image.image, image.allocation)
    }
    
    view_info := imageview_create_info(
        image.image,
        format,
        view_aspect_flags,
        view_type,
    )
    vk_check(
        vk.CreateImageView(state.device, &view_info, nil, &image.view)
    ) or_return
    
    image.extent = extent
    image.format = format

    ok = true
    return
}

destroy_image :: proc(self: Image) {
    state := get_vk_state()
    vk.DestroyImageView(state.device, self.view, nil)
    vma.destroy_image(state.global_allocator, self.image, self.allocation)
}
