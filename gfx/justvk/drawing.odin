 package justvk

import "core:fmt"
import "core:log"
import "core:c"
import "core:slice"

import vk "vendor:vulkan"
import "vendor:glfw"

import "jamgine:lin"

Render_Target :: struct {
    dc : ^Device_Context,
    framebuffer : vk.Framebuffer,
    image_format : vk.Format,
    target_images : []vk.Image,
    image_views : []vk.ImageView,
    render_pass : Render_Pass,
    render_layout : vk.ImageLayout,
    standard_layout : vk.ImageLayout,

    draw_done_semaphore : vk.Semaphore,
    draw_done_fence : vk.Fence,

    width, height : int,
}

Bind_Record :: struct {
    binding_location : int,
    // Per array index
    bound_resources : []Any_Descriptor_Resource,
}
Pipeline :: struct {
    dc : ^Device_Context,
    vk_pipeline : vk.Pipeline,
    vk_layout : vk.PipelineLayout,
    program : Shader_Program,
    current_target : Render_Target,
    vertex_input_layout : Vertex_Layout,
    command_pool : vk.CommandPool,
    command_buffer : vk.CommandBuffer,
    command_buffer_fence : vk.Fence,
    descriptor_set_allocator : Descriptor_Set_Allocator,

    // This set should reflect the bound descriptors in realtime
    // as bind_...() functions are called but should only be used
    // to store this state and copy into other sets; it must never
    // be used in a command buffer.
    master_set : vk.DescriptorSet,
    master_set_handle : Descriptor_Set_Handle,
    bind_records : []Bind_Record,

    current_descriptor_set_handle : Descriptor_Set_Handle,
    num_descriptor_bindings : int,
    num_descriptors_including_array_elements : int,
    uniform_binding_descriptor_counts : []int,
    active : bool,
    wait_semaphores : [dynamic]vk.Semaphore,
    wait_stages : [dynamic]vk.PipelineStageFlags,

    render_pass : Render_Pass,
}

Render_Pass :: struct {
    dc : ^Device_Context,
    vk_pass : vk.RenderPass,
    format : vk.Format,
}

