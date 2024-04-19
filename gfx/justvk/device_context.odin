package justvk

import "core:log"
import "core:fmt"
import "core:strings"
import "core:builtin"
import "core:c"

import vk "vendor:vulkan"
import "vendor:glfw"

Any_Descriptor_Resource :: union {
    Texture, ^Uniform_Buffer, ^Storage_Buffer
}
Descriptor_Resource_Destroy_Callback :: #type proc(Any_Descriptor_Resource, ^Pipeline)
Device_Context :: struct {
    vk_device : vk.Device,

    graphics_device : Graphics_Device,

    queues : struct {
        graphics, transfer, present, compute : vk.Queue,
    },
    graphics_family, transfer_family, present_family, compute_family : u32,

    transfer_pool : vk.CommandPool,

    default_offscreen_color_render_pass_argb_bytes : Render_Pass,
    default_offscreen_color_render_pass_srgb_f16   : Render_Pass,
    default_offscreen_color_render_pass_srgb_f32   : Render_Pass,

    null_ubo : ^Uniform_Buffer,
    null_sbo : ^Storage_Buffer,
    null_texture_srgb : Texture,

    pipelines : [dynamic]^Pipeline, // #Sync this needs to be synced if we are to delete resources & make pipelines in async
}



target_dc : ^Device_Context;

set_target_device_context :: proc(dc : ^Device_Context) {
    target_dc = dc;
}
get_target_device_context :: proc() -> ^Device_Context {
    return target_dc;
}


