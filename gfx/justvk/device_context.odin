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
    null_texture_rgba : Texture,

    pipelines : [dynamic]^Pipeline,
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


    log.debug("Available queues:")
    for q,i in graphics_device.queue_family_properties {
        log.debug("\tindex:", i, "flags:", q.queueFlags);
    }

    // [queue_id]count
    used_queues_set := make(map[u32]u32);
    defer delete(used_queues_set);

    graphics_index, present_index, transfer_index, compute_index : u32 = c.UINT32_MAX,c.UINT32_MAX,c.UINT32_MAX,c.UINT32_MAX;

    // Graphics queue: first best with GRAPHICS flag
    for fam,i in graphics_device.queue_family_properties {
        if .GRAPHICS in fam.queueFlags {
            graphics_family = cast(u32)i;
            graphics_index = used_queues_set[cast(u32)i];
            used_queues_set[cast(u32)i] += 1;
            log.debug("Picked graphics queue: ", fam.queueFlags, "index", graphics_index);
            break;
        }
    }
    if graphics_index == c.UINT32_MAX do panic("Missing graphics queue");

    // #Incomplete #Refactor
    temp_surface : vk.SurfaceKHR;
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API);
    glfw.WindowHint(glfw.VISIBLE, glfw.FALSE);
    glfw_window := glfw.CreateWindow(1, 1, "TEMPORARY FOR INITIALIZATION YOU SHOULD NOT SEE THIS", nil, nil);
    glfw.CreateWindowSurface(vk_instance, glfw_window, nil, &temp_surface);
    defer vk.DestroySurfaceKHR(vk_instance, temp_surface, nil);
    defer glfw.DestroyWindow(glfw_window);

    // Present queue: First best where parallel queue is available
    for fam,i in graphics_device.queue_family_properties {
        
        supports_present : b32;
        vk.GetPhysicalDeviceSurfaceSupportKHR(graphics_device.vk_physical_device, cast(u32)i, temp_surface, &supports_present);
        if supports_present {
            if cast(u32)i not_in used_queues_set || used_queues_set[cast(u32)i] < fam.queueCount {
                present_family = cast(u32)i;
                present_index = used_queues_set[cast(u32)i];
                log.debug("Picked present queue:  ", fam.queueFlags, "index", present_index);
                used_queues_set[cast(u32)i] += 1;
                break;
            }
        }
    }
    if present_index == c.UINT32_MAX do panic("Missing present queue");
        
    // Transfer queue: First best where parallel queue is available
    for fam,i in graphics_device.queue_family_properties {
        if .TRANSFER in fam.queueFlags {
            transfer_family = cast(u32)i;
            transfer_index = used_queues_set[cast(u32)i];
            used_queues_set[cast(u32)i] += 1;
            log.debug("Picked transfer queue:", fam.queueFlags, "index", transfer_index);
            break;
        }
    }
    if transfer_index == c.UINT32_MAX do panic("Missing transfer queue");

    for fam,i in graphics_device.queue_family_properties {
        if .COMPUTE in fam.queueFlags {
            compute_family = cast(u32)i;
            compute_index = used_queues_set[cast(u32)i];
            used_queues_set[cast(u32)i] += 1;
            log.debug("Picked compute queue:", fam.queueFlags, "index", compute_index);
            break;
        }
    }
    if compute_index == c.UINT32_MAX do panic("Missing compute queue");
    
    //
    // Create Logical Device
        
    log.infof("Targetting GPU:\n\t%s\n\t%s Driver Version %s\n", graphics_device.device_name, graphics_device.vendor_name, graphics_device.driver_version_string);
    
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

    Null :: struct {
        _ : int,
    }
    null_ubo = make_uniform_buffer(Null, .VRAM_WITH_IMPROVISED_STAGING_BUFFER, allocator=allocator, dc=dc);
    null_sbo = make_storage_buffer(Null, .VRAM_WITH_IMPROVISED_STAGING_BUFFER, allocator=allocator, dc=dc);
    null_texture_rgba = make_texture(1, 1, nil, .RGBA, {.SAMPLE, .WRITE}, dc=dc);

    return dc;
}
destroy_device_context :: proc(using dc : ^Device_Context) {

    vk.DeviceWaitIdle(vk_device);

    destroy_uniform_buffer(dc.null_ubo);
    destroy_storage_buffer(dc.null_sbo);
    destroy_texture(dc.null_texture_rgba);
    
    vk.DestroyRenderPass(vk_device, dc.default_offscreen_color_render_pass_argb_bytes.vk_pass, nil);
    vk.DestroyRenderPass(vk_device, dc.default_offscreen_color_render_pass_srgb_f16.vk_pass, nil);
    vk.DestroyRenderPass(vk_device, dc.default_offscreen_color_render_pass_srgb_f32.vk_pass, nil);
    
    vk.DestroyCommandPool(vk_device, transfer_pool, nil);
    vk.DestroyDevice(vk_device, nil);

    delete(dc.pipelines);
    free(dc);
}