make_render_target :: proc(width, height : int, images : []vk.Image, format : vk.Format, standard_layout : vk.ImageLayout, layout : vk.ImageLayout, using dc := target_dc) -> Render_Target {

    assert(len(images) > 0);
    num_attachments := len(images);

    render_target : Render_Target;
    render_target.target_images = slice.clone(images);
    render_target.image_views = make([]vk.ImageView, num_attachments);
    render_target.render_layout = layout;
    render_target.standard_layout = standard_layout;
    render_target.dc = dc;
    render_target.width = width;
    render_target.height = height;
    render_target.image_format = format;

    for image, i in render_target.target_images {
        view_create_info : vk.ImageViewCreateInfo ;
        view_create_info.sType = .IMAGE_VIEW_CREATE_INFO;
        view_create_info.image = image;
        view_create_info.viewType = .D2;
        view_create_info.format = format;
        view_create_info.components.r = .IDENTITY;
        view_create_info.components.g = .IDENTITY;
        view_create_info.components.b = .IDENTITY;
        view_create_info.components.a = .IDENTITY;
        view_create_info.subresourceRange.aspectMask = {.COLOR};
        view_create_info.subresourceRange.baseMipLevel = 0;
        view_create_info.subresourceRange.levelCount = 1;
        view_create_info.subresourceRange.baseArrayLayer = 0;
        view_create_info.subresourceRange.layerCount = 1;
        if vk.CreateImageView(vk_device, &view_create_info, nil, &render_target.image_views[i]) != .SUCCESS {
            panic("Failed creating image view"); // TODO : errors
        }
    }

    render_target.render_pass = make_render_pass(format, standard_layout, layout, num_attachments, dc=dc);

    framebuffer_info : vk.FramebufferCreateInfo;
    framebuffer_info.sType = .FRAMEBUFFER_CREATE_INFO;
    framebuffer_info.renderPass = render_target.render_pass.vk_pass;
    framebuffer_info.attachmentCount = cast(u32)len(render_target.image_views);
    framebuffer_info.pAttachments = slice_to_multi_ptr(render_target.image_views);
    framebuffer_info.width = cast(u32)width;
    framebuffer_info.height = cast(u32)height;
    framebuffer_info.layers = 1;

    if vk.CreateFramebuffer(vk_device, &framebuffer_info, nil, &render_target.framebuffer) != .SUCCESS {
        panic("Failed creating framebuffer");
    }

    render_target.draw_done_fence = make_fence(dc);
    render_target.draw_done_semaphore = make_semaphore(dc);

    log.infof("Created a Render Target");
    log.infof("\tLayout: %s", layout);
    log.infof("\tFormat: %s", format);

    return render_target;
}
make_texture_render_target :: proc(texture : Texture) -> Render_Target {

    if .DRAW not_in texture.usage_mask {
        log.errorf("Texture 0x%x was used to create a render target, but it does not have the .DRAW usage flag. %s", texture.vk_image, texture.usage_mask);
    }

    return make_render_target(texture.width, texture.height, {texture.vk_image}, texture_format_to_vk_format(texture.format), .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL, dc=texture.dc);
}
make_multiple_textures_render_target :: proc(textures : []Texture) -> Render_Target {

    images := make([]vk.Image, len(textures), allocator=context.temp_allocator);

    assert(len(textures) > 0);
    last_w := textures[0].width;
    last_h := textures[0].height;
    last_fmt := textures[0].format;
    last_dc := textures[0].dc;
    for texture, i in textures {
        if texture.width != last_w || texture.height != last_h ||texture.format != last_fmt ||texture.dc != last_dc {
            panic("When making render targets with multiple textures they all need to be of the same size and format");
        }

        if .DRAW not_in texture.usage_mask {
            log.errorf("Texture 0x%x was used to create a render target, but it does not have the .DRAW usage flag. %s", texture.vk_image, texture.usage_mask);
        }

        images[i] = texture.vk_image;

        last_w = texture.width;
        last_h = texture.height;
        last_fmt = texture.format;
        last_dc = texture.dc;
    }

    return make_render_target(last_w, last_h, images, texture_format_to_vk_format(last_fmt), .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL, dc=last_dc);
}
destroy_render_target :: proc(render_target : Render_Target) {
    using render_target.dc;
    vk.DeviceWaitIdle(vk_device);
    destroy_fence(render_target.draw_done_fence, render_target.dc);
    destroy_semaphore(render_target.draw_done_semaphore, render_target.dc);
    vk.DestroyFramebuffer(vk_device, render_target.framebuffer, nil);
    vk.DestroyRenderPass(vk_device, render_target.render_pass.vk_pass, nil);
    
    for img_view in render_target.image_views {
        vk.DestroyImageView(vk_device, img_view, nil);
    }
    delete(render_target.image_views);
    delete(render_target.target_images);
}

make_shader_stage :: proc(module : Shader_Module) -> vk.PipelineShaderStageCreateInfo {
    create_info : vk.PipelineShaderStageCreateInfo;
    create_info.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO;
    create_info.stage = {module.stage};
    create_info.module = module.vk_module;
    create_info.pName = "main";

    return create_info;
}

