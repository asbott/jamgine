package justvkold

import "core:fmt"
import "core:os"
import "core:builtin"
import "core:c"
import "core:mem"
import "core:strings"
import "core:runtime"
import "core:slice"
import "core:intrinsics"
import "core:reflect"
import "core:math"
import "core:log"

import "vendor:glfw"
import vk "vendor:vulkan"
import stb "vendor:stb/image"

import "jamgine:lin"
import "jamgine:shaderc"
import glsl "jamgine:glsl_inspect"















Semaphore :: vk.Semaphore;
Fence     :: vk.Fence;

Sync_Mode :: enum {
    ASYNC,
    SYNC,
}
Queue_Family_Set :: struct {
    graphics  : Maybe(u32),
    present  : Maybe(u32),
    transfer  : Maybe(u32),
}
GPU_Info :: struct {
    vk_physical_device : vk.PhysicalDevice,
    props : vk.PhysicalDeviceProperties,
    memory_props : vk.PhysicalDeviceMemoryProperties,
    features : vk.PhysicalDeviceFeatures,
    queue_family_set : Queue_Family_Set,
    queue_family_propertes : []vk.QueueFamilyProperties,
}
Device_Context :: struct {
    vk_device : vk.Device,
    gpu : GPU_Info,

    used_queues_set : map[u32]u32,
    graphics_queue : vk.Queue,
    present_queue : vk.Queue,
    transfer_queue : vk.Queue,

    shaders_to_destroy : [dynamic]Shader_Module,
    pipelines_to_destroy : [dynamic]^Pipeline,

    num_active_pipelines : int,

    transfer_pool : vk.CommandPool,

    render_texture_pass : vk.RenderPass,

    // Feels like the best solution right now among a lot of really
    // bad solutions. The problem is that we defer descriptor updates
    // for each frame in flight which means if we delete a resource
    // it may be fine in the current frame as long as we dont bind it
    // afterwards, but the writes may still be deferred for other frames
    // in flight meaning we will update a descriptor set with an
    // invalid descriptor write. So, for now, we'll just keep track of
    // all alive pipelines and everytime we destroy a resource that
    // could be used in a deferred descriptor write, we make sure that
    // potential write is removed in all frames in flight.
    pipelines : [dynamic]^Pipeline,

}
Render_Target :: struct {
    image          : vk.Image,
    image_view     : vk.ImageView,
    framebuffer    : vk.Framebuffer,
    image_format   : vk.Format,
    extent         : vk.Extent2D,
    index          : u32, // Relevant in swap chain
    current_layout : vk.ImageLayout,
    render_pass    : vk.RenderPass,
    
    image_ready_semaphore_pointer : ^vk.Semaphore, // Points to a semaphore if sync is necessary, otherwise nil
    render_done_semaphore : vk.Semaphore,
}
Command_Buffer_Factory :: struct {
    dc : ^Device_Context,
    pool : vk.CommandPool,
    buffers : [dynamic]vk.CommandBuffer,
    fences : [dynamic]vk.Fence,
    next_index : int,
}
Graphics_Window :: struct {
    dc : ^Device_Context,

    number_of_frames : int,

    frame_targets : []^Render_Target,
    //frame_fences : []vk.Fence,
    frame_index : int,
    
    // Same format and extent as all its targets
    image_format : vk.Format,
    extent : vk.Extent2D,
    
    vk_swap_chain : vk.SwapchainKHR,
    retrieve_semaphores : []vk.Semaphore,
    
    active_target : ^Render_Target,
    
    glfw_window : glfw.WindowHandle, // #Unused?
    surface : vk.SurfaceKHR,
    surface_render_pass : vk.RenderPass,

    // #Memory #Fragmentation #Speed
    command_buffer_factories : []Command_Buffer_Factory,

    should_pipeline_wait_for_render_semaphore : bool,

    pipelines : [dynamic]^Pipeline,
}
// Shader_Program and Shader_Module should be passed as value because there is no reason for them
// to change after initial compilation. The data is for read-only purposes.
Shader_Program :: struct {
    vertex, fragment : Shader_Module,
    geometry, tesselation : Maybe(Shader_Module),

    vertex_input_layout : Vertex_Layout,
    
    uniforms : []glsl.Uniform,
    descriptor_set_layout : vk.DescriptorSetLayout,
}
Shader_Module :: struct {
    bytes : []byte,
    text_source : string,
    stage : vk.ShaderStageFlag,
    vk_module : vk.ShaderModule,
    info : glsl.Glsl_Stage_Info,
}
Pipeline_Config :: struct {
    max_uses_per_frame : int,
    dynamic_states : []vk.DynamicState,
}
DEFAULT_PIPELINE_CONFIG :: Pipeline_Config {
    max_uses_per_frame=1,
    dynamic_states={.VIEWPORT, .SCISSOR},
};
Pipeline :: struct {
    dc : ^Device_Context,


    // #Refactor ?
    // I wanted to disconnect graphics window and pipeline concepts but
    // I can't think of a way to have a descriptor set for each frame in
    // flight without the pipeline depending on the window.
    // However, we can just set the window in pipeline in initialization
    // which is probably fine because I can't think of a scenario where
    // we would have pipelines without a graphics window.
    window : ^Graphics_Window,

    program : Shader_Program,
    vk_pipeline : vk.Pipeline,
    vk_layout : vk.PipelineLayout,

    active_target : ^Render_Target,
    descriptor_pool : vk.DescriptorPool,
    descriptor_sets : [][]vk.DescriptorSet,
    descr_write_queues : [][dynamic]vk.WriteDescriptorSet,

    wait_semaphores : [dynamic]vk.Semaphore,
    wait_stages : [dynamic]vk.PipelineStageFlags,

    num_descriptors_including_array_elements : int,
    num_descriptor_bindings : int,
    uniform_binding_descriptor_counts : []int,

    command_buffer : vk.CommandBuffer,
    command_fence : vk.Fence,
    
    config : Pipeline_Config,
    num_uses_this_frame : int,
}


vk_inst : vk.Instance;
vk_messenger : vk.DebugUtilsMessengerEXT;
glsl_compiler : ^shaderc.compiler;

validation_layers : []cstring;

// Resources to destroy on shutdown, if they haven't already been so by the program
dcs_to_destroy : [dynamic]^Device_Context;

target_dc : ^Device_Context;

wait_all_queues :: proc(dc : ^Device_Context) {
    // DeviceWaitIdle ?
    vk.QueueWaitIdle(dc.graphics_queue);
    vk.QueueWaitIdle(dc.present_queue);
    vk.QueueWaitIdle(dc.transfer_queue);
}

wait_all_command_fences :: proc(window : ^Graphics_Window) {
    using window.dc;
    for fact in window.command_buffer_factories {        
        if cast(u32)len(fact.fences) == 0 do continue;
        vk.WaitForFences(vk_device, cast(u32)len(fact.fences), slice_to_multi_ptr(fact.fences[:]), true, c.UINT64_MAX);
    }
}

wait_current_frame_fences :: proc(window : ^Graphics_Window) {
    using window.dc;
    fact := window.command_buffer_factories[window.frame_index];
    
    if cast(u32)len(fact.fences) == 0 do return;
    vk.WaitForFences(vk_device, cast(u32)len(fact.fences), slice_to_multi_ptr(fact.fences[:]), true, c.UINT64_MAX);
}

set_target_device_context :: proc(dc : ^Device_Context) {
    target_dc = dc;
}
get_target_device_context :: proc() -> ^Device_Context {
    return target_dc;
}

get_front_render_target :: proc(window : ^Graphics_Window) -> (^Render_Target) {
    return window.active_target;
    /*
    wait_current_frame_fences(dc);

    target_index : u32;
    result := vk.AcquireNextImageKHR(vk_device, target_window_swap_chain.vk_swap_chain, c.UINT64_MAX, target_window_swap_chain.retrieve_semaphores[target_window_swap_chain.frame_index], 0, &target_index);

    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        destroy_target_swap_chain(dc);
        create_target_swap_chain(dc);
        return get_front_render_target(dc);
    } else if result != .SUCCESS {
        panic("Failed retrieve next image");
    }

    target := target_window_swap_chain.frame_targets[target_index];
    target.image_ready_semaphore_pointer = &target_window_swap_chain.retrieve_semaphores[target_window_swap_chain.frame_index];

    return target;
    */
}

begin_draw_commands :: proc(pipeline : ^Pipeline, target : ^Render_Target) {
    using pipeline.dc;
    pipeline.dc.num_active_pipelines += 1;
    pipeline.active_target = target;

    if target.current_layout == .SHADER_READ_ONLY_OPTIMAL {
        // #Sync
        transition_image_layout(target.image, target.image_format, target.current_layout, .COLOR_ATTACHMENT_OPTIMAL, dc=pipeline.dc);
        target.current_layout = .COLOR_ATTACHMENT_OPTIMAL;
    }

    //if pipeline.command_fence != 0 do vk.WaitForFences(vk_device, 1, &pipeline.command_fence, true, c.UINT64_MAX);
    
    pipeline.command_buffer, pipeline.command_fence = request_command_buffer(&pipeline.window.command_buffer_factories[pipeline.window.frame_index]);
    vk.ResetCommandBuffer(pipeline.command_buffer, {});

    // #Limitation #Speed
    // Managing descriptor sets get very complicated without this
    // limitation because #Sync issues when trying to update a
    // descriptor set that's already in use in a previous command
    // buffer. We could sync with fences but I think that will be
    // a pretty bad hidden performance problem. This might be a fair
    // exchange in verbose but performant vs simple but slow and unpredictable.
    // If we really needed a more dynamic pipeline we can make a simple
    // "Dynamic_Pipeline" kind of thing which is just a "growing" pipeline
    // that rebuilds itself whenever more uses are necessary (like dynamic array).
    // This might also turn out to be a big problem in terms of #Speed when
    // destroying resources if there are a lot of resources and a lot of writes.
    assert(pipeline.num_uses_this_frame < pipeline.config.max_uses_per_frame, fmt.tprintf("Pipeline max usage per frame of %i was exceeded. Set pipeline config in make_pipeline to allow for more uses.", pipeline.config.max_uses_per_frame));
    
    pipeline_allocate_descriptor_set_if_needed(pipeline, pipeline.window.frame_index);

    cmd_begin_info : vk.CommandBufferBeginInfo;
    cmd_begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
    cmd_begin_info.flags = {};
    cmd_begin_info.pInheritanceInfo = nil;
    vk.BeginCommandBuffer(pipeline.command_buffer, &cmd_begin_info);

    render_pass_info : vk.RenderPassBeginInfo;
    render_pass_info.sType = .RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = target.render_pass;
    render_pass_info.framebuffer = target.framebuffer;
    render_pass_info.renderArea.offset = {0, 0};
    render_pass_info.renderArea.extent = target.extent;
    clear_color := vk.ClearValue{color={float32={0.0, 1.0, 0.0, 1.0}}};
    render_pass_info.clearValueCount = 1;
    render_pass_info.pClearValues = &clear_color;
    vk.CmdBeginRenderPass(pipeline.command_buffer, &render_pass_info, .INLINE);

    vk.CmdBindPipeline(pipeline.command_buffer, .GRAPHICS, pipeline.vk_pipeline);

    viewport : vk.Viewport;
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width  = cast(f32)target.extent.width;
    viewport.height = cast(f32)target.extent.height;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;

    scissor : vk.Rect2D;
    scissor.offset = {0, 0};
    scissor.extent = target.extent;

    vk.CmdSetViewport(pipeline.command_buffer, 0, 1, &viewport);
    vk.CmdSetScissor(pipeline.command_buffer, 0, 1, &scissor);
}
/*cmd_draw_instanced :: proc(using pipeline : ^Pipeline, vertex_count, instance_count, vertex_start, instance_start : int) {
    vk.CmdDraw(command_buffer, cast(u32)vertex_count, cast(u32)instance_count, cast(u32)vertex_start, cast(u32)instance_start);
}*/
cmd_draw_vertex_buffer :: proc(pipeline : ^Pipeline, vbo : ^Vertex_Buffer, start_index : int = 0, num_instances := 1) {
    // TODO #Errorhandling
    // Compare vbo vertex layout to pipeline program vertex layout
    // and return error if incompatible

    //if vbo.transfer_done_semaphore != 0 do append(&pipeline.wait_semaphores, vbo.transfer_done_semaphore);
    offsets :[]vk.DeviceSize= {cast(vk.DeviceSize)start_index};
    vk.CmdBindVertexBuffers(pipeline.command_buffer, 0, 1, &vbo.vk_buffer, slice_to_multi_ptr(offsets));
    update_and_cmd_bind_descriptor_sets(pipeline);
    vk.CmdDraw(pipeline.command_buffer, cast(u32)(vbo.size / size_of(vbo.layout.stride)), cast(u32)num_instances, cast(u32)start_index, 0);
}
cmd_draw_indexed :: proc(pipeline : ^Pipeline, vbo : ^Vertex_Buffer, ibo : ^Index_Buffer, index_count := -1, index_offset := 0, vertex_offset := 0, num_instances := 1) {
    //if vbo.transfer_done_semaphore != 0 do append(&pipeline.wait_semaphores, vbo.transfer_done_semaphore);
    //if ibo.transfer_done_semaphore != 0 do append(&pipeline.wait_semaphores, ibo.transfer_done_semaphore);
    offsets :[]vk.DeviceSize= {0};
    vk.CmdBindVertexBuffers(pipeline.command_buffer, 0, 1, &vbo.vk_buffer, slice_to_multi_ptr(offsets));
    vk.CmdBindIndexBuffer(pipeline.command_buffer, ibo.vk_buffer, cast(vk.DeviceSize)0, .UINT32);
    update_and_cmd_bind_descriptor_sets(pipeline);
    vk.CmdDrawIndexed(pipeline.command_buffer, cast(u32)index_count if index_count > 0 else cast(u32)(ibo.size / size_of(u32)), cast(u32)num_instances, cast(u32)index_offset, cast(i32)vertex_offset, 0);
}
cmd_clear :: proc(pipeline : ^Pipeline, clear_mask : vk.ImageAspectFlags = { .COLOR }, clear_color := lin.Vector4{0, 0, 0, 1.0}, clear_rect : Maybe(lin.Vector4) = nil) {

    clear_rect := clear_rect;
    if clear_rect == nil {
        clear_rect = lin.Vector4{0, 0, cast(f32)pipeline.active_target.extent.width, cast(f32)pipeline.active_target.extent.height};
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
end_draw_commands_sync :: proc(pipeline : ^Pipeline, extra_wait_semaphores := []vk.Semaphore{}) {
    using pipeline.dc;
    done_fence := end_draw_commands_async(pipeline, extra_wait_semaphores);
    vk.WaitForFences(vk_device, 1, &done_fence, true, c.UINT64_MAX);
}
end_draw_commands_async :: proc(using pipeline : ^Pipeline, extra_wait_semaphores := []vk.Semaphore{}, signal_semaphore : vk.Semaphore = 0) -> (vk.Fence){
    using pipeline.dc;
    assert(active_target != nil, "Pipelines has no render target set, did you call begin_draw_commands first?");

    vk.CmdEndRenderPass(pipeline.command_buffer);
    vk.EndCommandBuffer(pipeline.command_buffer);

    wait_image := window.active_target.image_ready_semaphore_pointer != nil;
    wait_last  := window.should_pipeline_wait_for_render_semaphore;

    // This is only false for the first pipeline used per frame
    window.should_pipeline_wait_for_render_semaphore = true;
    
    //wait_stages : []vk.PipelineStageFlags = {{.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_OUTPUT}};
    if wait_image do append(&pipeline.wait_semaphores, window.active_target.image_ready_semaphore_pointer^);
    if wait_last  do append(&pipeline.wait_semaphores, window.active_target.render_done_semaphore);

    window.active_target.image_ready_semaphore_pointer = nil;
    
    for s in extra_wait_semaphores {
        append(&wait_semaphores, s);
    }
    for ws in pipeline.wait_semaphores {
        append(&pipeline.wait_stages, vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT});
    }

    submit_info : vk.SubmitInfo;
    submit_info.waitSemaphoreCount = cast(u32)len(wait_semaphores);
    submit_info.pWaitSemaphores = slice_to_multi_ptr(wait_semaphores[:]);
    submit_info.pWaitDstStageMask = slice_to_multi_ptr(wait_stages[:]);
    submit_info.sType = .SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &pipeline.command_buffer;
    if signal_semaphore != 0 {
        signal_semaphores := []vk.Semaphore {
            pipeline.active_target.render_done_semaphore,
            signal_semaphore,
        };
        submit_info.signalSemaphoreCount = 2;
        submit_info.pSignalSemaphores = slice_to_multi_ptr(signal_semaphores);
    } else {
        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = &pipeline.active_target.render_done_semaphore;
    }
    
    vk.ResetFences(vk_device, 1, &pipeline.command_fence);
    res := vk.QueueSubmit(graphics_queue, 1, &submit_info, pipeline.command_fence);
    if res != .SUCCESS {
        panic(fmt.tprintf("Queue submit fail %s", res));
    }

    // #Speed #Sync #Temporary #Incomplete
    // Dont want to deal with this right now , 
    // the render texture needs to wait for command buffer above
    // to be done before transition happens. Should just pass a semaphore.
    wait_fence(pipeline.command_fence, dc);
    if active_target.current_layout == .COLOR_ATTACHMENT_OPTIMAL {
        // #Sync
        transition_image_layout(active_target.image, active_target.image_format, active_target.current_layout, .SHADER_READ_ONLY_OPTIMAL, dc=pipeline.dc);
        active_target.current_layout = .SHADER_READ_ONLY_OPTIMAL;
    }

    clear(&pipeline.wait_semaphores);
    clear(&pipeline.wait_stages);
    
    pipeline.command_buffer = nil;

    pipeline.num_uses_this_frame += 1;

    num_active_pipelines -= 1;

    return pipeline.command_fence;
}

render_and_swap_window_buffers :: proc(window : ^Graphics_Window) {
    using window.dc;


    //
    // Swap buffers ("Present") when graphics queue is done (sync on GPU)
    present_wait_semaphores : [] vk.Semaphore = {window.active_target.render_done_semaphore};
    swap_chains : []vk.SwapchainKHR = { window.vk_swap_chain };
    present_info : vk.PresentInfoKHR;
    present_info.sType = .PRESENT_INFO_KHR;
    present_info.waitSemaphoreCount = cast(u32)len(present_wait_semaphores);
    present_info.pWaitSemaphores = slice_to_multi_ptr(present_wait_semaphores);
    present_info.swapchainCount = cast(u32)len(swap_chains);
    present_info.pSwapchains = slice_to_multi_ptr(swap_chains);
    present_info.pImageIndices = &window.active_target.index;
    present_info.pResults = nil;
    vk.QueuePresentKHR(present_queue, &present_info);
    window.should_pipeline_wait_for_render_semaphore = false;
    
    window.frame_index = (window.frame_index + 1) % len(window.command_buffer_factories);
    wait_current_frame_fences(window);

    extract_window_active_target(window);

    reset_command_buffer_factory(&window.command_buffer_factories[window.frame_index]);

    for p in window.pipelines {
        p.num_uses_this_frame = 0;
        p.command_fence = 0;
    }
}
extract_window_active_target :: proc(window : ^Graphics_Window) {
    using window.dc;
    target_index : u32;
    result := vk.AcquireNextImageKHR(vk_device, window.vk_swap_chain, c.UINT64_MAX, window.retrieve_semaphores[window.frame_index], 0, &target_index);

    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        recreate_or_init_window_swap_chain(window);
        extract_window_active_target(window);
        return;
    } else if result != .SUCCESS {
        panic("Failed retrieve next image");
    }

    window.active_target = window.frame_targets[target_index];
    window.active_target.image_ready_semaphore_pointer = &window.retrieve_semaphores[window.frame_index];
}

