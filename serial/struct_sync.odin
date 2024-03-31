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

Disk_Sync_Kind :: enum {
    WRITE_CHANGES_TO_DISK,
    READ_CHANGES_FROM_DISK,
    BOTH_WITH_DISK_PRIORITY,
    BOTH_WITH_RAM_PRIORITY,
}
Sync_Start_Action :: enum {
    COPY_DISK_TO_RAM,
    COPY_RAM_TO_DISK,
    NOTHING,
}

Struct_Binding :: struct {
    struct_info_base : ^reflect.Type_Info,
    struct_info : reflect.Type_Info_Struct,
    ptr : rawptr,
    last_transferred_data : rawptr,
    file_handle : os.Handle,
    path : string,
    sync : Disk_Sync_Kind,
    number_of_last_transferred_bytes : int,
}

bindings : [dynamic]Struct_Binding;

@(thread_local)
seen_member_struct_types_set : [dynamic]^reflect.Type_Info;

bind_struct_data_to_file :: proc(data : ^$Struct, path : string, sync : Disk_Sync_Kind, start_action : Sync_Start_Action = .COPY_DISK_TO_RAM) where intrinsics.type_is_struct(Struct) {
    if bindings == nil do bindings = make([dynamic]Struct_Binding);
    assert(data != nil, "Nil data cannot be bound to disk");

    initial_info := type_info_of(Struct);
    binding : Struct_Binding;
    binding.path = path;
    binding.ptr = data;
    binding.sync = sync;
    #partial switch v in initial_info.variant {
        case reflect.Type_Info_Named: 
            binding.struct_info = v.base.variant.(reflect.Type_Info_Struct);
            binding.struct_info_base = v.base;
        case: 
            binding.struct_info = initial_info.variant.(reflect.Type_Info_Struct);
            binding.struct_info_base = initial_info;
    }

    MAX_ATTEMPTS :: 10;

    dir := filepath.dir(path);
    defer delete(dir);
    if !os.exists(dir) do os.make_directory(dir);
    
    if !os.exists(path) {
        f, err := os.open(path, os.O_CREATE);
        if err == os.ERROR_NONE do os.close(f);
    }

    

    if start_action == .COPY_DISK_TO_RAM {
        file_err : os.Errno = os.ERROR_NOT_ENOUGH_MEMORY;
        attempts := 0;
        for file_err != os.ERROR_NONE && attempts < MAX_ATTEMPTS {
            binding.file_handle, file_err = os.open(path, os.O_RDONLY);
            attempts += 1;
        }
        assert(file_err == os.ERROR_NONE, fmt.tprintf("Failed opening file for binding struct data '%s'", path));

        read_struct_from_file(&binding);

        write_struct_to_file(&binding);

        os.close(binding.file_handle);
    } else if start_action != .NOTHING do panic("unimplemented"); // #Incomplete

    switch sync {
        case .WRITE_CHANGES_TO_DISK: {
            if os.exists(path) do os.remove(path);
            file_err : os.Errno = os.ERROR_NOT_ENOUGH_MEMORY;
            attempts := 0;
            for file_err != os.ERROR_NONE && attempts < MAX_ATTEMPTS {
                binding.file_handle, file_err = os.open(path, os.O_WRONLY | os.O_CREATE);
                attempts += 1;
            }
            assert(file_err == os.ERROR_NONE, fmt.tprintf("Failed opening file for binding struct data '%s'", path));

            alloc_err : mem.Allocator_Error;
            binding.last_transferred_data, alloc_err = mem.alloc(size_of(Struct));

            //sz, sz_err := os.file_size(binding.file_handle);
            //binding.number_of_last_transferred_bytes = cast(int)sz;
            //assert(file_err == os.ERROR_NONE);

            assert(alloc_err == .None);
        }
        case .BOTH_WITH_DISK_PRIORITY, .BOTH_WITH_RAM_PRIORITY, .READ_CHANGES_FROM_DISK: {
            panic("unimplemented"); // #Incomplete
        }
    }

    append(&bindings, binding);
}

update_synced_data :: proc() {
    for _, i in bindings {
        binding := &bindings[i];

        struct_size := binding.struct_info_base.size;
        now := binding.ptr;
        last := binding.last_transferred_data;

        switch binding.sync {
            case .WRITE_CHANGES_TO_DISK: {
                need_write := false;
                if mem.compare_ptrs(binding.ptr, binding.last_transferred_data, struct_size) != 0 do need_write = true;

                if need_write {                    
                    write_struct_to_file(binding);
                }
            }

            case .BOTH_WITH_DISK_PRIORITY, .BOTH_WITH_RAM_PRIORITY, .READ_CHANGES_FROM_DISK: {}
        }       
    }
}


