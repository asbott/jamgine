package justvk

import "core:log"
import "core:fmt"
import "core:strings"
import "core:mem"
import "core:slice"

import vk "vendor:vulkan"

import "jamgine:shaderc"
import jvk "jamgine:gfx/justvk"

Compute_Shader :: struct {
    dc : ^Device_Context,
    vk_module : vk.ShaderModule,
    info : jvk.Glsl_Stage_Info,
    text_source : string,
    bytes : []byte,
    descriptor_set_layout : vk.DescriptorSetLayout,
}

Compute_Context :: struct {
    dc : ^Device_Context,
    vk_pipeline : vk.Pipeline,
    vk_layout : vk.PipelineLayout,
    vk_cache : vk.PipelineCache,
    shader : Compute_Shader,

    descriptor_pool : vk.DescriptorPool,
    descriptor_set : vk.DescriptorSet,

    command_pool : vk.CommandPool,
    command_buffer : vk.CommandBuffer,

    command_buffer_fence : vk.Fence,
}

compile_compute_shader :: proc(src : string, constants : []Shader_Constant = nil, using dc := target_dc) -> (cs : Compute_Shader, ok : bool) {

    cs.dc = dc;

    glsl_compiler := shaderc.compiler_initialize();
    defer shaderc.compiler_release(glsl_compiler);
    
    opts := shaderc.compile_options_initialize();
    defer shaderc.compile_options_release(opts);
    
    shaderc.compile_options_set_optimization_level(opts, .Performance);
    
    defer {
        cs.dc = dc;
        if ok {
            log.debugf("Compiled a compute shader");
            log_layout(cs.info.layout);
        }
    }
    
    for constant in constants {
        val_str := "";
        switch value in constant.value {
            case string: val_str = value;
            case int: val_str = fmt.tprint(value);
            case f32: val_str = fmt.tprint(value);
        }
        shaderc.compile_options_add_macro_definition(opts, strings.clone_to_cstring(constant.name, allocator=context.temp_allocator), len(constant.name), strings.clone_to_cstring(val_str, allocator=context.temp_allocator), len(val_str));
    }
    add_standard_shader_macros(opts, dc);

    // #Incomplete
    // We discard of the original source so if we need to recompile
    // we can't update constants; it will use the old values.
    pp_result := shaderc.compile_into_preprocessed_text(
        glsl_compiler, 
        strings.clone_to_cstring(src, allocator=context.temp_allocator), 
        len(src), .GlslDefaultComputeShader, "NOFILE", "main", opts,
    );

    pp_status := shaderc.result_get_compilation_status(pp_result);
    if pp_status != .Success {
        ok = false;
        log.error(fmt.tprintf("Compute shader PRE-PROCESS ERROR:\n%s\n", shaderc.result_get_error_message(pp_result))); // #tprint
        return;
    }

    pp_bytes := mem.byte_slice(shaderc.result_get_bytes(pp_result), cast(int)shaderc.result_get_length(pp_result));

    pp_src := string(pp_bytes);
    cstr := cast(cstring)slice_to_multi_ptr(pp_bytes); // Not null terminated!

    result := shaderc.compile_into_spv(glsl_compiler, cstr, len(pp_src), .GlslDefaultComputeShader, "NOFILE", "main", opts);
    defer shaderc.result_release(result);
    status := shaderc.result_get_compilation_status(result);
    if status == .Success {
        // #Memcleanup
        bytes := mem.byte_slice(shaderc.result_get_bytes(result), shaderc.result_get_length(result));
        create_info : vk.ShaderModuleCreateInfo;
        create_info.sType = .SHADER_MODULE_CREATE_INFO;
        create_info.codeSize = len(bytes);
        create_info.pCode = cast(^u32)slice_to_multi_ptr(bytes);
        
        if vk.CreateShaderModule(dc.vk_device, &create_info, nil, &cs.vk_module) == .SUCCESS {
            cs.text_source = strings.clone(pp_src);
            cs.bytes = slice.clone(bytes);
            ok = true;

            err : Glsl_Inspect_Error;
            cs.info, err = inspect_glsl(cs.text_source, .COMPUTE);

            if err.kind != .NONE {
                log.error("Compute shader glsl inspect error %s: %s", err.kind, err.str);
                vk.DestroyShaderModule(dc.vk_device, cs.vk_module, nil);
                return;
            }

            if cs.info.layout.push_constant != nil {
                ps := &cs.info.layout.push_constant.(Glsl_Field);
                max_ps_size := dc.graphics_device.props.limits.maxPushConstantsSize;

                if ps.type.size > cast(int)max_ps_size {
                    log.warn("Compute Push constant size %i exceeds device limit %i, it is truncated to device limit.", ps.type.size, max_ps_size);
                    ps.type.size = cast(int)max_ps_size;
                }
            }
        } else {
            log.error("Failed creating shader module");
            ok = false;
            return;
        }

        vk_descriptor_bindings := make([]vk.DescriptorSetLayoutBinding, len(cs.info.layout.descriptor_bindings));

        for db,i in cs.info.layout.descriptor_bindings {
            layout_binding := &vk_descriptor_bindings[i];
            layout_binding.binding = cast(u32)db.location;
            layout_binding.descriptorType = to_vk_desciptor_type(db.kind);
            layout_binding.descriptorCount = 1 if db.field.type.kind != .ARRAY else cast(u32)(db.field.type.elem_count);
            layout_binding.stageFlags = {to_vk_stage_flag(db.stage)};
            layout_binding.pImmutableSamplers = nil;
        }

        layout_info : vk.DescriptorSetLayoutCreateInfo;
        layout_info.sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = cast(u32)len(vk_descriptor_bindings);
        layout_info.pBindings = slice_to_multi_ptr(vk_descriptor_bindings);
        
        if vk.CreateDescriptorSetLayout(vk_device, &layout_info, nil, &cs.descriptor_set_layout) != .SUCCESS {
            panic("Failed creating description set layout");
        }

        return;
    } else {
        ok = false;
        log.error(fmt.tprintf("Compute shader COMPILAITION ERROR:\n%s\n", shaderc.result_get_error_message(result))); // #tprint
        return;
    }   
}   

