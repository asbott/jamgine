package justvk

import "core:mem"
import "core:builtin"
import "core:intrinsics"
import "core:fmt"

import vk "vendor:vulkan"

// #Unused ?
Buffer_Kind :: enum {
    CUSTOM, VERTEX, INDEX, UNIFORM, STORAGE,
}
Buffer_Storage_Kind :: enum {
    // Store in ram and guaranteed instantly reflect on GPU
    RAM_SYNCED,
    // Store in ram and guarantee reflect on GPU when flush
    RAM_UNSYNCED,

    // "Improvise" with each transfer by creating and destroying
    // a staging buffer.
    VRAM_WITH_IMPROVISED_STAGING_BUFFER,

    // Keep a staging buffer allocated for transfers.
    VRAM_WITH_CONSTANT_STAGING_BUFFER,
}

Buffer :: struct {
    dc : ^Device_Context,

    kind      : Buffer_Kind,
    storage   : Buffer_Storage_Kind,
    vk_buffer : vk.Buffer,
    memory    : Device_Memory_Handle,
    size      : int,

    // Only valid if stored in RAM
    data_pointer : rawptr,

    // Only valid with constant staging buffer flag
    staging_buffer : vk.Buffer,
    staging_memory : Device_Memory_Handle,
    transfer_command_buffer : vk.CommandBuffer,
}

Vertex_Buffer :: struct {
    using base : Buffer,

    layout       : Vertex_Layout,
    vertex_count : int,
}

Index_Buffer :: struct {
    using base : Buffer,

    index_count : int,
}

Uniform_Buffer :: struct {
    using base : Buffer,

    desc_info : vk.DescriptorBufferInfo,
}

Storage_Buffer :: struct {
    using base : Buffer,

    desc_info : vk.DescriptorBufferInfo,
}