update_and_cmd_bind_descriptor_sets :: proc(pipeline : ^Pipeline) {
    using pipeline.dc;
    writes := pipeline.descr_write_queues[pipeline.window.frame_index];
    if len(writes) > 0 {
        vk.UpdateDescriptorSets(vk_device, cast(u32)len(writes), slice_to_multi_ptr(writes[:]), 0, nil);
        clear(&pipeline.descr_write_queues[pipeline.window.frame_index]);
    }
    vk.CmdBindDescriptorSets(pipeline.command_buffer, .GRAPHICS, pipeline.vk_layout, 0, 1, &pipeline.descriptor_sets[pipeline.window.frame_index][pipeline.num_uses_this_frame], 0, nil);
}

queue_resource_descriptor_write :: proc(pipeline : ^Pipeline, binding_location : int, index : int, type : vk.DescriptorType, buffer_info : ^vk.DescriptorBufferInfo, image_info : ^vk.DescriptorImageInfo, using dc : ^Device_Context) {

    if pipeline.dc.num_active_pipelines > 0 {
        // #Limitation #Sync
        // This limitation would be fine if it was per thread.
        // Because we should totally be able to bind resources from
        // different threads as long as the threads don't share
        // pipelines.
        panic("Resources cannot be bound while a pipeline is active #Limitation #Sync");   
    }

    assert(binding_location >= 0, "Binding location was < 0, but it must be >= 0");
    for i in 0..<len(pipeline.descr_write_queues) {
        pipeline_allocate_descriptor_set_if_needed(pipeline, i);
        write : vk.WriteDescriptorSet;
        write.sType = .WRITE_DESCRIPTOR_SET;
        write.dstSet = pipeline.descriptor_sets[i][pipeline.num_uses_this_frame];
        write.dstBinding = cast(u32)binding_location;
        write.dstArrayElement = cast(u32)index;
        write.descriptorType = type;
        write.descriptorCount = 1;
        write.pImageInfo = image_info;
        write.pBufferInfo = buffer_info;
        write.pTexelBufferView = nil;
        write.pNext = nil;
        append(&pipeline.descr_write_queues[i], write);
    }
}
clear_descriptor_writes_texture :: proc(texture : ^Texture) {
    // #Speed #Dumb
    using texture.dc;
    for pipeline in pipelines {
        for q,i in pipeline.descr_write_queues {
            for j := len(pipeline.descr_write_queues[i])-1; j >= 0; j -= 1 {
                write := pipeline.descr_write_queues[i][j];
                if write.pImageInfo != nil && write.pImageInfo.imageView == texture.desc_info.imageView {
                    unordered_remove(&pipeline.descr_write_queues[i], j);
                    continue;
                }
            }
        }
    }
}
clear_descriptor_writes_uniform_buffer :: proc(ubo : ^Uniform_Buffer) {
    // #Speed #Dumb
    using ubo.dc;
    for pipeline in pipelines {
        for q,i in pipeline.descr_write_queues {
            for j := len(pipeline.descr_write_queues[i])-1; j >= 0; j -= 1 {
                write := pipeline.descr_write_queues[i][j];
                if write.pBufferInfo != nil && write.pBufferInfo.buffer == ubo.vk_buffer {
                    unordered_remove(&pipeline.descr_write_queues[i], j);
                    continue;
                }
            }
        }
    }
}
bind_uniform_buffer :: proc(pipeline : ^Pipeline, binding_location : int, ubo : ^Uniform_Buffer, index := 0, using dc := target_dc) {
    queue_resource_descriptor_write(pipeline, binding_location, index, .UNIFORM_BUFFER, &ubo.desc_info, nil, dc);
}
bind_texture :: proc(pipeline : ^Pipeline, binding_location : int, texture : ^Texture, index := 0, using dc := target_dc) {
    queue_resource_descriptor_write(pipeline, binding_location, index, .COMBINED_IMAGE_SAMPLER, nil, &texture.desc_info, dc);
}

request_command_buffer :: proc(cbf : ^Command_Buffer_Factory) -> (vk.CommandBuffer, vk.Fence) {
    using cbf.dc;

    for cbf.next_index >= len(cbf.buffers) {
        cmd_alloc_info : vk.CommandBufferAllocateInfo;
        cmd_alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
        cmd_alloc_info.commandPool = cbf.pool;
        cmd_alloc_info.level = .PRIMARY;
        cmd_alloc_info.commandBufferCount = 1;

        buffer : vk.CommandBuffer;
        if vk.AllocateCommandBuffers(vk_device, &cmd_alloc_info, &buffer) != .SUCCESS {
            panic("Failed creating command buffer");
        }

        fence := make_fence(cbf.dc);

        append(&cbf.buffers, buffer);
        append(&cbf.fences, fence);
    }

    cbf.next_index += 1;
    return cbf.buffers[cbf.next_index-1], cbf.fences[cbf.next_index-1];
}
reset_command_buffer_factory :: proc(cbf : ^Command_Buffer_Factory) {
    using cbf.dc;

    cbf.next_index = 0;
}

init :: proc() {
	
    // Load basic procs for creating instance
    vk.load_proc_addresses_global(cast(rawptr)glfw.GetInstanceProcAddress);
    create_vk_instance();
    // Load rest of procs for instance
    vk.load_proc_addresses_instance(vk_inst);
    
    when ODIN_DEBUG {
        create_debug_messenger();
    }

    dcs_to_destroy = make([dynamic]^Device_Context);
    glsl_compiler = shaderc.compiler_initialize();
}
init_and_make_target_device_context :: proc(glfw_window : glfw.WindowHandle, pdevice : vk.PhysicalDevice = nil, allocator := context.allocator) {
    init();
    set_target_device_context(make_device_context(glfw_window, pdevice, allocator));
}


