package justvk

import "core:log"
import "core:fmt"
import "core:strings"
import "core:builtin"
import "core:c"
import "core:runtime"
import "core:slice"
import "core:os"

import vk "vendor:vulkan"
import "vendor:glfw"

vk_instance : vk.Instance;
vk_messenger : vk.DebugUtilsMessengerEXT;

validation_layers := []cstring {
    "VK_LAYER_KHRONOS_validation",
    "VK_LAYER_KHRONOS_shader_object",
};

vk_string_to_string :: proc(vk_string : [$N]byte, allocator := context.allocator) -> string {
    context.allocator = allocator;

    builder : strings.Builder;
    strings.builder_init_len_cap(&builder, 0, len(vk_string));
    defer strings.builder_destroy(&builder);
    for b in vk_string {
        if b == 0 do break;
        strings.write_byte(&builder, b);
    }

    return strings.clone(strings.to_string(builder));
}

slice_to_multi_ptr :: proc(slice : []$T) -> [^]T {
    return cast([^]T)builtin.raw_data(slice);
}
multi_ptr_to_slice :: proc(mptr : [^]$T, count : int) -> []T {
    return slice.from_ptr(mptr, count);
}

@(private)
add_validation_layers :: proc(create_info : ^vk.InstanceCreateInfo, allocator := context.allocator) -> bool {
    context.allocator = allocator;
    available_count : u32;
    vk.EnumerateInstanceLayerProperties(&available_count, nil);
    
    available := make([]vk.LayerProperties, available_count);
    vk.EnumerateInstanceLayerProperties(&available_count, slice_to_multi_ptr(available));
    
    log.debug("Querying Available validation layers:");
    
    for avail in available {
        avail_str := vk_string_to_string(avail.layerName);
        defer delete(avail_str);
        log.debug("\t", avail_str);
    }

    final_layers := make_multi_pointer([^]cstring, len(validation_layers));
    next_final_layer := 0;
    for l in validation_layers {
        match := false;
        for avail in available {
            avail_str := vk_string_to_string(avail.layerName);
            wanted_str := strings.clone_from_cstring(l);
            defer delete(avail_str);
            defer delete(wanted_str);
            
            if avail_str == wanted_str {
                match = true;
                break;
            }
        }   

        if match {
            final_layers[next_final_layer] = l;
            next_final_layer += 1;
        }
    }

    log.debug("Added", next_final_layer, "validation layers");
    create_info.ppEnabledLayerNames = final_layers;
    create_info.enabledLayerCount = cast(u32)next_final_layer;

    return next_final_layer == len(validation_layers);
}


begin_single_use_command_buffer :: proc(using dc : ^Device_Context) -> vk.CommandBuffer {
    alloc_info : vk.CommandBufferAllocateInfo;
    alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.level = .PRIMARY;
    alloc_info.commandPool = transfer_pool;
    alloc_info.commandBufferCount = 1;

    command_buffer : vk.CommandBuffer;
    
    res := vk.AllocateCommandBuffers(vk_device, &alloc_info, &command_buffer);
    if res != .SUCCESS {
        panic(fmt.tprintf("AllocateCommandBuffers error: %s", res));
    }

    begin_info : vk.CommandBufferBeginInfo;
    begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = {.ONE_TIME_SUBMIT};        
    vk.BeginCommandBuffer(command_buffer, &begin_info);

    return command_buffer;
}
submit_and_destroy_single_use_command_buffer :: proc(command_buffer : vk.CommandBuffer, signal_semaphore : vk.Semaphore = 0, using dc : ^Device_Context) {
    command_buffer := command_buffer;
    vk.EndCommandBuffer(command_buffer);

    submit_info : vk.SubmitInfo;
    submit_info.sType = .SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &command_buffer;
    submit_info.signalSemaphoreCount = 0;
    submit_info.pSignalSemaphores = nil;
    signal_semaphore := signal_semaphore;
    if signal_semaphore != 0 {
        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = &signal_semaphore;
    }
    
    // #Sync #Speed
    // This makes it so all single use command buffers need all transfers to finish.
    // Should perhaps have yet a nother queue solely for single use command buffers
    // so it will finish as fast as possible since it's not dependent on other
    // operations.
    res := vk.QueueSubmit(queues.transfer, 1, &submit_info, 0);
    if res != .SUCCESS {
        panic(fmt.tprintf("Failed single use queue submit '%s'", res));
    }
    if signal_semaphore == 0 do vk.QueueWaitIdle(queues.transfer);
    vk.FreeCommandBuffers(vk_device, transfer_pool, 1, &command_buffer);
}

