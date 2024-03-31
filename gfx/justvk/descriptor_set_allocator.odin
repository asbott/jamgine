package justvk

import "core:fmt"

import vk "vendor:vulkan"

//
// Basically a block allocator but for descriptor sets of a certain
// layout instead of memory.
//
// #Sync #Race
// Problem for multithreading. It might be the case that we can disallow
// this to be shared over threads but since the initial idea is to use
// this per shader program that seems like quite the limitation. But it
// might be fine.

// #Speed #Tweak #Limitation
DESCRIPTOR_SETS_PER_POOL :: 4

Descriptor_Set_Handle :: int

Descriptor_Set_Block :: struct {
    set : vk.DescriptorSet,
    allocated : bool,
    next_free : Maybe(int),
    busy_fence : vk.Fence,
}
Descriptor_Set_Allocator :: struct {
    dc : ^Device_Context,
    layout : vk.DescriptorSetLayout,
    num_buffers : int,
    num_samplers : int,
    num_storage_buffers : int,

    // #Memory #Fragmentation #Speed
    pools : [dynamic]vk.DescriptorPool,
    set_blocks  : [dynamic]Descriptor_Set_Block,
    busy_blocks : [dynamic]Descriptor_Set_Handle,

    first_free : Descriptor_Set_Handle,
}

make_descriptor_pool :: proc(alloc : ^Descriptor_Set_Allocator) -> vk.DescriptorPool {
    using alloc.dc;
    buffers_size : vk.DescriptorPoolSize;
    buffers_size.descriptorCount = cast(u32)alloc.num_buffers;
    buffers_size.type = .UNIFORM_BUFFER;
    samplers_size : vk.DescriptorPoolSize;
    samplers_size.descriptorCount = cast(u32)alloc.num_samplers;
    samplers_size.type = .COMBINED_IMAGE_SAMPLER;
    storage_buffers_size : vk.DescriptorPoolSize;
    storage_buffers_size.descriptorCount = cast(u32)alloc.num_storage_buffers;
    storage_buffers_size.type = .STORAGE_BUFFER;

    sizes : [3]vk.DescriptorPoolSize;

    next : int;

    if alloc.num_buffers > 0 {
        sizes[next] = buffers_size;
        next += 1;
    }
    if alloc.num_samplers > 0 {
        sizes[next] = samplers_size;
        next += 1;
    }
    if alloc.num_storage_buffers > 0 {
        sizes[next] = storage_buffers_size;
        next += 1;
    }
    

    the_pool : vk.DescriptorPool;
    pool_create : vk.DescriptorPoolCreateInfo;
    pool_create.sType = .DESCRIPTOR_POOL_CREATE_INFO;
    pool_create.maxSets = DESCRIPTOR_SETS_PER_POOL;
    pool_create.pPoolSizes = slice_to_multi_ptr(sizes[:]);
    pool_create.poolSizeCount = cast(u32)next;

    if vk.CreateDescriptorPool(vk_device, &pool_create, nil, &the_pool) != .SUCCESS {
        panic("Failed creating descriptor pool");
    }

    return the_pool;
}

init_descriptor_set_allocator :: proc(alloc : ^Descriptor_Set_Allocator, set_layout : vk.DescriptorSetLayout, layout : Glsl_Layout, using dc : ^Device_Context) {

    alloc.dc = dc;
    alloc.layout = set_layout;
    alloc.num_buffers = layout.num_ubos;
    alloc.num_samplers = layout.num_samplers;
    alloc.num_storage_buffers = layout.num_sbos;

    alloc.pools = make([dynamic]vk.DescriptorPool);
    alloc.set_blocks = make([dynamic]Descriptor_Set_Block);
    alloc.busy_blocks = make([dynamic]Descriptor_Set_Handle);

    append(&alloc.pools, make_descriptor_pool(alloc));
    resize(&alloc.set_blocks, DESCRIPTOR_SETS_PER_POOL);

    alloc.first_free = 0;
}