// #Refactor
// The vertex layout should be inferred from reflecting the glsl shaders once
// glsl reflection is implemented.
make_pipeline :: proc(program : Shader_Program, window : ^Graphics_Window, config := DEFAULT_PIPELINE_CONFIG, using dc := target_dc, allocator := context.allocator) -> ^Pipeline {
    context.allocator = allocator;

    vertex_layout := program.vertex_input_layout;

    p := new(Pipeline);
    append(&pipelines_to_destroy, p);

    p.dc = dc;
    p.window = window;
    p.program = program;
    p.config = config;
    p.wait_semaphores = make([dynamic]vk.Semaphore);
    p.wait_stages = make([dynamic]vk.PipelineStageFlags);

    make_shader_stage :: proc(module : Shader_Module) -> vk.PipelineShaderStageCreateInfo {
        create_info : vk.PipelineShaderStageCreateInfo;
        create_info.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO;
        create_info.stage = {module.stage};
        create_info.module = module.vk_module;
        create_info.pName = "main";

        return create_info;
    }
    
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
    input_info.vertexBindingDescriptionCount = 1;
    input_info.pVertexBindingDescriptions = &vertex_layout.binding;
    input_info.vertexAttributeDescriptionCount = cast(u32)len(vertex_layout.attributes);
    input_info.pVertexAttributeDescriptions = slice_to_multi_ptr(vertex_layout.attributes);

    input_assembly : vk.PipelineInputAssemblyStateCreateInfo;
    input_assembly.sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = .TRIANGLE_LIST;
    input_assembly.primitiveRestartEnable = false;
    
    dynamic_state_info : vk.PipelineDynamicStateCreateInfo;
    dynamic_state_info.sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic_state_info.dynamicStateCount = cast(u32)len(config.dynamic_states);
    dynamic_state_info.pDynamicStates = slice_to_multi_ptr(config.dynamic_states);

    viewport : vk.Viewport;
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = cast(f32)window.extent.width;
    viewport.height = cast(f32)window.extent.height;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;

    scissor : vk.Rect2D;
    scissor.offset = {0, 0};
    scissor.extent = window.extent;
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
    blend_attachment.colorWriteMask = {.R, .G, .B, .A};
    blend_attachment.blendEnable = true;
    blend_attachment.srcColorBlendFactor = .SRC_ALPHA;
    blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
    blend_attachment.colorBlendOp = .ADD;
    blend_attachment.srcAlphaBlendFactor = .ONE;
    blend_attachment.dstAlphaBlendFactor = .ZERO;
    blend_attachment.alphaBlendOp = .ADD;

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
    pipeline_info.renderPass = window.surface_render_pass;
    pipeline_info.subpass = 0;
    pipeline_info.basePipelineHandle = 0;
    pipeline_info.basePipelineIndex = -1;
    if vk.CreateGraphicsPipelines(vk_device, 0, 1, &pipeline_info, nil, &p.vk_pipeline) != .SUCCESS {
        panic("Failed creating pipeline");
    }
    
    //
    // Descriptor Pool
    
    num_descriptors := cast(u32)len(program.uniforms);
    p.uniform_binding_descriptor_counts = make([]int, len(program.uniforms));

    num_samplers := 0;
    num_buffers := 0;
    
    for uniform,i in program.uniforms {
        p.num_descriptor_bindings += 1;
        type := get_uniform_descriptor_type(uniform);
        desc_count := uniform.type.size / uniform.type.elem_size;
        p.num_descriptors_including_array_elements += desc_count;
        p.uniform_binding_descriptor_counts[uniform.binding] = desc_count; // #Uniformcoherency
        uniform_count := 1 if uniform.type.kind != .ARRAY else uniform.type.size / uniform.type.elem_size;;
        if type == .UNIFORM_BUFFER {
            num_buffers += uniform_count;
        } else if type == .COMBINED_IMAGE_SAMPLER {
            num_samplers += uniform_count;
        } else {
            panic("Unhandled descriptor type");
        }
    }
    
    buffers_size : vk.DescriptorPoolSize;
    buffers_size.descriptorCount = cast(u32)num_buffers;
    buffers_size.type = .UNIFORM_BUFFER;
    samplers_size : vk.DescriptorPoolSize;
    samplers_size.descriptorCount = cast(u32)num_samplers;
    samplers_size.type = .COMBINED_IMAGE_SAMPLER;
    sizes := []vk.DescriptorPoolSize {
        buffers_size, samplers_size,
    }
    
    num_sets := len(window.frame_targets);
    
    // #Memory #Fragmentation #Speed !!!
    // #Memory #Fragmentation #Speed !!!
    // #Memory #Fragmentation #Speed !!!
    // #Memory #Fragmentation #Speed !!!
    p.descr_write_queues = make([][dynamic]vk.WriteDescriptorSet, num_sets);
    for q,i in p.descr_write_queues {
        p.descr_write_queues[i] = make([dynamic]vk.WriteDescriptorSet);
    }
    pool_info : vk.DescriptorPoolCreateInfo;
    pool_info.sType = .DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.poolSizeCount = cast(u32)len(sizes);
    pool_info.pPoolSizes = slice_to_multi_ptr(sizes);
    pool_info.maxSets = cast(u32)num_sets * cast(u32)config.max_uses_per_frame;
    if vk.CreateDescriptorPool(vk_device, &pool_info, nil, &p.descriptor_pool) != .SUCCESS {
        panic("Failed to create descriptor pool");
    }

    p.descriptor_sets = make([][]vk.DescriptorSet, num_sets);
    for layers, i in p.descriptor_sets {
        p.descriptor_sets[i] = make([]vk.DescriptorSet, config.max_uses_per_frame);
    }

    append(&window.pipelines, p);
    append(&dc.pipelines, p);
    
    return p;
}
pipeline_allocate_descriptor_set_if_needed :: proc(pipeline : ^Pipeline, frame_index : int) {
    using pipeline.dc;
    assert(pipeline.num_uses_this_frame < pipeline.config.max_uses_per_frame, fmt.tprintf("Pipeline max usage per frame of %i was exceeded. Set pipeline config in make_pipeline to allow for more uses.", pipeline.config.max_uses_per_frame));
    set := &pipeline.descriptor_sets[frame_index][pipeline.num_uses_this_frame];
    if set^ != 0 do return;
    desc_alloc_info : vk.DescriptorSetAllocateInfo;
    desc_alloc_info.sType = .DESCRIPTOR_SET_ALLOCATE_INFO;
    desc_alloc_info.descriptorPool = pipeline.descriptor_pool;
    desc_alloc_info.descriptorSetCount = 1;
    desc_alloc_info.pSetLayouts = &pipeline.program.descriptor_set_layout;
    if (vk.AllocateDescriptorSets(vk_device, &desc_alloc_info, set) != .SUCCESS) {
        panic("Failed to allocate descriptor sets");
    }

    if pipeline.num_uses_this_frame > 0 {
        prev_set := &pipeline.descriptor_sets[frame_index][pipeline.num_uses_this_frame-1];
        for count, binding in pipeline.uniform_binding_descriptor_counts {
            // #Uniformcoherency
            copy_info : vk.CopyDescriptorSet;
            copy_info.sType = .COPY_DESCRIPTOR_SET;
            copy_info.descriptorCount = cast(u32)count;
            
            copy_info.dstSet = set^;
            copy_info.dstBinding = cast(u32)binding;
            copy_info.dstArrayElement = 0;
    
            copy_info.srcSet = prev_set^;
            copy_info.srcBinding = cast(u32)binding;
            copy_info.srcArrayElement = 0;
    
            vk.UpdateDescriptorSets(vk_device, 0, nil, 1, &copy_info);
        }
    }
}
destroy_pipeline :: proc(pipeline : ^Pipeline, loc := #caller_location) {
    using pipeline.dc;
    
    wait_all_queues(pipeline.dc);

    vk.DestroyDescriptorPool(vk_device, pipeline.descriptor_pool, nil);
    
    vk.DestroyPipelineLayout(vk_device, pipeline.vk_layout, nil);
    vk.DestroyPipeline(vk_device, pipeline.vk_pipeline, nil);
    
    unordered_remove(&pipeline.window.pipelines, index_of(pipeline.window.pipelines[:], pipeline));
    unordered_remove(&pipelines_to_destroy, index_of(pipelines_to_destroy[:], pipeline));
    unordered_remove(&pipelines, index_of(pipelines[:], pipeline));

    for layer, i in pipeline.descriptor_sets {
        delete (pipeline.descriptor_sets[i]);
    }
    delete(pipeline.descriptor_sets);
    delete(pipeline.wait_semaphores);
    delete(pipeline.wait_stages);


    free(pipeline);
}

index_of :: proc(slice : []$T, item : T) -> int {
    for thing,i in slice {
        if thing == item do return i;
    }
    return -1;
}
get_uniform_descriptor_type :: proc(uniform : glsl.Uniform) -> vk.DescriptorType {
    if uniform.type.elem_kind == .SAMPLER1D || uniform.type.elem_kind == .SAMPLER2D || uniform.type.elem_kind == .SAMPLER3D {
        return .COMBINED_IMAGE_SAMPLER;
    } else {
        return .UNIFORM_BUFFER;
    }
}
compile_shader_source :: proc(dc : ^Device_Context, src : string, kind : shaderc.shaderKind, constants : []Shader_Constant = nil, allocator := context.allocator) -> (module : Shader_Module, ok : bool) {
    context.allocator = allocator;
    // #Memory

    
    opts := shaderc.compile_options_initialize();
    defer shaderc.compile_options_release(opts);
    
    shaderc.compile_options_set_optimization_level(opts, .Performance);
    
    
    for constant in constants {
        val_str := "";
        switch value in constant.value {
            case string: val_str = value;
            case int: val_str = fmt.tprint(value);
            case f32: val_str = fmt.tprint(value);
        }
        shaderc.compile_options_add_macro_definition(opts, strings.clone_to_cstring(constant.name, allocator=context.temp_allocator), len(constant.name), strings.clone_to_cstring(val_str, allocator=context.temp_allocator), len(val_str));
    }

    // #Incomplete
    // We discard of the original source so if we need to recompile
    // we can't update constants; it will use the old values.
    pp_result := shaderc.compile_into_preprocessed_text(
        glsl_compiler, 
        strings.clone_to_cstring(src, allocator=context.temp_allocator), 
        len(src), kind, "NOFILE", "main", opts,
    );
    pp_bytes := mem.byte_slice(shaderc.result_get_bytes(pp_result), cast(int)shaderc.result_get_length(pp_result));

    pp_src := string(pp_bytes);
    cstr := cast(cstring)slice_to_multi_ptr(pp_bytes); // Not null terminated!
    
    result := shaderc.compile_into_spv(glsl_compiler, cstr, len(pp_src), kind, "NOFILE", "main", opts);
    defer shaderc.result_release(result);
    status := shaderc.result_get_compilation_status(result);
    if status == .Success {
        // #Memcleanup
        bytes := mem.byte_slice(shaderc.result_get_bytes(result), shaderc.result_get_length(result));
        #partial switch kind {
            case .VertexShader: module.stage = .VERTEX;
            case .FragmentShader: module.stage = .FRAGMENT;
            case .GlslTessControlShader: module.stage = .TESSELLATION_CONTROL;
            case .GeometryShader: module.stage = .GEOMETRY;
            case: panic("unimplemented");
        }
        create_info : vk.ShaderModuleCreateInfo;
        create_info.sType = .SHADER_MODULE_CREATE_INFO;
        create_info.codeSize = len(bytes);
        create_info.pCode = cast(^u32)slice_to_multi_ptr(bytes);
        
        if vk.CreateShaderModule(dc.vk_device, &create_info, nil, &module.vk_module) == .SUCCESS {
            module.text_source = strings.clone(pp_src);
            module.bytes = slice.clone(bytes);
            ok = true;

            module.info = glsl.inspect_glsl(module.text_source);

            append(&dc.shaders_to_destroy, module);

        } else {
            log.error("Failed creating shader module");
            ok = false;
        }

        return;
    } else {
        ok = false;
        log.error(fmt.tprintf("%s COMPILAITION ERROR:\n%s\n", kind, shaderc.result_get_error_message(result))); // #tprint
        return;
    }

}
Shader_Constant :: struct {
    name : string,
    value : union { int, f32, string },
}
make_shader_program_from_sources :: proc(vertex_src, fragment_src : string, tessellation_src : string = "", geometry_src : string = "", constants : []Shader_Constant = nil, using dc : ^Device_Context = target_dc, allocator := context.allocator) -> (program : Shader_Program, ok : bool) {
    context.allocator = allocator;

    return  make_shader_program_from_modules(
        vertex_module=       compile_shader_source(dc, vertex_src, .VertexShader, constants=constants)            or_return,
        fragment_module=     compile_shader_source(dc, fragment_src, .FragmentShader, constants=constants)        or_return,
        tessellation_module=(compile_shader_source(dc, tessellation_src, .TessControlShader, constants=constants) or_return) if len(tessellation_src) > 0 else nil,
        geometry_module=    (compile_shader_source(dc, geometry_src, .GeometryShader, constants=constants)        or_return) if len(geometry_src) > 0 else nil,
        dc=dc,
    );
}
make_shader_program_from_modules :: proc(vertex_module, fragment_module : Shader_Module, tessellation_module : Maybe(Shader_Module) = nil, geometry_module : Maybe(Shader_Module) = nil, using dc := target_dc) -> (program : Shader_Program, ok:bool) {
    program.vertex = vertex_module;
    program.fragment = fragment_module;
    program.tesselation = tessellation_module;
    program.geometry = geometry_module;
    
    program.vertex_input_layout = make_vertex_layout_from_glsl_reflection(program.vertex.info);
    defer {
        if !ok do destroy_vertex_layout(program.vertex_input_layout);
    }

    
    mods := []Maybe(Shader_Module){
        vertex_module, 
        fragment_module, 
        tessellation_module, 
        geometry_module,
    };

    
    binding_used_set := make(map[int]Shader_Module);
    defer delete(binding_used_set);
    
    // First validate and count uniforms
    num_uniforms := 0;
    for maybe_mod in mods {
        if maybe_mod == nil do continue;
        mod := maybe_mod.(Shader_Module);
        for uniform in mod.info.uniforms {
            if uniform.binding in binding_used_set {
                log.errorf("Program Link Error: duplicate uniform binding on '%i'. First in %s, then in %s.", uniform.binding, binding_used_set[uniform.binding].stage, mod.stage);
                return {}, false;
            }
            binding_used_set[uniform.binding] = mod;
            num_uniforms += 1;
        }
    }
    for i in 0..<len(binding_used_set) {
        if i not_in binding_used_set do panic("Shader bindings & locations must be coherent (0, 1, 2, 3 ...) #Incomplete");
    }

    program.uniforms = make([]glsl.Uniform, num_uniforms);
    ubo_bindings := make([]vk.DescriptorSetLayoutBinding, num_uniforms);
    defer {
        if !ok do delete(program.uniforms);
    }

    i := 0;
    for maybe_mod in mods {
        if maybe_mod == nil do continue;
        mod := maybe_mod.(Shader_Module);

        
        for uniform in mod.info.uniforms {
            program.uniforms[i] = uniform;

            layout_binding := &ubo_bindings[i];
            layout_binding.binding = cast(u32)uniform.binding;
            layout_binding.descriptorType = get_uniform_descriptor_type(uniform);
            layout_binding.descriptorCount = 1 if uniform.type.kind != .ARRAY else cast(u32)(uniform.type.size / uniform.type.elem_size);
            layout_binding.stageFlags = {mod.stage};
            layout_binding.pImmutableSamplers = nil;

            i += 1;
        }
    }

    layout_info : vk.DescriptorSetLayoutCreateInfo;
    layout_info.sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = cast(u32)len(ubo_bindings);
    layout_info.pBindings = slice_to_multi_ptr(ubo_bindings);
    
    if vk.CreateDescriptorSetLayout(vk_device, &layout_info, nil, &program.descriptor_set_layout) != .SUCCESS {
        panic("Failed creating description set layout");
    }

    return program, true;
}
make_shader_program :: proc{make_shader_program_from_modules, make_shader_program_from_sources};

get_program_uniform_binding :: proc(program : Shader_Program, uniform_name : string) -> int {

    // If we dont find by variable name then find by user type name
    backup := -1;
    for uniform in program.uniforms {
        if uniform.name == uniform_name do return uniform.binding;

        if uniform.type.elem_kind == .USER_TYPE && uniform.type.elem_name == uniform_name do backup = uniform.binding;
    }
    return backup;
}
 