make_semaphore :: proc(using dc : ^Device_Context, timeline : bool = false) -> vk.Semaphore {
    sem : vk.Semaphore;
    semaphore_info : vk.SemaphoreCreateInfo;
    semaphore_info.sType = .SEMAPHORE_CREATE_INFO;
    if timeline {
        info : vk.SemaphoreTypeCreateInfo;
        info.sType = .SEMAPHORE_TYPE_CREATE_INFO;
        info.semaphoreType = .TIMELINE;
        semaphore_info.pNext = &info;
    }
    if vk.CreateSemaphore(vk_device, &semaphore_info, nil, &sem) != .SUCCESS {
        panic("Failed creating a semaphore");
    }

    return sem;
}
destroy_semaphore :: proc(semaphore : vk.Semaphore, using dc : ^Device_Context) {
    vk.DeviceWaitIdle(vk_device);
    vk.DestroySemaphore(vk_device, semaphore, nil);
}
make_fence :: proc(using dc : ^Device_Context) -> vk.Fence {
    fence : vk.Fence;
    fence_info : vk.FenceCreateInfo;
    fence_info.sType = .FENCE_CREATE_INFO;
    fence_info.flags = {.SIGNALED};
    if vk.CreateFence(vk_device, &fence_info, nil, &fence) != .SUCCESS {
        panic("Failed creating fence");
    }
    return fence;
}
destroy_fence :: proc(fence : vk.Fence, using dc : ^Device_Context) {
    vk.DeviceWaitIdle(vk_device);
    vk.DestroyFence(vk_device, fence, nil);
}
wait_fence :: proc(fence : vk.Fence, using dc := target_dc) {
    fence := fence;
    vk.WaitForFences(vk_device, 1, &fence, true, c.UINT64_MAX);
}

Staging_Buffer_Kind :: enum {
    TRANSFER_SRC,
    TRANSFER_DST,
    TRANSFER_DST_AND_SRC
}
make_staging_buffer :: proc(size : vk.DeviceSize, kind : Staging_Buffer_Kind, using dc : ^Device_Context) -> (buffer : vk.Buffer, memory_handle : Device_Memory_Handle) {
    buffer_info : vk.BufferCreateInfo;
    buffer_info.sType = .BUFFER_CREATE_INFO;
    buffer_info.size = size;
    switch kind {
        case .TRANSFER_SRC: buffer_info.usage = {.TRANSFER_SRC};
        case .TRANSFER_DST: buffer_info.usage = {.TRANSFER_DST};
        case .TRANSFER_DST_AND_SRC: buffer_info.usage = {.TRANSFER_DST, .TRANSFER_SRC};
    }
    
    buffer_info.sharingMode = .EXCLUSIVE;

    if (vk.CreateBuffer(vk_device, &buffer_info, nil, &buffer) != .SUCCESS) {
        panic("Failed to create buffer");
    }

    /*mem_reqs : vk.MemoryRequirements;
    vk.GetBufferMemoryRequirements(vk_device, buffer, &mem_reqs);

    alloc_info : vk.MemoryAllocateInfo;
    alloc_info.sType = .MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = find_memory_index(dc, mem_reqs.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT});
    
    if (vk.AllocateMemory(vk_device, &alloc_info, nil, &memory_handle) != .SUCCESS) {
        panic("Failed to allocate buffer memory");
    }

    vk.BindBufferMemory(vk_device, buffer, memory_handle, 0);*/

    // #Redundant Does it need to be host-coherent?
    memory_handle = request_and_bind_device_memory(buffer, {.HOST_VISIBLE, .HOST_COHERENT}, dc);

    return;
}
destroy_staging_buffer :: proc(buffer : vk.Buffer, memory_handle : Device_Memory_Handle, using dc : ^Device_Context) {
    vk.DestroyBuffer(vk_device, buffer, nil);
    free_device_memory(memory_handle);
}

find_memory_index :: proc(using dc : ^Device_Context, type_bits : u32, required_properties : []vk.MemoryPropertyFlag) -> u32 {
    base_loop: for i in 0..< graphics_device.memory_props.memoryTypeCount {
        for flag in required_properties do if (flag not_in graphics_device.memory_props.memoryTypes[i].propertyFlags) do continue base_loop;
        if ((type_bits & (1 << i)) != 0) {
            return i;
        }
    }
    panic("No suitable memory type");
}


