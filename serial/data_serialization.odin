package serial

import "core:encoding/json"
import "core:intrinsics"
import "core:reflect"
import "core:runtime"
import "core:os"
import "core:slice"
import "core:log"
import "core:mem"
import "core:fmt"
import "core:builtin"
import "core:strings"
import "core:path/filepath"

ptr_to_json_int :: proc(ptr : rawptr, type : ^reflect.Type_Info) -> json.Integer {
    val : json.Integer;
    if      type.size == 1  do val = cast(json.Integer)((cast(^i8)ptr)^);
    else if type.size == 2  do val = cast(json.Integer)((cast(^i16)ptr)^);
    else if type.size == 4  do val = cast(json.Integer)((cast(^i32)ptr)^);
    else if type.size == 8  do val = cast(json.Integer)((cast(^i64)ptr)^);
    else if type.size == 16 do val = cast(json.Integer)((cast(^i128)ptr)^);
    else {
        log.warn("Unhandled integer type size", type.size);
        return -1;
    }
    return val;
}
ptr_to_json_float :: proc(ptr : rawptr, type : ^reflect.Type_Info) -> json.Float {
    val : json.Float;
    if type.size == 2       do val = cast(json.Float)((cast(^f16)ptr)^);
    else if type.size == 4  do val = cast(json.Float)((cast(^f32)ptr)^);
    else if type.size == 8  do val = cast(json.Float)((cast(^f64)ptr)^);
    else {
        log.warn("Unhandled float type size", type.size);
        return -1;
    }
    return val;
}
ptr_to_json_bool :: proc(ptr : rawptr, type : ^reflect.Type_Info) -> json.Boolean {
    val : json.Boolean;
    if type.size == 1       do val = cast(json.Boolean)((cast(^bool)ptr)^);
    else if type.size == 4  do val = cast(json.Boolean)((cast(^b32)ptr)^);
    else if type.size == 8  do val = cast(json.Boolean)((cast(^b64)ptr)^);
    else {
        log.warn("Unhandled bool type size", type.size);
        return false;
    }
    return val;
}
ptr_to_json_string :: proc(ptr : rawptr) -> json.String {
    maybe_it := (cast(^string)ptr)^;
    if len(maybe_it) <= 0 || maybe_it == "" do return "";
    return (cast(^string)ptr)^
}
ptr_to_json_array :: proc(start : rawptr, elem_type : ^reflect.Type_Info, count : int) -> json.Array {
    end := mem.ptr_offset(cast(^u8)start, elem_type.size * count);

    if count > 0 {
        arr := make(json.Array, count);

        for i in 0..<count {
            ptr := mem.ptr_offset(cast(^u8)start, i * elem_type.size);
            arr[i] = to_json_value(ptr, elem_type);
        }

        return arr;
    } else {
        return nil;
    }
}

@(thread_local)
seen_member_struct_types_set : [dynamic]^reflect.Type_Info;