destroy_shader_program :: proc(program : Shader_Program, dc := target_dc) {
    wait_all_queues(dc);
    vk.DestroyDescriptorSetLayout(dc.vk_device, program.descriptor_set_layout, nil);
    destroy_shader_module(program.vertex, dc);
    destroy_shader_module(program.fragment, dc);
    if program.tesselation != nil do destroy_shader_module(program.tesselation.(Shader_Module), dc);
    if program.geometry != nil    do destroy_shader_module(program.geometry.(Shader_Module), dc);
    destroy_vertex_layout(program.vertex_input_layout);
}
destroy_shader_module :: proc(module : Shader_Module, using dc := target_dc) {
    wait_all_queues(dc);
    module:=module;
    delete(module.bytes);
    delete(module.text_source);
    glsl.free_glsl_inspect_info(module.info);
    vk.DestroyShaderModule(vk_device, module.vk_module, nil);

    for s, i in shaders_to_destroy {
        if s.vk_module == module.vk_module {
            unordered_remove(&shaders_to_destroy, i);
            break;
        }
    }
}
make_render_target :: proc(image : vk.Image, format : vk.Format, extent : vk.Extent2D, render_pass : vk.RenderPass, using dc := target_dc, allocator := context.allocator) -> ^Render_Target {
    context.allocator = allocator;

    image_view : vk.ImageView;

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
    if vk.CreateImageView(vk_device, &view_create_info, nil, &image_view) != .SUCCESS {
        panic("Failed creating image view"); // TODO : errors
    }

    attachments : []vk.ImageView = {
        image_view,
    };

    framebuffer_info : vk.FramebufferCreateInfo;
    framebuffer_info.sType = .FRAMEBUFFER_CREATE_INFO;
    framebuffer_info.renderPass = render_pass;
    framebuffer_info.attachmentCount = cast(u32)len(attachments);
    framebuffer_info.pAttachments = slice_to_multi_ptr(attachments);
    framebuffer_info.width = extent.width;
    framebuffer_info.height = extent.height;
    framebuffer_info.layers = 1;

    framebuffer : vk.Framebuffer;
    if vk.CreateFramebuffer(vk_device, &framebuffer_info, nil, &framebuffer) != .SUCCESS {
        panic("Failed creating framebuffer");
    }

    render_target := new(Render_Target);
    render_target.image = image;
    render_target.image_view = image_view;
    render_target.framebuffer = framebuffer;
    render_target.image_format = format;
    render_target.extent = extent;
    render_target.render_done_semaphore = make_semaphore(dc);
    render_target.render_pass = render_pass;
    

    return render_target;
}
destroy_render_target :: proc(target : ^Render_Target, using dc := target_dc) {
    wait_all_queues(dc);
    vk.DestroySemaphore(vk_device, target.render_done_semaphore, nil);
    vk.DestroyFramebuffer(vk_device, target.framebuffer, nil);
    vk.DestroyImageView(vk_device, target.image_view, nil);
}

make_render_pass :: proc(format : vk.Format, layout : vk.ImageLayout, clear_on_bind : bool, using dc := target_dc) -> (render_pass : vk.RenderPass){
    color_attachment : vk.AttachmentDescription;
    color_attachment.format = format;
    color_attachment.samples = {._1};
    color_attachment.loadOp = .CLEAR if clear_on_bind else .LOAD;
    color_attachment.storeOp = .STORE;
    color_attachment.stencilLoadOp = .DONT_CARE;
    color_attachment.stencilStoreOp = .DONT_CARE;
    color_attachment.initialLayout = .UNDEFINED if clear_on_bind else layout;
    color_attachment.finalLayout = layout;
    
    color_attachment_ref : vk.AttachmentReference;
    color_attachment_ref.attachment = 0;
    color_attachment_ref.layout = layout;
    
    subpass : vk.SubpassDescription;
    subpass.pipelineBindPoint = .GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_attachment_ref;
    
    dependency : vk.SubpassDependency;
    dependency.srcSubpass = vk.SUBPASS_EXTERNAL;
    dependency.dstSubpass = 0;
    dependency.srcStageMask = {.COLOR_ATTACHMENT_OUTPUT};
    dependency.srcAccessMask = {};
    dependency.dstStageMask = {.COLOR_ATTACHMENT_OUTPUT};
    dependency.dstAccessMask = {.COLOR_ATTACHMENT_WRITE};
    
    render_pass_info : vk.RenderPassCreateInfo;
    render_pass_info.sType = .RENDER_PASS_CREATE_INFO;
    render_pass_info.attachmentCount = 1;
    render_pass_info.pAttachments = &color_attachment;
    render_pass_info.subpassCount = 1;
    render_pass_info.pSubpasses = &subpass;
    render_pass_info.dependencyCount = 1;
    render_pass_info.pDependencies = &dependency;
    
    if vk.CreateRenderPass(vk_device, &render_pass_info, nil, &render_pass) != .SUCCESS {
        panic("Failed to create render pass");
    }

    return;
}

Swap_Chain_Support_Details :: struct {
    capabilities : vk.SurfaceCapabilitiesKHR,
    formats : []vk.SurfaceFormatKHR,
    present_modes : []vk.PresentModeKHR,
};
make_device_context :: proc(glfw_window : glfw.WindowHandle, pdevice : vk.PhysicalDevice = nil, allocator := context.allocator) -> ^Device_Context {
    context.allocator = allocator;
    
    pdevice := pdevice;
    if pdevice == nil {
        ok := false;
        pdevice, ok = get_most_suitable_physical_device();
        if !ok {
            // TODO: return error;
            panic("No suitable physical device found");
        }
    }
    
    using dc := new(Device_Context);

    props : vk.PhysicalDeviceProperties;
    memory_props : vk.PhysicalDeviceMemoryProperties;
    features : vk.PhysicalDeviceFeatures;
    vk.GetPhysicalDeviceProperties(pdevice, &props);
    vk.GetPhysicalDeviceMemoryProperties(pdevice, &memory_props);
    vk.GetPhysicalDeviceFeatures(pdevice, &features);
    
    
    shaders_to_destroy   = make([dynamic]Shader_Module);
    pipelines_to_destroy = make([dynamic]^Pipeline);
    pipelines = make([dynamic]^Pipeline);
    
    queue_family_count : u32;
    vk.GetPhysicalDeviceQueueFamilyProperties(pdevice, &queue_family_count, nil);
    gpu.queue_family_propertes = make([]vk.QueueFamilyProperties, queue_family_count);
    vk.GetPhysicalDeviceQueueFamilyProperties(pdevice, &queue_family_count, slice_to_multi_ptr(gpu.queue_family_propertes));

    when ODIN_DEBUG {
        log.debug("Available queues:", gpu.queue_family_propertes, sep="\n\t");
    }

    // [queue_id]count
    used_queues_set = make(map[u32]u32);

    graphics_index, present_index, transfer_index : u32;

    // Graphics queue: first best with GRAPHICS flag
    for fam,i in gpu.queue_family_propertes {
        if .GRAPHICS in fam.queueFlags {
            gpu.queue_family_set.graphics = cast(u32)i;
            graphics_index = used_queues_set[cast(u32)i];
            used_queues_set[cast(u32)i] += 1;
            log.debug("Picked graphics queue:\n\t", fam, "index", graphics_index);
            break;
        }
    }
    if gpu.queue_family_set.graphics == nil do panic("Missing graphics queue");

    // #Incomplete #Refactor ooooof
    temp_surface : vk.SurfaceKHR;
    glfw.CreateWindowSurface(vk_inst, glfw_window, nil, &temp_surface);
    defer vk.DestroySurfaceKHR(vk_inst, temp_surface, nil);
    // Present queue: First best where parallel queue is available
    for fam,i in gpu.queue_family_propertes {
        
        supports_present : b32;
        vk.GetPhysicalDeviceSurfaceSupportKHR(pdevice, cast(u32)i, temp_surface, &supports_present);
        if supports_present {
            if cast(u32)i not_in used_queues_set || used_queues_set[cast(u32)i] < fam.queueCount {
                gpu.queue_family_set.present = cast(u32)i;
                present_index = used_queues_set[cast(u32)i];
                log.debug("Picked present queue:\n\t", fam, "index", present_index);
                used_queues_set[cast(u32)i] += 1;
                break;
            }
        }
    }
    if gpu.queue_family_set.present == nil do panic("Missing present queue");
        
    // Transfer queue: First best where parallel queue is available
    for fam,i in gpu.queue_family_propertes {
        if .TRANSFER in fam.queueFlags {
            if cast(u32)i not_in used_queues_set || used_queues_set[cast(u32)i] < fam.queueCount {
                gpu.queue_family_set.transfer = cast(u32)i;
                transfer_index = used_queues_set[cast(u32)i];
                log.debug("Picked transfer queue:\n\t", fam, "index", transfer_index);
                used_queues_set[cast(u32)i] += 1;
                break;
            }
        }
    }
    if gpu.queue_family_set.transfer == nil do panic("Missing transfer queue");
    
    
    gpu.vk_physical_device = pdevice;
    gpu.props = props;
    gpu.memory_props = memory_props;
    gpu.features = features;

    
    
    //
    // Create Logical Device
    
    device_name := gpu.props.deviceName;
    vendor_name := get_vendor_name(cast(Vendor_Kind)gpu.props.vendorID);
    driver_ver := format_driver_version(cast(Vendor_Kind)gpu.props.vendorID, gpu.props.driverVersion);
    log.infof("Targetting GPU:\n\t%s\n\t%s Driver Version %s\n", device_name, vendor_name, driver_ver);
    
    queues := make([]u32, len(used_queues_set));
    i := 0;
    for k, v in used_queues_set {
        queues[i] = k;
        i += 1;
    }
    queue_create_infos := make([]vk.DeviceQueueCreateInfo, len(queues));
    defer delete(queue_create_infos);
    for q,i in queues {
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
    
    
    if !check_physical_device_features(gpu, required_features) {
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
    if vk.CreateDevice(pdevice, &logical_device_create_info, nil, &vk_device) != .SUCCESS {
        panic("Create device failed"); // TODO: return error 
    }
    append(&dcs_to_destroy, dc);
    
    //
    // Get Queues
    
    // #Refactor
    graphics_queue_raw : vk.Queue;
    vk.GetDeviceQueue(vk_device, gpu.queue_family_set.graphics.(u32), graphics_index, &graphics_queue_raw);
    graphics_queue = graphics_queue_raw;
    
    present_queue_raw : vk.Queue;
    vk.GetDeviceQueue(vk_device, gpu.queue_family_set.present.(u32), present_index, &present_queue_raw);
    present_queue = present_queue_raw;

    transfer_queue_raw : vk.Queue;
    vk.GetDeviceQueue(vk_device, gpu.queue_family_set.transfer.(u32), transfer_index, &transfer_queue_raw);
    transfer_queue = transfer_queue_raw;

    cmd_pool_info : vk.CommandPoolCreateInfo;
    cmd_pool_info.sType = .COMMAND_POOL_CREATE_INFO;
    cmd_pool_info.flags = {.RESET_COMMAND_BUFFER};
    cmd_pool_info.queueFamilyIndex = gpu.queue_family_set.transfer.(u32);

    if vk.CreateCommandPool(vk_device, &cmd_pool_info, nil, &dc.transfer_pool) != .SUCCESS {
        panic("Failed creating command pool");
    }

    render_texture_pass = make_render_pass(.R32G32B32A32_SFLOAT, .COLOR_ATTACHMENT_OPTIMAL, false, dc=dc);

    log.infof("Created a device context\n");

    return dc;
}
make_graphics_window :: proc(glfw_window : glfw.WindowHandle, using dc := target_dc) -> ^Graphics_Window{
    pdevice := gpu.vk_physical_device;
    
    window := new(Graphics_Window);
    window.dc = dc;
    window.glfw_window = glfw_window;
    window.should_pipeline_wait_for_render_semaphore = false;
    window.pipelines = make([dynamic]^Pipeline);

    //
    // Create Surface
    if glfw.CreateWindowSurface(vk_inst, glfw_window, nil, &window.surface) != .SUCCESS {
        panic("Failed creating window surface"); // TODO: return error
    }
    
    //
    // Check support
    required_device_exts := []cstring { // #Copypaste
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
    };
    if !check_physical_device_extensions(pdevice, required_device_exts) {
        panic("Missing an extension for physical device"); // TODO: return error
    }
    swap_chain_details := get_swap_chain_support_details(pdevice, window.surface);
    
    has_required_swap_chain_support := len(swap_chain_details.present_modes) > 0 && ((len(swap_chain_details.formats) > 0));
    
    if !has_required_swap_chain_support {
        panic("Missing required swap chain support") // TODO error
    }

    surface_format := choose_swap_chain_format(swap_chain_details.formats);
    window.image_format = surface_format.format;
    
    window.surface_render_pass = make_render_pass(surface_format.format, .PRESENT_SRC_KHR, false, dc=dc);

    recreate_or_init_window_swap_chain(window);
    semaphore_info : vk.SemaphoreCreateInfo;
    semaphore_info.sType = .SEMAPHORE_CREATE_INFO;
    window.retrieve_semaphores = make([]vk.Semaphore, len(window.frame_targets));
    for sem, i in window.retrieve_semaphores {
        if vk.CreateSemaphore(vk_device, &semaphore_info, nil, &window.retrieve_semaphores[i]) != .SUCCESS {
            panic("Failed creating semaphore");
        }
    }

    window.number_of_frames = len(window.frame_targets);

    window.command_buffer_factories = make([]Command_Buffer_Factory, len(window.frame_targets));
    for f, i in window.command_buffer_factories {
        fact := &window.command_buffer_factories[i];
        fact.dc = dc;
        fact.buffers = make([dynamic]vk.CommandBuffer);
        fact.fences = make([dynamic]vk.Fence);
        //
        // Command pool
        cmd_pool_info : vk.CommandPoolCreateInfo;
        cmd_pool_info.sType = .COMMAND_POOL_CREATE_INFO;
        cmd_pool_info.flags = {.RESET_COMMAND_BUFFER};
        cmd_pool_info.queueFamilyIndex = gpu.queue_family_set.graphics.(u32);
    
        // #Speed
        // Should make one pool per family IF different families are used for the different queues
        if vk.CreateCommandPool(vk_device, &cmd_pool_info, nil, &fact.pool) != .SUCCESS {
            panic("Failed creating command pool");
        }
    }

    
    
    extract_window_active_target(window);
    log.infof("Created graphics window with %i render targets\n", len(window.frame_targets));
    
    return window;
}
recreate_or_init_window_swap_chain :: proc(window : ^Graphics_Window) {
    
    using window.dc;
    
    if window.command_buffer_factories != nil {
        wait_all_command_fences(window);
    }
    if window.vk_swap_chain != 0 {
        
        for target in window.frame_targets {
            destroy_render_target(target, window.dc);
        }
        vk.DestroySwapchainKHR(vk_device, window.vk_swap_chain, nil);
    }
    swap_chain_details := get_swap_chain_support_details(gpu.vk_physical_device, window.surface);
    
    surface_format := choose_swap_chain_format(swap_chain_details.formats);
    present_mode := choose_swap_chain_present_mode(swap_chain_details.present_modes);
    extent := choose_swap_extent(swap_chain_details.capabilities, window.glfw_window);
    
    image_count :u32= swap_chain_details.capabilities.minImageCount + 1;
    if (swap_chain_details.capabilities.maxImageCount > 0 && image_count > swap_chain_details.capabilities.maxImageCount) {
        image_count = swap_chain_details.capabilities.maxImageCount;
    }
    sc_create_info : vk.SwapchainCreateInfoKHR;
    sc_create_info.sType = .SWAPCHAIN_CREATE_INFO_KHR;
    sc_create_info.surface = window.surface;
    sc_create_info.minImageCount = image_count;
    sc_create_info.imageFormat = surface_format.format;
    sc_create_info.imageColorSpace = surface_format.colorSpace;
    sc_create_info.imageExtent = extent;
    
    sc_create_info.imageArrayLayers = 1;
    sc_create_info.imageUsage = {.COLOR_ATTACHMENT}
    indices := []u32{gpu.queue_family_set.graphics.(u32), gpu.queue_family_set.present.(u32)};
    if (gpu.queue_family_set.graphics != gpu.queue_family_set.present) {
        sc_create_info.imageSharingMode = .CONCURRENT;
        sc_create_info.queueFamilyIndexCount = 2;
        sc_create_info.pQueueFamilyIndices = slice_to_multi_ptr(indices);
    } else {
        sc_create_info.imageSharingMode = .EXCLUSIVE;
        sc_create_info.queueFamilyIndexCount = 0;
        sc_create_info.pQueueFamilyIndices = nil;
    }
    sc_create_info.preTransform = swap_chain_details.capabilities.currentTransform;
    sc_create_info.compositeAlpha = {.OPAQUE};
    sc_create_info.presentMode = present_mode;
    sc_create_info.clipped = true;
    sc_create_info.oldSwapchain = 0;
    
    err := vk.CreateSwapchainKHR(vk_device, &sc_create_info, nil, &window.vk_swap_chain);
    if err != .SUCCESS {
        panic(fmt.tprintf("Failed creating swap chain (%s)\n", err));  // TODO: error
    }
    window.extent = extent;
    window.image_format = surface_format.format; 
    
    vk.GetSwapchainImagesKHR(vk_device, window.vk_swap_chain, &image_count, nil);
    swap_chain_images := make([]vk.Image, image_count);
    defer delete(swap_chain_images);
    vk.GetSwapchainImagesKHR(vk_device, window.vk_swap_chain, &image_count, slice_to_multi_ptr(swap_chain_images));
    if window.frame_targets == nil do window.frame_targets = make([]^Render_Target, len(swap_chain_images));
    //if window.frame_fences == nil do window.frame_fences = make([]vk.Fence, len(swap_chain_images));

    assert(len(swap_chain_images) == len(window.frame_targets));
    
    for img, i in swap_chain_images {
        window.frame_targets[i] = make_render_target(
            img, 
            window.image_format,
            window.extent,
            window.surface_render_pass,
            dc=window.dc,
        );
        transition_image_layout(img, window.image_format, .UNDEFINED, .PRESENT_SRC_KHR, dc=window.dc);
        window.frame_targets[i].current_layout = .PRESENT_SRC_KHR;
        window.frame_targets[i].index = cast(u32)i;
        //if window.frame_fences[i] == 0 do window.frame_fences[i] = make_fence(window.dc);
    }

}
destroy_device_context :: proc(using dc : ^Device_Context) {
    wait_all_queues(dc);
    vk.DestroyCommandPool(vk_device, transfer_pool, nil);
    
    for i in 0..<len(dcs_to_destroy) {
        if dcs_to_destroy[i] == dc do unordered_remove(&dcs_to_destroy, i);
    }
    
    vk.DestroyDevice(dc.vk_device, nil);

    delete(shaders_to_destroy);
    delete(pipelines_to_destroy);
    delete(pipelines);
    delete(used_queues_set);

    free(dc);
}
destroy_graphics_window :: proc(window : ^Graphics_Window) {
    using window.dc;
    wait_all_queues(window.dc);
    vk.DeviceWaitIdle(vk_device);
    wait_all_command_fences(window);

    
    /*for fence,i in window.frame_fences {
        destroy_fence(fence, window.dc);
    }*/

    for sem in window.retrieve_semaphores {
        vk.DestroySemaphore(vk_device, sem, nil);
    }
    
    for target in window.frame_targets {
        destroy_render_target(target, window.dc);
    }
    vk.DestroySwapchainKHR(vk_device, window.vk_swap_chain, nil);
    
    delete (window.retrieve_semaphores);
    //delete (window.frame_fences);
    delete (window.frame_targets);

    for fact in window.command_buffer_factories {
        if cast(u32)len(fact.fences) > 0 do vk.WaitForFences(vk_device, cast(u32)len(fact.fences), slice_to_multi_ptr(fact.fences[:]), true, c.UINT64_MAX);
        vk.FreeCommandBuffers(vk_device, fact.pool, cast(u32)len(fact.buffers), slice_to_multi_ptr(fact.buffers[:]));
        vk.DestroyCommandPool(vk_device, fact.pool, nil);

        for fence in fact.fences {
            destroy_fence(fence, window.dc);
        }
    }

    vk.DestroyRenderPass(vk_device, window.surface_render_pass, nil);
    vk.DestroySurfaceKHR(vk_inst, window.surface, nil);   
}
get_swap_chain_support_details :: proc(pdevice : vk.PhysicalDevice, surface : vk.SurfaceKHR) -> (details : Swap_Chain_Support_Details) {

    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(pdevice, surface, &details.capabilities);

    if surface != 0 {
        fmt_count : u32;
        vk.GetPhysicalDeviceSurfaceFormatsKHR(pdevice, surface, &fmt_count, nil);
        if (fmt_count != 0) {
            details.formats = make([]vk.SurfaceFormatKHR, fmt_count);
            vk.GetPhysicalDeviceSurfaceFormatsKHR(pdevice, surface, &fmt_count, slice_to_multi_ptr(details.formats));
        }
    }

    present_count : u32;
    vk.GetPhysicalDeviceSurfacePresentModesKHR(pdevice, surface, &present_count, nil);

    if (present_count != 0) {
        details.present_modes = make([]vk.PresentModeKHR, present_count);
        vk.GetPhysicalDeviceSurfacePresentModesKHR(pdevice, surface, &present_count, slice_to_multi_ptr(details.present_modes));
    }

    return;
}

choose_swap_chain_format :: proc(formats : []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
    for available in formats {
        if (available.format == .R8G8B8A8_SRGB && available.colorSpace == .SRGB_NONLINEAR) {
            return available;
        } else if (available.format == .B8G8R8A8_SRGB && available.colorSpace == .SRGB_NONLINEAR) {
            return available;
        }
    }
    return formats[0];
}
choose_swap_chain_present_mode :: proc(modes : []vk.PresentModeKHR) -> vk.PresentModeKHR {
    for available in modes {
        if (available == .MAILBOX) {
            return available;
        }
    }

    return .FIFO; // Always present
}

choose_swap_extent :: proc(capabilities : vk.SurfaceCapabilitiesKHR, target_window : glfw.WindowHandle = nil) -> vk.Extent2D {
    if (capabilities.currentExtent.width != c.UINT32_MAX) {
        return capabilities.currentExtent;
    } else if (target_window != nil) {
        width, height := glfw.GetFramebufferSize(target_window);

        actual_extent := vk.Extent2D {u32(width), u32(height)};

        actual_extent.width  = clamp(actual_extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
        actual_extent.height = clamp(actual_extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);

        return capabilities.currentExtent;
    } else {
        panic("Unimplemented"); // Not sure what would need to be done here or if it's even possible to get here
    }
}



create_vk_instance :: proc() {
    app_info : vk.ApplicationInfo;
    app_info.sType = .APPLICATION_INFO;
    app_info.pApplicationName = "Hello Vulkan";
    app_info.applicationVersion = vk.MAKE_VERSION(1, 0, 0);
    app_info.pEngineName = "No Engine";
    app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0);
    app_info.apiVersion = vk.API_VERSION_1_2;

    create_info : vk.InstanceCreateInfo;
    create_info.sType = .INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;
    create_info.enabledLayerCount = 0;

    exts, ok := check_and_get_vk_extensions();
    if !ok {
        log.error("Required VK extension is missing, aborting");
    }
    defer delete(exts);
    create_info.flags = { vk.InstanceCreateFlag.ENUMERATE_PORTABILITY_KHR };
    create_info.ppEnabledExtensionNames = slice_to_multi_ptr(exts);
    create_info.enabledExtensionCount = cast(u32)len(exts);

    when ODIN_DEBUG {
        if !add_validation_layers(&create_info) {
            log.error("Failed to add some validation layers");
        }
        validation_layers = mem.slice_ptr(create_info.ppEnabledLayerNames, cast(int)create_info.enabledLayerCount);
    }

    if vk.CreateInstance(&create_info, nil, &vk_inst) != .SUCCESS {
        log.error("Failed to create VK instance");
        os.exit(-1);
    }

    log.info("Successfully created VK instance");
}

create_debug_messenger :: proc() {
    create_info : vk.DebugUtilsMessengerCreateInfoEXT;
    create_info.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    create_info.messageSeverity = {.VERBOSE, .WARNING, .ERROR};
    create_info.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE};
    create_info.pfnUserCallback = vk_debug_callback;
    create_info.pUserData = new_clone(context.logger);
    if vk.CreateDebugUtilsMessengerEXT(vk_inst, &create_info, nil, &vk_messenger) != .SUCCESS do log.error("Failed creating VK debug messenger");
}

Vendor_Kind :: enum {
    NVIDIA   = 0x10DE,
    AMD      = 0x1002,
    INTEL    = 0x8086,
    ARM      = 0x13B5,
    IMGTEC   = 0x1010,
    QUALCOMM = 0x5143,
}
vendor_id_to_name : map[Vendor_Kind]string = {
    .NVIDIA   = "Nvidia",
    .AMD      = "AMD",
    .INTEL    = "Intel",    
    .ARM      = "ARM",
    .IMGTEC   = "ImgTec",
    .QUALCOMM = "Qualcomm",
};
get_vendor_name :: proc(vendor_id : Vendor_Kind) -> string {
    if vendor_id not_in vendor_id_to_name {
        return "UNKNOWN VENDOR";
    } else {
        return vendor_id_to_name[vendor_id];
    }
}
format_driver_version :: proc(vendor_id: Vendor_Kind, driver_version: u32) -> string {
    #partial switch vendor_id {
        case .NVIDIA:
            major := (driver_version >> 22) & 0x3FF;
            minor := (driver_version >> 14) & 0xFF;
            patch := (driver_version >> 6) & 0xFF;
            build := driver_version & 0x3F;
            return fmt.tprintf("%i.%i.%i build %i", major, minor, patch, build); // #tprint
        case .INTEL: {
            when ODIN_OS == .Windows {
                major := (driver_version >> 14);
                minor := driver_version & 0x3FFF;
                return fmt.tprintf("%i.%i", major, minor); // #tprint
            } else {
                fallthrough;
            }
        }
        case:
            return fmt.tprintf("%i", driver_version); // #tprint
    }
}



