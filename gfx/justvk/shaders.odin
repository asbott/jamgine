package justvk

import "core:log"
import "core:fmt"
import "core:strings"
import "core:builtin"
import "core:mem"
import "core:slice"
import "core:reflect"

import vk "vendor:vulkan"
import "vendor:glfw"

import "jamgine:shaderc"


Shader_Program :: struct {
    vertex, fragment : Shader_Module,
    geometry, tesselation : Maybe(Shader_Module),

    vertex_input_layout : Vertex_Layout,
    
    program_layout : Glsl_Layout,
    descriptor_set_layout : vk.DescriptorSetLayout,
}
Shader_Module :: struct {
    bytes : []byte,
    text_source : string,
    stage : vk.ShaderStageFlag,
    vk_module : vk.ShaderModule,
    info : Glsl_Stage_Info,
}
Shader_Constant :: struct {
    name : string,
    value : union { int, f32, string },
}

log_layout :: proc(layout : Glsl_Layout) {
    if len(layout.inputs) > 0 do log.debug("Inputs:");
    for input in layout.inputs {
        log.debugf("\t%s : %s%s", 
            input.field.name, 
            input.field.type.elem_type.kind if input.field.type.elem_type != nil else input.field.type.kind, 
            fmt.tprintf("[%i]", (input.field.type.elem_count)) if input.field.type.kind == .ARRAY else "",
        );
    }
    if len(layout.outputs) > 0 do log.debug("Outputs:");
    for output in layout.outputs {
        log.debugf("\t%s : %s%s", 
            output.field.name, 
            output.field.type.elem_type.kind if output.field.type.elem_type != nil else output.field.type.kind, 
            fmt.tprintf("[%i]", (output.field.type.elem_count)) if output.field.type.kind == .ARRAY else "",
        );
    }
    if len(layout.descriptor_bindings) > 0 do log.debug("Descriptor bindings:");
    for db in layout.descriptor_bindings {
        log.debugf("\t%s : %s%s (%s)", 
            db.field.name, 
            db.field.type.elem_type.kind if db.field.type.elem_type != nil else db.field.type.kind, 
            fmt.tprintf("[%i]", (db.field.type.elem_count)) if db.field.type.kind == .ARRAY else "",
            db.kind,
        );
    }
}

