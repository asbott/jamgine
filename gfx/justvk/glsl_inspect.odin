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

    result.num_samplers = a.num_samplers + b.num_samplers;
    result.num_ubos = a.num_ubos + b.num_ubos;
    result.num_sbos = a.num_sbos + b.num_sbos;

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

                desc_count := 1 if item.decl.type.kind != .ARRAY else item.decl.type.elem_count
                switch db.kind {
                    case .SAMPLER: {
                        layout.num_samplers += desc_count;
                    }
                    case .STORAGE_BUFFER: {
                        layout.num_sbos += desc_count;
                    }
                    case .UNIFORM_BUFFER: {
                        layout.num_ubos += desc_count;
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

