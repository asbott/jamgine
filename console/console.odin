package console

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:gfx/text"
import "jamgine:input"
import "jamgine:osext"
import "jamgine:utils"
import "jamgine:lin"
import "jamgine:bible"
import "jamgine:serial"
import jvk "jamgine:gfx/justvk"

import "vendor:glfw"
import stb "vendor:stb/image"

import "core:path/filepath"
import "core:time"
import "core:math"
import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"
import "core:strings"
import "core:intrinsics"
import "core:runtime"
import "core:strconv"
import "core:log"
import "core:reflect"
import "core:os"
import "core:sys/windows"
import "core:mem"
import "core:builtin"
import "core:c"
import "core:sort"

ATLAS_HEIGHT :: 4096;

State_Kind :: enum {
    CLOSED,
    HALF_OPEN,
    FULL_OPEN
}

Entry :: struct {
    content    : string,
    level      : log.Level,
    is_user    : bool,
    
    using noserialize : struct {
        size           : lin.Vector2,
        lines          : []string,
        rendered_lines : []imm.Rendered_Text,
        dirty          : bool,
        atlas_uv       : lin.Vector4,
    },
}

Command_Value :: union {
    int, f32, string, bool, rawptr
}
Console_State_Info :: struct #packed {
    font_family_path : string,
    font_size        : int,
    openess          : State_Kind,
    command_history  : [dynamic]string,
    lookback_index   : int,
    
    caret_anim_time   : f32,
    caret_color       : lin.Vector4,
    focused           : bool,
    display_level     : log.Level,
    last_suggestions  : [dynamic]string,
    entries           : [dynamic]Entry,
    
    level_toggle_flags : [int(log.Level.Fatal)+1]bool,
    working_directory : string,

    using noserialize : struct {
        history_texture : jvk.Texture,
        history_atlases : [dynamic]imm.Text_Atlas,
        history_atlas_index : int,
        history_target : jvk.Render_Target,
        history_pipeline : ^jvk.Pipeline,
        history_needs_render : bool,
        font_family       : ^text.Font_Family,
        font              : ^text.Font_Variation, // Expected to be owned by console, will be deleted on resize etc
        commands     : map[string]Command,
        did_console_create_font_family : bool,
    }
}

TOGGLE_SPEED      :: 6.0;
CLOSED_POS        :: 0.0;
HALF_POS          :: 0.3;
FULL_POS          :: 0.9;
BASE_COLOR        :: lin.Vector4{ 0.0, 0.0, 0.0, 0.85 };
PROMPT_COLOR      :: lin.Vector4{ 0.03, 0.03, 0.03, 0.9 };
USER_ENTRY_COLOR  :: lin.Vector4{ .3, .6, .8, 1.0 };
DEFAULT_FONT_SIZE :: 18;
VERTICAL_PADDING  :: 0.25;
LEFT_PADDING      :: 1.0;


imm_context       : ^imm.Imm_Context;
current_pos       : f32;
prompt_line       : strings.Builder;
caret_pos         : uint;
caret_visual_x    : f32;
caret_target_x    : f32;
caret_last_x      : f32;
caret_visual_w    : f32;
caret_last_w      : f32;
caret_target_w    : f32;
yscroll           : f32;
smoothwatch       : time.Stopwatch;
muted             := false;
state             : Console_State_Info;


toggle_key : c.int = glfw.KEY_F1;
close_key  : c.int = glfw.KEY_ESCAPE;
enum_types : map[string]runtime.Type_Info_Enum;

max_entries := 9000;

suggest_index : int;


Command_Param :: struct {
    name : string,
    type : ^runtime.Type_Info,
}
Command :: struct {
    base_callback : Command_Proc,
    untyped_proc : rawptr,
    help_str : string,
    params : []Command_Param,
    name : string,
}
Any_Proc :: struct($P : typeid) {
    the_proc : P,
}
Command_Proc :: #type proc(command : Command, args : ..Command_Value) -> (Command_Value, bool);

get_level_foreground_color :: proc(level : log.Level) -> lin.Vector4 {
    switch level {
        case .Debug:   return lin.Vector4{0.5, 0.6, 0.8, 1.0};
        case .Info:    return lin.Vector4{0.8, 0.8, 0.8, 1.0};
        case .Warning: return lin.Vector4{0.9, 0.9, 0.25, 1.0};
        case .Error:   return lin.Vector4{0.9, 0.1, 0.1, 1.0};
        case .Fatal:   return lin.Vector4{0.0, 0.0, 0.0, 1.0};
    }
    
    return gfx.WHITE;
}
get_level_background_color :: proc(level : log.Level) -> lin.Vector4 {
    switch level {
        case .Debug:   return lin.Vector4{0.0, 0.0, 0.0, 0.0};
        case .Info:    return lin.Vector4{0.0, 0.0, 0.0, 0.0};
        case .Warning: return lin.Vector4{0.0, 0.0, 0.0, 0.0};
        case .Error:   return lin.Vector4{0.0, 0.0, 0.0, 0.0};
        case .Fatal:   return lin.Vector4{0.8, 0.0, 0.0, 1.0};
    }
    
    return gfx.WHITE;
}