write_struct_to_file :: proc(binding : ^Struct_Binding) {
    struct_size := binding.struct_info_base.size;
    os.seek(binding.file_handle, 0, 0);
    if binding.number_of_last_transferred_bytes > 0 {
        zero_bytes, err := mem.alloc_bytes(binding.number_of_last_transferred_bytes, allocator=context.temp_allocator);
        assert(err == .None);
        
        os.write_ptr(binding.file_handle, builtin.raw_data(zero_bytes), binding.number_of_last_transferred_bytes);        
        os.seek(binding.file_handle, 0, 0);
    }
    obj := binding_to_json_object(binding);

    // The marshaller writes to many decimal places which makes the
    // parser parse it incorrectly....... 
    /*opts : json.Marshal_Options;
    opts.spec = .SJSON;
    marshalled, merr := json.marshal(obj, opts, allocator=context.temp_allocator);
    assert(merr == nil, "Marshalling json failed for some reason");
    to_write := string(marshalled);*/

    to_write := tprint_json_obj(obj);

    os.write_string(binding.file_handle, to_write);
    binding.number_of_last_transferred_bytes = len(to_write);
    os.flush(binding.file_handle);
}
read_struct_from_file :: proc(binding : ^Struct_Binding) {
    bytes, ok := os.read_entire_file(binding.file_handle);

    if ok {
        result, err := json.parse(bytes, spec=json.Specification.JSON5, parse_integers=true, allocator=context.allocator);
    
        if err != .None {
            log.errorf("Failed parsing json for bound struct '%s' (%s)", binding.path, err);
            return;
        }

        json_obj_to_struct(binding.ptr, result.(json.Object), binding.struct_info, binding.struct_info_base);
        
        delete(bytes);
    } else {
        log.errorf("Failed reading bound file '%s'", binding.path);
    }
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

            json_obj_to_struct(ptr, value.(json.Object), v, type);
        }
        case reflect.Type_Info_Pointer: {
            pointer_to := base_or_self(v.elem);

            #partial switch vp in pointer_to.variant {
                case reflect.Type_Info_Struct: {
                    if !check_field_is(name,value, json.Object) do return;
                    json_obj_to_struct(ptr, value.(json.Object), vp, pointer_to);
                }
                case: {
                    // Not sure why we even serialize pointer addresses
                    if !check_field_is(name,value, json.Integer) do return;
                    return;
                }
            }
        }
        case: log.warn("Unsupported type", v, "in synced struct"); return;
    }
}

json_obj_to_struct :: proc(data : rawptr, obj : json.Object, struct_info : reflect.Type_Info_Struct, struct_info_base : ^reflect.Type_Info) {

    for name, i in struct_info.names {
        type := base_or_self(struct_info.types[i]);
        offset := struct_info.offsets[i];

        ptr := mem.ptr_offset(cast(^u8)data, offset);

        if name not_in obj do continue;
        assign_json_value(ptr, type, name, obj[name]);

    }

}

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
binding_to_json_object :: proc(binding : ^Struct_Binding, allocator := context.allocator) -> json.Object {
    context.allocator = allocator;

    if seen_member_struct_types_set == nil do seen_member_struct_types_set = make(type_of(seen_member_struct_types_set));
    clear(&seen_member_struct_types_set);
    
    if binding.sync != .WRITE_CHANGES_TO_DISK do panic("unimplemented"); // #Incomplete

    ptr := binding.ptr;

    if has_seen_struct_type(binding.struct_info_base) {
        log.warnf("Self-referencing member of type '%s' detected; some member(s) will be ignored", binding.struct_info_base);
        return nil;
    }
    append(&seen_member_struct_types_set, binding.struct_info_base);
    defer pop(&seen_member_struct_types_set);
    return to_json_object(ptr, binding.struct_info, binding.struct_info_base);
}

base_or_self :: proc(maybe_named : ^reflect.Type_Info) -> ^reflect.Type_Info{
    #partial switch v in maybe_named.variant {
        case reflect.Type_Info_Named: return v.base;
        case: return maybe_named;
    }
    return nil;
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