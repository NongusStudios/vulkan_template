package main

import "core:mem"
import sa "core:container/small_array"

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

    info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = size,
        usage = usage,
        flags = flags,
        sharingMode = .EXCLUSIVE,
    }

    vk_check(
        vma.create_buffer(
            state.global_allocator,
            info, allocation,
            &buffer.buffer, &buffer.allocation, nil),
    ) or_return
    
    
    buffer.size = size

    return buffer, true
}

create_staging_buffer :: proc(dst: Buffer, ) -> (staging_buffer: Buffer, ok: bool) {
    staging_buffer = create_buffer(
        dst.size, 
        { .TRANSFER_SRC }, 
        allocation_create_info(.Cpu_Only, { .HOST_VISIBLE, .HOST_COHERENT })
    ) or_return 

    return staging_buffer, true
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
    
    return true
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

    return image, true
}

destroy_image :: proc(self: Image) {
    state := get_vk_state()
    vk.DestroyImageView(state.device, self.view, nil)
    vma.destroy_image(state.global_allocator, self.image, self.allocation)
}

/*
    Descriptor Group
*/
Descriptor_Group :: struct {
    pool:    vk.DescriptorPool,
    sets:    []vk.DescriptorSet,
    layouts: []vk.DescriptorSetLayout,
}

destroy_descriptor_group :: proc(self: Descriptor_Group) {
    vk.DestroyDescriptorPool(get_vk_state().device, self.pool, nil)
    for layout in self.layouts {
        vk.DestroyDescriptorSetLayout(get_vk_state().device, layout, nil)
    }

    delete(self.sets)
    delete(self.layouts)
}

descriptor_group_allocate_sets :: proc(self: ^Descriptor_Group) -> (ok: bool) {
    alloc_info := vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = self.pool,
        descriptorSetCount = u32(len(self.sets)),
        pSetLayouts = raw_data(self.layouts[:])
    }

    vk_check(vk.AllocateDescriptorSets(
        get_vk_state().device,
        &alloc_info, raw_data(self.sets[:])
    )) or_return

    return true
}

// Resets and reallocates sets in the group
descriptor_group_reset :: proc(self: ^Descriptor_Group) -> (ok: bool) {
    vk.ResetDescriptorPool(get_vk_state().device, self.pool, {})
    descriptor_group_allocate_sets(self)
    return true
}

MAX_DESCRIPTOR_LAYOUT_BINDINGS :: 16
Descriptor_Layout_Bindings :: sa.Small_Array(MAX_DESCRIPTOR_LAYOUT_BINDINGS, vk.DescriptorSetLayoutBinding)
Descriptor_Layout_Info :: struct {
    bindings: Descriptor_Layout_Bindings,
    flags: vk.DescriptorSetLayoutCreateFlags,
}

Descriptor_Group_Builder :: struct {
    layout_bindings: [dynamic]Descriptor_Layout_Info,
    pool_sizes: map[vk.DescriptorType]u32,
    current: int,
    max_sets: u32,
}

create_descriptor_group_builder :: proc() -> Descriptor_Group_Builder {
    return {
        layout_bindings = make([dynamic]Descriptor_Layout_Info),
        pool_sizes = make(map[vk.DescriptorType]u32),
        current = -1,
    }
}

destroy_descriptor_group_builder :: proc(self: Descriptor_Group_Builder) {
    delete(self.layout_bindings)
    delete(self.pool_sizes)
}

// Adds a new set to the group and makes it the current one to be worked on
descriptor_group_builder_add_set :: proc(self: ^Descriptor_Group_Builder, layout_flags := vk.DescriptorSetLayoutCreateFlags{}) {
    append(&self.layout_bindings, Descriptor_Layout_Info{ flags = layout_flags })
    self.current = len(self.layout_bindings)-1
    self.max_sets += 1
}

// Adds a binding to the current set. The binding index starts at 0 and is incremented for each added binding
descriptor_group_builder_add_binding :: proc(self: ^Descriptor_Group_Builder,
    type: vk.DescriptorType,
    stage: vk.ShaderStageFlags,
    count: u32 = 1,
) {
    assert(self.current >= 0, "No active set - call descriptor_group_builder_add_set first")

    layout_info := &self.layout_bindings[self.current]
    assert(sa.len(layout_info.bindings) < MAX_DESCRIPTOR_LAYOUT_BINDINGS, "Too many bindings in set")

    sa.push_back(&layout_info.bindings, vk.DescriptorSetLayoutBinding{
        binding = u32(sa.len(layout_info.bindings)),
        descriptorType = type,
        descriptorCount = count,
        stageFlags = stage,
    })

    self.pool_sizes[type] += count
}

descriptor_group_builder_build :: proc(self: ^Descriptor_Group_Builder, pool_flags: vk.DescriptorPoolCreateFlags = {}) -> (group: Descriptor_Group, ok: bool) {
    group = Descriptor_Group {
        sets = make([]vk.DescriptorSet, self.max_sets),
        layouts = make([]vk.DescriptorSetLayout, self.max_sets),
    }

    for &layout_info, i in self.layout_bindings {
        create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            flags = layout_info.flags,
            bindingCount = u32(sa.len(layout_info.bindings)),
            pBindings = raw_data(sa.slice(&layout_info.bindings)),
        }

        vk_check(vk.CreateDescriptorSetLayout(
            get_vk_state().device, &create_info, nil, &group.layouts[i]
        )) or_return
    }

    sizes := make([]vk.DescriptorPoolSize, len(self.pool_sizes)); defer delete(sizes)
    
    i := 0
    for type, count in self.pool_sizes {
        sizes[i] = {
            type = type,
            descriptorCount = count,
        }
        i += 1
    }

    pool_info := vk.DescriptorPoolCreateInfo {
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets = self.max_sets,
        poolSizeCount = u32(len(sizes)),
        pPoolSizes = raw_data(sizes[:]),
        flags = pool_flags,
    }

    vk_check(vk.CreateDescriptorPool(
        get_vk_state().device,
        &pool_info, nil, &group.pool,
    )) or_return

    descriptor_group_allocate_sets(&group) or_return

    return group, true
}