destroy_compute_shader :: proc(cs : Compute_Shader) {
    vk.DestroyDescriptorSetLayout(cs.dc.vk_device, cs.descriptor_set_layout, nil);
    vk.DestroyShaderModule(cs.dc.vk_device, cs.vk_module, nil);
    delete(cs.text_source);
    delete(cs.bytes);
}

make_compute_context :: proc(cs : Compute_Shader) -> ^Compute_Context {
    using cs.dc;

    ctx := new(Compute_Context);
    ctx.dc = cs.dc;   
    
    ctx.shader = cs;

    layout_info : vk.PipelineLayoutCreateInfo;
    layout_info.sType = .PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.setLayoutCount = 1;
    descriptor_set_layout := cs.descriptor_set_layout;
    layout_info.pSetLayouts = &descriptor_set_layout;

    layout_info.pushConstantRangeCount = 0;
    layout_info.pPushConstantRanges = nil;
    if cs.info.layout.push_constant != nil {
        max_ps_size := graphics_device.props.limits.maxPushConstantsSize;
        ps_size := cast(u32)cs.info.layout.push_constant.(Glsl_Field).type.size;
        range : vk.PushConstantRange;
        range.offset = 0;
        range.size = min(ps_size, max_ps_size);
        range.stageFlags = {.COMPUTE};
        layout_info.pushConstantRangeCount = 1;
        layout_info.pPushConstantRanges = &range;

        assert(range.size < max_ps_size, "Push constant too large");
    }

    if vk.CreatePipelineLayout(vk_device, &layout_info, nil, &ctx.vk_layout) != .SUCCESS {
        panic("Failed creating pipeline layout");
    }

    stage_info : vk.PipelineShaderStageCreateInfo;
    stage_info.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO;
    stage_info.stage = {.COMPUTE};
    stage_info.module = cs.vk_module;
    stage_info.pName = "main";

    cache_info : vk.PipelineCacheCreateInfo;
    cache_info.sType = .PIPELINE_CACHE_CREATE_INFO;
    if vk.CreatePipelineCache(vk_device, &cache_info, nil, &ctx.vk_cache) != .SUCCESS {
        panic("Failed CreatePipelineCache");
    }

    create_info : vk.ComputePipelineCreateInfo;
    create_info.sType = .COMPUTE_PIPELINE_CREATE_INFO;
    create_info.stage = stage_info;
    create_info.flags = {};
    create_info.layout = ctx.vk_layout;

    if vk.CreateComputePipelines(vk_device, ctx.vk_cache, 1, &create_info, nil, &ctx.vk_pipeline) != .SUCCESS {
        panic("Failed creating compute pipeline");
    }

    cs_layout := cs.info.layout;

    buffers_size : vk.DescriptorPoolSize;
    buffers_size.descriptorCount = cast(u32)cs_layout.num_ubos;
    buffers_size.type = .UNIFORM_BUFFER;
    samplers_size : vk.DescriptorPoolSize;
    samplers_size.descriptorCount = cast(u32)cs_layout.num_samplers;
    samplers_size.type = .COMBINED_IMAGE_SAMPLER;
    storage_buffers_size : vk.DescriptorPoolSize;
    storage_buffers_size.descriptorCount = cast(u32)cs_layout.num_sbos;
    storage_buffers_size.type = .STORAGE_BUFFER;

    sizes : [3]vk.DescriptorPoolSize;

    next : int;

    if cs_layout.num_ubos > 0 {
        sizes[next] = buffers_size;
        next += 1;
    }
    if cs_layout.num_samplers > 0 {
        sizes[next] = samplers_size;
        next += 1;
    }
    if cs_layout.num_sbos > 0 {
        sizes[next] = storage_buffers_size;
        next += 1;
    }

    pool_create : vk.DescriptorPoolCreateInfo;
    pool_create.sType = .DESCRIPTOR_POOL_CREATE_INFO;
    pool_create.maxSets = 1;
    pool_create.pPoolSizes = slice_to_multi_ptr(sizes[:]);
    pool_create.poolSizeCount = cast(u32)next;

    if vk.CreateDescriptorPool(vk_device, &pool_create, nil, &ctx.descriptor_pool) != .SUCCESS {
        panic("Failed creating descriptor pool");
    }

    {
        alloc_info : vk.DescriptorSetAllocateInfo;
        alloc_info.sType = .DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = ctx.descriptor_pool;
        alloc_info.descriptorSetCount = 1;
        cs_desc_layout := cs.descriptor_set_layout;
        alloc_info.pSetLayouts = &cs_desc_layout;
        if vk.AllocateDescriptorSets(vk_device, &alloc_info, &ctx.descriptor_set) != .SUCCESS {
            panic("Failed allocating descriptor set");
        }
    }

    cmd_pool_info : vk.CommandPoolCreateInfo;
    cmd_pool_info.sType = .COMMAND_POOL_CREATE_INFO;
    cmd_pool_info.flags = {.TRANSIENT};
    cmd_pool_info.queueFamilyIndex = compute_family;

    if vk.CreateCommandPool(vk_device, &cmd_pool_info, nil, &ctx.command_pool) != .SUCCESS {
        panic("Failed creating pipeline command pool");
    }

    {
        alloc_info : vk.CommandBufferAllocateInfo;
        alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandBufferCount = 1;
        alloc_info.commandPool = ctx.command_pool;
        if vk.AllocateCommandBuffers(vk_device, &alloc_info, &ctx.command_buffer) != .SUCCESS {
            panic("Failed allocating pipeline command buffer");
        }
    }

    ctx.command_buffer_fence = make_fence(ctx.dc);

    return ctx;
}
destroy_compute_context :: proc(ctx : ^Compute_Context) {
    using ctx.dc;
    
    destroy_fence(ctx.command_buffer_fence, ctx.dc);
    vk.DestroyCommandPool(vk_device, ctx.command_pool, nil);
    vk.DestroyDescriptorPool(vk_device, ctx.descriptor_pool, nil);
    vk.DestroyPipeline(vk_device, ctx.vk_pipeline, nil);
    vk.DestroyPipelineCache(vk_device, ctx.vk_cache, nil);
    vk.DestroyPipelineLayout(vk_device, ctx.vk_layout, nil);

    free(ctx);
}

