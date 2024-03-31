package justvk


//This is for post-processing an already checked & compiled shader
//source so it will panic or fail assertion in unexpected (or unimplemented)
//cases.


import "core:log"
import "core:fmt"
import "core:strings"
import "core:builtin"
import "core:mem"
import "core:slice"
import "core:reflect"
import "core:strconv"

import vk "vendor:vulkan"
import "vendor:glfw"

import "jamgine:shaderc"
import "jamgine:utils"

Glsl_Type_Kind :: enum {
    INT, UINT, FLOAT, DOUBLE, BOOL,
    VEC2, VEC3, VEC4,
    IVEC2, IVEC3, IVEC4,
    UVEC2, UVEC3, UVEC4,
    DVEC2, DVEC3, DVEC4,
    BVEC2, BVEC3, BVEC4,
    MAT4, MAT3, MAT2,
    MAT4x3, MAT4x2,
    MAT3x2, MAT3x4,
    MAT2x3, MAT2x4,
    SAMPLER1D, SAMPLER2D, SAMPLER3D,
    USER_TYPE, ARRAY, VOID
}
is_glsl_type_sampler_descriptor :: proc(kind : Glsl_Type_Kind) -> bool {
    return kind == .SAMPLER1D || kind == .SAMPLER2D || kind == .SAMPLER3D;
}
Glsl_IO_Kind :: enum {
    IN, OUT,
}
Glsl_Type :: struct {
    kind : Glsl_Type_Kind,

    size : int,
    std140_size : int,
    std430_size : int,

    elem_type : ^Glsl_Type,
    elem_count : int,

    name : string,
}
Glsl_Field :: struct {
    name : string,
    type : ^Glsl_Type,
}
Glsl_Descriptor_Kind :: enum {
    UNIFORM_BUFFER, STORAGE_BUFFER, SAMPLER
}
to_vk_desciptor_type :: proc(kind : Glsl_Descriptor_Kind) -> vk.DescriptorType {
    switch kind {
        case .SAMPLER:        return .COMBINED_IMAGE_SAMPLER;
        case .UNIFORM_BUFFER: return .UNIFORM_BUFFER;
        case .STORAGE_BUFFER: return .STORAGE_BUFFER;
    }
    panic("What");
}
Glsl_Stage_Kind :: enum {
    VERTEX, FRAGMENT, GEOMETRY, COMPUTE
}
to_vk_stage_flag :: proc(kind : Glsl_Stage_Kind) -> vk.ShaderStageFlag {
    switch kind {
        case .VERTEX:   return .VERTEX;
        case .FRAGMENT: return .FRAGMENT;
        case .GEOMETRY: return .GEOMETRY;
        case .COMPUTE:  return .COMPUTE;
    }
    panic("What");
}

Glsl_Descriptor_Binding :: struct {
    stage : Glsl_Stage_Kind,
    kind : Glsl_Descriptor_Kind,
    location : int,
    field : Glsl_Field,
}
Glsl_IO_Item :: struct {
    stage : Glsl_Stage_Kind,
    kind : Glsl_IO_Kind,
    location : int,
    field : Glsl_Field,
}
Glsl_Layout :: struct {
    stage : Glsl_Stage_Kind,

    local_size_x, local_size_y, local_size_z : int,

    num_ubos, num_sbos, num_samplers : int,

    descriptor_bindings : []Glsl_Descriptor_Binding,
    inputs : []Glsl_IO_Item,
    outputs : []Glsl_IO_Item,

    types : []Glsl_Type,

    push_constant : Maybe(Glsl_Field),
}
Glsl_Stage_Info :: struct {
    layout : Glsl_Layout,
    version : int,

    parser : Glsl_Parser,
}

get_glsl_type_size :: proc(type : Glsl_Type_Kind, loc := #caller_location) -> int {
    switch (type) {
    case .VOID:
        return 0;
    case .BOOL, .INT, .UINT, .FLOAT, .SAMPLER1D, .SAMPLER2D, .SAMPLER3D:
        return 4;
    case .DOUBLE, .VEC2, .UVEC2, .IVEC2, .BVEC2:
        return 8;
    case .VEC3, .UVEC3, .IVEC3, .BVEC3:
        return 12;
    case .DVEC2, .VEC4, .UVEC4, .IVEC4, .BVEC4, .MAT2:
        return 16;
    case .DVEC3, .MAT3x2, .MAT2x3:
        return 24;
    case .DVEC4, .MAT4x2, .MAT2x4:
        return 32;
    case .MAT3:
        return 36;
    case .MAT4x3, .MAT3x4:
        return 48;
    case .MAT4:
        return 64;
    case .USER_TYPE: panic("Cannot get size of glsl type USER_TYPE", loc);
    case .ARRAY: panic("Cannot get size of glsl type ARRAY", loc);
    }
    panic("whut");
}