bind_command :: proc(command_name : string, the_proc : $P, help := "") where intrinsics.type_is_proc(P) {
    any_proc := new(Any_Proc(P)); // #Cleanup #Mem
    any_proc.the_proc = the_proc;

    command : Command;
    command.untyped_proc = any_proc;
    command.help_str = strings.clone(help); // #Leak
    command.name = strings.clone(command_name); // #Leak #Cleanup
    proc_info := type_info_of(P).variant.(runtime.Type_Info_Procedure);
    if proc_info.params != nil {
        params_info := proc_info.params.variant.(runtime.Type_Info_Parameters);
        command.params = make([]Command_Param, len(params_info.names));

        for name, i in params_info.names {
            command.params[i] = {name, params_info.types[i]};
        }
    }

    if len(help) <= 0 {
        if command.params == nil {
            // #Cleanup #Leak
            command.help_str = strings.clone(fmt.tprintf("%s:\n\tNo arguments", command_name)); 
        } else {
            builder : strings.Builder;
            strings.builder_init_len_cap(&builder, 0, 128);
            defer strings.builder_destroy(&builder);

            strings.write_string(&builder, fmt.tprintf("%s:", command_name));

            for param in command.params {
                // #Bug
                // Somehow the wrong name ends up here from other commands....
                strings.write_string(&builder, fmt.tprintf("\n\t%s : %s", param.name, param.type));
            }

            // #Cleanup #Leak
            command.help_str = strings.clone(strings.to_string(builder)); 
        }
    }

    command.base_callback = proc(command : Command, args : ..Command_Value) -> (result:Command_Value, ok:bool) {
        proc_pointer := (cast(^Any_Proc(P))command.untyped_proc);
        the_proc := proc_pointer.the_proc;
        //the_proc := (cast(^P)the_proc_untyped.data)^;
        
        procedure_type := type_info_of(P).variant.(runtime.Type_Info_Procedure);

        params :^runtime.Type_Info_Parameters= &procedure_type.params.variant.(runtime.Type_Info_Parameters) if procedure_type.params != nil else nil;
        results :^runtime.Type_Info_Parameters= &procedure_type.results.variant.(runtime.Type_Info_Parameters) if procedure_type.results != nil else nil;
        

        if params != nil && len(params.names) != len(args) {
            push_entry(fmt.tprintf("Argument count mismatch. Expected %i, got %i. Use command 'help %s' for more information.", len(params.names), len(args), command.name), level=.Error);
            return nil, false;
        }
        
        if params != nil do for param_name, index in params.names {
            type := params.types[index];
            
            arg := args[index];
            
            if reflect.union_variant_typeid(type.variant) == runtime.Type_Info_Named {
                named_type := type.variant.(runtime.Type_Info_Named);
                name := named_type.name;
                if name not_in enum_types {
                    push_entry(fmt.tprint("Internal error: enum type", name, "is not bound in console (call bind_enum). Use command 'help ", command.name, "' for more information."), .Error);
                    return nil, false;
                }
                
                if !utils.variant_is(arg, string) {
                    push_entry(fmt.tprintf("Argument type mismatch for argument %i (%s). Expected %s, got %s. Use command 'help %s' for more information.", index+1, command.params[index].name, name, utils.type_of_variant(arg), command.name), level=.Error);
                    return nil, false;
                }

                tinfo := enum_types[name];

                arg_str := arg.(string);
                
                val : Maybe(runtime.Type_Info_Enum_Value);
                for member_name, index in tinfo.names {
                    if member_name == arg_str {
                        val = tinfo.values[index];
                        break;
                    }
                }
                
                if val == nil {
                    push_entry(fmt.tprintf("Argument type mismatch for argument %i (%s). Expected %s, got %s. Use command 'help %s' for more information.", index+1, command.params[index].name, name, utils.type_of_variant(arg), command.name), level=.Error);
                    return nil, false;
                }
                
                args[index] = cast(int)val.(runtime.Type_Info_Enum_Value);
            } else if type != type_info_of(utils.type_of_variant(arg)) {
                push_entry(fmt.tprintf("Argument type mismatch for argument %i (%s). Expected %s, got %s. Use command 'help %s' for more information.", index+1, command.params[index].name, type, utils.type_of_variant(arg), command.name), level=.Error);
                return nil, false;
            }
        }
        
        callback := the_proc;
        when intrinsics.type_proc_return_count(P) == 1 {
            when intrinsics.type_proc_parameter_count(P) == 0 {
                result = callback();
            } else when intrinsics.type_proc_parameter_count(P) == 1 {
                result = callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 2 {
                result = callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 3 {
                result = callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 4 {
                result = callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                    args[3].(intrinsics.type_proc_parameter_type(P, 3)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 3)) else cast(intrinsics.type_proc_parameter_type(P, 3))args[3].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 5 {
                result = callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                    args[3].(intrinsics.type_proc_parameter_type(P, 3)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 3)) else cast(intrinsics.type_proc_parameter_type(P, 3))args[3].(int),
                    args[4].(intrinsics.type_proc_parameter_type(P, 4)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 4)) else cast(intrinsics.type_proc_parameter_type(P, 4))args[4].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 6 {
                result = callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                    args[3].(intrinsics.type_proc_parameter_type(P, 3)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 3)) else cast(intrinsics.type_proc_parameter_type(P, 3))args[3].(int),
                    args[4].(intrinsics.type_proc_parameter_type(P, 4)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 4)) else cast(intrinsics.type_proc_parameter_type(P, 4))args[4].(int),
                    args[5].(intrinsics.type_proc_parameter_type(P, 5)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 5)) else cast(intrinsics.type_proc_parameter_type(P, 5))args[5].(int),
                );
            } else {
                #assert(false, "Max 6 arguments for command");
            }
        } else when intrinsics.type_proc_return_count(P) == 0 {
            when intrinsics.type_proc_parameter_count(P) == 0 {
                callback();
            } else when intrinsics.type_proc_parameter_count(P) == 1 {
                callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 2 {
                callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 3 {
                callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 4 {
                callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                    args[3].(intrinsics.type_proc_parameter_type(P, 3)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 3)) else cast(intrinsics.type_proc_parameter_type(P, 3))args[3].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 5 {
                callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                    args[3].(intrinsics.type_proc_parameter_type(P, 3)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 3)) else cast(intrinsics.type_proc_parameter_type(P, 3))args[3].(int),
                    args[4].(intrinsics.type_proc_parameter_type(P, 4)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 4)) else cast(intrinsics.type_proc_parameter_type(P, 4))args[4].(int),
                );
            } else when intrinsics.type_proc_parameter_count(P) == 6 {
                callback(
                    args[0].(intrinsics.type_proc_parameter_type(P, 0)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 0)) else cast(intrinsics.type_proc_parameter_type(P, 0))args[0].(int),
                    args[1].(intrinsics.type_proc_parameter_type(P, 1)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 1)) else cast(intrinsics.type_proc_parameter_type(P, 1))args[1].(int),
                    args[2].(intrinsics.type_proc_parameter_type(P, 2)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 2)) else cast(intrinsics.type_proc_parameter_type(P, 2))args[2].(int),
                    args[3].(intrinsics.type_proc_parameter_type(P, 3)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 3)) else cast(intrinsics.type_proc_parameter_type(P, 3))args[3].(int),
                    args[4].(intrinsics.type_proc_parameter_type(P, 4)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 4)) else cast(intrinsics.type_proc_parameter_type(P, 4))args[4].(int),
                    args[5].(intrinsics.type_proc_parameter_type(P, 5)) when intrinsics.type_is_variant_of(Command_Value, intrinsics.type_proc_parameter_type(P, 5)) else cast(intrinsics.type_proc_parameter_type(P, 5))args[5].(int),
                );
            } else {
                #assert(false, "Max 6 arguments for command");
            }
        } else {
            #assert(false, "1 or 0 results allowed for command functions");
        }
        
        return result, true;
    };


    state.commands[command_name] = command;
}

bind_enum :: proc($T : typeid) where intrinsics.type_is_enum(T) {
    named_info := type_info_of(T);
    tinfo := named_info.variant.(runtime.Type_Info_Named).base.variant.(runtime.Type_Info_Enum);
    
    enum_types[named_info.variant.(runtime.Type_Info_Named).name] = tinfo;
}

append_char_to_prompt :: proc(char : rune, pos := caret_pos) {
    old_str := fmt.tprint(strings.to_string(prompt_line));
    if pos < cast(uint)utf8.rune_count(old_str) {
        strings.builder_reset(&prompt_line);
        
        i :uint= 0;
        for existing_char in old_str {
            if i == pos {
                strings.write_rune(&prompt_line, char);    
            }
            strings.write_rune(&prompt_line, existing_char);

            i += 1;
        }
    } else {
        strings.write_rune(&prompt_line, char);
    }

    if caret_pos >= pos do set_caret_pos(caret_pos + 1);
}

append_string_to_prompt :: proc(str : string, pos := caret_pos) {
    old_str := fmt.tprint(strings.to_string(prompt_line));
    if pos < cast(uint)utf8.rune_count(old_str) {
        strings.builder_reset(&prompt_line);
        
        i :uint= 0;
        for existing_char in old_str {
            if i == pos {
                strings.write_string(&prompt_line, str);
            }
            strings.write_rune(&prompt_line, existing_char);

            i += 1;
        }
    } else {
        strings.write_string(&prompt_line, str);
    }
    

    if caret_pos >= pos do set_caret_pos(caret_pos + cast(uint)utf8.rune_count(str))
}

remove_char_from_prompt_at_caret :: proc() {

    if caret_pos == 0 do return;
    
    old_str := fmt.tprint(strings.to_string(prompt_line));
    strings.builder_reset(&prompt_line);
    
    i :uint= 0;
    for existing_char in old_str {
        if i != caret_pos-1 {
            strings.write_rune(&prompt_line, existing_char);
        }
        
        i += 1;
    }
    
    set_caret_pos(caret_pos-1);
}

handle_char :: proc(char : rune) {
    if state.openess == .CLOSED do return;
    append_char_to_prompt(char);

    reset_lookback();
}