write_compute_descriptor :: proc(ctx : ^Compute_Context, binding_location : int, array_index : int, type : vk.DescriptorType, image_info : ^vk.DescriptorImageInfo, buffer_info : ^vk.DescriptorBufferInfo) {
    using ctx.dc;

    // #Uniformcoherency
    if binding_location < 0 || binding_location > len(ctx.shader.info.layout.descriptor_bindings) {
        log.warnf("Invalid uniform binding location %i", binding_location);
        return;
    }

    write : vk.WriteDescriptorSet;
    write.sType = .WRITE_DESCRIPTOR_SET;
    write.dstSet = ctx.descriptor_set;
    write.dstBinding = cast(u32)binding_location;
    write.dstArrayElement = cast(u32)array_index;
    write.descriptorType = type;
    write.descriptorCount = 1;
    write.pImageInfo = image_info;
    write.pBufferInfo = buffer_info;
    write.pTexelBufferView = nil;
    write.pNext = nil;

    vk.UpdateDescriptorSets(vk_device, 1, &write, 0, nil);
}

bind_compute_uniform_buffer :: proc(ctx : ^Compute_Context, ubo : ^Uniform_Buffer, binding_location : int, array_index := 0) {
    write_compute_descriptor(ctx, binding_location, array_index, .UNIFORM_BUFFER, nil, &ubo.desc_info);
}
bind_compute_storage_buffer :: proc(ctx : ^Compute_Context, sbo : ^Storage_Buffer, binding_location : int, array_index := 0) {
    write_compute_descriptor(ctx, binding_location, array_index, .STORAGE_BUFFER, nil, &sbo.desc_info);
}
bind_compute_texture :: proc(ctx : ^Compute_Context, texture : Texture, binding_location : int, array_index := 0) {

    if .SAMPLE not_in texture.usage_mask {
        log.errorf("Tried to bind texture 0x%x to binding location %i, but it does not have the .SAMPLE usage flag. Set usage mask: %s", texture.vk_image, binding_location, texture.usage_mask);
        return;
    }

    desc_info := texture.desc_info;
    write_compute_descriptor(ctx, binding_location, array_index, .COMBINED_IMAGE_SAMPLER, &desc_info, nil);
}