make_pipeline :: proc(program : Shader_Program, render_pass : Render_Pass, using dc := target_dc) -> ^Pipeline {
    
    p := new(Pipeline);
    p.program = program;
    p.vertex_input_layout = program.vertex_input_layout;
    p.dc = dc;
    p.wait_semaphores = make([dynamic]vk.Semaphore);
    p.wait_stages = make([dynamic]vk.PipelineStageFlags);
    p.render_pass = render_pass;
    

    vertex_layout := program.vertex_input_layout;
    
    num_stages := 2;
    if program.tesselation != nil do num_stages += 1;
    if program.geometry != nil    do num_stages += 1;

    shader_stages := make([]vk.PipelineShaderStageCreateInfo, num_stages);
    shader_stages[0] = make_shader_stage(program.vertex);
    shader_stages[1] = make_shader_stage(program.fragment);
    if program.tesselation != nil do shader_stages[2] = make_shader_stage(program.tesselation.(Shader_Module));
    if program.geometry != nil    do shader_stages[3] = make_shader_stage(program.geometry.(Shader_Module));
    
    input_info : vk.PipelineVertexInputStateCreateInfo;
    input_info.sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    input_info.vertexBindingDescriptionCount = 1 if len(vertex_layout.attributes) > 0 else 0;
    input_info.pVertexBindingDescriptions = &vertex_layout.binding;
    input_info.vertexAttributeDescriptionCount = cast(u32)len(vertex_layout.attributes);
    input_info.pVertexAttributeDescriptions = slice_to_multi_ptr(vertex_layout.attributes);

    input_assembly : vk.PipelineInputAssemblyStateCreateInfo;
    input_assembly.sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = .TRIANGLE_LIST;
    input_assembly.primitiveRestartEnable = false;
    
    dynamic_states : []vk.DynamicState = {.VIEWPORT, .SCISSOR};
    dynamic_state_info : vk.PipelineDynamicStateCreateInfo;
    dynamic_state_info.sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic_state_info.dynamicStateCount = cast(u32)len(dynamic_states);
    dynamic_state_info.pDynamicStates = slice_to_multi_ptr(dynamic_states);
    

    viewport : vk.Viewport;
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = 1;//cast(f32)render_target.width;
    viewport.height = 1;//cast(f32)render_target.height;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;

    scissor : vk.Rect2D;
    scissor.offset = {0, 0};
    scissor.extent = {1, 1};//{ cast(u32)render_target.width, cast(u32)render_target.height };
    viewport_state : vk.PipelineViewportStateCreateInfo;
    viewport_state.sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;
    viewport_state.pScissors = &scissor;

    rasterizer : vk.PipelineRasterizationStateCreateInfo;
    rasterizer.sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.depthClampEnable = false
    rasterizer.rasterizerDiscardEnable = false;
    rasterizer.polygonMode = .FILL;
    rasterizer.lineWidth = 1.0;
    rasterizer.cullMode = {};
    rasterizer.frontFace = {};
    rasterizer.depthBiasEnable = false;
    rasterizer.depthBiasConstantFactor = 0.0;
    rasterizer.depthBiasClamp = 0.0;
    rasterizer.depthBiasSlopeFactor = 0.0;

    multisampling : vk.PipelineMultisampleStateCreateInfo;
    multisampling.sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.sampleShadingEnable = false;
    multisampling.rasterizationSamples = {._1};
    multisampling.minSampleShading = 1.0;
    multisampling.pSampleMask = nil;
    multisampling.alphaToCoverageEnable = false;
    multisampling.alphaToOneEnable = false;

    blend_attachment : vk.PipelineColorBlendAttachmentState;
    num_channels := count_channels(render_pass.format);
    if num_channels == 1 {
        blend_attachment.colorWriteMask = {.R};
        blend_attachment.blendEnable = (.COLOR_ATTACHMENT_BLEND in get_format_props(render_pass.format, graphics_device).optimalTilingFeatures);
        blend_attachment.srcColorBlendFactor = .ONE;
        blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
        blend_attachment.colorBlendOp = .ADD;
        blend_attachment.srcAlphaBlendFactor = .ONE;
        blend_attachment.dstAlphaBlendFactor = .ZERO;
        blend_attachment.alphaBlendOp = .ADD;
    } else if num_channels == 2 {
        blend_attachment.colorWriteMask = {.R, .G};
        blend_attachment.blendEnable = (.COLOR_ATTACHMENT_BLEND in get_format_props(render_pass.format, graphics_device).optimalTilingFeatures);
        blend_attachment.srcColorBlendFactor = .ONE;
        blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
        blend_attachment.colorBlendOp = .ADD;
        blend_attachment.srcAlphaBlendFactor = .ONE;
        blend_attachment.dstAlphaBlendFactor = .ZERO;
        blend_attachment.alphaBlendOp = .ADD;
    } else if num_channels == 3 {
        blend_attachment.colorWriteMask = {.R, .G, .B};
        blend_attachment.blendEnable = (.COLOR_ATTACHMENT_BLEND in get_format_props(render_pass.format, graphics_device).optimalTilingFeatures);
        blend_attachment.srcColorBlendFactor = .ONE;
        blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
        blend_attachment.colorBlendOp = .ADD;
        blend_attachment.srcAlphaBlendFactor = .ONE;
        blend_attachment.dstAlphaBlendFactor = .ZERO;
        blend_attachment.alphaBlendOp = .ADD;
    } else if num_channels == 4 {
        blend_attachment.colorWriteMask = {.R, .G, .B, .A};
        blend_attachment.blendEnable = (.COLOR_ATTACHMENT_BLEND in get_format_props(render_pass.format, graphics_device).optimalTilingFeatures);
        blend_attachment.srcColorBlendFactor = .SRC_ALPHA;
        blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
        blend_attachment.colorBlendOp = .ADD;
        blend_attachment.srcAlphaBlendFactor = .SRC_ALPHA;
        blend_attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA;
        blend_attachment.alphaBlendOp = .ADD;
    }

    blending : vk.PipelineColorBlendStateCreateInfo;
    blending.sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    blending.logicOpEnable = false;
    blending.logicOp = .COPY;
    blending.attachmentCount = 1;
    blending.pAttachments = &blend_attachment;
    blending.blendConstants[0] = 0.0;
    blending.blendConstants[1] = 0.0;
    blending.blendConstants[2] = 0.0;
    blending.blendConstants[3] = 0.0;

    layout_info : vk.PipelineLayoutCreateInfo;
    layout_info.sType = .PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.setLayoutCount = 1;
    descriptor_set_layout := program.descriptor_set_layout;
    layout_info.pSetLayouts = &descriptor_set_layout;

    layout_info.pushConstantRangeCount = 0;
    layout_info.pPushConstantRanges = nil;
    if program.program_layout.push_constant != nil {
        max_ps_size := dc.graphics_device.props.limits.maxPushConstantsSize;
        ps_size := cast(u32)program.program_layout.push_constant.(Glsl_Field).type.size;
        range : vk.PushConstantRange;
        range.offset = 0;
        range.size = min(ps_size, max_ps_size);
        range.stageFlags = {.VERTEX}; // #Limitation #Incomplete
        layout_info.pushConstantRangeCount = 1;
        layout_info.pPushConstantRanges = &range;

        assert(range.size < max_ps_size, "Push constant too large");
    }

    if vk.CreatePipelineLayout(vk_device, &layout_info, nil, &p.vk_layout) != .SUCCESS {
        panic("Failed creating pipeline layout");
    }

    pipeline_info : vk.GraphicsPipelineCreateInfo;
    pipeline_info.sType = .GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_info.stageCount = cast(u32)len(shader_stages);
    pipeline_info.pStages = slice_to_multi_ptr(shader_stages);
    pipeline_info.pVertexInputState = &input_info;
    pipeline_info.pInputAssemblyState = &input_assembly;
    pipeline_info.pViewportState = &viewport_state;
    pipeline_info.pRasterizationState = &rasterizer;
    pipeline_info.pMultisampleState = &multisampling;
    pipeline_info.pDepthStencilState = nil;
    pipeline_info.pColorBlendState = &blending;
    pipeline_info.pDynamicState = &dynamic_state_info;
    pipeline_info.layout = p.vk_layout;
    pipeline_info.renderPass = render_pass.vk_pass;
    pipeline_info.subpass = 0;
    pipeline_info.basePipelineHandle = 0;
    pipeline_info.basePipelineIndex = -1;
    if vk.CreateGraphicsPipelines(vk_device, 0, 1, &pipeline_info, nil, &p.vk_pipeline) != .SUCCESS {
        panic("Failed creating pipeline");
    }

    cmd_pool_info : vk.CommandPoolCreateInfo;
    cmd_pool_info.sType = .COMMAND_POOL_CREATE_INFO;
    cmd_pool_info.flags = {.TRANSIENT};
    cmd_pool_info.queueFamilyIndex = graphics_family;

    if vk.CreateCommandPool(vk_device, &cmd_pool_info, nil, &p.command_pool) != .SUCCESS {
        panic("Failed creating pipeline command pool");
    }

    alloc_info : vk.CommandBufferAllocateInfo;
    alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.commandBufferCount = 1;
    alloc_info.commandPool = p.command_pool;
    if vk.AllocateCommandBuffers(vk_device, &alloc_info, &p.command_buffer) != .SUCCESS {
        panic("Failed allocating pipeline command buffer");
    }

    p.command_buffer_fence = make_fence(p.dc);

    // #Memory #Fragmentation
    p.uniform_binding_descriptor_counts = make([]int, len(program.program_layout.descriptor_bindings));
    
    for db,i in program.program_layout.descriptor_bindings {
        type := to_vk_desciptor_type(db.kind);
        desc_count := 1 if db.field.type.kind != .ARRAY else db.field.type.elem_count;
        p.num_descriptor_bindings += 1;
        p.num_descriptors_including_array_elements += desc_count;
        p.uniform_binding_descriptor_counts[i] = desc_count;
    }
    
    init_descriptor_set_allocator(&p.descriptor_set_allocator, program.descriptor_set_layout, program.program_layout, dc);
    
    p.master_set_handle, p.master_set = allocate_descriptor_set(&p.descriptor_set_allocator);
    
    // #Uniformcoherency, just look for highest binding and make the the len
    p.bind_records = make([]Bind_Record, p.num_descriptor_bindings);
    for db,i in program.program_layout.descriptor_bindings {
        type := to_vk_desciptor_type(db.kind);
        desc_count := 1 if db.field.type.kind != .ARRAY else db.field.type.elem_count;
        
        record := &p.bind_records[db.location];
        record.binding_location = db.location;
        record.bound_resources = make(type_of(record.bound_resources), desc_count);

        for binding,arr_index in record.bound_resources {
            if type == .UNIFORM_BUFFER {
                write_descriptor(p, db.location, arr_index, .UNIFORM_BUFFER, nil, &null_ubo.desc_info);
                record.bound_resources[arr_index] = null_ubo;
            } else if type == .COMBINED_IMAGE_SAMPLER {
                write_descriptor(p, db.location, arr_index, .COMBINED_IMAGE_SAMPLER, &null_texture_rgba.desc_info, nil);
                record.bound_resources[arr_index] = null_texture_rgba;
            }
        }
    }

    append(&dc.pipelines, p);

    log.info("Created a pipeline");
    log.debugf("\tCommand Pool: 0x%x", p.command_pool);
    log.debugf("\tCommand Buffer: 0x%x", p.command_buffer);

    return p;
}
destroy_pipeline :: proc(pipeline : ^Pipeline) {
    using pipeline.dc;

    match := false;
    for p, i in pipelines {
        if p == pipeline {
            ordered_remove(&pipelines, i);
            match = true;
            break;
        }
    }
    assert(match, "Untracked pipeline");

    vk.DeviceWaitIdle(vk_device);
    destroy_fence(pipeline.command_buffer_fence, pipeline.dc);
    command_buffer := pipeline.command_buffer;
    release_descriptor_set(&pipeline.descriptor_set_allocator, pipeline.master_set_handle);
    destroy_descriptor_set_allocator(pipeline.descriptor_set_allocator);
    vk.FreeCommandBuffers(vk_device, pipeline.command_pool, 1, &command_buffer);
    vk.DestroyCommandPool(vk_device, pipeline.command_pool, nil);
    vk.DestroyPipelineLayout(vk_device, pipeline.vk_layout, nil);
    vk.DestroyPipeline(vk_device, pipeline.vk_pipeline, nil);
    delete(pipeline.wait_semaphores);
    delete(pipeline.wait_stages);
    free(pipeline);
}