handle_key :: proc(glfw_key, scancode, action, mods : c.int) -> (handled : bool){
    if action != glfw.RELEASE {
        handled = true;
        if glfw_key == glfw.KEY_ENTER {
            // #Memory #Fragmentation
            prompt_line := strings.clone(strings.to_string(prompt_line));
            if len(state.command_history) == 0 || state.command_history[len(state.command_history)-1] != prompt_line {
                append(&state.command_history, prompt_line);
            }
            cmd_lines := []string{prompt_line};
            and_index := strings.index(prompt_line, "&&");
            if and_index != -1 {
                // #Incomplete #Limitation
                // The '&&' could be within double quotes...
                cmd_lines = strings.split(prompt_line, "&&", allocator=context.temp_allocator);
            }
            for cmd in cmd_lines {
                
                result, ok := send_command(cmd);
                if ok && result != nil do push_entry(fmt.tprint(result));
            }
            clear_prompt();
            reset_lookback();
        } else if glfw_key == glfw.KEY_BACKSPACE {
            remove_char_from_prompt_at_caret();
            reset_lookback();
        } else if glfw_key == glfw.KEY_DELETE {
            if caret_pos >= cast(uint)get_prompt_len() do return;
            set_caret_pos(caret_pos + 1)
            remove_char_from_prompt_at_caret();
            reset_lookback();
        } else if glfw_key == glfw.KEY_LEFT {
            if caret_pos > 0 {
                set_caret_pos(caret_pos - 1);
                if (mods & glfw.MOD_CONTROL) != 0 {
                    for caret_pos > 0 {
                        if !unicode.is_white_space(get_char_in_prompt(int(caret_pos))) && unicode.is_white_space(get_char_in_prompt(int(caret_pos-1))) do break;
                        set_caret_pos(caret_pos - 1);
                    }
                }
            }
        } else if glfw_key == glfw.KEY_RIGHT {
            if caret_pos < cast(uint)utf8.rune_count(strings.to_string(prompt_line)) {
                set_caret_pos(caret_pos + 1);
                if (mods & glfw.MOD_CONTROL) != 0 {
                    for caret_pos < cast(uint)utf8.rune_count(strings.to_string(prompt_line)) {
                        if caret_pos > 0 && unicode.is_white_space(get_char_in_prompt(int(caret_pos))) && !unicode.is_white_space(get_char_in_prompt(int(caret_pos-1))) do break;
                        set_caret_pos(caret_pos + 1);
                    }
                }
            }
        } else if glfw_key == glfw.KEY_HOME {
            set_caret_pos(0);
        } else if glfw_key == glfw.KEY_END {
            set_caret_pos(cast(uint)get_prompt_len());
        } else if glfw_key == glfw.KEY_UP {
            if (mods & glfw.MOD_SHIFT) != 0 {
                if len(state.last_suggestions) > 0 {
                    suggest_index += 1;
                    if suggest_index >= len(state.last_suggestions) do suggest_index = 0;
    
                    set_prompt(state.last_suggestions[suggest_index]);
                }
            } else {
                if state.lookback_index-1 >= 0 {
                    state.lookback_index -= 1;
                    set_prompt(state.command_history[state.lookback_index]);
                }
            }
        } else if glfw_key == glfw.KEY_DOWN {
            if (mods & glfw.MOD_SHIFT) != 0 {
                if len(state.last_suggestions) > 0 {
                    suggest_index -= 1;
                    if suggest_index < 0 do suggest_index = len(state.last_suggestions)-1;
    
                    set_prompt(state.last_suggestions[suggest_index]);
                }
            } else {
                if state.lookback_index+1 < len(state.command_history) {
                    state.lookback_index += 1;
                    set_prompt(state.command_history[state.lookback_index]);
                } else {
                    clear_prompt();
                    reset_lookback();
                }
            }
        } else if glfw_key == glfw.KEY_V && (mods & glfw.MOD_CONTROL) != 0 {
            append_string_to_prompt(osext.get_sys_clipboard_utf8(context.temp_allocator));
        } else if glfw_key == glfw.KEY_C && (mods & glfw.MOD_CONTROL) != 0 {
            
        } else if glfw_key == glfw.KEY_X && (mods & glfw.MOD_CONTROL) != 0 {
            
        } else if glfw_key == toggle_key {
            if (mods & glfw.MOD_SHIFT) != 0 {
                state.openess = .FULL_OPEN;
            } else {
                if state.openess != .CLOSED && !state.focused {
                    state.focused = true;
                } else {
                    if      state.openess == .CLOSED         do state.openess = .HALF_OPEN;
                    else if state.openess == .HALF_OPEN do state.openess = .FULL_OPEN;
                    else if state.openess == .FULL_OPEN do state.openess = .HALF_OPEN;
                    state.focused = true;
                }
            }
        } else if glfw_key == close_key {
            state.openess = .CLOSED;
        } else {
            handled = true;
        }
    }

    return;
}

set_scroll :: proc(scroll : f32) {
    yscroll = scroll;
    state.history_needs_render = true;
}
handle_scroll :: proc(xoffset, yoffset : f32) -> (handled : bool) {
    if state.openess == .CLOSED do return false;
    if yscroll + yoffset < get_max_scroll() {
        set_scroll(yscroll + yoffset);
    } else {
        set_scroll(get_max_scroll());
    }
    
    if yscroll < 0 do set_scroll(0);

    return true;
}

push_entry :: proc(content : string, level := log.Level.Info, is_user := false) {

    if muted do return;

    state.history_needs_render = true;

    // TODO
    // Break into more lines if it doesnt fit horizontally

    context.logger = log.Logger{};

    e : Entry;
    e.content = strings.clone(fmt.tprint(">", content) if is_user else content); // #Cleanup #Leak
    e.size = text.measure(state.font, e.content);
    e.is_user = is_user;
    e.level = level;
    e.dirty = true;

    append(&state.entries, e);

    // #Speed
    for len(state.entries) > max_entries {
        free_entry(state.entries[0]);
        pop_front(&state.entries);
    }
}
free_entry :: proc(entry : Entry) {
    delete(entry.content);
    delete(entry.lines);
}