combine_glsl_layouts :: proc(a, b : Glsl_Layout) -> (result: Glsl_Layout, ok: bool){
    if a.local_size_x != 1 && b.local_size_x != 1 {
        log.error("Multiple layouts set local_size_x");
        return {}, false;
    }
    if a.local_size_y != 1 && b.local_size_y != 1 {
        log.error("Multiple layouts set local_size_y");
        return {}, false;
    }
    if a.local_size_z != 1 && b.local_size_z != 1 {
        log.error("Multiple layouts set local_size_z");
        return {}, false;
    }
    if a.push_constant != nil && b.push_constant != nil {
        log.error("Multiple layouts define push_constant");
        return {}, false;
    }

    result.local_size_x = a.local_size_x if a.local_size_x != 1 else b.local_size_x;
    result.local_size_y = a.local_size_y if a.local_size_y != 1 else b.local_size_y;
    result.local_size_z = a.local_size_z if a.local_size_z != 1 else b.local_size_z;
    result.push_constant = a.push_constant if a.push_constant != nil else b.push_constant;

    result.descriptor_bindings = make([]Glsl_Descriptor_Binding, len(a.descriptor_bindings) + len(b.descriptor_bindings));

    defer {
        if !ok {
            delete(result.descriptor_bindings);
        }
    }

    
    combine_stuff :: proc(acollection, bcollection, result_collection : $T) -> bool{
        int_set := make(map[int]bool);
        defer delete(int_set);
        i := 0;
        for thing in acollection {
            if thing.location in int_set {
                log.error("Multiply used location/binding ", thing.location);
                return false;
            }
            int_set[thing.location] = true;
            result_collection[i] = thing;
            i += 1;
        }
        for thing in bcollection {
            if thing.location in int_set {
                log.error("Multiply used location/binding ", thing.location);
                return false;
            }
            int_set[thing.location] = true;
            result_collection[i] = thing;
            i += 1;
        }

        return true;
    }

    combine_stuff(a.descriptor_bindings, b.descriptor_bindings, result.descriptor_bindings) or_return;
    //combine_stuff(a.inputs, b.inputs, result.inputs) or_return;
    //combine_stuff(a.outputs, b.outputs, result.outputs) or_return;

    return result, true;
}

Glsl_Inspect_Error_Kind :: enum {
    NONE,
    PARSE_ERROR,
    MISSING_LOCATION_QUALIFIER
}
Glsl_Inspect_Error :: struct {
    kind : Glsl_Inspect_Error_Kind,
    str : string,

    // Non-nil if error kind is .PARSE_ERROR
    parse_err : ^Glsl_Parse_Error,
}
make_inspect_err :: proc(kind : Glsl_Inspect_Error_Kind, str : string) -> Glsl_Inspect_Error {
    return {
        kind=kind,
        str=str,
        parse_err=nil,
    };
}

glsl_type_to_vk_format :: proc(type : Glsl_Type_Kind) -> vk.Format {
    switch (type) {
        case .INT:    return .R32_SINT;
        case .UINT:   return .R32_UINT;
        case .FLOAT:  return .R32_SFLOAT;
        case .DOUBLE: return .R64_SFLOAT;
        case .BOOL:   return .R32_SINT;
        case .VEC2:   return .R32G32_SFLOAT;
        case .VEC3:   return .R32G32B32_SFLOAT;
        case .VEC4:   return .R32G32B32A32_SFLOAT;
        case .IVEC2:  return .R32G32_SINT;
        case .IVEC3:  return .R32G32B32_SINT;
        case .IVEC4:  return .R32G32B32A32_SINT;
        case .UVEC2:  return .R32G32_UINT;
        case .UVEC3:  return .R32G32B32_UINT;
        case .UVEC4:  return .R32G32B32A32_UINT;
        case .DVEC2:  return .R64G64_SFLOAT;
        case .DVEC3:  return .R64G64B64_SFLOAT;
        case .DVEC4:  return .R64G64B64A64_SFLOAT;
        case .BVEC2:  return .R32G32_SINT;    
        case .BVEC3:  return .R32G32B32_SINT;  
        case .BVEC4:  return .R32G32B32A32_SINT;  
        case .MAT2, .MAT3, .MAT4, 
        .MAT4x3, .MAT4x2, .MAT3x2, .MAT3x4,
        .MAT2x3, .MAT2x4, .SAMPLER1D, .SAMPLER2D, 
        .SAMPLER3D, .USER_TYPE, .ARRAY, .VOID:
            panic(fmt.tprintf("Vulkan does not have format for type %s\n", type));
    }
    panic(fmt.tprintf("Vulkan does not have format for type %s\n", type));
}