write_descriptor :: proc(pipeline : ^Pipeline, binding_location : int, array_index : int, type : vk.DescriptorType, image_info : ^vk.DescriptorImageInfo, buffer_info : ^vk.DescriptorBufferInfo) {
    using pipeline.dc;

    // #Uniformcoherency
    assert(binding_location >= 0 && binding_location < len(pipeline.bind_records), "Binding location out of range");
    assert(array_index >= 0 && array_index < len(pipeline.bind_records[binding_location].bound_resources), "Uniform array index out of range");

    assert(!pipeline.active, "Resources must be bound to a pipeline when it's INactive; before calling begin_draw() or after end_draw()");

    // #Uniformcoherency
    if binding_location < 0 || binding_location > pipeline.num_descriptor_bindings {
        log.warnf("Invalid uniform binding location %i", binding_location);
        return;
    }

    write : vk.WriteDescriptorSet;
    write.sType = .WRITE_DESCRIPTOR_SET;
    write.dstSet = pipeline.master_set;
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

bind_uniform_buffer :: proc(pipeline : ^Pipeline, ubo : ^Uniform_Buffer, binding_location : int, array_index := 0) {
    write_descriptor(pipeline, binding_location, array_index, .UNIFORM_BUFFER, nil, &ubo.desc_info);

    // #Slow
    for db in pipeline.program.program_layout.descriptor_bindings {
        if db.location == binding_location {
            pipeline.bind_records[binding_location].bound_resources[array_index] = ubo;
            break;
        }
    }
}
bind_storage_buffer :: proc(pipeline : ^Pipeline, sbo : ^Storage_Buffer, binding_location : int, array_index := 0) {
    write_descriptor(pipeline, binding_location, array_index, .STORAGE_BUFFER, nil, &sbo.desc_info);

    // #Slow
    for db in pipeline.program.program_layout.descriptor_bindings {
        if db.location == binding_location {
            pipeline.bind_records[binding_location].bound_resources[array_index] = sbo;
            break;
        }
    }
}
bind_texture :: proc(pipeline : ^Pipeline, texture : Texture, binding_location : int, array_index := 0) {

    if .SAMPLE not_in texture.usage_mask {
        log.errorf("Tried to bind texture 0x%x to binding location %i, but it does not have the .SAMPLE usage flag. Set usage mask: %s", texture.vk_image, binding_location, texture.usage_mask);
        return;
    }

    desc_info := texture.desc_info;
    write_descriptor(pipeline, binding_location, array_index, .COMBINED_IMAGE_SAMPLER, &desc_info, nil);

    // #Slow
    for db in pipeline.program.program_layout.descriptor_bindings {
        if db.location == binding_location {
            pipeline.bind_records[binding_location].bound_resources[array_index] = texture;
            break;
        }
    }
}

transition_image_layout :: proc(image : vk.Image, format : vk.Format, old_layout : vk.ImageLayout, new_layout : vk.ImageLayout, signal_semaphore : vk.Semaphore = 0, using dc : ^Device_Context = target_dc) {
    command_buffer := begin_single_use_command_buffer(dc);

    barrier : vk.ImageMemoryBarrier;
    barrier.sType = .IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange.aspectMask = {.COLOR};
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.pNext = nil;

    src_stage : vk.PipelineStageFlags;
    dst_stage : vk.PipelineStageFlags;

    decide_stage_and_access_mask :: proc(layout : vk.ImageLayout) -> (stage : vk.PipelineStageFlags, access : vk.AccessFlags) {
        if layout == .UNDEFINED {
            access = {};
            stage = {.TOP_OF_PIPE};
        } else if layout == .PRESENT_SRC_KHR {
            access = {.MEMORY_READ};
            stage = {.COLOR_ATTACHMENT_OUTPUT};
        } else if layout == .COLOR_ATTACHMENT_OPTIMAL {
            access = {.COLOR_ATTACHMENT_WRITE};
            stage = {.COLOR_ATTACHMENT_OUTPUT};
        } else if layout == .SHADER_READ_ONLY_OPTIMAL {
            access = {.SHADER_READ};
            stage = {.FRAGMENT_SHADER};
        } else if layout == .TRANSFER_DST_OPTIMAL {
            access = {.TRANSFER_WRITE};
            stage = {.TRANSFER};
        } else if layout == .TRANSFER_SRC_OPTIMAL {
            access = {.TRANSFER_READ};
            stage = {.TRANSFER};
        } else {
            panic(fmt.tprintf("Unhandled image layout '%s' for transitioning\n", layout))
        }
        return;
    }

    src_stage, barrier.srcAccessMask = decide_stage_and_access_mask(old_layout);
    dst_stage, barrier.dstAccessMask = decide_stage_and_access_mask(new_layout);

    vk.CmdPipelineBarrier(command_buffer, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier);

    submit_and_destroy_single_use_command_buffer(command_buffer, signal_semaphore=signal_semaphore, dc=dc);
}



begin_draw :: proc(pipeline : ^Pipeline, target : Render_Target) {
    assert(!pipeline.active, "Pipeline begin/end mismatch; begin_draw was called when pipeline is already active.");
    using pipeline.dc;

    pipeline.current_target = target;
    pipeline.active = true;
    descriptor_set : vk.DescriptorSet;
    pipeline.current_descriptor_set_handle, descriptor_set = allocate_descriptor_set(&pipeline.descriptor_set_allocator);

    if pipeline.render_pass.format != target.render_pass.format {
        log.warnf("Pipeline render pass format and target render pass format do not match. Behaviour is ill-defined.\nPipeline render pass format: %s\nTarget render pass format: %s", pipeline.render_pass.format, target.render_pass.format);
    }

    // #Sync #Speed
    wait_fence(pipeline.command_buffer_fence, pipeline.dc);

    check_vk_result(vk.ResetCommandPool(vk_device, pipeline.command_pool, {}));

    cmd_begin_info : vk.CommandBufferBeginInfo;
    cmd_begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
    cmd_begin_info.flags = {};
    cmd_begin_info.pInheritanceInfo = nil;
    check_vk_result(vk.BeginCommandBuffer(pipeline.command_buffer, &cmd_begin_info));

    render_pass_info : vk.RenderPassBeginInfo;
    render_pass_info.sType = .RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = target.render_pass.vk_pass;
    assert(target.render_pass.vk_pass != 0);
    render_pass_info.framebuffer = target.framebuffer;
    render_pass_info.renderArea.offset = {0, 0};
    render_pass_info.renderArea.extent = { cast(u32)target.width, cast(u32)target.height };
    clear_color := vk.ClearValue{color={float32={0.0, 1.0, 0.0, 1.0}}};
    render_pass_info.clearValueCount = 1;
    render_pass_info.pClearValues = &clear_color;
    vk.CmdBeginRenderPass(pipeline.command_buffer, &render_pass_info, .INLINE);

    // #Speed
    for db,i in pipeline.program.program_layout.descriptor_bindings {
        binding := db.location;
        count := pipeline.uniform_binding_descriptor_counts[i];

        copy_info : vk.CopyDescriptorSet;
        copy_info.sType = .COPY_DESCRIPTOR_SET;
        copy_info.descriptorCount = cast(u32)count;
        
        copy_info.dstSet = descriptor_set;
        copy_info.dstBinding = cast(u32)binding;
        copy_info.dstArrayElement = 0;

        copy_info.srcSet = pipeline.master_set;
        copy_info.srcBinding = cast(u32)binding;
        copy_info.srcArrayElement = 0;

        vk.UpdateDescriptorSets(vk_device, 0, nil, 1, &copy_info);
    }
    vk.CmdBindDescriptorSets(pipeline.command_buffer, .GRAPHICS, pipeline.vk_layout, 0, 1, &descriptor_set, 0, nil);

    vk.CmdBindPipeline(pipeline.command_buffer, .GRAPHICS, pipeline.vk_pipeline);

    viewport : vk.Viewport;
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width  = cast(f32)target.width;
    viewport.height = cast(f32)target.height;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;

    scissor : vk.Rect2D;
    scissor.offset = {0, 0};
    scissor.extent = { cast(u32)target.width, cast(u32)target.height };
    vk.CmdSetViewport(pipeline.command_buffer, 0, 1, &viewport);
    vk.CmdSetScissor(pipeline.command_buffer, 0, 1, &scissor);
}
end_draw :: proc(pipeline : ^Pipeline, wait_sem : vk.Semaphore = 0) {
    assert(pipeline.active, "Pipeline begin/end mismatch; end_draw was called before begin_draw");
    using pipeline.dc;
    target := pipeline.current_target;

    vk.CmdEndRenderPass(pipeline.command_buffer);
    check_vk_result(vk.EndCommandBuffer(pipeline.command_buffer));

    if wait_sem != 0 {
        append(&pipeline.wait_semaphores, wait_sem);
    }

    for sem in pipeline.wait_semaphores {
        // #Limitation #Depth
        append(&pipeline.wait_stages, vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT});
    }

    submit_info : vk.SubmitInfo;
    submit_info.sType = .SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    command_buffer := pipeline.command_buffer;
    submit_info.pCommandBuffers = &command_buffer;
    submit_info.signalSemaphoreCount = 0;
    submit_info.waitSemaphoreCount = cast(u32)len(pipeline.wait_semaphores);
    submit_info.pWaitSemaphores = slice_to_multi_ptr(pipeline.wait_semaphores[:]);
    submit_info.pWaitDstStageMask = slice_to_multi_ptr(pipeline.wait_stages[:]);
    
    command_fence := pipeline.command_buffer_fence;

    check_vk_result(vk.ResetFences(vk_device, 1, &command_fence));
    check_vk_result(vk.QueueSubmit(queues.graphics, 1, &submit_info, command_fence));

    // #Sync #Speed
    wait_fence(command_fence, pipeline.dc);
    //release_descriptor_set(&pipeline.descriptor_set_allocator, pipeline.current_descriptor_set_handle, command_fence);
    release_descriptor_set(&pipeline.descriptor_set_allocator, pipeline.current_descriptor_set_handle, 0);
    

    clear(&pipeline.wait_semaphores);
    clear(&pipeline.wait_stages)

    pipeline.current_descriptor_set_handle = -1;
    pipeline.active = false;

}