to_json_value :: proc(ptr : rawptr, type : ^reflect.Type_Info) -> json.Value {
    #partial switch v in type.variant {

        case reflect.Type_Info_Integer: return ptr_to_json_int(ptr, type);
        case reflect.Type_Info_Float:   return ptr_to_json_float(ptr, type);
        case reflect.Type_Info_Boolean: return ptr_to_json_bool(ptr, type);
        case reflect.Type_Info_String:  {
            return ptr_to_json_string(ptr);
        }
        case reflect.Type_Info_Array: {
            return ptr_to_json_array(ptr, base_or_self(v.elem), v.count);                        
        }
        case reflect.Type_Info_Slice: {
            raw_slice := ((cast(^runtime.Raw_Slice)ptr)^);
            if raw_slice.data == nil do return nil;
            return ptr_to_json_array(raw_slice.data, base_or_self(v.elem), raw_slice.len);
        }
        case reflect.Type_Info_Dynamic_Array: {
            raw_arr := ((cast(^runtime.Raw_Dynamic_Array)ptr)^);
            if raw_arr.data == nil do return nil;
            return ptr_to_json_array(raw_arr.data, base_or_self(v.elem), raw_arr.len);
        }
        case reflect.Type_Info_Map: {
            if true {
                log.error("Map members not supported in synced structs");
                return nil;
            }
            key_type := base_or_self(v.key);
            value_type := base_or_self(v.value);
            raw_map := ((cast(^runtime.Raw_Map)ptr)^);

            arr := make(json.Array);
            
            info := v;

            it_ := 0;
            it := &it_;

            ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw_map, info.map_info)
            for /**/ ; it^ < int(runtime.map_cap(raw_map)); it^ += 1 {
                if hash := hs[it^]; runtime.map_hash_is_valid(hash) {
                    key_ptr   := runtime.map_cell_index_dynamic(ks, info.map_info.ks, uintptr(it^));
                    value_ptr := runtime.map_cell_index_dynamic(vs, info.map_info.vs, uintptr(it^));
                    
                    pair := make(json.Object);
                    pair["k"] = to_json_value(cast(rawptr)key_ptr, key_type);
                    pair["v"] = to_json_value(cast(rawptr)value_ptr, value_type);
                    append(&arr, pair);
                }

            }

            return arr;
        }
        case reflect.Type_Info_Enum: return ptr_to_json_int(ptr, type);
        case reflect.Type_Info_Struct: {

            if has_seen_struct_type(type) {
                log.warnf("Self-referencing member of type '%s' detected; some member(s) will be ignored", type);
                return nil;
            }
            append(&seen_member_struct_types_set, type);
            defer pop(&seen_member_struct_types_set);

            

            return to_json_object(ptr, v, type);
        }

        case reflect.Type_Info_Pointer: {
            pointer_to := base_or_self(v.elem);

            addr := (cast(^uintptr)ptr)^;

            if addr == 0 do return nil;

            #partial switch pv in pointer_to.variant {
                case reflect.Type_Info_Struct: {
                    if has_seen_struct_type(pointer_to) {
                        log.warnf("Self-referencing member of type '%s' detected; some member(s) will be ignored", pointer_to);
                        return nil;
                    }
                    append(&seen_member_struct_types_set, pointer_to);
                    defer pop(&seen_member_struct_types_set);

                    return to_json_object(ptr, pv, pointer_to);
                }
                case: {
                    return to_json_value(ptr, pointer_to);
                }
            }
        }
        case reflect.Type_Info_Matrix: {
            matrix_size := type.size;
            elem_size := v.elem_size;

            if elem_size == 4 {
                return ptr_to_json_array(ptr, base_or_self(v.elem), cast(int)(matrix_size / elem_size));
            } else {
                log.warn("Unsupported matrix element size", elem_size);
                return nil;
            }
        }
        

        case: log.warn("Unsupported type", v, "in synced struct"); return nil;
    }
}

has_seen_struct_type :: proc(type : ^reflect.Type_Info) -> bool {
    for seen in seen_member_struct_types_set {
        if seen == type do return true;
    }
    return false;
}
to_json_object :: proc(ptr : rawptr, struct_info : reflect.Type_Info_Struct, struct_info_base : ^reflect.Type_Info) -> json.Object{
    obj : json.Object = make(json.Object);

    for name, i in struct_info.names {
        type := base_or_self(struct_info.types[i]);
        offset := struct_info.offsets[i];
        member_ptr := mem.ptr_offset(cast(^u8)ptr, offset);

        if strings.to_lower(name) == "noserialize" do continue;

        obj[name] = to_json_value(member_ptr, type);
    }

    return obj;
}
struct_to_json :: proc(item : $T) -> json.Object {

    item := item;
    ptr : rawptr = &item;
    type := base_or_self(type_info_of(T));
    struct_info := type.variant.(reflect.Type_Info_Struct);

    return to_json_object(ptr, struct_info, type);
}

