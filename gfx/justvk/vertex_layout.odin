package justvk

import "core:log"
import "core:fmt"
import "core:strings"
import "core:builtin"
import "core:mem"
import "core:slice"
import "core:reflect"
import "core:intrinsics"

import vk "vendor:vulkan"
import "vendor:glfw"

Vertex_Layout :: struct {
    binding    : vk.VertexInputBindingDescription,
    attributes : []vk.VertexInputAttributeDescription,
    stride : int, // #Unused ? This is in binding

    used_allocator : mem.Allocator,
}

make_vertex_layout_from_glsl_layout :: proc(glsl_layout : Glsl_Layout, allocator := context.allocator) -> (layout : Vertex_Layout) {
    context.allocator = allocator;
    using layout;
    used_allocator = allocator; 

    num_fields := len(glsl_layout.inputs);
    attributes = make([]vk.VertexInputAttributeDescription, num_fields);

    offset : int;
    for input, i in glsl_layout.inputs {
        attributes[i].binding = 0;
        attributes[i].location = cast(u32)input.location;
        attributes[i].offset = cast(u32)offset;
        attributes[i].format = glsl_type_to_vk_format(input.field.type.kind);

        offset += get_glsl_type_size(input.field.type.kind);
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