get_most_suitable_physical_device :: proc() -> (pdevice : vk.PhysicalDevice, any_suitable : bool) {
    device_count : u32;
    vk.EnumeratePhysicalDevices(vk_inst, &device_count, nil);

    if device_count == 0 do return nil, false;

    physical_devices := make([]vk.PhysicalDevice, device_count);
    vk.EnumeratePhysicalDevices(vk_inst, &device_count, slice_to_multi_ptr(physical_devices));

    log.debug("Querying available devices");
    for pdevice in physical_devices {
        props : vk.PhysicalDeviceProperties;
        vk.GetPhysicalDeviceProperties(pdevice, &props);
        log.debugf("\t%s\n", props.deviceName);
    }

    top_device := physical_devices[0];
    top_score := rate_physical_device(top_device);

    for i in 1..<len(physical_devices) {
        candidate := physical_devices[i];

        if candidate_score := rate_physical_device(candidate); candidate_score > top_score {
            top_device = candidate;
            top_score = candidate_score;
        }
    }

    if top_score == 0 do return nil, false;

    return top_device, true;
}

rate_physical_device :: proc(pdevice : vk.PhysicalDevice) -> int {
    props : vk.PhysicalDeviceProperties;
    features : vk.PhysicalDeviceFeatures;
    vk.GetPhysicalDeviceProperties(pdevice, &props);
    vk.GetPhysicalDeviceFeatures(pdevice, &features);

    score := 0;

    if (props.deviceType == .DISCRETE_GPU) {
        score += 1000;
    }

    score += cast(int)props.limits.maxImageDimension2D;

    if features.sampleRateShading do score += 100;

    if !features.geometryShader do return 0;

    return score;
}
check_and_get_vk_extensions :: proc(allocator := context.allocator) -> ([]cstring, bool) {
    context.allocator = allocator;
    glfw_exts := glfw.GetRequiredInstanceExtensions();
    required_extensions := make([dynamic]cstring, len(glfw_exts), len(glfw_exts)+2);
    log.debug("Querying required VK extensions:");
    for i in 0..<len(glfw_exts) {
        required_extensions[i] = glfw_exts[i];
        log.debug("\t", required_extensions[i]);
    }
    append(&required_extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
    log.debug("\t", vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
    when ODIN_DEBUG {
        append(&required_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME);
        log.debug("\t", vk.EXT_DEBUG_UTILS_EXTENSION_NAME);
    }
    //append(&required_extensions, vk.KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME);
    //log.debug("\t", vk.KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME);

    num_available_extensions : u32;
    vk.EnumerateInstanceExtensionProperties(nil, &num_available_extensions, nil);
    available_extensions := make([]vk.ExtensionProperties, num_available_extensions);
    vk.EnumerateInstanceExtensionProperties(nil, &num_available_extensions, slice_to_multi_ptr(available_extensions));
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
            log.error("Missing required extension '", required_ext, "'", sep="");
            return required_extensions[:], false;
        }
    }
    return required_extensions[:], true;
}

