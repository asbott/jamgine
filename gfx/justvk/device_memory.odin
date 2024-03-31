package justvk

import vk "vendor:vulkan"

Device_Memory_Handle :: struct {
    dc : ^Device_Context,
    page : vk.DeviceMemory,
    byte_index : vk.DeviceSize,
}

Any_Memory_Resource :: union { vk.Buffer, vk.Image }
request_and_bind_device_memory :: proc(resource : Any_Memory_Resource, flags : []vk.MemoryPropertyFlag, using dc : ^Device_Context) -> Device_Memory_Handle {
    // #Incomplete #Temporary
    // Since number of allocations is limited in vulkan we should manage memory
    // in something like pages instead, maybe with best-fit or something, probably
    // not block allocators because memory fragmentation in device memory is likely
    // terrible. But for now we just allocate per request because it's not a problem
    // yet.
    // However !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // Allocating in pages need that if we do multithreading then we need to
    // properly sync mapping to the different pages because a page can only be
    // mapped once at a time (I think)
    requirements : vk.MemoryRequirements;
    
    switch v in resource {
        case vk.Buffer: vk.GetBufferMemoryRequirements(vk_device, v, &requirements);
        case vk.Image: vk.GetImageMemoryRequirements(vk_device, v, &requirements);
    }

    handle :=  request_device_memory(cast(int)requirements.size, cast(int)requirements.alignment, flags, requirements.memoryTypeBits, dc);

    switch v in resource {
        case vk.Buffer: vk.BindBufferMemory(vk_device, v, handle.page, handle.byte_index);
        case vk.Image: vk.BindImageMemory(vk_device, v, handle.page, handle.byte_index);
    }

    return handle;
}
request_device_memory :: proc(number_of_bytes : int, alignment : int, flags : []vk.MemoryPropertyFlag, type_bits : u32, using dc : ^Device_Context) -> Device_Memory_Handle {

    alloc_info : vk.MemoryAllocateInfo;
    alloc_info.sType = .MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = cast(vk.DeviceSize)number_of_bytes;
    alloc_info.memoryTypeIndex = find_memory_index(dc, type_bits, flags);

    handle : Device_Memory_Handle;
    if vk.AllocateMemory(vk_device, &alloc_info, nil, &handle.page) != .SUCCESS {
        panic("Failed to allocate vertex buffer memory");
    }
    handle.dc = dc;

    return handle;
}
free_device_memory :: proc(handle : Device_Memory_Handle) {
    using handle.dc;
    // #Incomplete #Temporary
    assert(handle.byte_index == 0);
    // #Incomplete
    // #Incomplete
    // #Incomplete
    // #Incomplete
    vk.FreeMemory(vk_device, handle.page, nil);
}

// #Sync
map_device_memory :: proc(handle : Device_Memory_Handle, size : int) -> rawptr {
    assert(handle.page != 0, "Mapping unallocated buffer");
    mapped_data : rawptr;
    vk.MapMemory(handle.dc.vk_device, handle.page, handle.byte_index, cast(vk.DeviceSize)size, {}, &mapped_data);
    return mapped_data;    
}

// #Sync
unmap_device_memory :: proc(handle : Device_Memory_Handle) {
    vk.UnmapMemory(handle.dc.vk_device, handle.page);
}