struct_to_json_string :: proc(item : $T, allocator := context.allocator) -> string {
    context.temp_allocator = allocator;

    return tprint_json_obj(struct_to_json(item));
}

struct_to_json_file :: proc(item : $T, path : string) -> bool {
    str := struct_to_json_string(item, context.temp_allocator);

    file, file_err := os.open(path, os.O_WRONLY | os.O_CREATE);

    if file_err == os.ERROR_NONE {
        written, write_err := os.write_string(file, str);
        os.flush(file);
        os.close(file);
        return write_err == os.ERROR_NONE;
    } else {
        log.error("Could not serialize struct ", typeid_of(T));
        return false;
    }
}



tprint_json_value :: proc(value : json.Value, builder : ^strings.Builder) {

    switch v in value {
        case json.Integer: {
            fmt.sbprintf(builder, "%i", v);
        }
        case json.Float: {
            fmt.sbprintf(builder, "%f", v);
        }
        case json.String: {
            fmt.sbprint(builder, "\"");
            fmt.sbprint(builder, encode_string(v, allocator=context.temp_allocator));
            fmt.sbprint(builder, "\"");
        }
        case json.Boolean: {
            fmt.sbprint(builder, v);
        }
        case json.Array: {
            fmt.sbprint(builder, "[");
            for elem,i in v {
                tprint_json_value(elem, builder)

                if i < len(v)-1 do fmt.sbprint(builder, ",");
            }
            fmt.sbprint(builder, "]");
        }
        case json.Object: {
            tprint_json_obj(v, builder);
        }
        case json.Null: {
            fmt.sbprint(builder, "null");
        }
        case: { // nil
            fmt.sbprint(builder, "null");
        }
    }
}


tprint_json_obj :: proc(obj : json.Object, builder : ^strings.Builder = nil, allocator:=context.temp_allocator) -> string {
    context.allocator = allocator;

    builder := builder;
    if builder == nil {
        builder = new(strings.Builder)
        strings.builder_init(builder);
    }

    strings.write_rune(builder, '{');
    i := 0;
    for key, value in obj {
        fmt.sbprint(builder, "\"", key, "\"", ":", sep="");
        tprint_json_value(value, builder);

        if i < len(obj)-1 do fmt.sbprint(builder, ",");
        i += 1;
    }
    strings.write_rune(builder, '}');

    return strings.to_string(builder^);
}

encode_string :: proc(str : string, allocator := context.temp_allocator) -> string {
    context.allocator = allocator;
    builder : strings.Builder;
    strings.builder_init(&builder, 0, cast(int)(f32(len(str)) * 1.2));

    encoded := "";
    first_esc_index := strings.index_any(str, "\n\t\"\\\b\f\r");
    
    if first_esc_index != -1 {

        last_index := -1;
        pos := 0;
        for next_index := first_esc_index; next_index != -1; next_index = strings.index_any(str[pos:], "\n\t\"\\\b\f\r") {
    
            strings.write_string(&builder, str[pos:pos+next_index]);

            esc := str[pos:][next_index];
    
            if esc == '\n'      do strings.write_string(&builder, "\\n");
            else if esc == '\t' do strings.write_string(&builder, "\\t");
            else if esc == '"'  do strings.write_string(&builder, "\\\"");
            else if esc == '\\' do strings.write_string(&builder, "\\\\");
            else if esc == '\b' do strings.write_string(&builder, "\\b");
            else if esc == '\f' do strings.write_string(&builder, "\\f");
            else if esc == '\r' do strings.write_string(&builder, "\\r");
            
            
            pos = pos + next_index + 1;
            
            last_index = next_index;
        }
        if pos < len(str) {
            strings.write_string(&builder, str[pos:]);
        }
        encoded = strings.to_string(builder);
    } else {
        encoded = str;
    }

    
    return encoded;
}

decode_string :: proc(str : string, allocator := context.temp_allocator) -> (string, bool) {

    // Apparently json handles escape sequences ?
    return str, false;
}