inspect_glsl :: proc(src : string, stage : Glsl_Stage_Kind) -> (info : Glsl_Stage_Info, err : Glsl_Inspect_Error) {

    init_glsl_parser(&info.parser);

    // #Leak ?
    src_file := lex_source(&info.parser.lexer, src);

    top_scope, parse_err := parse_glsl(&info.parser);

    if parse_err != nil {
        // Format the parse error
        err.kind = .PARSE_ERROR;
        err.parse_err = parse_err;

        switch v in parse_err.variant {
            case Glsl_Parse_Error_Unexpected_Token: {
                exp_string : string;
                switch exp in v.expected {
                    case string: exp_string = exp;
                    case ^Token: exp_string = exp.name;
                }
                err.str = fmt.tprintf("Unexpected token. Expected '%s', got:\n%s", exp_string, tprint_token(v.got));
            } 
            case Glsl_Parse_Error_Version_Already_Specified: {
                err.str = fmt.tprintf("Glsl version was specified more than once. First here:\n%s\n... Then here:\n%s", tprint_token(v.last_specified_token), tprint_token(v.now_specified_token));
            }
            case Glsl_Parse_Error_Unknown_Qualifier: {
                err.str = fmt.tprintf("Unknown qualifier '%s':\n%s", v.token.name, tprint_token(v.token));
            }
            case Glsl_Parse_Error_Undeclared_Identifier: {
                err.str = fmt.tprintf("Undeclared identifier '%s':\n%s", v.token.name, tprint_token(v.token));
            }
            case Glsl_Parse_Error_Unexpected_Eof: {
                err.str = fmt.tprintf("Unexpected end of file:\n%s", tprint_token(v.token));
            }
        }

        return;
    }

    info.version = info.parser.version;
    info.layout.local_size_x = 1;
    info.layout.local_size_y = 1;
    info.layout.local_size_z = 1;

    layout := &info.layout;

    layout.stage = stage;
    layout.types = make([]Glsl_Type, len(top_scope.types));

    convert_type :: proc(ast_type : ^Glsl_Ast_Type_Decl, type : ^Glsl_Type, all_types : []Glsl_Type) {
        type.kind = ast_type.kind;
        type.size = ast_type.size;
        type.std140_size = ast_type.std140_size;
        type.std430_size = ast_type.std430_size;

        if ast_type.elem_type != nil {
            type.elem_type = &all_types[ast_type.elem_type.type_index]; // This gets converted later
            type.elem_count = ast_type.elem_count;
        }

        type.name = ast_type.ident.name;
    }

    for ast_type,i in top_scope.types {
        convert_type(ast_type, &layout.types[i], layout.types);
    }

    descriptor_bindings := make([dynamic]Glsl_Descriptor_Binding);
    inputs := make([dynamic]Glsl_IO_Item);
    outputs := make([dynamic]Glsl_IO_Item);

    get_qual :: proc(item : ^Glsl_Ast_Layout_Item, kind : Glsl_Layout_Qualifier_Kind) -> ^Glsl_Ast_Layout_Qualifier {
        for qual in item.qualifiers {
            if qual.kind == kind {
                return qual;
            }
        }
        return nil;
    }

    
    for item in top_scope.layout {
        switch item.kind {
            case .IN: {
                if item.decl == nil {
                    for qual in item.qualifiers {
                        if qual.kind == .local_size_x {
                            info.layout.local_size_x = qual.value.(int);
                        } else if qual.kind == .local_size_y {
                            info.layout.local_size_y = qual.value.(int);
                        } else if qual.kind == .local_size_z {
                            info.layout.local_size_z = qual.value.(int);
                        }
                    }
                    break;
                }

                fallthrough;
            }
            case .OUT: {
                io : Glsl_IO_Item;

                io.kind = .IN if item.kind == .IN else .OUT;
                io.stage = stage;

                location_qual := get_qual(item, .location);
                if location_qual == nil || location_qual.value == nil {
                    return {}, make_inspect_err(.MISSING_LOCATION_QUALIFIER, fmt.tprintf("Missing location qualifier for layout input/output\n%s", tprint_token(item.token)));
                }

                io.location = location_qual.value.(int);

                io.field.type = &layout.types[item.decl.type.type_index];
                io.field.name = item.decl.ident.name;

                append(&inputs if item.kind == .IN else &outputs, io);
            }
            case .UNIFORM: {
                if get_qual(item, .push_constant) != nil {
                    ps : Glsl_Field;
                    
                    ps.type = &layout.types[item.decl.type.type_index];
                    ps.name = item.decl.ident.name;
                    
                    layout.push_constant = ps;
                    break;
                }

                db : Glsl_Descriptor_Binding;
                db.stage = stage;
                
                switch item.storage_specifier {
                    case .IN, .OUT: {panic("You should not be here...")};

                    case .BUFFER: db.kind = .STORAGE_BUFFER;

                    case .UNIFORM: {
                        if is_glsl_type_sampler_descriptor(item.decl.type.kind) || (item.decl.type.kind == .ARRAY && is_glsl_type_sampler_descriptor(item.decl.type.elem_type.kind)) {
                            db.kind = .SAMPLER;
                        } else {
                            db.kind = .UNIFORM_BUFFER;
                        }
                    }
                }

                switch db.kind {
                    case .SAMPLER: {
                        layout.num_samplers += 1;
                    }
                    case .STORAGE_BUFFER: {
                        layout.num_sbos += 1;
                    }
                    case .UNIFORM_BUFFER: {
                        layout.num_ubos += 1;
                    }
                }

                location_qual := get_qual(item, .binding);
                if location_qual == nil || location_qual.value == nil {
                    return {}, make_inspect_err(.MISSING_LOCATION_QUALIFIER, fmt.tprintf("Missing 'binding'' qualifier for layout input/output\n%s", tprint_token(item.token)));
                }

                db.location = location_qual.value.(int);

                db.field.type = &layout.types[item.decl.type.type_index];
                db.field.name = item.decl.ident.name;

                append(&descriptor_bindings, db);
            }
        }
    }

    layout.descriptor_bindings = descriptor_bindings[:];
    layout.inputs = inputs[:];
    layout.outputs = outputs[:];

    return;
}

free_glsl_inspect_info :: proc(info : ^Glsl_Stage_Info) {
    destroy_glsl_parser(&info.parser);
}