check_physical_device_extensions :: proc(pdevice : vk.PhysicalDevice, required : []cstring, allocator := context.allocator) -> (ok: bool) {
    context.allocator = allocator;

    ext_count : u32;
    vk.EnumerateDeviceExtensionProperties(pdevice, nil, &ext_count, nil);

    available := make([]vk.ExtensionProperties, ext_count);
    defer delete(available);

    vk.EnumerateDeviceExtensionProperties(pdevice, nil, &ext_count, slice_to_multi_ptr(available));

    num_match := 0;

    log.debug("Required device extensions:", required);
    for req in required {
        for avail in available {
            avail_name := vk_string_to_string(avail.extensionName);
            req_name := strings.clone_from_cstring(req);
            defer delete(avail_name);
            defer delete(req_name);

            if avail_name == req_name {
                num_match += 1;
                log.debug(req_name, "... OK");
                break;
            }
        }
    }

    return num_match == len(required);
}
check_physical_device_features :: proc(gpu : GPU_Info, required_features : vk.PhysicalDeviceFeatures) -> bool {
    log.debug("Querying Required features: ");

    struct_info := type_info_of(vk.PhysicalDeviceFeatures).variant.(reflect.Type_Info_Named).base.variant.(reflect.Type_Info_Struct);

    all_present := true;
    for name,i in struct_info.names {
        required := reflect.struct_field_value(required_features, reflect.struct_field_by_name(vk.PhysicalDeviceFeatures, name)).(b32);
        existing := reflect.struct_field_value(gpu.features, reflect.struct_field_by_name(vk.PhysicalDeviceFeatures, name)).(b32);


        if required && !existing {
            log.debug("\t", name, " ... MISSING");
            all_present = false;
        } else if required && existing {
            log.debug("\t", name, " ... OK");
        }
    }
    return all_present;
}
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

    wanted_layers := []cstring {
        "VK_LAYER_KHRONOS_validation",
        "VK_LAYER_KHRONOS_shader_object",
    };
    final_layers := make_multi_pointer([^]cstring, len(wanted_layers));
    next_final_layer := 0;
    log.debug("Adding validation layers:");
    for l in wanted_layers {
        log.debug("\t%s... ", l);

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

        if !match {
            log.debug("MISSING");
        } else {
            log.debug("PRESENT");
            final_layers[next_final_layer] = l;
            next_final_layer += 1;
        }
    }

    log.debug("Added", next_final_layer, "validation layers");
    create_info.ppEnabledLayerNames = final_layers;
    create_info.enabledLayerCount = cast(u32)next_final_layer;

    return next_final_layer == len(wanted_layers);
}



vk_debug_callback :: proc "system" (
        severity: vk.DebugUtilsMessageSeverityFlagsEXT, 
        types: vk.DebugUtilsMessageTypeFlagsEXT, 
        callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT, 
        user_data: rawptr) -> b32 {
    context = runtime.default_context();
    context.logger = (cast(^log.Logger)user_data)^;

    //fmt.println("\n[VK VALIDATION]:", pCallbackData.pMessage);
    
    
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

    fmt.sbprintln(&builder, "VK VALIDATION MESSAGE\n");
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
    fmt.println(strings.to_string(builder));

    return false;
}

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
    res := vk.QueueSubmit(transfer_queue, 1, &submit_info, 0);
    if res != .SUCCESS {
        panic(fmt.tprintf("Failed single use queue submit '%s'", res));
    }
    if signal_semaphore == 0 do vk.QueueWaitIdle(transfer_queue);
    vk.FreeCommandBuffers(vk_device, transfer_pool, 1, &command_buffer);
}

// #Syncs
transfer_data_to_device_buffer_improvised :: proc(data : rawptr, dst_buffer : vk.Buffer, size : vk.DeviceSize, using dc : ^Device_Context) {
    staging_buffer, staging_memory := make_staging_buffer(size, dc);
    
    staging_ptr : rawptr;
    vk.MapMemory(vk_device, staging_memory, 0, size, {}, &staging_ptr);
    mem.copy(staging_ptr, data, cast(int)size);
    vk.UnmapMemory(vk_device, staging_memory);

    cmd := begin_single_use_command_buffer(dc);
    
    copy_region : vk.BufferCopy;
    copy_region.srcOffset = 0;
    copy_region.dstOffset = 0;
    copy_region.size = cast(vk.DeviceSize)size;
    vk.CmdCopyBuffer(cmd, staging_buffer, dst_buffer, 1, &copy_region);
    
    submit_and_destroy_single_use_command_buffer(cmd, dc=dc);
    destroy_staging_buffer(staging_buffer, staging_memory, dc);
}
// #Syncs
transfer_data_to_device_image_improvised :: proc(data : rawptr, x, y, width, height : int, dst_image : vk.Image, size : vk.DeviceSize, using dc : ^Device_Context) {
    staging_buffer, staging_memory := make_staging_buffer(size, dc);
    staging_ptr : rawptr;
    vk.MapMemory(vk_device, staging_memory, 0, size, {}, &staging_ptr);
    mem.copy(staging_ptr, data, cast(int)size);
    vk.UnmapMemory(vk_device, staging_memory);
    command_buffer := begin_single_use_command_buffer(dc);
    
    copy_region :  vk.BufferImageCopy;
    copy_region.bufferOffset = 0;
    copy_region.bufferRowLength = 0;
    copy_region.bufferImageHeight = 0;
    copy_region.imageSubresource.aspectMask = {.COLOR};
    copy_region.imageSubresource.mipLevel = 0;
    copy_region.imageSubresource.baseArrayLayer = 0;
    copy_region.imageSubresource.layerCount = 1;
    copy_region.imageOffset = {cast(i32)x, cast(i32)y, 0};
    copy_region.imageExtent = {cast(u32)width,cast(u32)height,1};

    vk.CmdCopyBufferToImage(command_buffer, staging_buffer, dst_image, .TRANSFER_DST_OPTIMAL, 1, &copy_region);
    
    submit_and_destroy_single_use_command_buffer(command_buffer, dc=dc);
    destroy_staging_buffer(staging_buffer, staging_memory, dc);
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


Buffer_Kind :: enum {
    CUSTOM,
    VERTEX,
    INDEX,
    UNIFORM,
}
// #Rename
Buffer_Storage_Kind :: enum {
    // Stores the data in VRAM for quick access on GPU but uses
    // a staging buffer which STAYS ALLOCATED in RAM allowing for
    // fairly quick upload. 
    // Recommended for: 
    // GPU access - frequently
    // CPU read   - never/infrequently
    // CPU write  - semi-frequently
    STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER, 
    SEMI_DYNAMIC_MESH_STORAGE = STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER,
    // Stores the data in VRAM for quick access on GPU but uses
    // a staging buffer which is allocated and freed per upload.
    // Recommended for: 
    // GPU access - frequently
    // CPU read   - never/infrequently
    // CPU write  - once/infrequently
    STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER,
    STATIC_MESH_STORAGE = STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER,
    // Stores the data RAM and syncing for GPU. From my understanding this
    // basically means the GPU reads from RAM. It will be synced so GPU
    // will be aware of any writes made in RAM. 
    // Recommended for: 
    // GPU access - semi-frequently
    // CPU read   - frequently
    // CPU write  - frequently
    STORE_IN_RAM_SYNCED,
    DYNAMIC_MESH_STORAGE = STORE_IN_RAM_SYNCED,
    // Stores the data RAM and syncing for GPU. From my understanding this
    // basically means the GPU reads from RAM. Changes to RAM needs to
    // be manually flushed for GPU. 
    // Recommended for: 
    // GPU access - semi-frequently
    // CPU read   - frequently
    // CPU write  - frequently
    STORE_IN_RAM_NOT_SYNCED,
    DYNAMIC_MESH_STORAGE_MANUAL = STORE_IN_RAM_NOT_SYNCED,
}
Buffer :: struct {
    vk_buffer : vk.Buffer,
    memory_handle : vk.DeviceMemory,
    size : int,
    dc : ^Device_Context,
    storage_kind : Buffer_Storage_Kind,
    kind : Buffer_Kind,

    // Optional
    staging_buffer : vk.Buffer,
    staging_memory : vk.DeviceMemory,
    transfer_command_buffer : vk.CommandBuffer,
    transfer_done_semaphore : vk.Semaphore,
    transfer_semaphore_counter : u64,
    transfer_fence : vk.Fence,
}

init_buffer_base :: proc(dc : ^Device_Context, buffer : ^Buffer, size : vk.DeviceSize, usage : vk.BufferUsageFlags, sharing_mode : vk.SharingMode, storage_kind : Buffer_Storage_Kind, kind : Buffer_Kind) {
    buffer.dc = dc;
    buffer_info : vk.BufferCreateInfo;
    buffer_info.sType = .BUFFER_CREATE_INFO;
    buffer_info.size = size;
    buffer_info.usage = usage;
    buffer_info.sharingMode = sharing_mode;

    if vk.CreateBuffer(dc.vk_device, &buffer_info, nil, &buffer.vk_buffer) != .SUCCESS {
        panic("Failed to create vertex buffer");
    }
    buffer.size = cast(int)size;
    buffer.kind = kind;
    buffer.storage_kind = storage_kind;

    switch storage_kind {
        case .STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER: {
            buffer.transfer_done_semaphore = make_semaphore(dc, true);
        }
        case .STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER: {
            buffer.transfer_fence = make_fence(dc);
            buffer.transfer_done_semaphore = make_semaphore(dc, true);
        }
        case .STORE_IN_RAM_NOT_SYNCED, .STORE_IN_RAM_SYNCED: {}
    }
}
make_custom_buffer :: proc(dc : ^Device_Context, size : int, usage : vk.BufferUsageFlags, sharing_mode : vk.SharingMode, storage_kind : Buffer_Storage_Kind) -> ^Buffer {
    buffer := new(Buffer);
    init_buffer_base(dc, buffer, cast(vk.DeviceSize)size, usage, sharing_mode, storage_kind, .CUSTOM);
    return buffer;
}
find_memory_index :: proc(using dc : ^Device_Context, type_bits : u32, required_properties : []vk.MemoryPropertyFlag) -> u32 {
    base_loop : for i in 0..< gpu.memory_props.memoryTypeCount {
        for flag in required_properties do if (flag not_in gpu.memory_props.memoryTypes[i].propertyFlags) do continue base_loop;
        if ((type_bits & (1 << i)) != 0) {
            return i;
        }
    }
    panic("No suitable memory type");
}
allocate_buffer_memory :: proc(buffer : ^Buffer, required_properties : []vk.MemoryPropertyFlag, size : int, data : rawptr = nil) {
    using buffer.dc;

    if buffer.memory_handle != 0 {
        panic("Buffer has already been bound to memory, cannot allocate again.");
    }

    requirements : vk.MemoryRequirements;
    vk.GetBufferMemoryRequirements(vk_device, buffer.vk_buffer, &requirements);

    alloc_info : vk.MemoryAllocateInfo;
    alloc_info.sType = .MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = requirements.size;
    alloc_info.memoryTypeIndex = find_memory_index(buffer.dc, requirements.memoryTypeBits, required_properties);

    if vk.AllocateMemory(vk_device, &alloc_info, nil, &buffer.memory_handle) != .SUCCESS {
        panic("Failed to allocate vertex buffer memory");
    }
    vk.BindBufferMemory(vk_device, buffer.vk_buffer, buffer.memory_handle, 0);
    
    if data != nil {
        set_buffer_data(buffer, data, size);
    }
}
deallocate_buffer_memory :: proc(buffer : ^Buffer) {
    using buffer.dc;
    vk.FreeMemory(vk_device, buffer.memory_handle, nil);
}
map_buffer :: proc(buffer : ^Buffer, size : int) -> rawptr {
    using buffer.dc;
    assert(buffer.memory_handle != 0, "Mapping unallocated buffer");
    mapped_data : rawptr;
    vk.MapMemory(vk_device, buffer.memory_handle, 0, cast(vk.DeviceSize)size, {}, &mapped_data);
    return mapped_data;
}
unmap_buffer :: proc(buffer : ^Buffer) {
    using buffer.dc;
    vk.UnmapMemory(vk_device, buffer.memory_handle);
}
set_buffer_data :: proc(buffer : ^Buffer, data : rawptr, size : int) {
    using buffer.dc;
    assert(buffer.memory_handle != 0, "Setting unallocated buffer");

    assert(size <= buffer.size, "Buffer overflow");

    switch buffer.storage_kind {
        case .STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER: {
            transfer_data_to_device_buffer_improvised(data, buffer.vk_buffer, cast(vk.DeviceSize)size, buffer.dc);
        }
        case .STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER: {

            // #Speed #Sync
            // #Speed #Sync
            // #Speed #Sync
            // #Speed #Sync
            // This should maybe be the standard but have an async options which returns
            // a semaphore that needs to be waited on, likely passed to end_draw_commands.
            defer vk.QueueWaitIdle(transfer_queue);

            if buffer.staging_buffer == 0 {
                buffer.staging_buffer, buffer.staging_memory = make_staging_buffer(cast(vk.DeviceSize)size, buffer.dc);
        
                alloc_info : vk.CommandBufferAllocateInfo;
                alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
                alloc_info.level = .PRIMARY;
                alloc_info.commandPool = transfer_pool;
                alloc_info.commandBufferCount = 1;
                
                vk.AllocateCommandBuffers(vk_device, &alloc_info, &buffer.transfer_command_buffer);
            }

            staging_ptr : rawptr;
            vk.MapMemory(vk_device, buffer.staging_memory, 0, cast(vk.DeviceSize)size, {}, &staging_ptr);
            mem.copy(staging_ptr, data, size);
            vk.UnmapMemory(vk_device, buffer.staging_memory);
            
            begin_info : vk.CommandBufferBeginInfo;
            begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
            begin_info.flags = {.SIMULTANEOUS_USE};
            // #Speed #Sync
            // We should be able to queue more transfer commands
            // without needing to wait for the previous one I think?
            // But in such cases maybe there is no reason to not use
            // STORE_IN_RAM_SYNC instead.
            vk.WaitForFences(vk_device, 1, &buffer.transfer_fence, true, c.UINT64_MAX);
            vk.ResetFences(vk_device, 1, &buffer.transfer_fence);
            vk.BeginCommandBuffer(buffer.transfer_command_buffer, &begin_info);
            
            copy_region : vk.BufferCopy;
            copy_region.srcOffset = 0;
            copy_region.dstOffset = 0;
            copy_region.size = cast(vk.DeviceSize)size;
            vk.CmdCopyBuffer(buffer.transfer_command_buffer, buffer.staging_buffer, buffer.vk_buffer, 1, &copy_region);
            
            vk.EndCommandBuffer(buffer.transfer_command_buffer);

            
            /*current_value : u64;
            vk.GetSemaphoreCounterValue(vk_device, buffer.transfer_done_semaphore, &current_value);
            fmt.println(current_value);
            for current_value > 0 {
                vk.GetSemaphoreCounterValue(vk_device, buffer.transfer_done_semaphore, &current_value);
                fmt.println(current_value);

                /*wait_info : vk.SemaphoreWaitInfo;
                wait_info.sType = .SEMAPHORE_WAIT_INFO;
                wait_info.pSemaphores = &buffer.transfer_done_semaphore;
                values : []u64 = {1};
                wait_info.pValues = slice_to_multi_ptr(values);
                wait_info.semaphoreCount = 1;
                wait_info.pNext = nil;
                vk.WaitSemaphores(vk_device, &wait_info, c.UINT64_MAX);*/

                signal_info : vk.SemaphoreSignalInfo;
                signal_info.sType = .SEMAPHORE_SIGNAL_INFO;
                signal_info.semaphore = buffer.transfer_done_semaphore;
                signal_info.value = 1;
                vk.SignalSemaphore(vk_device, &signal_info);

                vk.GetSemaphoreCounterValue(vk_device, buffer.transfer_done_semaphore, &current_value);
                fmt.println(current_value);
                os.exit(1);
            }*/

            /*buffer.transfer_semaphore_counter += 1;

            timeline_submit_info : vk.TimelineSemaphoreSubmitInfo;
            timeline_submit_info.sType = .TIMELINE_SEMAPHORE_SUBMIT_INFO;
            timeline_submit_info.signalSemaphoreValueCount = 1;
            timeline_submit_info.pSignalSemaphoreValues = &buffer.transfer_semaphore_counter;
            submit_info.pNext = &timeline_submit_info;*/

            submit_info : vk.SubmitInfo;
            submit_info.sType = .SUBMIT_INFO;
            submit_info.pSignalSemaphores = &buffer.transfer_done_semaphore;
            submit_info.signalSemaphoreCount = 0;
            submit_info.commandBufferCount = 1;
            submit_info.pCommandBuffers = &buffer.transfer_command_buffer;
            
            vk.QueueSubmit(transfer_queue, 1, &submit_info, buffer.transfer_fence);
        }
        case .STORE_IN_RAM_NOT_SYNCED, .STORE_IN_RAM_SYNCED: {
            staging_ptr : rawptr = map_buffer(buffer, size);
            mem.copy(staging_ptr, data, size);
            unmap_buffer(buffer);
        }
    }
}
destroy_buffer_base :: proc(buffer : ^Buffer) {
    using buffer.dc;
    wait_all_queues(buffer.dc);
    switch buffer.storage_kind {
        case .STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER: {
            destroy_staging_buffer(buffer.staging_buffer, buffer.staging_memory, buffer.dc);
            vk.DestroySemaphore(vk_device, buffer.transfer_done_semaphore, nil);
        }
        case .STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER: {
            vk.WaitForFences(vk_device, 1, &buffer.transfer_fence, true, c.UINT64_MAX);
            vk.DestroyFence(vk_device, buffer.transfer_fence, nil);
            vk.DestroySemaphore(vk_device, buffer.transfer_done_semaphore, nil);
        }
        case .STORE_IN_RAM_NOT_SYNCED: {}
        case .STORE_IN_RAM_SYNCED : {}
    }
    
    vk.DestroyBuffer(vk_device, buffer.vk_buffer, nil);
    deallocate_buffer_memory(buffer);
}
wait_buffer_idle :: proc(buffer : ^Buffer) {
    using buffer.dc;
    switch buffer.storage_kind {
        case .STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER: {}
        case .STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER: {
            vk.WaitForFences(vk_device, 1, &buffer.transfer_fence, true, c.UINT64_MAX);
            
        }
        case .STORE_IN_RAM_NOT_SYNCED: {}
        case .STORE_IN_RAM_SYNCED : {}
    }
}
make_staging_buffer :: proc(size : vk.DeviceSize, using dc : ^Device_Context) -> (buffer : vk.Buffer, memory_handle : vk.DeviceMemory) {
    buffer_info : vk.BufferCreateInfo;
    buffer_info.sType = .BUFFER_CREATE_INFO;
    buffer_info.size = size;
    buffer_info.usage = {.TRANSFER_SRC};
    buffer_info.sharingMode = .EXCLUSIVE;

    if (vk.CreateBuffer(vk_device, &buffer_info, nil, &buffer) != .SUCCESS) {
        panic("Failed to create buffer");
    }

    mem_reqs : vk.MemoryRequirements;
    vk.GetBufferMemoryRequirements(vk_device, buffer, &mem_reqs);

    alloc_info : vk.MemoryAllocateInfo;
    alloc_info.sType = .MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = find_memory_index(dc, mem_reqs.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT});
    
    if (vk.AllocateMemory(vk_device, &alloc_info, nil, &memory_handle) != .SUCCESS) {
        panic("Failed to allocate buffer memory");
    }

    vk.BindBufferMemory(vk_device, buffer, memory_handle, 0);

    return;
}
destroy_staging_buffer :: proc(buffer : vk.Buffer, memory_handle : vk.DeviceMemory, using dc : ^Device_Context) {
    vk.DestroyBuffer(vk_device, buffer, nil);
    vk.FreeMemory(vk_device, memory_handle, nil);
}