cmd_draw :: proc(pipeline : ^Pipeline, num_vertices : int, num_instances : int, first_vertex : int = 0, first_instance : int = 0) {
    assert(pipeline.active, "Pipeline is not active; call being_draw() before doing draw commands");
    vk.CmdDraw(pipeline.command_buffer, cast(u32)num_vertices, cast(u32)num_instances, cast(u32)first_vertex, cast(u32)first_instance);
}
cmd_draw_vertex_buffer :: proc(pipeline : ^Pipeline, vbo : ^Vertex_Buffer, num_vertices := -1, offset := 0, num_instances := 1, first_vertex := 0, first_instance := 0) {
    assert(pipeline.active, "Pipeline is not active; call being_draw() before doing draw commands");
    num_vertices := num_vertices if num_vertices > 0 else vbo.vertex_count;

    offset := cast(vk.DeviceSize)offset;
    vk.CmdBindVertexBuffers(pipeline.command_buffer, 0, 1, &vbo.vk_buffer, &offset);
    vk.CmdDraw(pipeline.command_buffer, cast(u32)num_vertices, cast(u32)num_instances, cast(u32)first_vertex, cast(u32)first_instance);
}
cmd_draw_indexed :: proc(pipeline : ^Pipeline, vbo : ^Vertex_Buffer, ibo : ^Index_Buffer, index_count := -1, index_offset := 0, num_instances := 1, first_vertex := 0, first_instance := 0) {
    assert(pipeline.active, "Pipeline is not active; call being_draw() before doing draw commands");
    index_count := index_count if index_count > 0 else ibo.index_count;

    vbo_offset :vk.DeviceSize= 0;
    vk.CmdBindVertexBuffers(pipeline.command_buffer, 0, 1, &vbo.vk_buffer, &vbo_offset);
    vk.CmdBindIndexBuffer(pipeline.command_buffer, ibo.vk_buffer, cast(vk.DeviceSize)0, .UINT32);
    vk.CmdDrawIndexed(pipeline.command_buffer, cast(u32)index_count, cast(u32)num_instances, cast(u32)index_offset, 0, cast(u32)first_instance);
}