format_lines :: proc(entry : ^Entry) {
    lines := make([dynamic]string);
    rendered_lines := make([dynamic]imm.Rendered_Text);

    line_start := 0;

    window_size := gfx.get_window_size();

    max_line_width := window_size.x - get_left_padding() * 2;

    line_so_far : string;

    line_width : f32;
    last_char : rune = -1;
    
    rune_size : int;
    rune_index : int;
    for byte_index := 0; byte_index < len(entry.content); byte_index += rune_size {
        char,_ := utf8.decode_rune_in_string(entry.content[byte_index:]);
        rune_size = utf8.rune_size(char);

        start_byte_index := line_start;
        end_byte_index := byte_index + rune_size;
        line_so_far = entry.content[start_byte_index:end_byte_index if end_byte_index > -1 else len(entry.content)];
        glyph_info := text.get_glyph_info(state.font, char);

        line_width += glyph_info.advance;
        if last_char != -1 {
            line_width += text.get_kerning_advance(state.font, last_char, char);
        }
        if char == '\t' {
            space_glyph := text.get_glyph_info(state.font, ' ');
            num_spaces := text.TAB_STOP_SIZE - (utf8.rune_count(line_so_far)) % (text.TAB_STOP_SIZE);
            line_width += space_glyph.advance * cast(f32)num_spaces;
        }
        
        // #Bug unicode
        if line_width > (max_line_width) || char == '\n' {
            if line_so_far[0] == ' ' && len(line_so_far) >= 2 && line_so_far[1] != ' ' {
                line_so_far = line_so_far[1:];
            }
            if line_so_far[len(line_so_far)-1] == '\n' {
                line_so_far = line_so_far[:len(line_so_far)-1];
            }
            newline_index := strings.index(line_so_far, "\n");
            if newline_index != -1 {
                log.error("Console formatted line has a newline whut !!");
            }
            append(&lines, line_so_far);

            // #Copypaste
            rendered : imm.Rendered_Text;
            render_ok : bool;
            for atlas, i in state.history_atlases {
                rendered, render_ok = imm.get_or_render_text(&state.history_atlases[i], line_so_far, state.font, imm_context);
                if render_ok do break;
            }
            if !render_ok {
                append_atlas();
                rendered, render_ok = imm.render_text(&state.history_atlases[state.history_atlas_index], line_so_far, state.font, imm_context);
                assert(render_ok, "Failed rendering console text");
            }
            append(&rendered_lines, rendered);

            line_start = byte_index+1;
            line_so_far = "";
            line_width = 0;
        }
        last_char = char;
        rune_index += 1;
    }
    if len(line_so_far) > 0 {
        append(&lines, entry.content[line_start:]);
        // #Copypaste
        rendered : imm.Rendered_Text;
        render_ok : bool;
        for atlas, i in state.history_atlases {
            rendered, render_ok = imm.get_or_render_text(&state.history_atlases[i], line_so_far, state.font, imm_context);
            if render_ok do break;
        }
        if !render_ok {
            append_atlas();
            rendered, render_ok = imm.render_text(&state.history_atlases[state.history_atlas_index], line_so_far, state.font, imm_context);
            assert(render_ok, "Failed rendering console text");
        }
        append(&rendered_lines, rendered);
    }

    if entry.lines != nil do delete(entry.lines);
    if entry.rendered_lines != nil {
        // #Leak kinda
        delete(entry.rendered_lines);
    }

    entry.lines = lines[:];
    entry.rendered_lines = rendered_lines[:];

    entry.dirty = false;
}

send_command :: proc(line : string) -> (Command_Value, bool) {

    line := strings.trim_left_space(line);
    line = strings.trim_right_space(line);

    

    for sug in state.last_suggestions {
        delete(sug);
    }
    clear(&state.last_suggestions);
    suggest_index = -1;

    push_entry(line, is_user=true);

    if line == "" do return nil, false;

    split_command :: proc(line : string) -> []string {
        context.allocator = context.temp_allocator;
        word_builder : strings.Builder;
        strings.builder_init_len_cap(&word_builder, 0, 16);

        result := make([dynamic]string);
        in_quotation := false;

        i := 0;
        for char in line {
            defer i += 1; // manually need to keep track of pos because
                          // for loop index will be byte index.
            if unicode.is_space(char) && !in_quotation {
                if utf8.rune_count(strings.to_string(word_builder)) > 0 {
                    append(&result, strings.clone(strings.to_string(word_builder)));
                    strings.builder_reset(&word_builder);
                }
                continue;
            }

            if char == '"' {
                strings.write_rune(&word_builder, '"');
                if in_quotation {
                    append(&result, strings.clone(strings.to_string(word_builder)));
                    strings.builder_reset(&word_builder);    
                }
                in_quotation = !in_quotation;
                continue;
            }

            strings.write_rune(&word_builder, char);
            if i == utf8.rune_count(line)-1 {
                append(&result, strings.clone(strings.to_string(word_builder)));
                strings.builder_reset(&word_builder);
            }
        }

        return result[:];
    }

    segments := split_command(line);

    assert(len(segments) > 0);

    command_name := segments[0];

    if command_name not_in state.commands {

        push_entry(fmt.tprintf("No such command '%s'. Use command 'see_commands' for a list of all commands.", command_name), level=.Error);

        suggestions_builder : strings.Builder;
        strings.builder_init_len_cap(&suggestions_builder, 0, 256);
        defer strings.builder_destroy(&suggestions_builder);

        for existing_command in state.commands {

            this_len := utf8.rune_count(command_name);
            existing_len := utf8.rune_count(existing_command);

            score :f32= 0;
            num_mismatch := 0;
            max_score :f32= cast(f32)this_len;

            shortest := existing_len > this_len ? command_name : existing_command;
            other := existing_len > this_len ? existing_command : command_name;

            for char, index in shortest {
                if utf8.rune_at_pos(shortest, index) == utf8.rune_at_pos(other, index) {
                    score += 1;
                }
            }

            count_diff := abs(existing_len - this_len);
            for char, index in shortest {
                if (index+count_diff >= existing_len) do break;
                if utf8.rune_at_pos(shortest, index) == utf8.rune_at_pos(other, index+count_diff) {
                    score += 1;
                }
            }

            score_ratio := score / max_score;

            if score_ratio >= 0.6 {
                strings.write_string(&suggestions_builder, "\n\t");
                strings.write_string(&suggestions_builder, existing_command);

                if len(segments) > 1 {
                    append(&state.last_suggestions, strings.clone(fmt.tprintf("%s %s", existing_command, strings.join(segments[1:], " ", allocator=context.temp_allocator))));
                } else {
                    append(&state.last_suggestions, strings.clone(fmt.tprint(existing_command)));
                }
            }
        }

        if strings.builder_len(suggestions_builder) > 0 {
            push_entry(fmt.tprint("Did you mean:", strings.to_string(suggestions_builder), sep=""));
        }
        
        return nil, false;
    }
    
    command := state.commands[command_name];
    callback := command.base_callback;

    if len(command.params) != len(segments)-1 {
        push_entry(fmt.tprintf("Argument count mismatch. Expected %i, got %i. Use command 'help %s' for more information.", len(command.params), len(segments)-1, command.name), level=.Error);
        return nil, false;
    }

    args := make([dynamic]Command_Value, 0, len(segments), allocator=context.temp_allocator);

    for i in 1..<len(segments) {
        param := command.params[i-1];
        if segments[i] == "true"       {
            append(&args, true);
        } else if segments[i] == "false" {
            append(&args, false);
        } else {
            if param.type != type_info_of(f32) {
                int_val, int_ok := strconv.parse_int(segments[i]);
                if int_ok {
                    append(&args, int_val);
                    continue;
                }
            }
            f32_val, f32_ok := strconv.parse_f32(segments[i]);
            if f32_ok {
                append(&args, f32_val);
                continue;
            }

            // #Cleanup
            purged, allocated := strings.remove_all(segments[i], "\"");
            //if allocated do delete(segments[i]);
            segments[i] = purged;
            append(&args, segments[i]);
        }
    }

    result, ok := callback(command, ..args[:]);

    

    return result, ok;
}

get_max_scroll :: proc() -> f32 {
    height :f32= 0;
    #reverse for entry in state.entries {
        if !state.level_toggle_flags[entry.level] do continue;
        height += cast(f32)len(entry.lines);
    }
    return height;
} 

get_prompt_height :: proc() -> f32 {
    vert := get_vertical_padding();
    return state.font.font_size + vert * 2;
}
get_view_height :: proc() -> f32 {
    window_size := gfx.get_window_size();
    full_height := (window_size.y * FULL_POS);
    return full_height - get_prompt_height();
}
get_vertical_padding :: proc() -> f32 {
    return state.font.font_size * VERTICAL_PADDING;
}
get_left_padding :: proc() -> f32 {
    return state.font.font_size * LEFT_PADDING;
}

do_entries_exceed_view_height :: proc() -> bool {
    total_height :f32= 0;
    #reverse for e,i in state.entries {
        entry := &state.entries[i];
        
        
        assert(!entry.dirty);

        sz := text.measure(state.font, entry.content);

        total_height += sz.y + get_vertical_padding();

        if total_height > get_view_height() {
            return true;
        }
    }

    return false;
}