init_buffer_base :: proc(dc : ^Device_Context, buffer : ^Buffer, size : int, usage : vk.BufferUsageFlags, sharing_mode : vk.SharingMode, storage_kind : Buffer_Storage_Kind, kind : Buffer_Kind, initial_data : rawptr = nil) {
    buffer.dc = dc;
    buffer_info : vk.BufferCreateInfo;
    buffer_info.sType = .BUFFER_CREATE_INFO;
    buffer_info.size = cast(vk.DeviceSize)size;
    buffer_info.usage = usage;
    buffer_info.sharingMode = sharing_mode;

    if vk.CreateBuffer(dc.vk_device, &buffer_info, nil, &buffer.vk_buffer) != .SUCCESS {
        panic("Failed to create vertex buffer");
    }
    buffer.size = cast(int)size;
    buffer.kind = kind;
    buffer.storage = storage_kind;
    switch storage_kind {
        case .RAM_UNSYNCED: {
            allocate_buffer_memory(buffer, { .HOST_VISIBLE }, size, initial_data);
        }
        case .RAM_SYNCED: {
            allocate_buffer_memory(buffer, { .HOST_COHERENT, .HOST_VISIBLE }, size, initial_data);
        }
        case .VRAM_WITH_CONSTANT_STAGING_BUFFER: {
            fallthrough;
        }
        case .VRAM_WITH_IMPROVISED_STAGING_BUFFER: {
            allocate_buffer_memory(buffer, { .DEVICE_LOCAL }, size, initial_data);
        }
    }
}
destroy_buffer_base :: proc(buffer : ^Buffer) {
    using buffer.dc;
    vk.DeviceWaitIdle(buffer.dc.vk_device);

    

    switch buffer.storage {
        case .VRAM_WITH_CONSTANT_STAGING_BUFFER: {
            destroy_staging_buffer(buffer.staging_buffer, buffer.staging_memory, buffer.dc);
            vk.FreeCommandBuffers(vk_device, transfer_pool, 1, &buffer.transfer_command_buffer);
        }
        case .VRAM_WITH_IMPROVISED_STAGING_BUFFER: {}
        case .RAM_SYNCED: {
            unmap_device_memory(buffer.memory);
        }
        case .RAM_UNSYNCED : {
            unmap_device_memory(buffer.memory);
        }
    }
    
    vk.DestroyBuffer(vk_device, buffer.vk_buffer, nil);
    deallocate_buffer_memory(buffer);
}
make_custom_buffer :: proc(dc : ^Device_Context, size : int, usage : vk.BufferUsageFlags, sharing_mode : vk.SharingMode, storage_kind : Buffer_Storage_Kind) -> ^Buffer {
    buffer := new(Buffer);
    init_buffer_base(dc, buffer, size, usage, sharing_mode, storage_kind, .CUSTOM);
    return buffer;
}
destroy_custom_buffer :: proc(buffer : ^Buffer) {
    destroy_buffer_base(buffer);
    free(buffer);
}
allocate_buffer_memory :: proc(buffer : ^Buffer, required_properties : []vk.MemoryPropertyFlag, size : int, data : rawptr = nil) {
    using buffer.dc;

    if buffer.memory.page != 0 {
        panic("Buffer has already been bound to memory, cannot allocate again.");
    }

    buffer.memory = request_and_bind_device_memory(buffer.vk_buffer, required_properties, buffer.dc);
    
    if data != nil {
        set_buffer_data(buffer, data, size);
    }

}
deallocate_buffer_memory :: proc(buffer : ^Buffer) {
    using buffer.dc;
    free_device_memory(buffer.memory);
}
map_buffer :: proc(buffer : ^Buffer, size : int) -> rawptr {
    if buffer.data_pointer != nil do return buffer.data_pointer;
    return map_device_memory(buffer.memory, size);
}
unmap_buffer :: proc(buffer : ^Buffer) {
    if buffer.data_pointer != nil do return;
    unmap_device_memory(buffer.memory);
}
set_buffer_data :: proc(buffer : ^Buffer, data : rawptr, size : int) {
    using buffer.dc;
    assert(buffer.memory.page != 0, "Setting unallocated buffer");

    assert(size <= buffer.size, "Buffer overflow");

    switch buffer.storage {
        case .VRAM_WITH_IMPROVISED_STAGING_BUFFER: {
            transfer_data_to_device_buffer_improvised(data, buffer.vk_buffer, cast(vk.DeviceSize)size, buffer.dc);
        }
        case .VRAM_WITH_CONSTANT_STAGING_BUFFER: {

            if buffer.staging_buffer == 0 {
                // #Speed ?
                // DST and SRC are not always needed
                buffer.staging_buffer, buffer.staging_memory = make_staging_buffer(cast(vk.DeviceSize)size, .TRANSFER_DST_AND_SRC, buffer.dc);
        
                alloc_info : vk.CommandBufferAllocateInfo;
                alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
                alloc_info.level = .PRIMARY;
                alloc_info.commandPool = transfer_pool;
                alloc_info.commandBufferCount = 1;
                
                vk.AllocateCommandBuffers(vk_device, &alloc_info, &buffer.transfer_command_buffer);
            }

            staging_ptr := map_device_memory(buffer.staging_memory, size);
            mem.copy(staging_ptr, data, size);
            unmap_device_memory(buffer.staging_memory);
            
            begin_info : vk.CommandBufferBeginInfo;
            begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
            //begin_info.flags = {.SIMULTANEOUS_USE}; // Why?
            begin_info.flags = {};

            vk.BeginCommandBuffer(buffer.transfer_command_buffer, &begin_info);

            copy_region : vk.BufferCopy;
            copy_region.srcOffset = 0;
            copy_region.dstOffset = 0;
            copy_region.size = cast(vk.DeviceSize)size;
            vk.CmdCopyBuffer(buffer.transfer_command_buffer, buffer.staging_buffer, buffer.vk_buffer, 1, &copy_region);
            
            vk.EndCommandBuffer(buffer.transfer_command_buffer);


            submit_info : vk.SubmitInfo;
            submit_info.sType = .SUBMIT_INFO;
            submit_info.commandBufferCount = 1;
            submit_info.pCommandBuffers = &buffer.transfer_command_buffer;
            
            vk.QueueSubmit(queues.transfer, 1, &submit_info, 0);

            // #Speed #Sync
            // #Speed #Sync
            // #Speed #Sync
            // #Speed #Sync
            // This should maybe be the standard but have an async options which returns
            // a semaphore that needs to be waited on, likely passed to end_draw_commands.
            // We should be able to queue more transfer commands
            // without needing to wait for the previous one I think?
            // But in such cases maybe there is no reason to not use
            // STORE_IN_RAM_SYNC instead.
            vk.QueueWaitIdle(queues.transfer);
        }
        case .RAM_SYNCED, .RAM_UNSYNCED: {
            if buffer.data_pointer == nil {
                buffer.data_pointer = map_device_memory(buffer.memory, buffer.size);
            }
            mem.copy(buffer.data_pointer, data, size);
        }
    }
}
read_buffer_data :: proc(buffer : ^Buffer, result : rawptr) {
    using buffer.dc;

    switch buffer.storage {
        case .VRAM_WITH_IMPROVISED_STAGING_BUFFER: {
            
            staging_buffer, staging_memory := make_staging_buffer(cast(vk.DeviceSize)buffer.size, .TRANSFER_DST, buffer.dc);
            defer destroy_staging_buffer(staging_buffer, staging_memory, dc=buffer.dc);

            command_buffer := begin_single_use_command_buffer(buffer.dc);

            copy_region : vk.BufferCopy;
            copy_region.srcOffset = 0;
            copy_region.dstOffset = 0;
            copy_region.size = cast(vk.DeviceSize)buffer.size;
            vk.CmdCopyBuffer(command_buffer, buffer.vk_buffer, staging_buffer, 1, &copy_region);

            submit_and_destroy_single_use_command_buffer(command_buffer, dc=buffer.dc);

            mapped_ptr := map_buffer(buffer, buffer.size);
            mem.copy(result, mapped_ptr, buffer.size);
            unmap_buffer(buffer);
        }
        case .VRAM_WITH_CONSTANT_STAGING_BUFFER: {
            
            if buffer.staging_buffer == 0 {
                // #Speed ?
                // DST and SRC are not always needed
                buffer.staging_buffer, buffer.staging_memory = make_staging_buffer(cast(vk.DeviceSize)buffer.size, .TRANSFER_DST_AND_SRC, buffer.dc);
                
                alloc_info : vk.CommandBufferAllocateInfo;
                alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
                alloc_info.level = .PRIMARY;
                alloc_info.commandPool = transfer_pool;
                alloc_info.commandBufferCount = 1;
                
                vk.AllocateCommandBuffers(vk_device, &alloc_info, &buffer.transfer_command_buffer);
            }
            staging_buffer, staging_memory := buffer.staging_buffer, buffer.staging_memory;

            begin_info : vk.CommandBufferBeginInfo;
            begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
            begin_info.flags = {.SIMULTANEOUS_USE};

            vk.BeginCommandBuffer(buffer.transfer_command_buffer, &begin_info);

            command_buffer := buffer.transfer_command_buffer;
            copy_region : vk.BufferCopy;
            copy_region.srcOffset = 0;
            copy_region.dstOffset = 0;
            copy_region.size = cast(vk.DeviceSize)buffer.size;
            vk.CmdCopyBuffer(command_buffer, buffer.vk_buffer, staging_buffer, 1, &copy_region);

            vk.EndCommandBuffer(command_buffer);

            submit_info : vk.SubmitInfo;
            submit_info.sType = .SUBMIT_INFO;
            submit_info.commandBufferCount = 1;
            submit_info.pCommandBuffers = &buffer.transfer_command_buffer;
            
            vk.QueueSubmit(queues.transfer, 1, &submit_info, 0);
            // #Speed #Sync
            vk.QueueWaitIdle(queues.transfer);

            mapped_ptr := map_device_memory(staging_memory, buffer.size);
            mem.copy(result, mapped_ptr, buffer.size);
            unmap_device_memory(staging_memory);
        }
        case .RAM_SYNCED, .RAM_UNSYNCED: {
            if buffer.data_pointer == nil {
                buffer.data_pointer = map_device_memory(buffer.memory, buffer.size);
            }
            mem.copy(result, buffer.data_pointer, buffer.size);
        }
    }

    
}