make_render_pass :: proc(format : vk.Format, standard_layout, render_layout : vk.ImageLayout, num_attachments : int = 1, using dc := target_dc) -> Render_Pass {
    
    assert(num_attachments > 0);

    attachments := make([]vk.AttachmentDescription, num_attachments);
    attachment_refs := make([]vk.AttachmentReference, num_attachments);
    defer {
        delete (attachment_refs);
        delete (attachments);
    }


    for i in 0..<num_attachments {
        attachment : vk.AttachmentDescription;
        attachment.format = format;
        attachment.samples = {._1};
        attachment.loadOp = .LOAD;
        attachment.storeOp = .STORE;
        attachment.stencilLoadOp = .DONT_CARE;
        attachment.stencilStoreOp = .DONT_CARE;
        attachment.initialLayout = standard_layout;
        attachment.finalLayout = standard_layout;

        attachment_ref : vk.AttachmentReference;
        attachment_ref.attachment = cast(u32)i;
        attachment_ref.layout = render_layout;

        attachments[i] = attachment;
        attachment_refs[i] = attachment_ref;
    }

    // #Depth #Limitation
    subpass : vk.SubpassDescription;
    subpass.colorAttachmentCount = cast(u32)num_attachments;
    subpass.pColorAttachments = slice_to_multi_ptr(attachment_refs);
    
    // #Incomplete #Limitation
    dependency : vk.SubpassDependency;
    dependency.srcSubpass = vk.SUBPASS_EXTERNAL;
    dependency.dstSubpass = 0;
    dependency.srcStageMask = {.COLOR_ATTACHMENT_OUTPUT};
    dependency.srcAccessMask = {};
    dependency.dstStageMask = {.COLOR_ATTACHMENT_OUTPUT};
    dependency.dstAccessMask = {.COLOR_ATTACHMENT_WRITE};
    
    render_pass_info : vk.RenderPassCreateInfo;
    render_pass_info.sType = .RENDER_PASS_CREATE_INFO;
    render_pass_info.attachmentCount = cast(u32)num_attachments;
    render_pass_info.pAttachments = slice_to_multi_ptr(attachments);
    render_pass_info.subpassCount = 1;
    render_pass_info.pSubpasses = &subpass;
    render_pass_info.dependencyCount = 1;
    render_pass_info.pDependencies = &dependency;
    
    render_pass : Render_Pass;
    render_pass.format = format;
    render_pass.dc = dc;
    if vk.CreateRenderPass(vk_device, &render_pass_info, nil, &render_pass.vk_pass) != .SUCCESS {
        panic("Failed to create render pass");
    }


    return render_pass;
}

destroy_render_pass :: proc(pass : Render_Pass) {
    vk.DestroyRenderPass(pass.dc.vk_device, pass.vk_pass, nil);
}


vk_debug_callback :: proc "system" (
    severity: vk.DebugUtilsMessageSeverityFlagsEXT, 
    types: vk.DebugUtilsMessageTypeFlagsEXT, 
    callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT, 
    user_data: rawptr) -> b32 {
    context = runtime.default_context();
    context.logger = (cast(^log.Logger)user_data)^;
    if callback_data.pMessageIdName == "WARNING-Shader-OutputNotConsumed" do return false;

    log_proc : type_of(log.infof);

    if .ERROR in severity {
        log_proc = log.errorf;
    } else if .WARNING in severity {
        log_proc = log.warnf;
    } else if .INFO in severity {
        log_proc = log.infof;
    } else if .VERBOSE in severity {
        log_proc = log.debugf;
    }

    builder : strings.Builder;
    strings.builder_init(&builder, allocator=context.temp_allocator);

    fmt.sbprintln(&builder, "\n-----------------VK VALIDATION MESSAGE-----------------\n");
    fmt.sbprintln(&builder, "--------------", callback_data.pMessageIdName, "--------------");
    //fmt.sbprintf(&builder, "0x%x\n\n", callback_data.messageIdNumber);
    //if callback_data.flags != {} do fmt.sbprintf(&builder, "FLAGS: %v\n", callback_data.flags);
    //if types != {}               do fmt.sbprintf(&builder, "TYPES: %v\n", types);

    fmt.sbprintln(&builder, "MESSAGE:\n", callback_data.pMessage, sep="");

    if callback_data.cmdBufLabelCount > 0 {
        labels := multi_ptr_to_slice(callback_data.pCmdBufLabels, cast(int)callback_data.cmdBufLabelCount);
        fmt.sbprintln(&builder, "LABELS: ", labels);
    }

    if callback_data.objectCount > 0 {
        objects := multi_ptr_to_slice(callback_data.pObjects, cast(int)callback_data.objectCount);
        fmt.sbprintln(&builder, "OBJECTS:");

        for obj,i in objects {
            //fmt.sbprintln(&builder, "\t", obj.pObjectName);
            fmt.sbprintln(&builder, "\tType:", obj.objectType);
            fmt.sbprintf(&builder, "\tHandle: 0x%x\n\t--\n", obj.objectHandle);
        }
    }

    if callback_data.queueLabelCount > 0 {
        labels := multi_ptr_to_slice(callback_data.pQueueLabels, cast(int)callback_data.queueLabelCount);
        fmt.sbprintln(&builder, "QUEUE LABELS: ", labels);
    }


    // #Incomplete
    // Logging to console will cause issues because double validation.
    // For example this might send a message which has glyphs that are
    // not yet rendered and push_entry needs to measure its strings which
    // needs the glyph to be rendered to know its measurements, and rendering
    // the glyph requires vk operations which means we go through validation
    // layers again.
    //log_proc(strings.to_string(builder));
    fmt.println(strings.to_string(builder), "\n");

    return false;
}