/*
// #Incomplete
Glsl_Type_Kind :: enum {
    INT, UINT, FLOAT, DOUBLE, BOOL,
    VEC2, VEC3, VEC4,
    IVEC2, IVEC3, IVEC4,
    UVEC2, UVEC3, UVEC4,
    DVEC2, DVEC3, DVEC4,
    BVEC2, BVEC3, BVEC4,
    MAT4, MAT3, MAT2,
    MAT4x3, MAT4x2,
    MAT3x2, MAT3x4,
    MAT2x3, MAT2x4,
    SAMPLER1D, SAMPLER2D, SAMPLER3D,
    USER_TYPE, ARRAY, VOID
}
parse_glsl_type :: proc(type_token : ^Token, loc := #caller_location) -> (Glsl_Type_Kind, bool) {
    type_str := type_token.name;
    if len(type_str) < len("int") do panic(fmt.tprintf("Invalid glsl vec type '%s'", type_str));

    first3 := type_str[:3];

    if type_str == "float" {
        return .FLOAT, true; 
    } else if first3 == "mat" {

        if len(type_str) == len("matX") {
            mat_len := type_str[3:4];
            if mat_len == "2" do return .MAT2, true;
            if mat_len == "3" do return .MAT3, true;
            if mat_len == "4" do return .MAT4, true;
        } else if len(type_str) == len("matXxX") {
            left, okleft := strconv.parse_int(type_str[3:4]);
            right, okright := strconv.parse_int(type_str[5:6]);
            assert(okleft && okright);
            if !okleft || !okright {
                log.errorf("Invalid mat type\n%s", tprint_token(type_token));
                return .VOID, false;
            }
            if left == 2 || right == 2 do return .MAT2, true;
            if left == 3 || right == 3 do return .MAT3, true;
            if left == 4 || right == 4 do return .MAT4, true;

            if left == 4 || right == 3 do return .MAT4x3, true;
            if left == 4 || right == 2 do return .MAT4x2, true;
            if left == 3 || right == 2 do return .MAT3x2, true;
            if left == 3 || right == 4 do return .MAT3x4, true;
            if left == 2 || right == 3 do return .MAT2x3, true;
            if left == 2 || right == 4 do return .MAT2x4, true;
        }

        panic(fmt.tprintf("Invalid glsl vec type '%s'", type_str));
    } else if first3 == "vec" {
        vec_len := type_str[3:4];
        if vec_len == "2" do return .VEC2, true;
        if vec_len == "3" do return .VEC3, true;
        if vec_len == "4" do return .VEC4, true;
        panic(fmt.tprintf("Invalid glsl vec type '%s'", type_str));
    } else if len(type_str) >= len("xvec") {
        assert(len(type_str) == 5);

        vec_start := type_str[:1];
        vec_len := type_str[4:5];

        if vec_start == "i" {
            if vec_len == "2" do return .IVEC2, true;
            if vec_len == "3" do return .IVEC3, true;
            if vec_len == "4" do return .IVEC4, true;
        } else if vec_start == "u" {
            if vec_len == "2" do return .UVEC2, true;
            if vec_len == "3" do return .UVEC3, true;
            if vec_len == "4" do return .UVEC4, true;
        } else if vec_start == "d" {
            if vec_len == "2" do return .DVEC2, true;
            if vec_len == "3" do return .DVEC3, true;
            if vec_len == "4" do return .DVEC4, true;
        } else if vec_start == "b" {
            if vec_len == "2" do return .BVEC2, true;
            if vec_len == "3" do return .BVEC3, true;
            if vec_len == "4" do return .BVEC4, true;
        }
        panic(fmt.tprintf("Invalid glsl vec type '%s'", type_str));
    } else if (type_str[0:7] == "sampler") {
        dimensions := type_str[7:8];
        if dimensions == "1" do return .SAMPLER1D, true;
        if dimensions == "2" do return .SAMPLER2D, true;
        if dimensions == "3" do return .SAMPLER3D, true;
        panic(fmt.tprintf("Invalid glsl vec type '%s'", type_str));
    } else if type_str == "int" {
        return .INT, true;
    } else if type_str == "uint" {
        return .UINT, true;
    } else if type_str == "double" {
        return .DOUBLE, true;
    } else if type_str == "bool" {
        return .BOOL, true;
    } else {
        return .USER_TYPE, true;
    }
}
get_glsl_type_size :: proc(type : Glsl_Type_Kind, loc := #caller_location) -> int {
    switch (type) {
    case .VOID:
        return 0;
    case .BOOL, .INT, .UINT, .FLOAT, .SAMPLER1D, .SAMPLER2D, .SAMPLER3D:
        return 4;
    case .DOUBLE, .VEC2, .UVEC2, .IVEC2, .BVEC2:
        return 8;
    case .VEC3, .UVEC3, .IVEC3, .BVEC3:
        return 12;
    case .DVEC2, .VEC4, .UVEC4, .IVEC4, .BVEC4, .MAT2:
        return 16;
    case .DVEC3, .MAT3x2, .MAT2x3:
        return 24;
    case .DVEC4, .MAT4x2, .MAT2x4:
        return 32;
    case .MAT3:
        return 36;
    case .MAT4x3, .MAT3x4:
        return 48;
    case .MAT4:
        return 64;
    case .USER_TYPE: panic("Cannot get size of glsl type USER_TYPE", loc);
    case .ARRAY: panic("Cannot get size of glsl type ARRAY", loc);
    }
    panic("whut");
}

glsl_type_to_vk_format :: proc(type : Glsl_Type_Kind) -> vk.Format {
    switch (type) {
        case .INT:    return .R32_SINT;
        case .UINT:   return .R32_UINT;
        case .FLOAT:  return .R32_SFLOAT;
        case .DOUBLE: return .R64_SFLOAT;
        case .BOOL:   return .R32_SINT;
        case .VEC2:   return .R32G32_SFLOAT;
        case .VEC3:   return .R32G32B32_SFLOAT;
        case .VEC4:   return .R32G32B32A32_SFLOAT;
        case .IVEC2:  return .R32G32_SINT;
        case .IVEC3:  return .R32G32B32_SINT;
        case .IVEC4:  return .R32G32B32A32_SINT;
        case .UVEC2:  return .R32G32_UINT;
        case .UVEC3:  return .R32G32B32_UINT;
        case .UVEC4:  return .R32G32B32A32_UINT;
        case .DVEC2:  return .R64G64_SFLOAT;
        case .DVEC3:  return .R64G64B64_SFLOAT;
        case .DVEC4:  return .R64G64B64A64_SFLOAT;
        case .BVEC2:  return .R32G32_SINT;    
        case .BVEC3:  return .R32G32B32_SINT;  
        case .BVEC4:  return .R32G32B32A32_SINT;  
        case .MAT2, .MAT3, .MAT4, 
        .MAT4x3, .MAT4x2, .MAT3x2, .MAT3x4,
        .MAT2x3, .MAT2x4, .SAMPLER1D, .SAMPLER2D, 
        .SAMPLER3D, .USER_TYPE, .ARRAY, .VOID:
            panic(fmt.tprintf("Vulkan does not have format for type %s\n", type));
    }
    panic(fmt.tprintf("Vulkan does not have format for type %s\n", type));
}

Glsl_Stage_Info :: struct {
    version  : int,
    inputs   : []Glsl_Layout_Input,
    outputs  : []Glsl_Layout_Output,
    uniforms : []Glsl_Uniform,
    storage_buffers : []Glsl_Uniform,
    push_constants : []Glsl_Push_Constant,

    local_size_x, local_size_y, local_size_z : int,
}
Glsl_Type :: struct {
    size : int,
    kind : Glsl_Type_Kind,
    name : string,
    elem_size : int, // Different from size if kind == .ARRAY
    elem_kind : Glsl_Type_Kind,
    elem_name : string,
    members : []Glsl_Field,
}
Glsl_Field :: struct {
    name : string,
    type : Glsl_Type,
    offset : int,
}
Glsl_Uniform :: struct {
    binding : int,
    using field : Glsl_Field,
}
Glsl_Layout_Input :: struct {
    location : int,
    using field : Glsl_Field,
}
Glsl_Layout_Output :: struct {
    location : int,
    using field : Glsl_Field,
}
Glsl_Push_Constant :: struct {
    using field : Glsl_Field,
}

Uniform_Member_Location :: struct {
    binding : int,
    offset : int,
}
get_uniform_binding :: proc(info : Glsl_Stage_Info, name : string) -> int {
    info := get_uniform_info(info, name);
    return info.binding if info != nil else -1;
}
// Returns null if uniform not present
get_uniform_info :: proc(info : Glsl_Stage_Info, name : string) -> ^Glsl_Uniform {
    for u,i in info.uniforms {
        if u.field.name == name do return &info.uniforms[i];
    }
    return nil;
}
get_uniform_member_location_by_uniform_info :: proc(uniform : ^Glsl_Uniform, member_name : string) -> (loc :Uniform_Member_Location) {
    loc.binding = uniform.binding;
    loc.offset = -1;

    if uniform.type.members != nil {
        for m in uniform.type.members {
            if m.name == member_name {
                loc.offset = m.offset;
                break;
            }
        }
    }

    return;
}
get_uniform_member_location_by_uniform_name :: proc(info : Glsl_Stage_Info, uniform_name : string, member_name : string) -> Uniform_Member_Location {
    return get_uniform_member_location_by_uniform_info(get_uniform_info(info, uniform_name), member_name);
}
get_uniform_member_location :: proc {
    get_uniform_member_location_by_uniform_name,
    get_uniform_member_location_by_uniform_info,
}

inspect_glsl :: proc(src : string) -> Glsl_Stage_Info {

    backup_allocator := context.allocator;

    // Allocate all parsing stuff in pools and free the pools when done
    parse_mem : mem.Dynamic_Pool;
    mem.dynamic_pool_init(&parse_mem);
    context.allocator = mem.dynamic_pool_allocator(&parse_mem);
    defer mem.dynamic_pool_destroy(&parse_mem);

    lexer : Lexer = make_lexer();
    source_file := lex_source(&lexer, src);

    ast := parse_glsl(&lexer);
    /*fmt.println(ast);
    for type in ast.types {
        fmt.println("type:", type);
        if type.kind == .USER_TYPE {
            utype := cast(^Inter_User_Type)type;
            for member in utype.members {
                fmt.printf("\t%s : %i : %s\n", member.name, member.offset, fmt.tprint(ast.types[member.type_index]^));
            }
        }
    }
    for input in ast.inputs {
        fmt.println("input:", input, "|", input.base);
    }
    for output in ast.outputs {
        fmt.println("output:", output, "|", output.base);
    }
    for uniform in ast.uniforms {
        fmt.println("uniform:", uniform, "|", uniform.base);
    }*/

    //
    // Allocate result in the caller context allocator
    context.allocator = backup_allocator;

    info : Glsl_Stage_Info;

    info.version  = ast.version;
    if len(ast.inputs) > 0   do info.inputs   = make([]Glsl_Layout_Input, len(ast.inputs));
    if len(ast.outputs) > 0  do info.outputs  = make([]Glsl_Layout_Output, len(ast.outputs));
    if len(ast.uniforms) > 0 do info.uniforms = make([]Glsl_Uniform, len(ast.uniforms));
    if len(ast.storage_buffers) > 0 do info.storage_buffers = make([]Glsl_Uniform, len(ast.storage_buffers));
    if len(ast.push_constants) > 0 do info.push_constants = make([]Glsl_Push_Constant, len(ast.push_constants));

    convert_type :: proc(ast : ^AST_Stage, parsed_type : ^Inter_Type) -> Glsl_Type {
        type : Glsl_Type;
        type.kind = parsed_type.kind;
        type.size = parsed_type.size;
        type.name = strings.clone(parsed_type.name) // #Leak;
        type.elem_kind = type.kind;
        type.elem_size = type.size;
        type.elem_name = type.name;
        
        if parsed_type.kind == .USER_TYPE {
            utype := cast(^Inter_User_Type)parsed_type;
            type.members = make([]Glsl_Field, len(utype.members));

            for _, i in type.members {
                member := &type.members[i];
                parsed_member := utype.members[i];

                member.name = strings.clone(parsed_member.name); // #Memory #Speed #Fragmentation
                member.offset = parsed_member.offset;

                member.type = convert_type(ast, ast.types[parsed_member.type_index]);
            }
        } else if parsed_type.kind == .ARRAY {
            atype := cast(^Inter_Array_Type)parsed_type;
            type.elem_kind = atype.elem_type.kind;
            type.elem_size = atype.size / atype.count;
            type.elem_name = strings.clone(atype.elem_type.name); // #Leak
        }

        return type;
    }

    for _, i in info.inputs {
        input := &info.inputs[i];
        parsed := ast.inputs[i];
        parsed_type := ast.types[parsed.type_index];

        input.location = parsed.location;
        input.field.name = strings.clone(parsed.name); // #Memory #Speed #Fragmentation
        input.field.type = convert_type(ast, parsed_type);
    }
    for _, i in info.outputs {
        output := &info.outputs[i];
        parsed := ast.outputs[i];
        parsed_type := ast.types[parsed.type_index];

        output.location = parsed.location;
        output.field.name = strings.clone(parsed.name); // #Memory #Speed #Fragmentation
        output.field.type = convert_type(ast, parsed_type);
    }
    for _, i in info.uniforms {
        uniform := &info.uniforms[i];
        parsed := ast.uniforms[i];
        parsed_type := ast.types[parsed.type_index];

        uniform.binding = parsed.binding;
        uniform.field.name = strings.clone(parsed.name); // #Memory #Speed #Fragmentation
        uniform.field.type = convert_type(ast, parsed_type);
    }
    for _, i in info.push_constants {
        ps := &info.push_constants[i];
        parsed := ast.push_constants[i];
        parsed_type := ast.types[parsed.type_index];

        ps.field.name = strings.clone(parsed.name); // #Memory #Speed #Fragmentation
        ps.field.type = convert_type(ast, parsed_type);
    }

    info.local_size_x = ast.local_size_x;
    info.local_size_y = ast.local_size_y;
    info.local_size_z = ast.local_size_z;

    return info;
}