add_standard_shader_macros :: proc(opts : shaderc.compileOptionsT, using dc : ^Device_Context) {
    shaderc.compile_options_add_macro_definition(opts, "highp_float", len("highp_float"), "double" if graphics_device.features.shaderFloat64 else "float", len("double") if graphics_device.features.shaderFloat64 else len("float"));
    shaderc.compile_options_add_macro_definition(opts, "RAND_MOD_RANGE", len("RAND_MOD_RANGE"), "2000", len("2000"));
}
compile_shader_source :: proc(using dc : ^Device_Context, src : string, kind : Glsl_Stage_Kind, constants : []Shader_Constant = nil, allocator := context.allocator) -> (module : Shader_Module, ok : bool) {
    context.allocator = allocator;
    // #Memory

    glsl_compiler := shaderc.compiler_initialize();
    defer shaderc.compiler_release(glsl_compiler);
    
    opts := shaderc.compile_options_initialize();
    defer shaderc.compile_options_release(opts);
    
    shaderc.compile_options_set_optimization_level(opts, .Performance);
    
    
    defer {
        if ok {
            log.debugf("Compiled a shader module of kind '%s'", kind);
            log_layout(module.info.layout);
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

    shaderc_kind : shaderc.shaderKind;
    switch kind {
        case .VERTEX: shaderc_kind = .VertexShader;
        case .FRAGMENT: shaderc_kind = .FragmentShader;
        case .GEOMETRY: shaderc_kind = .GeometryShader;
        case .COMPUTE: shaderc_kind = .GlslComputeShader;
    }

    // #Incomplete
    // We discard of the original source so if we need to recompile
    // we can't update constants; it will use the old values.
    pp_result := shaderc.compile_into_preprocessed_text(
        glsl_compiler, 
        strings.clone_to_cstring(src, allocator=context.temp_allocator), 
        len(src), shaderc_kind, "NOFILE", "main", opts,
    );
    pp_bytes := mem.byte_slice(shaderc.result_get_bytes(pp_result), cast(int)shaderc.result_get_length(pp_result));

    pp_src := string(pp_bytes);
    cstr := cast(cstring)slice_to_multi_ptr(pp_bytes); // Not null terminated!
    
    result := shaderc.compile_into_spv(glsl_compiler, cstr, len(pp_src), shaderc_kind, "NOFILE", "main", opts);
    defer shaderc.result_release(result);
    status := shaderc.result_get_compilation_status(result);
    if status == .Success {
        // #Memcleanup
        bytes := mem.byte_slice(shaderc.result_get_bytes(result), shaderc.result_get_length(result));
        module.stage = to_vk_stage_flag(kind);
        create_info : vk.ShaderModuleCreateInfo;
        create_info.sType = .SHADER_MODULE_CREATE_INFO;
        create_info.codeSize = len(bytes);
        create_info.pCode = cast(^u32)slice_to_multi_ptr(bytes);
        
        if vk.CreateShaderModule(dc.vk_device, &create_info, nil, &module.vk_module) == .SUCCESS {
            module.text_source = strings.clone(pp_src);
            module.bytes = slice.clone(bytes);
            ok = true; 

            info, err := inspect_glsl(module.text_source, kind);

            if err.kind != .NONE {
                log.errorf("Glsl inspect error %s: %s", err.kind, err.str);
                vk.DestroyShaderModule(dc.vk_device, module.vk_module, nil);
                ok = false;
                return;
            }

            module.info = info;
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
make_shader_program_from_sources :: proc(vertex_src, fragment_src : string, tessellation_src : string = "", geometry_src : string = "", constants : []Shader_Constant = nil, using dc : ^Device_Context = target_dc, allocator := context.allocator) -> (program : Shader_Program, ok : bool) {
    context.allocator = allocator;

    return  make_shader_program_from_modules(
        vertex_module=       compile_shader_source(dc, vertex_src, .VERTEX, constants=constants)     or_return,
        fragment_module=     compile_shader_source(dc, fragment_src, .FRAGMENT, constants=constants) or_return,
        tessellation_module=nil, // #Limitation #Incomplete
        geometry_module=    (compile_shader_source(dc, geometry_src, .GEOMETRY, constants=constants) or_return) if len(geometry_src) > 0 else nil,
        dc=dc,
    );
}
make_shader_program_from_modules :: proc(vertex_module, fragment_module : Shader_Module, tessellation_module : Maybe(Shader_Module) = nil, geometry_module : Maybe(Shader_Module) = nil, using dc := target_dc) -> (program : Shader_Program, ok:bool) {
    program.vertex = vertex_module;
    program.fragment = fragment_module;
    program.tesselation = tessellation_module;
    program.geometry = geometry_module;
    
    program.vertex_input_layout = make_vertex_layout_from_glsl_layout(program.vertex.info.layout);
    defer {
        if !ok do destroy_vertex_layout(program.vertex_input_layout);
        else {
            log.debugf("Compiled a shader program");
            log_layout(program.program_layout);
        }
    }
    layouts_ok : bool;
    program.program_layout, layouts_ok = combine_glsl_layouts(program.vertex.info.layout, program.fragment.info.layout);
    if layouts_ok && program.tesselation != nil do program.program_layout, layouts_ok = combine_glsl_layouts(program.vertex.info.layout, program.tesselation.(Shader_Module).info.layout);
    if layouts_ok && program.geometry != nil    do program.program_layout, layouts_ok = combine_glsl_layouts(program.vertex.info.layout, program.geometry.(Shader_Module).info.layout);

    if !layouts_ok do return {}, false;

    
    mods := []Maybe(Shader_Module){
        vertex_module, 
        fragment_module, 
        tessellation_module, 
        geometry_module,
    };

    
    for maybe_mod in mods {
        if maybe_mod == nil do continue;
        mod := maybe_mod.(Shader_Module);

        if mod.info.layout.push_constant != nil {
            if mod.stage != .VERTEX {
                log.error("Push constants are hard coded to only work with vertex stage #Incomplete #Limitation");
                return {}, false;
            }
            
            max_ps_size := dc.graphics_device.props.limits.maxPushConstantsSize;
            ps_size := cast(u32)mod.info.layout.push_constant.(Glsl_Field).type.size;
            if ps_size > max_ps_size {
                log.warnf("Push constant in %s is %i bytes which is bigger than the max push constant size of %i.", mod.stage, ps_size, max_ps_size);
            }
        }
    }


    vk_descriptor_bindings := make([]vk.DescriptorSetLayoutBinding, len(program.program_layout.descriptor_bindings));

    for db,i in program.program_layout.descriptor_bindings {
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
    
    if vk.CreateDescriptorSetLayout(vk_device, &layout_info, nil, &program.descriptor_set_layout) != .SUCCESS {
        panic("Failed creating description set layout");
    }

    return program, true;
}
make_shader_program :: proc{make_shader_program_from_modules, make_shader_program_from_sources};

get_program_descriptor_binding :: proc(program : Shader_Program, name : string) -> int {

    // If we dont find by variable name then find by user type name
    backup := -1;
    for db in program.program_layout.descriptor_bindings {
        if db.field.name == name do return db.location;

        if db.field.type.kind == .USER_TYPE && db.field.type.name == name do backup = db.location;
    }
    return backup;
}
 
destroy_shader_program :: proc(program : Shader_Program, using dc := target_dc) {
    vk.DeviceWaitIdle(vk_device);

    vk.DestroyDescriptorSetLayout(dc.vk_device, program.descriptor_set_layout, nil);
    destroy_shader_module(program.vertex, dc);
    destroy_shader_module(program.fragment, dc);
    if program.tesselation != nil do destroy_shader_module(program.tesselation.(Shader_Module), dc);
    if program.geometry != nil    do destroy_shader_module(program.geometry.(Shader_Module), dc);
    destroy_vertex_layout(program.vertex_input_layout);
}
destroy_shader_module :: proc(module : Shader_Module, using dc := target_dc) {
    vk.DeviceWaitIdle(vk_device);

    module := module;
    delete(module.bytes);
    delete(module.text_source);
    free_glsl_inspect_info(&module.info);
    vk.DestroyShaderModule(vk_device, module.vk_module, nil);
}