clear_prompt :: proc() {
    strings.builder_reset(&prompt_line);
    set_caret_pos(0);
    set_scroll(0);
}
set_prompt :: proc(str : string) {
    strings.builder_reset(&prompt_line);
    strings.write_string(&prompt_line, str);
    set_caret_pos(cast(uint)get_prompt_len());
}
get_prompt_len :: proc() -> int {
    return utf8.rune_count(strings.to_string(prompt_line));
}
get_char_in_prompt :: proc(at : int) -> rune {
    assert(at >= 0 && at < utf8.rune_count(strings.to_string(prompt_line)));

    return utf8.rune_at_pos(strings.to_string(prompt_line), at);
}

reset_lookback :: proc() {
    state.lookback_index = len(state.command_history);
}

set_caret_pos :: proc(pos : uint) {
    caret_pos = pos;

    caret_target_x = 0;
    
    i :uint= 1;
    last_char :rune= 0;
    for char in strings.to_string(prompt_line) {
        if i > caret_pos do break;
        glyph := text.get_glyph_info(state.font, char);
        caret_target_x += glyph.advance;
        if last_char != 0 do caret_target_x += text.get_kerning_advance(state.font, last_char, char);
        i += 1;
        last_char = char;
    }

    caret_last_x = caret_visual_x;

    if caret_pos < cast(uint)get_prompt_len() {
        char := utf8.rune_at_pos(strings.to_string(prompt_line), cast(int)caret_pos);
        glyph := text.get_glyph_info(state.font, char);
        caret_target_w = cast(f32)glyph.advance - cast(f32)glyph.xbearing; // .width?
    } else {
        caret_target_w = cast(f32)text.get_glyph_info(state.font, '0').width;
    }
    caret_last_w = caret_visual_w;

    time.stopwatch_reset(&smoothwatch);
    time.stopwatch_start(&smoothwatch);
}

update :: proc(dt : f32) {
    if state.openess == .CLOSED do state.focused = false;
    for e,i in gfx.window_events {
        if e.handled do continue;
        
        #partial switch v in e.variant {
            case gfx.Window_Char_Event: {
                if state.focused {
                    handle_char(e.variant.(gfx.Window_Char_Event).char);
                    gfx.window_events[i].handled = true;
                }
            }
            case gfx.Window_Key_Event: {
                using key_event := e.variant.(gfx.Window_Key_Event);
                handled := handle_key(key, scancode, action, mods);;
                if state.focused do gfx.window_events[i].handled = handled;
            }
            case gfx.Window_Scroll_Event: {
                using scroll_event := e.variant.(gfx.Window_Scroll_Event);
                if state.focused do gfx.window_events[i].handled = handle_scroll(xscroll, yscroll);                
            }
            case gfx.Window_Button_Event: {
                using button_event := e.variant.(gfx.Window_Button_Event);
                current_y := gfx.get_window_size().y - current_pos * gfx.get_window_size().y;
                if gfx.get_current_mouse_pos().y > current_y {
                    state.focused = true;
                    gfx.window_events[i].handled = true;
                } else {
                    state.focused = false;
                }
            }
            case gfx.Window_Resize_Event: {
                rerender_all();          
            }
            case gfx.Window_Mouse_Move_Event: {
                gfx.window_events[i].handled = v.ypos >= gfx.get_window_size().y-(current_pos * gfx.get_window_size().y);
            }
        }
    }

    move := dt * TOGGLE_SPEED;
    window_size := gfx.get_window_size();

    width := (cast(f32)window_size.x) * 1.0;
    height := (cast(f32)window_size.y) * FULL_POS;

    target_pos : f32;

    if      state.openess == .CLOSED    do target_pos = CLOSED_POS;
    else if state.openess == .HALF_OPEN do target_pos = HALF_POS;
    else if state.openess == .FULL_OPEN do target_pos = FULL_POS;

    diff := target_pos - current_pos;

    if abs(diff) <= move {
        current_pos = target_pos;
    } else {
        if diff > 0 do current_pos += move;
        if diff < 0 do current_pos -= move;
    }
}

append_atlas :: proc() {
    window_size := gfx.get_window_size();
    if window_size.x <= 0 do window_size.x = 1;
    if window_size.y <= 0 do window_size.y = 0;
    new_atlas := imm.make_text_atlas(cast(int)window_size.x, ATLAS_HEIGHT);
    state.history_atlas_index = len(state.history_atlases);
    append(&state.history_atlases, new_atlas);
}
rerender_all :: proc() {
    for e,i in state.entries {
        state.entries[i].dirty = true;
    }
    state.history_needs_render = true;

    for atlas in state.history_atlases {
        imm.destroy_text_atlas(atlas);
    }
    clear(&state.history_atlases);
    jvk.destroy_pipeline(state.history_pipeline);
    jvk.destroy_render_target(state.history_target);
    jvk.destroy_texture(state.history_texture);

    window_size := gfx.get_window_size();
    sampler := jvk.DEFAULT_SAMPLER_SETTINGS;
    sampler.min_filter = .NEAREST;
    sampler.mag_filter = .NEAREST;
    append_atlas();
    state.history_texture = jvk.make_texture(cast(int)window_size.x, cast(int)get_view_height(), nil, .RGBA_HDR, {.SAMPLE, .DRAW}, sampler=sampler);
    state.history_target = jvk.make_texture_render_target(state.history_texture);
    state.history_pipeline = jvk.make_pipeline(imm.shaders.basic2d, state.history_target.render_pass);
}