make_vertex_buffer :: proc(vertices : []$Vertex_Type, storage_kind : Buffer_Storage_Kind, using dc := target_dc) -> ^Vertex_Buffer {
    vbo := new(Vertex_Buffer);

    size := (size_of(Vertex_Type) * len(vertices));
    init_buffer_base(dc, vbo, size, {.VERTEX_BUFFER, .TRANSFER_DST}, .EXCLUSIVE, storage_kind, .VERTEX, builtin.raw_data(vertices));

    vbo.layout = make_vertex_layout_from_type(Vertex_Type);
    vbo.vertex_count = len(vertices);

    return vbo;
}
destroy_vertex_buffer :: proc(vbo : ^Vertex_Buffer) {
    destroy_vertex_layout(vbo.layout);
    destroy_buffer_base(vbo);
    free(vbo);
}

make_index_buffer :: proc(indices : []u32, storage_kind : Buffer_Storage_Kind, using dc := target_dc) -> ^Index_Buffer {
    ibo := new(Index_Buffer);

    size := (size_of(u32) * len(indices));
    init_buffer_base(dc, ibo, size, {.INDEX_BUFFER, .TRANSFER_DST}, .EXCLUSIVE, storage_kind, .INDEX, builtin.raw_data(indices));

    ibo.index_count = len(indices);

    return ibo;
}
destroy_index_buffer :: proc(ibo : ^Index_Buffer) {
    destroy_buffer_base(ibo);
    free(ibo);
}