free_glsl_inspect_info :: proc(info : Glsl_Stage_Info) {
    free_type :: proc(type : Glsl_Type) {
        for m in type.members {
            delete(m.name);
            free_type(m.type);
        }
    }
    free_field :: proc(field : Glsl_Field) {
        free_type(field.type);
        delete(field.name);
    }
    for input in info.inputs do free_field(input.field);
    if info.inputs != nil   do delete(info.inputs);

    for output in info.outputs do free_field(output.field);
    if info.outputs != nil  do delete(info.outputs);

    for uniform in info.uniforms do free_field(uniform.field);
    if info.uniforms != nil do delete(info.uniforms);

    for b in info.storage_buffers do free_field(b.field);
    if info.storage_buffers != nil do delete(info.storage_buffers);

    for ps in info.push_constants do free_field(ps.field);
    if info.push_constants != nil do delete(info.push_constants);
}


Inter_Type :: struct {
    name : string,
    kind : Glsl_Type_Kind,
    size : int,
}
Inter_User_Type :: struct {
    using base : Inter_Type,
    trailing_padding : int,
    total_padding : int,
    alignment : int,
    members : []Inter_Field, // Only for .USER_TYPE
}
Inter_Array_Type :: struct {
    using base : Inter_Type,

    elem_type : ^Inter_Type,
    count : int,
}
Inter_Field :: struct {
    name : string,
    type_index : int,
    offset : int,
}