cmd_clear :: proc(pipeline : ^Pipeline, clear_mask : vk.ImageAspectFlags = { .COLOR }, clear_color := lin.Vector4{0, 0, 0, 1.0}, clear_rect : Maybe(lin.Vector4) = nil) {

    clear_rect := clear_rect;
    if clear_rect == nil {
        clear_rect = lin.Vector4{0, 0, cast(f32)pipeline.current_target.width, cast(f32)pipeline.current_target.height};
    }
    vk_clear_rect : vk.ClearRect;
    vk_clear_rect.rect = vk.Rect2D {
        {cast(i32)clear_rect.(lin.Vector4).x, cast(i32)clear_rect.(lin.Vector4).y},
        {cast(u32)clear_rect.(lin.Vector4).z, cast(u32)clear_rect.(lin.Vector4).w},
    };
    vk_clear_rect.baseArrayLayer = 0;
    vk_clear_rect.layerCount = 1;

    clear_info : vk.ClearAttachment;
    clear_info.aspectMask = clear_mask;
    clear_info.colorAttachment = 0;
    clear_info.clearValue.color = transmute(vk.ClearColorValue)clear_color;
    vk.CmdClearAttachments(pipeline.command_buffer, 1, &clear_info, 1, &vk_clear_rect);
}

cmd_set_push_constant :: proc(pipeline : ^Pipeline, data : rawptr, offset : int, size : int) {
     // #Limitation #Incomplete (.VERTEX)
    vk.CmdPushConstants(pipeline.command_buffer, pipeline.vk_layout, {.VERTEX}, cast(u32)offset, cast(u32)size, data);
}

cmd_scissor_box :: proc(pipeline : ^Pipeline, x, y, width, height : f32) {

    x:=x;
    y:=y;
    width:=width;
    height:=height;
    if x < 0 {
        width += x;
        x = 0;
    }
    if y < 0 {
        height += y;
        y = 0;
    }

    if width <= 0 || height <= 0 {
        // #Hack #Bugprone
        x = 9999999;
        y = 9999999;
        width = 1;
        height = 1;
    }

    scissor : vk.Rect2D;
    scissor.offset = { cast(i32)x, cast(i32)y};
    scissor.extent = { cast(u32)width, cast(u32)height };
    vk.CmdSetScissor(pipeline.command_buffer, 0, 1, &scissor);
}