destroy_descriptor_set_allocator :: proc(alloc : Descriptor_Set_Allocator) {
    using alloc.dc;

    for pool in alloc.pools {
        vk.DestroyDescriptorPool(vk_device, pool, nil)
    }

    delete(alloc.pools);
    delete(alloc.set_blocks);
    delete(alloc.busy_blocks);
}

allocate_descriptor_set :: proc(alloc : ^Descriptor_Set_Allocator) -> (Descriptor_Set_Handle, vk.DescriptorSet) {
    using alloc.dc;
    // #Speed #Sync #Try
    // This might be slow but it might be trivial. Needs testing.
    // An alternative could be to dispatch fence waiting on as jobs
    // but that would require syncing which may very well make things
    // slower than this..
    // I have no idea how much of a slowdown vkGetFenceStatus is

    check_busy_blocks(alloc); // !!This may change first_free!!

    consumed := &alloc.set_blocks[alloc.first_free];
    handle := alloc.first_free;

    if consumed.next_free != nil {
        alloc.first_free = consumed.next_free.(int);
    } else {
        alloc.first_free += 1;
    }

    if alloc.first_free >= len(alloc.set_blocks) {
        resize(&alloc.set_blocks, len(alloc.set_blocks) + DESCRIPTOR_SETS_PER_POOL);
        append(&alloc.pools, make_descriptor_pool(alloc));
    }
    // Update adress, array might have resized
    consumed = &alloc.set_blocks[handle];

    assert(!consumed.allocated);

    consumed.allocated = true;
    if consumed.set == 0 {
        alloc_info : vk.DescriptorSetAllocateInfo;
        alloc_info.sType = .DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = alloc.pools[handle / DESCRIPTOR_SETS_PER_POOL];
        alloc_info.descriptorSetCount = 1;
        alloc_info.pSetLayouts = &alloc.layout;
        if vk.AllocateDescriptorSets(vk_device, &alloc_info, &consumed.set) != .SUCCESS {
            panic("Failed allocating descriptor set");
        }
    }
    
    return handle, consumed.set;
}

release_descriptor_set :: proc(alloc : ^Descriptor_Set_Allocator, handle : Descriptor_Set_Handle, busy_fence : vk.Fence = 0) {
    assert(check_descriptor_set_handle(alloc, handle), "Invalid descriptor set handle");

    assert(!alloc.set_blocks[alloc.first_free].allocated);

    if busy_fence == 0 {
        alloc.set_blocks[handle].allocated = false;
    
        alloc.set_blocks[handle].next_free = alloc.first_free;
    
        alloc.first_free = handle;
        assert(!alloc.set_blocks[alloc.first_free].allocated);
    } else {
        alloc.set_blocks[handle].busy_fence = busy_fence;
        append(&alloc.busy_blocks, handle);
    }
}

check_busy_blocks :: proc(alloc : ^Descriptor_Set_Allocator) {
    using alloc.dc;
    for i := len(alloc.busy_blocks)-1; i >= 0; i -= 1 {
        handle := alloc.busy_blocks[i];
        block := &alloc.set_blocks[handle];
        assert(block.busy_fence != 0, "Descriptor set block was marked as busy but no valid fence was set");

        fence_status := vk.GetFenceStatus(vk_device, block.busy_fence);

        if fence_status == .SUCCESS { // Signaled, ready
            unordered_remove(&alloc.busy_blocks, i);
            release_descriptor_set(alloc, handle);
            continue;
        } else if fence_status == .NOT_READY { // Unsignaled, not ready
            continue;
        } else {
            panic(fmt.tprint("GetFenceStatus failed", fence_status));
        }
    }
}

get_descriptor_set :: proc(alloc : ^Descriptor_Set_Allocator, handle : Descriptor_Set_Handle) -> vk.DescriptorSet {
    assert(check_descriptor_set_handle(alloc, handle), "Invalid descriptor set handle");

    return alloc.set_blocks[handle].set;
}

check_descriptor_set_handle :: proc(alloc : ^Descriptor_Set_Allocator, handle : Descriptor_Set_Handle) -> bool {
    return handle >= 0 && handle < len(alloc.set_blocks) && alloc.set_blocks[handle].set != 0 && alloc.set_blocks[handle].allocated;
}