draw :: proc() {
    //was_muted := muted;
    //muted = true;
    //defer muted = was_muted;
    
    if state.openess == .CLOSED && current_pos < 0.01 do return;

    window_size := gfx.get_window_size();

    backup_proj := imm_context.camera.proj;
    backup_view := imm_context.camera.view;
    defer {
        imm_context.camera.proj = backup_proj;
        imm_context.camera.view = backup_view;
    }

    prompt_text := strings.to_string(prompt_line);
    assert(caret_pos <= cast(uint)get_prompt_len(), "Console caret position out of range");

    backup_context := imm.get_current_context();
    imm.set_context(imm_context);

    width := (cast(f32)window_size.x) * 1.0;
    height := (cast(f32)window_size.y) * FULL_POS;

    prompt_height := get_prompt_height();

    center_y := height / 2.0 + cast(f32)window_size.y - current_pos * cast(f32)window_size.y;
    bottom_y := center_y - height / 2.0;
    prompt_y := bottom_y + prompt_height / 2.0;
    prompt_left :f32= 0;
    prompt_x := prompt_left + width / 2.0;


    text_size := text.measure(state.font, prompt_text);

    prompt_text_center_x := prompt_left + text_size.x / 2.0 + LEFT_PADDING * state.font.font_size;
    prompt_text_left := prompt_text_center_x - text_size.x / 2.0;    

    
    if state.history_needs_render {

        for i := 0; i < len(state.entries); i += 1 {
            e := state.entries[i];
            if e.dirty {
                // Modifying the temporary copy because this function might
                // push new entries which may resize the entries array
                format_lines(&e);
                state.entries[i] = e; 
            }
        }

        imm.set_default_2D_camera(cast(f32)state.history_texture.width, cast(f32)state.history_texture.height, imm_context);
        imm.set_render_target(state.history_target, imm_context);
        imm.begin(state.history_pipeline, imm_context);
        imm.clear_target(BASE_COLOR, imm_context);
        state.history_needs_render = false;
        line_cur :f32= state.font.font_size + get_vertical_padding()*2;
        line_cur_start := line_cur;
        line_start := (cast(int)yscroll)-1;
        line_count := 0;
        for i := len(state.entries) - 1; i >= 0; i -= 1 {
            entry := &state.entries[i];
            done := false;

            if len(entry.content) <= 0 {
                line_count += 1;
                line_cur += f32(state.font.ascent + state.font.line_gap - state.font.descent) + get_vertical_padding();
                continue;
            }

            #reverse for line,i in entry.lines {
                line_count += 1;
                if line_count >= line_start {
                    // #Speed   !!!
                    line_size := text.measure(state.font, line);
                    content_left := prompt_text_left;
                    text_pos := lin.Vector3{ content_left + line_size.x/2.0, line_cur-line_size.y/2.0, 0 };
                    text_pos.x = math.round(text_pos.x);
                    text_pos.y = math.round(text_pos.y);
                    level_color := get_level_foreground_color(entry.level);
                    imm.text(entry.rendered_lines[i], {2, -2, 0} + text_pos, font=state.font, color=gfx.BLACK);
                    imm.text(entry.rendered_lines[i], text_pos, font=state.font, color=level_color if !entry.is_user else USER_ENTRY_COLOR, background_color=get_level_background_color(entry.level));
                    line_cur += f32(state.font.ascent + state.font.line_gap - state.font.descent) + get_vertical_padding();
                }
                if line_cur - state.font.font_size > window_size.y {
                    done = true;
                    break;
                }
            }

        }
        assert(imm_context.active_pipeline == state.history_pipeline);
        imm.flush(imm_context);
    }


    imm.set_default_2D_camera(window_size.x, window_size.y, imm_context);
    imm.set_render_target(gfx.window_surface, imm_context);
    imm.begin2d(imm_context);

    // History rect
    imm.rectangle({ math.round(prompt_x), ((center_y+prompt_height/2)), 0 }, {cast(f32)state.history_texture.width, cast(f32)state.history_texture.height}, texture=state.history_texture, uv_range={0, 1, 1, 0});
    
    // Counter
    num_entries := len(state.entries);
    num_entry_text := fmt.tprintf("%i/%i", num_entries, max_entries);
    entry_text_size := text.measure(state.font, num_entry_text);
    num_entry_text_pos := lin.Vector3{width - entry_text_size.x / 2.0 - get_left_padding(), window_size.y - prompt_height / 2.0, 0};
    imm.rectangle(num_entry_text_pos, entry_text_size * (1.0 + VERTICAL_PADDING*2.0), color=BASE_COLOR);
    imm.text(num_entry_text, num_entry_text_pos, font=state.font);
    
    // Prompt
    imm.rectangle({prompt_x, prompt_y, 0}, {width, prompt_height}, color=PROMPT_COLOR);
    imm.text(prompt_text, {prompt_text_center_x, prompt_y, 0}, font=state.font, color=gfx.WHITE);

    if state.focused {
        // caret
        anim_progress := cast(f32)time.duration_seconds(time.stopwatch_duration(smoothwatch)) / state.caret_anim_time;
        caret_visual_x = caret_last_x + (caret_target_x - caret_last_x) * min(anim_progress, 1.0);
        caret_visual_w = caret_last_w + (caret_target_w - caret_last_w) * min(anim_progress, 1.0);
        caret_point := lin.Vector3{prompt_text_left + caret_visual_x + caret_visual_w/2.0, prompt_y, 0};
        imm.rectangle(caret_point, { caret_visual_w, state.font.font_size }, color=state.caret_color);
        if caret_pos < cast(uint)get_prompt_len() {
            char_under_caret := utf8.rune_at_pos(prompt_text, cast(int)caret_pos);
            str := utf8.runes_to_string([]rune{char_under_caret}, context.temp_allocator);
            imm.text(str, caret_point, color=gfx.inverse_color(state.caret_color), font=state.font);
        }
    }
    
    //sz := window_size;
    //imm.rectangle({sz.x/2, sz.y/2, 0}, sz, texture=state.history_atlas.texture);

    imm.flush(imm_context);

    imm.set_context(backup_context);
}

set_font :: proc(new_font : ^text.Font_Variation) {
    state.font = new_font;
}

set_font_family_from_disk :: proc(path : string) -> (ok: bool) {
    
    context.logger = {};

    defer {
        if !ok do push_entry(fmt.tprintf("Could not load font file from '%s'", path), .Error);
        else   do set_font_size(state.font_size);
    }
    
    new_font_family := text.open_font_family(path) or_return;
    
    if state.did_console_create_font_family {
        text.close_font_family(state.font_family);
        delete(state.font_family_path);
    }
    state.font_family = new_font_family;
    state.did_console_create_font_family = true;

    state.font_family_path = strings.clone(path);

    return true;
}

set_font_size :: proc(font_size : int) {
    //was_muted := muted;
    //muted = true;
    //defer muted = was_muted;

    context.logger = {};
    
    if font_size < 6 {
        push_entry("Minimum font size is 6.", .Error);
        return;
    }
    if font_size > 64 {
        push_entry("Maximum font size is 64.", .Error);
        return;
    }

    first_font := state.font == nil;

    if !first_font do text.delete_font_variation(state.font);
    state.font = text.make_font_variation(state.font_family, cast(f32)font_size);
    for entry,i in state.entries {
        state.entries[i].size = text.measure(state.font, entry.content);
    }
    
    if !first_font do rerender_all();

    state.font_size = font_size;
}

reset_font :: proc() {
    state.did_console_create_font_family = false;
    state.font_family = imm_context.default_font_family;
    state.font_family_path = "";
    set_font_size(DEFAULT_FONT_SIZE);
}

init :: proc (ctx : ^imm.Imm_Context) {
    imm_context = ctx;
    //muted = true;
    
    state = {};
    
    assert(gfx.window != nil, "Window needs to be initialized before term is");
    
    state.openess = .CLOSED;
    state.caret_anim_time = 0.06;
    state.caret_color = gfx.WHITE;
    current_pos = 0.0;

    state.working_directory,_ = filepath.abs(""); // #Leak
    
    strings.builder_init(&prompt_line);
    
    state.font_family = imm_context.default_font_family;
    state.did_console_create_font_family = false;
    state.font_family_path = "";
    state.font_size = DEFAULT_FONT_SIZE;

    state.entries = make([dynamic]Entry);
    state.commands = make(map[string]Command);
    state.command_history = make([dynamic]string);
    enum_types = make(map[string]runtime.Type_Info_Enum);
    state.level_toggle_flags[int(log.Level.Debug)]   = true;
    state.level_toggle_flags[int(log.Level.Info)]    = true;
    state.level_toggle_flags[int(log.Level.Warning)] = true;
    state.level_toggle_flags[int(log.Level.Error)]   = true;
    state.level_toggle_flags[int(log.Level.Fatal)]   = true;
    state.last_suggestions = make([dynamic]string);
    
    state.display_level = .Info;
    
    
    serial.bind_struct_data_to_file(&state, "console.sync", .WRITE_CHANGES_TO_DISK);
    
    // If we load any entries they need to be marked as dirty so they are formatted
    for e, i in state.entries {
        state.entries[i].dirty = true;
    }


    if state.font_family_path != "" {
        set_font_family_from_disk(state.font_family_path);
    }
    set_font_size(state.font_size);
    
    set_caret_pos(0);

    state.history_atlases = make([dynamic]imm.Text_Atlas);

    window_size := gfx.get_window_size();
    sampler := jvk.DEFAULT_SAMPLER_SETTINGS;
    sampler.min_filter = .NEAREST;
    sampler.mag_filter = .NEAREST;
    append_atlas();
    state.history_texture = jvk.make_texture(cast(int)window_size.x, cast(int)get_view_height(), nil, .RGBA_HDR, {.SAMPLE, .DRAW}, sampler=sampler);
    state.history_target = jvk.make_texture_render_target(state.history_texture);
    state.history_pipeline = jvk.make_pipeline(imm.shaders.basic2d, state.history_target.render_pass);
    state.history_needs_render = true;
    
    bind_enum(log.Level);

    push_entry("ESC to close ");
    push_entry("F1 to open/expand/contract ");

    bind_default_commands();
}