//
// Vertex buffer
//

Vertex_Layout :: struct {
    binding    : vk.VertexInputBindingDescription,
    attributes : []vk.VertexInputAttributeDescription,
    stride : int,

    used_allocator : mem.Allocator,
} 
Vertex_Buffer :: struct {
    using base : Buffer,
    layout : Vertex_Layout,
}

make_vertex_layout_from_glsl_reflection :: proc(info : glsl.Glsl_Stage_Info, allocator := context.allocator) -> (layout : Vertex_Layout) {
    context.allocator = allocator;
    using layout;
    used_allocator = allocator;

    num_fields := len(info.inputs);
    attributes = make([]vk.VertexInputAttributeDescription, num_fields);

    offset : int;
    for field, i in info.inputs {
        attributes[i].binding = 0;
        attributes[i].location = cast(u32)field.location;
        attributes[i].offset = cast(u32)offset;
        attributes[i].format = glsl_type_to_vk_format(field.type.kind);

        offset += glsl.get_glsl_type_size(field.type.kind);
    }
    binding.stride = cast(u32)offset;
    binding.inputRate = .VERTEX;
    binding.binding = 0;

    return;
}
make_vertex_layout_from_type :: proc($Vertex_Type : typeid, allocator := context.allocator) -> (layout : Vertex_Layout) where intrinsics.type_is_struct(Vertex_Type) {
    context.allocator = allocator;
    maybe_struct_info := type_info_of(Vertex_Type);
    struct_info : reflect.Type_Info_Struct;
    #partial switch v in maybe_struct_info.variant {
        case reflect.Type_Info_Struct: {
            struct_info = v;
        }
        case reflect.Type_Info_Named: {
            struct_info = v.base.variant.(reflect.Type_Info_Struct);
        }
    }

    num_members := len(struct_info.names);

    using layout;

    used_allocator = allocator;
    
    stride = size_of(Vertex_Type);

    binding.stride = cast(u32)stride;
    binding.inputRate = .VERTEX;
    binding.binding = 0;

    attributes = make([]vk.VertexInputAttributeDescription, num_members);

    for name,i in struct_info.names {

        offset := struct_info.offsets[i];
        type_base   := struct_info.types[i];

        attributes[i].binding = 0;
        attributes[i].location = cast(u32)i;
        attributes[i].offset = cast(u32)offset;

        set_format_from_type(type_base, &attributes[i], name);
        set_format_from_type :: proc(type_base : ^reflect.Type_Info, attribute : ^vk.VertexInputAttributeDescription, name : string) {
            // #Incomplete #Errorreporting #Refactor
            #partial switch type in type_base.variant {
                case reflect.Type_Info_Float: {
                    if type_base.size == 4      do attribute.format = .R32_SFLOAT
                    else if type_base.size == 8 do attribute.format = .R64_SFLOAT
                    else do panic(fmt.tprintf("Only 4 or 8-byte floats allowed in Vertex type (%s : %s)", name, type_base));
                }
                case reflect.Type_Info_Integer: {
                    if type_base.size == 1      do attribute.format = .R8_SINT if type.signed else .R8_UINT;
                    else if type_base.size == 2 do attribute.format = .R16_SINT if type.signed else .R16_UINT;
                    else if type_base.size == 4 do attribute.format = .R32_SINT if type.signed else .R32_UINT;
                    else if type_base.size == 8 do attribute.format = .R64_SINT if type.signed else .R64_UINT;
                    else do panic(fmt.tprintf("Only 1, 2, 4 or 8-byte integers allowed in Vertex type (%s : %s)", name, type_base));
                    
                }
                case reflect.Type_Info_Array: {
                    #partial switch elem_type in type.elem.variant {
                        case reflect.Type_Info_Float: {
                            
                            if type.elem.size == 4 {
                                if type.count == 2      do attribute.format = .R32G32_SFLOAT       
                                else if type.count == 3 do attribute.format = .R32G32B32_SFLOAT    
                                else if type.count == 4 do attribute.format = .R32G32B32A32_SFLOAT 
                                else do panic(fmt.tprintf("Unsupported array length of %i in vertex input type for member %s", type.count, name));
                            } else if type.elem.size == 8 {
                                if type.count == 2      do attribute.format = .R64G64_SFLOAT      
                                else if type.count == 3 do attribute.format = .R64G64B64_SFLOAT   
                                else if type.count == 4 do attribute.format = .R64G64B64A64_SFLOAT
                                else do panic(fmt.tprintf("Unsupported array length of %i in vertex input type for member %s", type.count, name));
                            } else do panic(fmt.tprintf("Only 4 or 8-byte floats allowed in Vertex type (%s : %s)", name, type.elem));
                        }
                        case reflect.Type_Info_Integer: {
                            if type.elem.size == 1      {
                                if type.count == 2      do attribute.format = .R8G8_SINT       if elem_type.signed else .R8G8_UINT;
                                else if type.count == 3 do attribute.format = .R8G8B8_SINT    if elem_type.signed else .R8G8B8_SINT;
                                else if type.count == 4 do attribute.format = .R8G8B8A8_SINT if elem_type.signed else .R8G8B8A8_SINT;
                                else do panic(fmt.tprintf("Unsupported array length of %i in vertex input type for member %s", type.count, name));
                            } else if type.elem.size == 2 {
                                if type.count == 2      do attribute.format = .R16G16_SINT       if elem_type.signed else .R16G16_UINT;
                                else if type.count == 3 do attribute.format = .R16G16B16_SINT    if elem_type.signed else .R16G16B16_SINT;
                                else if type.count == 4 do attribute.format = .R16G16B16A16_SINT if elem_type.signed else .R16G16B16A16_SINT;
                                else do panic(fmt.tprintf("Unsupported array length of %i in vertex input type for member %s", type.count, name));
                            } else if type.elem.size == 4 {
                                if type.count == 2      do attribute.format = .R32G32_SINT       if elem_type.signed else .R32G32_UINT;
                                else if type.count == 3 do attribute.format = .R32G32B32_SINT    if elem_type.signed else .R32G32B32_SINT;
                                else if type.count == 4 do attribute.format = .R32G32B32A32_SINT if elem_type.signed else .R32G32B32A32_SINT;
                                else do panic(fmt.tprintf("Unsupported array length of %i in vertex input type for member %s", type.count, name));
                            } else if type.elem.size == 8 {
                                if type.count == 2      do attribute.format = .R64G64_SINT       if elem_type.signed else .R64G64_UINT;
                                else if type.count == 3 do attribute.format = .R64G64B64_SINT    if elem_type.signed else .R64G64B64_SINT;
                                else if type.count == 4 do attribute.format = .R64G64B64A64_SINT if elem_type.signed else .R64G64B64A64_SINT;
                                else do panic(fmt.tprintf("Unsupported array length of %i in vertex input type for member %s", type.count, name));
                            } else do panic(fmt.tprintf("Only 1, 2, 4 or 8-byte integers allowed in Vertex type (%s : %s)", name, type.elem));

                        }       
                        case: panic(fmt.tprintf("Unsupported vertex member array element type %s, member '%s'", type.elem, name));
                    }
                }
                case reflect.Type_Info_Named: {
                    set_format_from_type(type_base.variant.(reflect.Type_Info_Named).base, attribute, name);
                }
                case: panic(fmt.tprintf("Unsupported vertex member type %s, member '%s'", type_base, name));
            }
        }
        
    }

    return;
}
destroy_vertex_layout :: proc(layout : Vertex_Layout) {
    context.allocator = layout.used_allocator;
    delete(layout.attributes);
}

make_vertex_buffer :: proc(vertices : []$Vertex_Type, storage_kind : Buffer_Storage_Kind, allocator := context.allocator, using dc := target_dc) -> ^Vertex_Buffer {
    context.allocator = allocator;

    vbo := new(Vertex_Buffer);

    vbo.layout = make_vertex_layout_from_type(Vertex_Type);

    size := (size_of(Vertex_Type) * len(vertices));

    switch storage_kind {
        case .STORE_IN_RAM_NOT_SYNCED: {
            init_buffer_base(dc, vbo, cast(vk.DeviceSize)size, {.VERTEX_BUFFER}, .EXCLUSIVE, storage_kind, .VERTEX);
            allocate_buffer_memory(vbo, { .HOST_VISIBLE }, size, slice_to_multi_ptr(vertices));
        }
        case .STORE_IN_RAM_SYNCED: {
            init_buffer_base(dc, vbo, cast(vk.DeviceSize)size, {.VERTEX_BUFFER}, .EXCLUSIVE, storage_kind, .VERTEX);
            allocate_buffer_memory(vbo, { .HOST_COHERENT, .HOST_VISIBLE }, size, slice_to_multi_ptr(vertices));
        }
        case .STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER: {
            fallthrough;
        }
        case .STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER: {
            init_buffer_base(dc, vbo, cast(vk.DeviceSize)size, {.VERTEX_BUFFER, .TRANSFER_DST}, .EXCLUSIVE, storage_kind, .VERTEX);
            allocate_buffer_memory(vbo, { .DEVICE_LOCAL }, size, slice_to_multi_ptr(vertices));
        }
    }

    return vbo;
}
set_vertex_buffer_data :: proc(vbo : ^Vertex_Buffer, vertices : []$Vertex_Type) {
    assert(vbo.base.kind == .VERTEX, "Buffer is not a vertex buffer");
    set_buffer_data(vbo, slice_to_multi_ptr(vertices), len(vertices) * size_of(Vertex_Type));
}
destroy_vertex_buffer :: proc(vbo : ^Vertex_Buffer) {
    using vbo.dc;
    destroy_vertex_layout(vbo.layout);
    destroy_buffer_base(vbo);
}

//
// Index buffer
//

Index_Buffer :: struct {
    using base : Buffer,
}