base_or_self :: proc(maybe_named : ^reflect.Type_Info) -> ^reflect.Type_Info{
    #partial switch v in maybe_named.variant {
        case reflect.Type_Info_Named: return v.base;
        case: return maybe_named;
    }
    return nil;
}


assign_json_value :: proc(ptr : rawptr, type : ^reflect.Type_Info, name : string, value : json.Value) {

    check_field_is :: proc(name : string, value : json.Value, $T : typeid, do_log := true) -> bool {

        field_type := reflect.union_variant_typeid(value);
        if field_type != typeid_of(T) {
            if do_log do log.warnf("Struct field '%s' expected corresponding field in JSON object to be of type '%s' but it was '%s'", name, typeid_of(T), field_type);
            return false;
        }

        return true;
    }

    #partial switch v in type.variant {
        case reflect.Type_Info_Integer: {
            if !check_field_is(name,value, json.Integer) do return;
            vv := value.(json.Integer);
            mem.copy(ptr, &vv, type.size);
        }
        case reflect.Type_Info_Float:   {
            if !check_field_is(name,value, json.Float) do return;
            if type.size == 2 {
                vv := cast(f16)value.(json.Float);
                mem.copy(ptr, &vv, type.size);
            } else if type.size == 4 {
                vv := cast(f32)value.(json.Float);
                ff := value.(json.Float);
                mem.copy(ptr, &vv, type.size);
            } else if type.size == 8 {
                vv := cast(f64)value.(json.Float);
                mem.copy(ptr, &vv, type.size);
            } else {
                panic("invalid float size");
            }
        }
        case reflect.Type_Info_Boolean: {
            if !check_field_is(name,value, json.Boolean) do return;
            vv := value.(json.Boolean);
            mem.copy(ptr, &vv, type.size);
        }
        case reflect.Type_Info_String:  {
            if !check_field_is(name,value, json.String) do return;
            str_decoded, _ := decode_string(value.(json.String), allocator=context.temp_allocator);
            raw_string := cast(^runtime.Raw_String)ptr;
            if raw_string.data != nil && raw_string.len >= len(str_decoded) {
                assert(raw_string.len < 999999999);
                mem.copy(raw_string.data, builtin.raw_data(str_decoded), raw_string.len);
            } else {
                // #Leak #Cleanup
                ((cast(^string)ptr)^) = strings.clone(str_decoded);

            }
        }
        case reflect.Type_Info_Array: {
            if !check_field_is(name,value, json.Array) do return;
            
            elem_type := base_or_self(v.elem);

            json_len := len(value.(json.Array));

            for i in 0..<min(json_len, v.count) {

                offset := i * v.elem_size;
                assign_json_value(mem.ptr_offset(cast(^u8)ptr, offset), elem_type, fmt.tprint(i), value.(json.Array)[i]);
            }
        }
        case reflect.Type_Info_Slice: {
            if !check_field_is(name,value, json.Array) do return;
            elem_type := base_or_self(v.elem);
            raw_slice := cast(^runtime.Raw_Slice)ptr;
            if raw_slice.len < len(value.(json.Array)) {
                if raw_slice.data != nil do free(raw_slice.data);
                // #Leak #Cleanup
                alloc_err : mem.Allocator_Error;
                raw_slice.data, alloc_err = mem.alloc(len(value.(json.Array)) * v.elem_size, elem_type.align);
                assert(alloc_err == .None);
                raw_slice.len = len(value.(json.Array));
            }
            for i in 0..<min(len(value.(json.Array)), raw_slice.len) {
                offset := i * v.elem_size;
                assign_json_value(mem.ptr_offset(cast(^u8)raw_slice.data, offset), elem_type, fmt.tprint(i), value.(json.Array)[i]);
            }
        }
        case reflect.Type_Info_Dynamic_Array: {
            if !check_field_is(name,value, json.Array) do return;
            elem_type := base_or_self(v.elem);
            raw_arr := cast(^runtime.Raw_Dynamic_Array)ptr;
            if raw_arr.cap < len(value.(json.Array)) {
                if raw_arr.data != nil do free(raw_arr.data, allocator=raw_arr.allocator);
                // #Leak #Cleanup
                alloc_err : mem.Allocator_Error;
                raw_arr.data, alloc_err = mem.alloc(len(value.(json.Array)) * v.elem_size, elem_type.align, allocator=raw_arr.allocator);
                assert(alloc_err == .None);
                raw_arr.cap = len(value.(json.Array));
            }
            raw_arr.len = len(value.(json.Array));
            for i in 0..<raw_arr.len {
                offset := i * v.elem_size;
                assign_json_value(mem.ptr_offset(cast(^u8)raw_arr.data, offset), elem_type, fmt.tprint(i), value.(json.Array)[i]);
            }
        }
        case reflect.Type_Info_Map: {
            log.error("Maps are not supported in synced structs. Deal with it.");
            return;
        }
        case reflect.Type_Info_Enum: {
            if !check_field_is(name,value, json.Integer) do return;

            vv := value.(json.Integer);
            mem.copy(ptr, &vv, type.size);
        }
        case reflect.Type_Info_Struct: {
            if !check_field_is(name,value, json.Object) do return;

            from_json_object(ptr, value.(json.Object), v, type);
        }
        case reflect.Type_Info_Pointer: {
            pointer_to := base_or_self(v.elem);

            #partial switch vp in pointer_to.variant {
                case reflect.Type_Info_Struct: {
                    if !check_field_is(name,value, json.Object) do return;
                    from_json_object(ptr, value.(json.Object), vp, pointer_to);
                }
                case: {
                    // Not sure why we even serialize pointer addresses
                    if !check_field_is(name,value, json.Integer) do return;
                    return;
                }
            }
        }
        case reflect.Type_Info_Matrix: {
            if !check_field_is(name,value, json.Array) do return;

            matrix_count := int(type.size / v.elem_size);

            elem_type := base_or_self(v.elem);
            json_len := len(value.(json.Array));

            for i in 0..<min(json_len, matrix_count) {
                offset := i * v.elem_size;
                assign_json_value(mem.ptr_offset(cast(^u8)ptr, offset), elem_type, fmt.tprint(i), value.(json.Array)[i]);
            }

        }
        case: log.warn("Unsupported type", v, "in synced struct"); return;
    }
}