shutdown :: proc() {
    muted = true;
    log.debug("Console shutdown");

    delete(state.command_history);

    delete(state.last_suggestions);

    // #Leak
    // Things get weird when content comes from disk.
    // Or actually the problem might be with when max_entires is reached
    //for e,i in state.entries {
        //delete(e.content); 
    //}
    delete(state.entries);

    jvk.destroy_render_target(state.history_target);
    jvk.destroy_texture(state.history_texture);
    jvk.destroy_pipeline(state.history_pipeline);

    for atlas in state.history_atlases {
        imm.destroy_text_atlas(atlas);
    }
    delete(state.history_atlases);

    text.delete_font_variation(state.font);
    if state.did_console_create_font_family {
        text.close_font_family(state.font_family);
    }

    delete(state.commands);
}

bind_default_commands :: proc() {
    bind_command("see_commands", proc () {
        builder : strings.Builder;

        sorted_keys := make([]string, len(state.commands));
        next := 0;
        for command_name in state.commands {
            sorted_keys[next] = command_name;
            next += 1;
        }

        utils.alpha_sort(sorted_keys);

        strings.builder_init_len_cap(&builder, 0, 128);
        defer strings.builder_destroy(&builder);
        strings.write_string(&builder, "List of commands:");

        for command_name in sorted_keys {
            command := state.commands[command_name];
            strings.write_string(&builder, fmt.tprintf("\n\n---- %s", command_name));
            if command.params != nil {
                strings.write_string(&builder, ":");
                for param in command.params {
                    strings.write_string(&builder, fmt.tprintf("\n\t- %s / %s", param.name, param.type));
                }
            }
        }

        push_entry(strings.to_string(builder));
    });
    bind_command("disable_console_level", proc(level : string){
        
        upper, err := strings.to_upper(level, context.temp_allocator);
        assert(err == .None);
        if      upper == "DEBUG"   do state.level_toggle_flags[log.Level.Debug] = false;
        else if upper == "INFO"    do state.level_toggle_flags[log.Level.Info] = false;
        else if upper == "WARNING" do state.level_toggle_flags[log.Level.Warning] = false;
        else if upper == "ERROR"   do state.level_toggle_flags[log.Level.Error] = false;
        else if upper == "FATAL"   do state.level_toggle_flags[log.Level.Fatal] = false;
        else {
            push_entry("Invalid level", .Error);
        }
    });
    
    bind_command("enable_console_level", proc(level : string){

        upper, err := strings.to_upper(level, context.temp_allocator);
        assert(err == .None);
        if      upper == "DEBUG"   do state.level_toggle_flags[log.Level.Debug] = true;
        else if upper == "INFO"    do state.level_toggle_flags[log.Level.Info] = true;
        else if upper == "WARNING" do state.level_toggle_flags[log.Level.Warning] = true;
        else if upper == "ERROR"   do state.level_toggle_flags[log.Level.Error] = true;
        else if upper == "FATAL"   do state.level_toggle_flags[log.Level.Fatal] = true;
        else {
            push_entry("Invalid level", .Error);
        }
    });
    bind_command("disable_all_console_levels", proc () {
        for flag,level  in state.level_toggle_flags do state.level_toggle_flags[level] = false;
    });
    bind_command("enable_all_console_levels", proc () {
        for flag,level  in state.level_toggle_flags do state.level_toggle_flags[level] = true;
    });
    bind_command("clear", proc () {
        for entry in state.entries {
            free_entry(entry);
        }
        clear(&state.entries);
        clear(&state.command_history);
        rerender_all();
        state.lookback_index = 0;
    });
    
    bind_command("push_entry", proc(text : string, level : log.Level) {
        push_entry(text, level);
    });

    bind_command("print_enum", proc(enum_name : string){
        if enum_name not_in enum_types {
            push_entry("No such enum", .Error);
            return;
        }
        tinfo := enum_types[enum_name];

        for name, index in tinfo.names {
            push_entry(fmt.tprintf("%s :: %i", name, cast(int)tinfo.values[index]));
        }
    });

    bind_command("set_caret_smooth_time", proc(anim_time : f32) {
        state.caret_anim_time = anim_time;    
    });
    bind_command("set_caret_color", proc(r, g, b, a : f32){
        state.caret_color = {r, g, b, a};
    });

    bind_command("set_font_size", set_font_size);
    bind_command("set_font_family_from_disk", set_font_family_from_disk);
    bind_command("reset_font", reset_font);

    bind_command("print_long_string", proc() -> string {
        return `For God so loved the world that he gave his one and only Son, that whoever believes in him shall not perish but have eternal life.
For God did not send his Son into the world to condemn the world, but to save the world through him. 
Whoever believes in him is not condemned, but whoever does not believe stands condemned already because they have not believed in the name of God’s one and only Son.
This is the verdict: Light has come into the world, but people loved darkness instead of light because their deeds were evil.
Everyone who does evil hates the light, and will not come into the light for fear that their deeds will be exposed. 
But whoever lives by the truth comes into the light, so that it may be seen plainly that what they have done has been done in the sight of God.`;
    });
 
    bind_command("help", proc(command_name : string) -> string {
        if command_name in state.commands {
            command := state.commands[command_name];
            return command.help_str;
        } else {
            return "No such command";
        }
    });

    bind_enum(bible.Book_Name);
    bind_command("verse", proc(book : bible.Book_Name, chapter : int, verse : int) -> string {
        verse, ok := bible.get_verse(book, chapter, verse);
        if ok {
            return verse;
        } else {
            return "No such verse found";
        }
    });
    bind_command("chapter", proc(book : bible.Book_Name, chapter_num : int) -> string {
        chapter, ok := bible.get_chapter(book, chapter_num);
        if ok {
            return chapter.display_text;
        } else {
            return "No such chapter found";
        }
    });
    bind_command("book", proc(book_name : bible.Book_Name) -> string {
        book, ok := bible.get_book(book_name);
        if ok {
            return book.display_text;
        } else {
            return "No such book found";
        }
    });
    bind_command("passage", proc(book_name : bible.Book_Name, chap_start, verse_start, chap_end, verse_end : int) -> string {
        builder : strings.Builder;
        context.allocator = context.temp_allocator;
        strings.builder_init(&builder);
        for chap in chap_start..=chap_end {
            chapter, ok := bible.get_chapter(book_name, chap);
            if !ok do break;
            min_ver, max_ver : int;
            max_ver = len(chapter.verses);

            if chap == chap_start do min_ver = verse_start;
            if chap == chap_end do max_ver = verse_end;

            min_ver = max(0, min_ver);
            max_ver = min(max_ver, len(chapter.verses));

            for ver in min_ver..<max_ver {
                verse := chapter.verses[ver];
                fmt.sbprintf(&builder, "[%i] %s ", ver, verse);
            }
        }
        if strings.builder_len(builder) == 0 do return "Invalid passage";



        return strings.to_string(builder);
    });

    bind_command("print_console_state", proc() -> string {
        return fmt.tprint(state);
    })

    bind_command("print_synced_files", proc() -> string {
        context.allocator = context.temp_allocator;
        builder : strings.Builder;
        strings.builder_init(&builder);

        for b in serial.bindings {
            fmt.sbprintln(&builder, b.path);
        }

        return strings.to_string(builder);
    });

    bind_command("print_synced_file_bytes", proc(path : string) -> string {
        context.allocator = context.temp_allocator;
        
        
        for b in serial.bindings {
            match, err := filepath.match(b.path, path);    

            if match do return fmt.tprint(mem.byte_slice(b.ptr, b.struct_info_base.size));
        }

        return "No such bound path";
    });
    bind_command("print_file_bytes", proc(path : string) -> string {
        context.allocator = context.temp_allocator;
        
        path := path;

        if !filepath.is_abs(path) {
            path = strings.join({state.working_directory, path}, sep="/");
        }
        
        file, err := os.open(path, os.O_RDONLY);

        if err == os.ERROR_NONE {
            bytes, ok := os.read_entire_file(file);

            if ok {
                return fmt.tprint(bytes);
            } else {
                return "Could not read file";
            }
        } else {
            return fmt.tprintf("Open error '%s' for '%s'", err, path);
        }
    });
    bind_command("print_file_text", proc(path : string) -> string {
        context.allocator = context.temp_allocator;
        
        path := path;

        if !filepath.is_abs(path) {
            path = strings.join({state.working_directory, path}, sep="/");
        }
        
        file, err := os.open(path, os.O_RDONLY);

        if err == os.ERROR_NONE {
            bytes, ok := os.read_entire_file(file);
            str,_ := strings.replace_all(string(bytes), "\r", "");

            if ok {
                return fmt.tprint(str);
            } else {
                return "Could not read file";
            }
        } else {
            return fmt.tprintf("Open error '%s' for '%s'", err, path);
        }
    });
    bind_command("ls", proc(path : string) -> string {
        context.allocator = context.temp_allocator;

        path := path;

        if !filepath.is_abs(path) {
            path = strings.join({state.working_directory, path}, sep="/");
        }

        if !os.exists(path) do return "Path does not exist";

        h, err := os.open(path);
        defer os.close(h);
        if err != os.ERROR_NONE do return "Could not open path";

        abs_path := path;
        if !filepath.is_abs(path) {
            abs_ok : bool;
            abs_path, abs_ok = filepath.abs(path);
            if !abs_ok do abs_path = path;
        }

        if os.is_file(path) {
            fs,err := os.file_size(h);
            if err != os.ERROR_NONE do return "Could not read file";


            return fmt.tprintf("'%s' is a file of %i bytes.", abs_path, fs);
        } else if os.is_dir(path) {

            builder : strings.Builder;
            strings.builder_init(&builder);
            entries, err := os.read_dir(h, 1000);
            if err != os.ERROR_NONE do return "Could not read directory";

            sort.bubble_sort_proc(entries, proc(a, b : os.File_Info) -> int {
                if a.is_dir && !b.is_dir do return -1;
                if !a.is_dir && b.is_dir do return 1;
                return 0;
            });

            fmt.sbprintf(&builder, "\n%s:\n\n", abs_path);

            for entry in entries {
                
                fmt.sbprintf(&builder, "[%s] %s | %i bytes | Accessed at %s | Created at %s\n", entry.is_dir ? "D" : "F", entry.name, entry.size, entry.access_time, entry.creation_time);
            }
            
            return strings.to_string(builder);
        } else {
            return "Path is something but it's not a file neither a directory.";
        }
        
    });

    bind_command("mkdir", proc(path : string) -> string {
        context.allocator = context.temp_allocator;
        path := path;
        if !filepath.is_abs(path) {
            path = strings.join({state.working_directory, path}, sep="/");
        }

        if os.exists(path) do return "Path already exists";

        err := os.make_directory(path);

        if err != os.ERROR_NONE {
            return fmt.tprint("OS error code", err);
        } else {
            return path;
        }
    });
    bind_command("touch", proc(path : string) -> string {
        context.allocator = context.temp_allocator;
        path := path;
        if !filepath.is_abs(path) {
            path = strings.join({state.working_directory, path}, sep="/");
        }

        if os.exists(path) do return "Path already exists";

        f, err := os.open(path, os.O_CREATE);

        if err != os.ERROR_NONE {
            return fmt.tprint("OS error code", err);
        } else {
            os.close(f);
            return path;
        }
    });
    bind_command("append", proc(path : string, content : string) -> string {
        context.allocator = context.temp_allocator;
        path := path;
        if !filepath.is_abs(path) {
            path = strings.join({state.working_directory, path}, sep="/");
        }

        if !os.exists(path) do return "No such file";

        if !os.is_file(path) do return "Path is not a file";

        f, err := os.open(path, os.O_APPEND);
        
        if err != os.ERROR_NONE {
            return fmt.tprint("OS error code", err);
        } else {
            written, err := os.write_string(f, content);
            if err != os.ERROR_NONE {
                return fmt.tprint("OS error code", err);
            } else {
                return fmt.tprintf("Wrote %i bytes into %s", written, path);
            }
        }
    });
    bind_command("cd", proc(path : string) -> string {
        path := path;
        if !filepath.is_abs(path) {
            path = strings.join({state.working_directory, path}, sep="/", allocator=context.temp_allocator);
        }

        if !os.exists(path) do return "No such directory";

        if !os.is_dir(path) do return "Path is not a directory";

        state.working_directory = strings.clone(path); // #Leak

        return path;
    });

    bind_command("dump_atlases", proc(dir : string) {
        if !os.exists(dir) {
            err := os.make_directory(dir);
            if err != os.ERROR_NONE {
                push_entry("Could not make directory", .Error);
                return;
            }
        }
        if !os.is_dir(dir) {
            push_entry("Path is not a directory", .Error);
            return;
        }
        for atlas,i in state.history_atlases {
            pixels_raw,_ := mem.alloc(atlas.texture.width * atlas.texture.height);
            defer free(pixels_raw);

            jvk.read_texture(atlas.texture, 0, 0, atlas.texture.width, atlas.texture.height, pixels_raw);

            stb.write_png(strings.clone_to_cstring(fmt.tprintf("%s/%i.png", dir, i), allocator=context.temp_allocator), cast(i32)atlas.texture.width, cast(i32)atlas.texture.height, 1, pixels_raw, cast(i32)atlas.texture.width);
        }

    });

    bind_command("explore_here", proc() {
        osext.open_in_explorer(state.working_directory);
    });
    bind_command("explore", proc(dir : string) {
        if !os.is_dir(dir) {
            push_entry("No such directory", .Error);
            return;
        }
        osext.open_in_explorer(dir);
    });
}

Console_Logger :: struct {
    file_handle : os.Handle,
}
create_console_logger :: proc(file_path := "log_output") -> log.Logger {
    data := new(Console_Logger);
    if !os.exists(file_path) do os.open(file_path, os.O_CREATE);
    err : os.Errno;
    data.file_handle, err = os.open(file_path, os.O_WRONLY);
    if err != os.ERROR_NONE do data.file_handle = os.INVALID_HANDLE;

	return log.Logger{console_logger_proc, data, log.Level.Debug, log.Default_Console_Logger_Opts}
}
console_logger_proc :: proc(logger_data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
    last_slash := strings.last_index_any(location.file_path, "/\\");
    filename := location.file_path[last_slash+1:] if last_slash != -1 else location.file_path;
    fmt.printf("%s [%s:%i]: %s\n", level, filename, location.line, text);
    
    if state.font != nil && #file != location.file_path do push_entry(text, level);
    logger := cast(^Console_Logger)logger_data;
    if logger.file_handle != os.INVALID_HANDLE {
        os.write_string(logger.file_handle, text);
        os.write_rune(logger.file_handle, '\n');
    }    
}