AST_Stage :: struct {
    version : int,
    types : [dynamic]^Inter_Type,

    inputs         : [dynamic]^AST_Input,
    outputs        : [dynamic]^AST_Output,
    uniforms       : [dynamic]^AST_Uniform,
    storage_buffers : [dynamic]^AST_Uniform,
    push_constants : [dynamic]^AST_Push_Constant,

    local_size_x, local_size_y, local_size_z : int,
}
AST_Node :: struct {
    token : ^Token,
    variant : union {
        AST_Input, AST_Output,
        AST_Uniform, AST_Var_Decl,
        AST_Function, AST_Push_Constant
    },
}

AST_Define :: struct {
    using base : ^AST_Node,
    /* */
}
AST_Var_Decl :: struct {
    using base : ^AST_Node,
    type_index : int,
    name : string,
}
AST_Input :: struct {
    using var_decl_base : AST_Var_Decl,
    location : int,
}
AST_Output :: struct {
    using var_decl_base : AST_Var_Decl,
    location : int,
}
AST_Uniform :: struct {
    using var_decl_base : AST_Var_Decl,
    binding : int,
}
AST_Push_Constant :: struct {
    using var_decl_base : AST_Var_Decl,
    
}
AST_Function :: struct {
    using base : ^AST_Node,
    /* */
}

make_ast :: proc($T : typeid, token : ^Token) -> ^T {
    ast := new(AST_Node);
    ast.token = token;
    ast.variant = T{};
    var := &ast.variant.(T);
    var.base = ast;

    return var;
}

get_type_index :: proc(ast : ^AST_Stage, type_name : string) -> int{
    for type, i in ast.types {
        if type.name == type_name do return i;
    }
    return -1;
}