make_index_buffer :: proc(indices : []u32, storage_kind : Buffer_Storage_Kind, allocator := context.allocator, using dc := target_dc) -> ^Index_Buffer {
    context.allocator = allocator;

    ibo := new(Index_Buffer);

    size := (size_of(u32) * len(indices));
    switch storage_kind {
        case .STORE_IN_RAM_NOT_SYNCED: {
            init_buffer_base(dc, ibo, cast(vk.DeviceSize)size, {.INDEX_BUFFER }, .EXCLUSIVE, storage_kind, .INDEX);
            allocate_buffer_memory(ibo, { .HOST_VISIBLE }, size, slice_to_multi_ptr(indices));
        }
        case .STORE_IN_RAM_SYNCED: {
            init_buffer_base(dc, ibo, cast(vk.DeviceSize)size, {.INDEX_BUFFER }, .EXCLUSIVE, storage_kind, .INDEX);
            allocate_buffer_memory(ibo, { .HOST_COHERENT, .HOST_VISIBLE }, size, slice_to_multi_ptr(indices));
        }
        case .STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER: {
            fallthrough;
        }
        case .STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER: {
            init_buffer_base(dc, ibo, cast(vk.DeviceSize)size, {.INDEX_BUFFER, .TRANSFER_DST}, .EXCLUSIVE, storage_kind, .INDEX);
            allocate_buffer_memory(ibo, { .DEVICE_LOCAL }, size, slice_to_multi_ptr(indices));
        }
    }

    return ibo;
}
set_index_buffer_data :: proc(ibo : ^Index_Buffer, indices : []u32) {
    assert(ibo.base.kind == .INDEX, "Buffer is not a index buffer");
    set_buffer_data(ibo, slice_to_multi_ptr(indices), len(indices) * size_of(indices[0]));
}
destroy_index_buffer :: proc(ibo : ^Index_Buffer) {
    using ibo.dc;
    destroy_buffer_base(ibo);
}


//
// Uniform buffer
//

Uniform_Buffer :: struct {
    using base : Buffer,
    desc_info : vk.DescriptorBufferInfo,
}

make_uniform_buffer :: proc($T : typeid, storage_kind : Buffer_Storage_Kind, allocator := context.allocator, using dc := target_dc) -> ^Uniform_Buffer {
    context.allocator = allocator;

    ubo := new(Uniform_Buffer);

    size := size_of(T);
    switch storage_kind {
        case .STORE_IN_RAM_NOT_SYNCED: {
            init_buffer_base(dc, ubo, cast(vk.DeviceSize)size, {.UNIFORM_BUFFER }, .EXCLUSIVE, storage_kind, .UNIFORM);
            allocate_buffer_memory(ubo, { .HOST_VISIBLE }, size, nil);
        }
        case .STORE_IN_RAM_SYNCED: {
            init_buffer_base(dc, ubo, cast(vk.DeviceSize)size, {.UNIFORM_BUFFER }, .EXCLUSIVE, storage_kind, .UNIFORM);
            allocate_buffer_memory(ubo, { .HOST_COHERENT, .HOST_VISIBLE }, size, nil);
        }
        case .STORE_ON_GPU_WITH_CONSTANT_STAGING_BUFFER: {
            fallthrough;
        }
        case .STORE_ON_GPU_WITH_IMPROVISED_STAGING_BUFFER: {
            init_buffer_base(dc, ubo, cast(vk.DeviceSize)size, {.UNIFORM_BUFFER, .TRANSFER_DST}, .EXCLUSIVE, storage_kind, .UNIFORM);
            allocate_buffer_memory(ubo, { .DEVICE_LOCAL }, size, nil);
        }
    }

    ubo.desc_info.buffer = ubo.vk_buffer;
    ubo.desc_info.offset = 0;
    ubo.desc_info.range = size_of(T);

    return ubo;
}
set_uniform_buffer_value :: proc(ubo : ^Uniform_Buffer, data : $T) {
    assert(ubo.base.kind == .UNIFORM, "Buffer is not a index buffer");
    data := data;
    set_buffer_data(ubo, &data, size_of(T));
}
destroy_uniform_buffer :: proc(ubo : ^Uniform_Buffer) {
    using ubo.dc;
    clear_descriptor_writes_uniform_buffer(ubo);
    // vbo could be in use in swap chain command buffer
    destroy_buffer_base(ubo);
}




Texture :: struct {
    dc : ^Device_Context,
    width, height, channels : int,
    format : Texture_Format,
    current_layout : vk.ImageLayout,
    vk_image : vk.Image,
    view : vk.ImageView,
    memory_handle : vk.DeviceMemory,
    sampler : vk.Sampler,
    desc_info : vk.DescriptorImageInfo,
}
Texture_Format :: enum {
    R, RG, RGB,
    BGR, RGBA, BGRA,

    R_HDR, RG_HDR, RGB_HDR,
    RGBA_HDR,
}
Sampler_Settings :: struct {
    mag_filter, min_filter : vk.Filter,
    mipmap_enable : bool,
    mipmap_mode : vk.SamplerMipmapMode,
    wrap_u, wrap_v, wrap_w : vk.SamplerAddressMode,
}
DEFAULT_SAMPLER_SETTINGS :: Sampler_Settings {
    mag_filter=.LINEAR, 
    min_filter=.LINEAR, 
    mipmap_enable=false, 
    mipmap_mode=.LINEAR, 
    wrap_u=.CLAMP_TO_EDGE, 
    wrap_v=.CLAMP_TO_EDGE, 
    wrap_w=.CLAMP_TO_EDGE,
}
count_channels :: proc(format : Texture_Format) -> int {
    switch format {
        case .R, .R_HDR:              return 1;
        case .RG, .RG_HDR:            return 2;
        case .RGB, .BGR, .RGB_HDR:    return 3;
        case .RGBA, .BGRA, .RGBA_HDR: return 4;
    }
    panic("unhandled format");
}
texture_format_to_vk_format :: proc(format : Texture_Format) -> vk.Format {
    switch format {
        case .R: return .R8_SRGB;
        case .RG: return .R8G8_SRGB;
        case .RGB: return .R8G8B8_SRGB;
        case .BGR: return .B8G8R8_SRGB;
        case .RGBA: return .R8G8B8A8_SRGB;
        case .BGRA: return .B8G8R8A8_SRGB;

        case .R_HDR: return .R32_SFLOAT;
        case .RG_HDR: return .R32G32_SFLOAT;
        case .RGB_HDR: return .R32G32B32_SFLOAT;
        case .RGBA_HDR: return .R32G32B32A32_SFLOAT;
    }
    panic("unhandled format");
}
get_texture_format_component_size :: proc(format : Texture_Format) -> int {
    switch format {
        case .R, .RG, .RGB, .BGR, .RGBA, .BGRA:
            return 1;
        case .R_HDR, .RG_HDR, .RGB_HDR, .RGBA_HDR:
            return 4;
    }
    panic("");
}
make_texture :: proc(data : rawptr, width, height : int, format : Texture_Format, sampler_settings := DEFAULT_SAMPLER_SETTINGS, using dc := target_dc) -> ^Texture {

    assert(width > 0 && height > 0);

    channels := count_channels(format);

    texture := new(Texture);
    texture.width = width;
    texture.height = height;
    texture.channels = channels;
    texture.format = format;
    texture.dc = dc;


    size := cast(vk.DeviceSize)(width * height * channels);
    staging_buffer : vk.Buffer;
    staging_memory : vk.DeviceMemory;

    image_info : vk.ImageCreateInfo;
    image_info.sType = .IMAGE_CREATE_INFO;
    image_info.imageType = .D2;
    image_info.extent.width = cast(u32)texture.width;
    image_info.extent.height = cast(u32)texture.height;
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = texture_format_to_vk_format(format);
    image_info.tiling = .OPTIMAL;
    image_info.initialLayout = .UNDEFINED;
    image_info.usage = {.TRANSFER_DST, .SAMPLED, .COLOR_ATTACHMENT}; // #Redundant #Fix, only render textures need .COLOR_ATTACHMENT flag
    image_info.sharingMode = .EXCLUSIVE;
    image_info.samples = {._1};
    image_info.flags = {};
    if vk.CreateImage(vk_device, &image_info, nil, &texture.vk_image) != .SUCCESS {
        panic("Failed to create image");
    }
    mem_requirements : vk.MemoryRequirements;
    vk.GetImageMemoryRequirements(vk_device, texture.vk_image, &mem_requirements);

    alloc_info : vk.MemoryAllocateInfo;
    alloc_info.sType = .MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = find_memory_index(dc, mem_requirements.memoryTypeBits, {.DEVICE_LOCAL});
    if vk.AllocateMemory(vk_device, &alloc_info, nil, &texture.memory_handle) != .SUCCESS {
        panic("Failed to allocate image memory");
    }

    vk.BindImageMemory(vk_device, texture.vk_image, texture.memory_handle, 0);

    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .UNDEFINED, .TRANSFER_DST_OPTIMAL, dc=dc);
    if data != nil do transfer_data_to_device_image_improvised(data, 0, 0, width, height, texture.vk_image, size, dc);
    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, dc=dc);

    view_info : vk.ImageViewCreateInfo;
    view_info.sType = .IMAGE_VIEW_CREATE_INFO;
    view_info.image = texture.vk_image;
    view_info.viewType = .D2;
    view_info.format = texture_format_to_vk_format(texture.format);
    view_info.subresourceRange.aspectMask = {.COLOR};
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    if vk.CreateImageView(vk_device, &view_info, nil, &texture.view) != .SUCCESS {
        panic("Failed to create texture image view");
    }

    sampler_info : vk.SamplerCreateInfo;
    sampler_info.sType = .SAMPLER_CREATE_INFO;
    sampler_info.magFilter = sampler_settings.mag_filter;
    sampler_info.minFilter = sampler_settings.min_filter;
    sampler_info.addressModeU = sampler_settings.wrap_u;
    sampler_info.addressModeV = sampler_settings.wrap_v;
    sampler_info.addressModeW = sampler_settings.wrap_w;
    sampler_info.mipmapMode = sampler_settings.mipmap_mode;
    sampler_info.anisotropyEnable = true;
    sampler_info.maxAnisotropy = dc.gpu.props.limits.maxSamplerAnisotropy;
    sampler_info.unnormalizedCoordinates = false;
    sampler_info.compareEnable = false;
    sampler_info.compareOp = .ALWAYS;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = 0.0;

    if vk.CreateSampler(vk_device, &sampler_info, nil, &texture.sampler) != .SUCCESS {
        panic("Failed to create texture sampler");
    }

    texture.desc_info.imageLayout = .SHADER_READ_ONLY_OPTIMAL;
    texture.desc_info.imageView = texture.view;
    texture.desc_info.sampler = texture.sampler;
    texture.current_layout = .SHADER_READ_ONLY_OPTIMAL;
    

    return texture;
}

// Region x, y, width, height
set_texture_pixels :: proc(texture : ^Texture, data : rawptr, region : lin.Vector4u) {
    using texture.dc;
    assert(texture != nil);
    assert(data != nil);

    L := cast(int)(region.x);
    R := cast(int)(region.x + region.z);
    B := cast(int)(region.y);
    T := cast(int)(region.y + region.w);

    // #Errormessage
    assert(R > L && L >= 0 && R <= texture.width);
    assert(T > B && B >= 0 && T <= texture.height);

    size := region.z * region.w * cast(u32)texture.channels * cast(u32)get_texture_format_component_size(texture.format);

    // #Sync all of these sync
    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), texture.current_layout, .TRANSFER_DST_OPTIMAL, dc=texture.dc);
    transfer_data_to_device_image_improvised(data, cast(int)region.x, cast(int)region.y, cast(int)region.z, cast(int)region.w, texture.vk_image, cast(vk.DeviceSize)size, texture.dc);
    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .TRANSFER_DST_OPTIMAL, texture.current_layout, dc=texture.dc);
}
destroy_texture :: proc(texture : ^Texture, using dc := target_dc) {
    clear_descriptor_writes_texture(texture);
    wait_all_queues(dc);
    vk.DestroySampler(vk_device, texture.sampler, nil);
    vk.DestroyImageView(vk_device, texture.view, nil);
    vk.DestroyImage(vk_device, texture.vk_image, nil);
    vk.FreeMemory(vk_device, texture.memory_handle, nil);
}


Render_Texture :: struct {
    using texture : ^Texture,
    target : ^Render_Target,
    
}
make_render_texture :: proc(width, height : int/*, format : Texture_Format*/, sampler_settings := DEFAULT_SAMPLER_SETTINGS, using dc := target_dc) -> ^Render_Texture{
    // #Incomplete #Limitation
    // the render target render passes are created with 32bit hdr format so it will be 
    // hard coded here for now as well.
    format :Texture_Format= .RGBA_HDR;

    render_texture := new(Render_Texture);

    
    render_texture.texture = make_texture(nil, width, height, format, sampler_settings, dc);
    render_texture.target = make_render_target(render_texture.vk_image, texture_format_to_vk_format(render_texture.format), {cast(u32)width, cast(u32)height}, render_texture_pass, dc);
    render_texture.target.current_layout = .SHADER_READ_ONLY_OPTIMAL;
    

    return render_texture;
}
destroy_render_texture :: proc(render_texture : ^Render_Texture) {
    using render_texture.dc;

    destroy_render_target(render_texture.target);
    destroy_texture(render_texture.texture);

    free(render_texture);
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
    vk.DestroyFence(vk_device, fence, nil);
}
wait_fence :: proc(fence : vk.Fence, using dc := target_dc) {
    fence := fence;
    vk.WaitForFences(vk_device, 1, &fence, true, c.UINT64_MAX);
}

shutdown :: proc() {

    for i := len(dcs_to_destroy)-1; i >= 0; i -= 1 {
        dc := dcs_to_destroy[i];
        for i := len(dc.shaders_to_destroy)-1; i >= 0; i -= 1 {
            shader := dc.shaders_to_destroy[i];
            destroy_shader_module(shader, dc);
        }
        for i := len(dc.pipelines_to_destroy)-1; i >= 0; i -= 1 {
            p := dc.pipelines_to_destroy[i];
            destroy_pipeline(p);
        }

        destroy_device_context(dc);
    }    

    when ODIN_DEBUG {
        vk.DestroyDebugUtilsMessengerEXT(vk_inst, vk_messenger, nil);
    }
    vk.DestroyInstance(vk_inst, nil);

    delete(dcs_to_destroy);
}