/*
    Descriptor Writer
*/
Descriptor_Write_Image_Single :: struct {
    type:   vk.DescriptorType,
    image: vk.DescriptorImageInfo,
}

Descriptor_Write_Buffer_Single :: struct {
    type:    vk.DescriptorType,
    buffer: vk.DescriptorBufferInfo,
}

Descriptor_Write_Images :: struct {
    type:   vk.DescriptorType,
    images: [dynamic]vk.DescriptorImageInfo,
}

Descriptor_Write_Buffers :: struct {
    type:    vk.DescriptorType,
    buffers: [dynamic]vk.DescriptorBufferInfo,
}

Descriptor_Write :: union {
    Descriptor_Write_Image_Single,
    Descriptor_Write_Buffer_Single,
    Descriptor_Write_Images,
    Descriptor_Write_Buffers,
}

Descriptor_Writer :: struct {
    writes: [dynamic]Descriptor_Write,
    current: int,
}

create_descriptor_writer :: proc() -> Descriptor_Writer {
    return {
        writes = make([dynamic]Descriptor_Write),
        current = -1,
    }
}

destroy_descriptor_writer :: proc(self: ^Descriptor_Writer) {
    descriptor_writer_reset(self)
    delete(self.writes)
}

descriptor_writer_reset :: proc(self: ^Descriptor_Writer) {
    for &write in self.writes {
        #partial switch w in write {
        case Descriptor_Write_Images: delete(w.images)
        case Descriptor_Write_Buffers: delete(w.buffers)
        }
    }
    clear(&self.writes)
    self.current = -1
}

// Add a multi image write that can be written to with append_write
descriptor_writer_add_images_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType) {
    append(&self.writes, Descriptor_Write_Images {
        type = type,
        images = make([dynamic]vk.DescriptorImageInfo),
    })
    self.current += 1
}

// Add a multi buffer write that can be written to with append_write
descriptor_writer_add_buffers_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType) {
    append(&self.writes, Descriptor_Write_Buffers {
        type = type,
        buffers = make([dynamic]vk.DescriptorBufferInfo),
    })
    self.current += 1
}

descriptor_writer_append_write :: proc{
    descriptor_writer_append_image_write,
    descriptor_writer_append_buffer_write,
}

// Append image info to current images write
descriptor_writer_append_image_write :: proc(self: ^Descriptor_Writer, image: vk.DescriptorImageInfo) {
    assert(self.current >= 0, "No active write - call add_images_write first")
    write, ok := self.writes[self.current].(Descriptor_Write_Images)
    assert(ok, "Active write is not the correct type - call add_images_write first")

    append(&write.images, image)
}

// Append buffer info to current buffers write
descriptor_writer_append_buffer_write :: proc(self: ^Descriptor_Writer, buffer: vk.DescriptorBufferInfo) {
    assert(self.current >= 0, "No active write - call add_buffers_write first")
    write, ok := self.writes[self.current].(Descriptor_Write_Buffers)
    assert(ok, "Active write is not the correct type - call add_buffers_write first")
    
    append(&write.buffers, buffer)
}

descriptor_writer_add_single_image_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType, image: vk.DescriptorImageInfo) {
    append(&self.writes, Descriptor_Write_Image_Single {
        type = type,
        image = image,
    })
    self.current += 1
}

descriptor_writer_add_single_buffer_write :: proc(self: ^Descriptor_Writer, type: vk.DescriptorType, buffer: vk.DescriptorBufferInfo) {
    append(&self.writes, Descriptor_Write_Buffer_Single {
        type = type,
        buffer = buffer,
    })
    self.current += 1
}

// Applies queued writes to a set. dstBinding is in the order of writes
descriptor_writer_write_set :: proc(self: ^Descriptor_Writer, set: vk.DescriptorSet) {
    write_infos := make([]vk.WriteDescriptorSet, len(self.writes)); defer delete(write_infos)

    for &write, binding in self.writes {
        write_info := &write_infos[binding]
        write_info.sType  = .WRITE_DESCRIPTOR_SET
        write_info.dstSet = set
        write_info.dstBinding = u32(binding)

        switch &w in write {
        case Descriptor_Write_Image_Single:
            write_info.descriptorType = w.type
            write_info.descriptorCount = 1
            write_info.pImageInfo = &w.image
        case Descriptor_Write_Buffer_Single:
            write_info.descriptorType = w.type
            write_info.descriptorCount = 1
            write_info.pBufferInfo = &w.buffer
        case Descriptor_Write_Images:
            write_info.descriptorType = w.type
            write_info.descriptorCount = u32(len(w.images))
            write_info.pImageInfo = raw_data(w.images[:])
        case Descriptor_Write_Buffers:
            write_info.descriptorType = w.type
            write_info.descriptorCount = u32(len(w.buffers))
            write_info.pBufferInfo = raw_data(w.buffers[:])
        }
    }

    vk.UpdateDescriptorSets(get_vk_state().device, u32(len(write_infos)), raw_data(write_infos[:]), 0, nil)
}