make_uniform_buffer_from_size :: proc(size : int, storage_kind : Buffer_Storage_Kind, using dc := target_dc) -> ^Uniform_Buffer {
    ubo := new(Uniform_Buffer);

    init_buffer_base(dc, ubo, size, {.UNIFORM_BUFFER, .TRANSFER_DST}, .EXCLUSIVE, storage_kind, .UNIFORM, nil);

    ubo.desc_info.buffer = ubo.vk_buffer;
    ubo.desc_info.offset = 0;
    ubo.desc_info.range = cast(vk.DeviceSize)size;

    return ubo;
}
make_uniform_buffer_from_type :: proc($T : typeid, storage_kind : Buffer_Storage_Kind, using dc := target_dc) -> ^Uniform_Buffer {
    ubo := make_uniform_buffer_from_size(size_of(T), storage_kind, dc);
    zero : T; 
    set_buffer_data(ubo, &zero, size_of(T)); // #Speed zero initialization
    return ubo;
}
make_uniform_buffer :: proc {
    make_uniform_buffer_from_size,
    make_uniform_buffer_from_type,
}
destroy_uniform_buffer :: proc(ubo : ^Uniform_Buffer) {
    using ubo.dc;

    vk.DeviceWaitIdle(vk_device);

    // #Sync
    for p in pipelines {
        for record,record_i in p.bind_records {
            for item, i in record.bound_resources {
                #partial switch resource in item {
                    case ^Uniform_Buffer: bind_uniform_buffer(p, null_ubo, record.binding_location, i);
                }
            }
        }
    }

    destroy_buffer_base(ubo);
    free(ubo);
}

make_storage_buffer_from_size :: proc(size : int, storage_kind : Buffer_Storage_Kind, using dc := target_dc) -> ^Storage_Buffer {
    sbo := new(Storage_Buffer);

    init_buffer_base(dc, sbo, size, {.STORAGE_BUFFER, .TRANSFER_DST, .TRANSFER_SRC}, .EXCLUSIVE, storage_kind, .STORAGE, nil);

    sbo.desc_info.buffer = sbo.vk_buffer;
    sbo.desc_info.offset = 0;
    sbo.desc_info.range = cast(vk.DeviceSize)size;

    return sbo;
}
make_storage_buffer_from_type :: proc($T : typeid, storage_kind : Buffer_Storage_Kind, using dc := target_dc) -> ^Storage_Buffer {
    size := (size_of(T));
    return make_storage_buffer_from_size(size, storage_kind, dc);
}
make_storage_buffer :: proc {
    make_storage_buffer_from_size,
    make_storage_buffer_from_type,
}
destroy_storage_buffer :: proc(sbo : ^Storage_Buffer) {
    using sbo.dc;

    vk.DeviceWaitIdle(vk_device);

    // #Sync
    for p in pipelines {
        for record,record_i in p.bind_records {
            for item, i in record.bound_resources {
                #partial switch resource in item {
                    case ^Storage_Buffer: bind_storage_buffer(p, null_sbo, record.binding_location, i);
                }
            }
        }
    }

    destroy_buffer_base(sbo);
    free(sbo);
}

transfer_data_to_device_buffer_improvised :: proc(data : rawptr, dst_buffer : vk.Buffer, size : vk.DeviceSize, using dc : ^Device_Context) {
    staging_buffer, staging_memory := make_staging_buffer(size, .TRANSFER_SRC, dc);
    
    staging_ptr := map_device_memory(staging_memory, cast(int)size);
    mem.copy(staging_ptr, data, cast(int)size);
    unmap_device_memory(staging_memory);

    cmd := begin_single_use_command_buffer(dc);
    
    copy_region : vk.BufferCopy;
    copy_region.srcOffset = 0;
    copy_region.dstOffset = 0;
    copy_region.size = cast(vk.DeviceSize)size;
    vk.CmdCopyBuffer(cmd, staging_buffer, dst_buffer, 1, &copy_region);
    
    submit_and_destroy_single_use_command_buffer(cmd, dc=dc);
    destroy_staging_buffer(staging_buffer, staging_memory, dc);
}