from_json_object :: proc(data : rawptr, obj : json.Object, struct_info : reflect.Type_Info_Struct, struct_info_base : ^reflect.Type_Info) {

    for name, i in struct_info.names {
        type := base_or_self(struct_info.types[i]);
        offset := struct_info.offsets[i];

        ptr := mem.ptr_offset(cast(^u8)data, offset);

        if name not_in obj do continue;
        assign_json_value(ptr, type, name, obj[name]);

    }
}

json_object_to_struct :: proc(obj : json.Object, $T : typeid) -> T {
    type := base_or_self(type_info_of(T));
    struct_info := type.variant.(reflect.Type_Info_Struct);

    data : T;
    from_json_object(&data, obj, struct_info, type);

    return data;
}
json_string_to_struct :: proc(str : string, $T : typeid) -> (result : T, ok : bool) {
    // #Leak json object, not sure if we copy the strings from it even
    bytes : []byte = mem.byte_slice(builtin.raw_data(str), len(str));
    obj, err := json.parse(bytes, spec=json.Specification.JSON5, parse_integers=true);
    
    if err != .None {
        return {}, false;
    }
    
    return json_object_to_struct(obj.(json.Object), T), true;
}
json_file_to_struct :: proc(path : string, $T : typeid) -> (result : T, ok : bool) {
    bytes : []byte;
    bytes, ok = os.read_entire_file(path);

    if ok {
        defer delete(bytes);

        return json_string_to_struct(string(bytes), T);
    }
    return;
}