does_vk_format_have_alpha_channel :: proc(format : vk.Format) -> bool {
    #partial switch format {
        case .R8G8B8A8_SINT,     .R8G8B8A8_UINT,     .R8G8B8A8_SRGB,
             .R16G16B16A16_SINT, .R16G16B16A16_UINT, .R16G16B16A16_SFLOAT,
             .R32G32B32A32_SINT, .R32G32B32A32_UINT, .R32G32B32A32_SFLOAT,
             .R64G64B64A64_SINT, .R64G64B64A64_UINT, .R64G64B64A64_SFLOAT: return true;
    }
    return false;
}

check_vk_result :: proc(res : vk.Result, loc := #caller_location) -> vk.Result {
    if res != .SUCCESS {
        log.errorf("VK result was %s at %s", res, loc);
    }
    return res;
}

init :: proc(application_name := "Vulkan Game App") -> bool {
    // Load basic procs for creating instance
    vk.load_proc_addresses_global(cast(rawptr)glfw.GetInstanceProcAddress);
    
    app_info : vk.ApplicationInfo;
    app_info.sType = .APPLICATION_INFO;
    app_info.pApplicationName = strings.clone_to_cstring(application_name, allocator=context.temp_allocator);
    app_info.applicationVersion = vk.MAKE_VERSION(1, 0, 0);
    app_info.pEngineName = "Jamgine Vulkan Renderer";
    app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0);
    app_info.apiVersion = vk.API_VERSION_1_2;

    create_info : vk.InstanceCreateInfo;
    create_info.sType = .INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;
    create_info.enabledLayerCount = 0;

    glfw_exts := glfw.GetRequiredInstanceExtensions();
    required_extensions := make([dynamic]cstring);
    defer delete(required_extensions);
    for i in 0..<len(glfw_exts) {
        append(&required_extensions, glfw_exts[i])
    }
    append(&required_extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
    when ODIN_DEBUG {
        append(&required_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME);
    }

    log.debug("Checking presence of required extensions:");
    for req in required_extensions {
        log.debug("\t", req);
    }

    num_available_extensions : u32;
    vk.EnumerateInstanceExtensionProperties(nil, &num_available_extensions, nil);
    available_extensions := make([]vk.ExtensionProperties, num_available_extensions);
    vk.EnumerateInstanceExtensionProperties(nil, &num_available_extensions, slice_to_multi_ptr(available_extensions));

    ok := true;
    for required_ext in required_extensions {
        match := false;
        for available_ext_prop, i in available_extensions {
            available_ext := vk_string_to_string(available_ext_prop.extensionName);
            required_ext_str :=  strings.clone_from_cstring(required_ext);
            defer delete(available_ext);
            defer delete(required_ext_str);

            if available_ext == required_ext_str {
                match = true;
                break;
            }
        }

        if !match {
            ok = false;
            log.error("Missing required extension '", required_ext, "'", sep="");
            break;
        }
    }

    if !ok {
        log.error("Required VK extension is missing, aborting");
        return false;
    }
    create_info.flags = { vk.InstanceCreateFlag.ENUMERATE_PORTABILITY_KHR };
    create_info.ppEnabledExtensionNames = slice_to_multi_ptr(required_extensions[:]);
    create_info.enabledExtensionCount = cast(u32)len(required_extensions[:]);

    when ODIN_DEBUG {
        if !add_validation_layers(&create_info) {
            log.error("Failed to add some validation layers");
        }
    }

    if vk.CreateInstance(&create_info, nil, &vk_instance) != .SUCCESS {
        log.error("Failed to create VK instance");
        return false;
    }

    log.info("Successfully created VK instance");

    // Load rest of procs for instance
    vk.load_proc_addresses_instance(vk_instance);

    when ODIN_DEBUG {
        
        debug_create_info : vk.DebugUtilsMessengerCreateInfoEXT;
        debug_create_info.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        debug_create_info.messageSeverity = {.VERBOSE, .WARNING, .ERROR};
        debug_create_info.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE};
        debug_create_info.pfnUserCallback = vk_debug_callback;
        debug_create_info.pUserData = new_clone(context.logger);
        if vk.CreateDebugUtilsMessengerEXT(vk_instance, &debug_create_info, nil, &vk_messenger) != .SUCCESS do log.error("Failed creating VK debug messenger");
    }

    return true;
}

shutdown :: proc() {
    log.debug("Justvk shutdown");
    when ODIN_DEBUG {
        vk.DestroyDebugUtilsMessengerEXT(vk_instance, vk_messenger, nil);
    }
    vk.DestroyInstance(vk_instance, nil);
}