Glsl_Storage_Kind :: enum {
    PACKED,
    STD140,
}
make_array_type :: proc (ast : ^AST_Stage, elem_type : ^Inter_Type, count : int) -> int {
    type := new(Inter_Array_Type);
    type.name = fmt.tprintf("%s[%i]", elem_type.name, count);
    type.kind = .ARRAY;
    type.size = count * elem_type.size;
    type.elem_type = elem_type;
    type.count = count;

    append(&ast.types, type);

    return len(ast.types)-1;
}
parse_and_arrayify_if_array :: proc(ast : ^AST_Stage, lexer : ^Lexer, type_index : int) -> int {
    first := lexer_peek(lexer);
    if first.kind != .OPEN_BRACK do return type_index;

    lexer_eat(lexer);
    count_token := lexer_eat(lexer);
    close_brack := lexer_eat(lexer);
    assert(count_token.kind == .LITERAL_INT);
    assert(close_brack.kind == .CLOSE_BRACK);

    type := ast.types[type_index];

    return make_array_type(ast, type, count_token.literal.(int));
}
parse_type_expression :: proc(ast : ^AST_Stage, lexer : ^Lexer, storage_if_struct : Glsl_Storage_Kind) -> int {
    type_token := lexer_peek(lexer, -1);
    after_token := lexer_peek(lexer);

    type_index : int;
    if after_token.kind == .OPEN_BRACE {
        lexer_eat(lexer);
        type_index = parse_user_type(lexer, ast, lexer_peek(lexer, -2).name, storage_if_struct);
    } else {
        assert(type_token.kind == .IDENTIFIER)
        type_index = get_type_index(ast, type_token.name);
        assert(type_index != -1);
    }

    after_token = lexer_peek(lexer);

    if after_token.kind == .OPEN_BRACK {
        lexer_eat(lexer);
        count_tok := lexer_eat(lexer);
        close_brack := lexer_eat(lexer);
        assert(close_brack.kind == .CLOSE_BRACK);
        after_token = lexer_eat(lexer);
        elem_type := ast.types[type_index];

        type_index = make_array_type(ast, elem_type, count_tok.literal.(int));
    }

    return type_index;
}
parse_user_type :: proc(lexer : ^Lexer, ast : ^AST_Stage, type_name : string, storage_kind : Glsl_Storage_Kind) -> int {
    
    first := lexer_peek(lexer, -1);
    assert(first.kind == .OPEN_BRACE);
    type := new(Inter_User_Type);
    type.kind = .USER_TYPE;
    type.name = strings.clone(type_name); // #Leak

    members := make([dynamic]Inter_Field); // #Leak
    current_chunk := 0;

    switch storage_kind {
        case .PACKED: {
            type.alignment = 1;
        }
        case .STD140: {
            type.alignment = 16;
        }
    }

    for next := lexer_eat(lexer); next.kind != .CLOSE_BRACE; next = lexer_eat(lexer) {
        type_token := next;
        
        f : Inter_Field;
        f.type_index = parse_type_expression(ast, lexer, storage_kind);
        name_token := lexer_eat(lexer);
        assert(name_token.kind == .IDENTIFIER);
        f.name = strings.clone(name_token.name);
        f.type_index = parse_and_arrayify_if_array(ast, lexer, f.type_index);
        
        semicolon := lexer_eat(lexer);
        assert(semicolon.kind == .SEMICOLON);
        
        member_type := ast.types[f.type_index];
        
        if storage_kind == .STD140 {
            
            if current_chunk != 0 && current_chunk + member_type.size > type.alignment {
                padding := type.alignment - current_chunk;
                type.size += padding;
                assert((type.size % type.size) == 0);
                type.total_padding += padding;
                current_chunk = 0;
            }
            misaligned := type.alignment - member_type.size % type.alignment;
            current_chunk = type.alignment - (current_chunk + misaligned) % type.alignment;
            
        }
        
        f.offset = type.size;
        type.size += member_type.size;
        append(&members, f);
    }
    if storage_kind == .STD140 {
        padding := type.alignment - current_chunk;
        type.size += padding;
        type.total_padding += padding;
        type.trailing_padding = padding;
    }

    type.members = members[:];

    append(&ast.types, type);
    return len(ast.types)-1;
}