do_compute :: proc(ctx : ^Compute_Context, x_elem_count : int, y_elem_count := 1, z_elem_count := 1, push_constant : rawptr = nil, signal_sem : vk.Semaphore = 0) {
    using ctx.dc;

    // #Sync #Speed
    wait_fence(ctx.command_buffer_fence, ctx.dc);


    check_vk_result(vk.ResetCommandPool(vk_device, ctx.command_pool, {}));
    cmd_begin_info : vk.CommandBufferBeginInfo;
    cmd_begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
    cmd_begin_info.flags = {};
    cmd_begin_info.pInheritanceInfo = nil;
    check_vk_result(vk.BeginCommandBuffer(ctx.command_buffer, &cmd_begin_info));
    vk.CmdBindDescriptorSets(ctx.command_buffer, .COMPUTE, ctx.vk_layout, 0, 1, &ctx.descriptor_set, 0, nil);
    vk.CmdBindPipeline(ctx.command_buffer, .COMPUTE, ctx.vk_pipeline);
    local_size_x := max(ctx.shader.info.layout.local_size_x, 1);
    local_size_y := max(ctx.shader.info.layout.local_size_y, 1);
    local_size_z := max(ctx.shader.info.layout.local_size_z, 1);
    group_size_x := (x_elem_count + local_size_x - 1) / local_size_x;
    group_size_y := (y_elem_count + local_size_y - 1) / local_size_y;
    group_size_z := (z_elem_count + local_size_z - 1) / local_size_z;

    if push_constant != nil && ctx.shader.info.layout.push_constant != nil {
        vk.CmdPushConstants(ctx.command_buffer, ctx.vk_layout, {.COMPUTE}, 0, cast(u32)ctx.shader.info.layout.push_constant.(Glsl_Field).type.size, push_constant);
    }
    vk.CmdDispatch(ctx.command_buffer, cast(u32)group_size_x, cast(u32)group_size_y, cast(u32)group_size_z);
    check_vk_result(vk.EndCommandBuffer(ctx.command_buffer));
    submit_info : vk.SubmitInfo;
    submit_info.sType = .SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    command_buffer := ctx.command_buffer;
    submit_info.pCommandBuffers = &command_buffer;
    command_fence := ctx.command_buffer_fence;
    submit_info.waitSemaphoreCount = 0;
    submit_info.signalSemaphoreCount = 0;
    if signal_sem != 0 {
        submit_info.signalSemaphoreCount = 1;
        sm := signal_sem;
        submit_info.pSignalSemaphores = &sm;
    }

    check_vk_result(vk.ResetFences(vk_device, 1, &command_fence));
    check_vk_result(vk.QueueSubmit(queues.compute, 1, &submit_info, command_fence));
}

is_compute_done :: proc(ctx : ^Compute_Context) -> bool {
    fence_status := vk.GetFenceStatus(ctx.dc.vk_device, ctx.command_buffer_fence);

    if fence_status == .SUCCESS { // Signaled, ready
        return true;
    } else if fence_status == .NOT_READY { // Unsignaled, not ready
        return false;
    } else {
        panic(fmt.tprint("GetFenceStatus failed", fence_status));
    }
}
wait_compute_done :: proc(ctx : ^Compute_Context) {
    wait_fence(ctx.command_buffer_fence);
}