make_device_context :: proc(specific_device : Maybe(Graphics_Device) = nil, allocator := context.allocator) -> ^Device_Context {
    context.allocator = allocator;
    
    using dc := new(Device_Context);

    dc.pipelines = make([dynamic]^Pipeline);

    if specific_device != nil do graphics_device = specific_device.(Graphics_Device);
    else {
        ok := false;
        graphics_device, ok = get_most_suitable_graphics_device();
        if !ok {
            // TODO: return error;
            panic("No suitable graphics device found");
        }
    }

    log.debug("Device context targetting device:");
    log.debug("\tName:", graphics_device.device_name);
    log.debug("\tVendor:", graphics_device.vendor_name);
    log.debug("\tDriver Version:", graphics_device.driver_version_string);
    log.debug("\tType:", graphics_device.props.deviceType);
    log.debug("\tDepth format:", graphics_device.depth_format);
    log.debug("\tGLSL f64 support:", graphics_device.features.shaderFloat64);


    log.debug("Available queues:")
    for q,i in graphics_device.queue_family_properties {
        log.debug("\tindex:", i, "flags:", q.queueFlags, "count:", q.queueCount);
    }

    // [queue_id]count
    used_queues_set := make(map[u32]u32);
    defer delete(used_queues_set);

    graphics_index, present_index, transfer_index, compute_index : u32 = c.UINT32_MAX,c.UINT32_MAX,c.UINT32_MAX,c.UINT32_MAX;

    Accept_Queue_Proc :: #type proc(^Device_Context, vk.QueueFamilyProperties, int) -> bool;

    pick_queue :: proc(using dc : ^Device_Context, used_queues_set : ^map[u32]u32, accept_proc : Accept_Queue_Proc) -> (family, index : u32, ok : bool) {

        backup_family, backup_index : Maybe(u32);

        // First, try to find a queue that is concurrent
        for fam,i in graphics_device.queue_family_properties {
            if accept_proc(dc, fam, i) {
                if cast(u32)i not_in used_queues_set || used_queues_set[cast(u32)i] < fam.queueCount {
                    family = cast(u32)i;
                    index = used_queues_set[cast(u32)i];
                    used_queues_set[cast(u32)i] += 1;
                    log.debug("Picked concurrent queue: ", fam.queueFlags, "index", index);
                    return family, index, true;
                } else {
                    backup_family = cast(u32)i;
                    backup_index = used_queues_set[cast(u32)i]-1;
                }
            }
        }

        // If no concurrent queue was found, use the backup (already found & used queue)
        if backup_family != nil {
            family = backup_family.(u32);
            index = backup_index.(u32);
            log.debug("Re-picked queue: ", graphics_device.queue_family_properties[backup_family.(u32)].queueFlags, "index", backup_index.(u32));
            return family, index, true;
        }
        return 0, 0, false;
    }


    log.debug("Picking graphics queue...");
    graphics_ok : bool;
    graphics_family, graphics_index, graphics_ok = pick_queue(dc, &used_queues_set, proc(using dc : ^Device_Context, fam : vk.QueueFamilyProperties, index : int) -> bool { 
        return .GRAPHICS in fam.queueFlags; 
    });
    if !graphics_ok {
        panic("Missing graphics queue");
    }    

    log.debug("Picking present queue...");
    present_ok : bool;
    present_family, present_index, present_ok = pick_queue(dc, &used_queues_set, proc(using dc : ^Device_Context, fam : vk.QueueFamilyProperties, index : int) -> bool { 
        return graphics_device.queue_family_surface_support[index];
    });
    if !present_ok {
        panic("Missing present queue");
    }
    
    log.debug("Picking transfer queue...");
    transfer_ok : bool;
    transfer_family, transfer_index, transfer_ok = pick_queue(dc, &used_queues_set, proc(using dc : ^Device_Context, fam : vk.QueueFamilyProperties, index : int) -> bool { 
        return .TRANSFER in fam.queueFlags; 
    });
    if !transfer_ok {
        panic("Missing transfer queue");
    }

    log.debug("Picking compute queue...");
    compute_ok : bool;
    compute_family, compute_index, compute_ok = pick_queue(dc, &used_queues_set, proc(using dc : ^Device_Context, fam : vk.QueueFamilyProperties, index : int) -> bool { 
        return .COMPUTE in fam.queueFlags; 
    });
    if !compute_ok {
        panic("Missing compute queue");
    }
    
    //
    // Create Logical Device
        
    target_queue_indices := make([]u32, len(used_queues_set));
    defer delete(target_queue_indices);
    i := 0;
    for family_index, index_in_family in used_queues_set {
        target_queue_indices[i] = family_index;
        i += 1;
    }
    queue_create_infos := make([]vk.DeviceQueueCreateInfo, len(target_queue_indices));
    defer delete(queue_create_infos);
    for q,i in target_queue_indices {
        prios := []f32{1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0}
        queue_create_info : vk.DeviceQueueCreateInfo;
        queue_create_info.sType = .DEVICE_QUEUE_CREATE_INFO;
        queue_create_info.queueFamilyIndex = q;
        assert(q in used_queues_set);
        queue_create_info.queueCount = used_queues_set[q];
        queue_create_info.pQueuePriorities = slice_to_multi_ptr(prios);
        queue_create_infos[i] = queue_create_info;
    }
    
    required_features : vk.PhysicalDeviceFeatures; // #Incomplete
    // #Portability
    // If we were for some reason to sometime target very old hardware,
    // then we may want to instead conditionally use these features.
    required_features.samplerAnisotropy = true;
    if graphics_device.features.shaderFloat64 do required_features.shaderFloat64 = true;
    
    if !check_physical_device_features(graphics_device, required_features) {
        panic("Missing a device feature; cannot continue.");
    }
    
    required_device_exts := []cstring { // #Copypaste
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
    };
    
    vk12_features : vk.PhysicalDeviceVulkan12Features;
    vk12_features.sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    vk12_features.timelineSemaphore = true;

    logical_device_create_info : vk.DeviceCreateInfo;
    logical_device_create_info.sType = .DEVICE_CREATE_INFO;
    logical_device_create_info.pQueueCreateInfos = slice_to_multi_ptr(queue_create_infos);
    logical_device_create_info.queueCreateInfoCount = cast(u32)len(queue_create_infos);
    logical_device_create_info.pEnabledFeatures = &required_features;
    logical_device_create_info.pNext = &vk12_features;
    logical_device_create_info.enabledExtensionCount = cast(u32)len(required_device_exts);
    logical_device_create_info.ppEnabledExtensionNames = slice_to_multi_ptr(required_device_exts);
    when ODIN_DEBUG {
        logical_device_create_info.enabledLayerCount = cast(u32)(len(validation_layers));
        logical_device_create_info.ppEnabledLayerNames = slice_to_multi_ptr(validation_layers);
    } else {
        logical_device_create_info.enabledLayerCount = 0;
    }
    if vk.CreateDevice(graphics_device.vk_physical_device, &logical_device_create_info, nil, &vk_device) != .SUCCESS {
        panic("Create device failed"); // TODO: return error 
    }
    
    vk.GetDeviceQueue(vk_device, graphics_family, graphics_index, &queues.graphics);
    vk.GetDeviceQueue(vk_device, present_family, present_index, &queues.present);
    vk.GetDeviceQueue(vk_device, transfer_family, transfer_index, &queues.transfer);
    vk.GetDeviceQueue(vk_device, compute_family, compute_index, &queues.compute);
    
    cmd_pool_info : vk.CommandPoolCreateInfo;
    cmd_pool_info.sType = .COMMAND_POOL_CREATE_INFO;
    cmd_pool_info.flags = {.TRANSIENT, .RESET_COMMAND_BUFFER};
    cmd_pool_info.queueFamilyIndex = transfer_family;

    if vk.CreateCommandPool(vk_device, &cmd_pool_info, nil, &dc.transfer_pool) != .SUCCESS {
        panic("Failed creating command pool");
    }

    dc.default_offscreen_color_render_pass_argb_bytes = make_render_pass(.R8G8B8A8_SINT,       .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL, dc=dc);
    dc.default_offscreen_color_render_pass_srgb_f16   = make_render_pass(.R16G16B16A16_SFLOAT, .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL, dc=dc);
    dc.default_offscreen_color_render_pass_srgb_f32   = make_render_pass(.R32G32B32A32_SFLOAT, .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL, dc=dc);

    log.infof("Created a device context\n");

    null_ubo = make_uniform_buffer(1, .VRAM_WITH_IMPROVISED_STAGING_BUFFER, dc=dc);
    null_sbo = make_storage_buffer(1, .VRAM_WITH_IMPROVISED_STAGING_BUFFER, dc=dc);
    null_texture_srgb = make_texture(1, 1, nil, .SRGBA, {.SAMPLE, .WRITE}, dc=dc);

    return dc;
}
destroy_device_context :: proc(using dc : ^Device_Context) {

    vk.DeviceWaitIdle(vk_device);

    destroy_uniform_buffer(dc.null_ubo);
    destroy_storage_buffer(dc.null_sbo);
    destroy_texture(dc.null_texture_srgb);
    
    vk.DestroyRenderPass(vk_device, dc.default_offscreen_color_render_pass_argb_bytes.vk_pass, nil);
    vk.DestroyRenderPass(vk_device, dc.default_offscreen_color_render_pass_srgb_f16.vk_pass, nil);
    vk.DestroyRenderPass(vk_device, dc.default_offscreen_color_render_pass_srgb_f32.vk_pass, nil);
    
    vk.DestroyCommandPool(vk_device, transfer_pool, nil);
    vk.DestroyDevice(vk_device, nil);

    delete(dc.pipelines);
    free(dc);
}