// TODO #Incomplete #Errors
// Return errors instead of asserting/panicking
parse_glsl :: proc(lexer : ^Lexer) -> ^AST_Stage {
    ast := new(AST_Stage);
    ast.types          = make([dynamic]^Inter_Type, 0, 32);
    ast.inputs         = make([dynamic]^AST_Input, 0, 32);
    ast.outputs        = make([dynamic]^AST_Output, 0, 32);
    ast.uniforms       = make([dynamic]^AST_Uniform, 0, 32);
    ast.storage_buffers = make([dynamic]^AST_Uniform, 0, 32);
    ast.push_constants = make([dynamic]^AST_Push_Constant, 0, 32);

    for i in 0..<len(Glsl_Type_Kind) {
        kind := cast(Glsl_Type_Kind)i;

        if kind == .USER_TYPE || kind == .ARRAY do continue;



        size := get_glsl_type_size(kind);

        type := new(Inter_Type);
        type.kind = kind;
        type.size = size;

        if      kind == .SAMPLER1D do type.name = "sampler1D";
        else if kind == .SAMPLER2D do type.name = "sampler2D";
        else if kind == .SAMPLER3D do type.name = "sampler3D";
        else do type.name = strings.clone(strings.to_lower(fmt.tprintf("%s", kind))); //#Leak
 
        append(&ast.types, type);
    }

    for first := lexer_eat(lexer); first != nil && first.kind != .EOF; first = lexer_eat(lexer) {

        for first.kind == .SEMICOLON {
            first = lexer_eat(lexer);
        }
        
        if first.kind == .HASH {
            next := lexer_eat(lexer);
            if next.name == "version" {
                version_number_token := lexer_eat(lexer);
                assert(version_number_token.kind == .LITERAL_INT);
                
                ast.version = version_number_token.literal.(int);
            }
        } else if first.kind == .KW_LAYOUT {
            open_par := lexer_eat(lexer);
            assert(open_par.kind == .OPEN_PAR);
            
            layout_kind_token := lexer_eat(lexer);
            
            if layout_kind_token.kind == .KW_PUSH_CONSTANT {
                close_par := lexer_eat(lexer);
                assert(close_par.kind == .CLOSE_PAR);

                uniform_token := lexer_eat(lexer);
                assert(uniform_token.kind == .KW_UNIFORM);

                lexer_eat(lexer); // eat type token
                ps := make_ast(AST_Push_Constant, layout_kind_token);
                ps.type_index = parse_type_expression(ast, lexer, .STD140);
                var_name := lexer_peek(lexer);
                if var_name.kind == .IDENTIFIER {
                    lexer_eat(lexer);
                    ps.name = var_name.name;
                } else {
                    ps.name = "GLOBAL"; // Unnamed
                }
                ps.type_index = parse_and_arrayify_if_array(ast, lexer, ps.type_index);

                append(&ast.push_constants, ps);

            } else if layout_kind_token.kind == .KW_LOCAL_SIZE_X {
                eq_token := lexer_eat(lexer);
                assert(eq_token.kind == .EQUALS);
                number_token := lexer_eat(lexer);
                assert(number_token.kind == .LITERAL_INT);
                ast.local_size_x = number_token.literal.(int);

                next := lexer_peek(lexer);
                if next.kind == .COMMA {
                    lexer_eat(lexer);
                    layout_kind_token = lexer_eat(lexer);
                    assert(layout_kind_token.kind == .KW_LOCAL_SIZE_Y);
                    number_token = lexer_eat(lexer);
                    assert(number_token.kind == .LITERAL_INT);
                    ast.local_size_y = number_token.literal.(int);
                    next = lexer_peek(lexer);
                }
                if next.kind == .COMMA {
                    lexer_eat(lexer);
                    layout_kind_token = lexer_eat(lexer);
                    assert(layout_kind_token.kind == .KW_LOCAL_SIZE_Z);
                    number_token = lexer_eat(lexer);
                    assert(number_token.kind == .LITERAL_INT);
                    ast.local_size_z = number_token.literal.(int);
                }


                close_par := lexer_eat(lexer);
                assert(close_par.kind == .CLOSE_PAR);
                in_token := lexer_eat(lexer);
                assert(in_token.kind == .KW_IN);

            } else if layout_kind_token.kind == .KW_LOCAL_SIZE_Y {
                eq_token := lexer_eat(lexer);
                assert(eq_token.kind == .EQUALS);
                number_token := lexer_eat(lexer);
                assert(number_token.kind == .LITERAL_INT);
                close_par := lexer_eat(lexer);
                assert(close_par.kind == .CLOSE_PAR);
                in_token := lexer_eat(lexer);
                assert(in_token.kind == .KW_IN);

                ast.local_size_y = number_token.literal.(int);
            } else if layout_kind_token.kind == .KW_LOCAL_SIZE_Z {
                eq_token := lexer_eat(lexer);
                assert(eq_token.kind == .EQUALS);
                number_token := lexer_eat(lexer);
                assert(number_token.kind == .LITERAL_INT);
                close_par := lexer_eat(lexer);
                assert(close_par.kind == .CLOSE_PAR);
                in_token := lexer_eat(lexer);
                assert(in_token.kind == .KW_IN);

                ast.local_size_z = number_token.literal.(int);
            } else {
                eq_token := lexer_eat(lexer);
                assert(eq_token.kind == .EQUALS);
                
                number_token := lexer_eat(lexer);
                assert(number_token.kind == .LITERAL_INT);
                
                close_par := lexer_eat(lexer);
                assert(close_par.kind == .CLOSE_PAR);
                
                if layout_kind_token.kind == .KW_LOCATION {
                    inout_token := lexer_eat(lexer);
    
                    if inout_token.kind == .KW_FLAT {
                        inout_token = lexer_eat(lexer);
                    }
    
                    lexer_eat(lexer); // eat type token
                    type_index := parse_type_expression(ast, lexer, .PACKED);
                    var_name_token := lexer_eat(lexer);
                    assert(var_name_token.kind == .IDENTIFIER);
                    var_name := var_name_token.name;
                    type_index = parse_and_arrayify_if_array(ast, lexer, type_index);
                    
                    if inout_token.kind == .KW_IN {
                        input := make_ast(AST_Input, first);
                        input.location = number_token.literal.(int);
                        input.type_index = type_index;
                        input.name = var_name;
                        
                        append(&ast.inputs, input);
                        
                    } else if inout_token.kind == .KW_OUT {
                        output := make_ast(AST_Output, first);
                        output.location = number_token.literal.(int);
                        output.type_index = type_index;
                        output.name = var_name;
    
                        append(&ast.outputs, output);
                    } else {
                        panic(fmt.tprintf("Expected in/out token\n%s",  tprint_token(inout_token)));
                    }
                } else if layout_kind_token.kind == .KW_BINDING {
                    uniform_or_buffer_token := lexer_eat(lexer);

                    assert(uniform_or_buffer_token.kind == .KW_UNIFORM || uniform_or_buffer_token.kind == .KW_BUFFER);
                    uniform := make_ast(AST_Uniform, uniform_or_buffer_token);
                    uniform.binding = number_token.literal.(int);
                    
                    lexer_eat(lexer); // eat type token
                    uniform.type_index = parse_type_expression(ast, lexer, .STD140);
                    var_name := lexer_peek(lexer);
                    if var_name.kind == .IDENTIFIER {
                        lexer_eat(lexer);
                        uniform.name = var_name.name;
                    } else {
                        uniform.name = "GLOBAL"; // Unnamed
                    }
                    uniform.type_index = parse_and_arrayify_if_array(ast, lexer, uniform.type_index);
    
                    if uniform_or_buffer_token.kind == .KW_UNIFORM {
                        append(&ast.uniforms, uniform);
                    } else if uniform_or_buffer_token.kind == .KW_BUFFER {
                        append(&ast.storage_buffers, uniform);
                    }
                } else {
                    panic(fmt.tprintf("Unexpected layout thing '%s':\n%s", layout_kind_token.name, tprint_token(layout_kind_token)));
                }
            }

            
        } else if first.kind == .IDENTIFIER {
            assert(get_type_index(ast, first.name) != -1);

            next := lexer_eat(lexer);

            has_type := get_type_index(ast, next.name) != -1;

            assert(!has_type); // Two types in a row

            next = lexer_eat(lexer);

            if next.kind == .OPEN_PAR { // Funciton
                // Skip until }
                depth := 0;
                for next != nil && next.kind != .EOF && (next.kind != .CLOSE_BRACE || depth > 1) {
                    if next.kind == .OPEN_BRACE do depth += 1;
                    if next.kind == .CLOSE_BRACE do depth -= 1;
                    next = lexer_eat(lexer);
                }
            } else { // Variable probably
                // Skip until semicolon
                for next != nil && next.kind != .EOF && next.kind != .SEMICOLON do next = lexer_eat(lexer);
            }
            
        } else if first.kind == .KW_CONST {
            // Skip until semicolon
            next := lexer_eat(lexer);
            for next != nil && next.kind != .EOF && next.kind != .SEMICOLON do next = lexer_eat(lexer);
        } else {
            log.warnf("Unexpected token, skipping to semi-colon:\n%s", tprint_token(first));
            next := lexer_eat(lexer);
            for next != nil && next.kind != .EOF && next.kind != .SEMICOLON do next = lexer_eat(lexer);
        }
    }
    return ast;
}*/