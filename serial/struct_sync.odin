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

import "jamgine:osext"

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
    file_handle : os.Handle,
    path : string,
    sync : Disk_Sync_Kind,
    number_of_last_transferred_bytes : int,
}

Serial_Binding_Id :: int;
bindings : [dynamic]Struct_Binding;



bind_struct_data_to_file :: proc(data : ^$Struct, path : string, sync : Disk_Sync_Kind, start_action : Sync_Start_Action = .COPY_DISK_TO_RAM) -> Serial_Binding_Id where intrinsics.type_is_struct(Struct)  {
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
            file_err : os.Errno = os.ERROR_NOT_ENOUGH_MEMORY;
            attempts := 0;
            for file_err != os.ERROR_NONE && attempts < MAX_ATTEMPTS {
                binding.file_handle, file_err = os.open(path, os.O_WRONLY);
                attempts += 1;
            }
            assert(file_err == os.ERROR_NONE, fmt.tprintf("Failed opening file for binding struct data '%s'", path));
        }
        case .BOTH_WITH_DISK_PRIORITY, .BOTH_WITH_RAM_PRIORITY, .READ_CHANGES_FROM_DISK: {
            panic("unimplemented"); // #Incomplete
        }
    }

    append(&bindings, binding);

    return len(bindings)-1;
}

sync_all :: proc() {
    for _, i in bindings {
        binding := &bindings[i];

        switch binding.sync {
            case .WRITE_CHANGES_TO_DISK: {
                write_struct_to_file(binding);
            }

            case .BOTH_WITH_DISK_PRIORITY, .BOTH_WITH_RAM_PRIORITY, .READ_CHANGES_FROM_DISK: {}
        }       
    }
}

sync_one :: proc(id : Serial_Binding_Id) {
    assert(id >= 0 && id < len(bindings), "Invalid serial ID");

    binding := &bindings[id];

    switch binding.sync {
        case .WRITE_CHANGES_TO_DISK: {
            write_struct_to_file(binding);
        }

        case .BOTH_WITH_DISK_PRIORITY, .BOTH_WITH_RAM_PRIORITY, .READ_CHANGES_FROM_DISK: {}
    }
}


write_struct_to_file :: proc(binding : ^Struct_Binding) {
    struct_size := binding.struct_info_base.size;
    os.seek(binding.file_handle, 0, 0);
    
    obj := binding_to_json_object(binding);

    to_write := tprint_json_obj(obj);

    // Win32: SetFilePointer and SetEndOfFile
    // Unix: ftruncate
    osext.clear_file(binding.file_handle);

    os.write_string(binding.file_handle, to_write);
    binding.number_of_last_transferred_bytes = len(to_write);
    os.flush(binding.file_handle);
}
read_struct_from_file :: proc(binding : ^Struct_Binding) {
    bytes, ok := os.read_entire_file(binding.file_handle);

    if ok {
        // #Leak json object, not sure if we copy the strings from it even
        result, err := json.parse(bytes, spec=json.Specification.JSON5, parse_integers=true, allocator=context.allocator);
    
        if err != .None {
            log.errorf("Failed parsing json for bound struct '%s' (%s)", binding.path, err);
            return;
        }

        from_json_object(binding.ptr, result.(json.Object), binding.struct_info, binding.struct_info_base);
        
        delete(bytes);
    } else {
        log.errorf("Failed reading bound file '%s'", binding.path);
    }
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





