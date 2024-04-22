package input

import "jamgine:gfx"
import "jamgine:lin"
import "vendor:glfw"
import "core:c"
import "core:fmt"

window : glfw.WindowHandle;

key_states              : [glfw.KEY_LAST + 1]c.int;
button_states           : [glfw.MOUSE_BUTTON_LAST+1]c.int;
last_key_states         : [glfw.KEY_LAST + 1]c.int;
last_button_states      : [glfw.MOUSE_BUTTON_LAST+1]c.int;
last_mouse_scroll_total : lin.Vector2;
mouse_scroll_total      : lin.Vector2;
last_mouse_pos          : lin.Vector2;
mouse_pos               : lin.Vector2;
mod_flags               : map[c.int]bool;

init :: proc(target_window : glfw.WindowHandle) {
    window = target_window;

    mod_flags = make(map[c.int]bool);
}

update :: proc() {
    copy(last_key_states[:], key_states[:]);
    copy(last_button_states[:], button_states[:]);

    last_mouse_pos = mouse_pos;
    last_mouse_scroll_total = mouse_scroll_total;

    for e,i in gfx.window_events {
        if e.handled do continue;
        gfx.window_events[i].handled = true;
        #partial switch v in e.variant {
            case gfx.Window_Key_Event: {
                using key_event := e.variant.(gfx.Window_Key_Event);
                handle_key(key, scancode, action, mods);
            }
            case gfx.Window_Button_Event: {
                using button_event := e.variant.(gfx.Window_Button_Event);
                handle_mouse_button(button, action, mods);
            }
            case gfx.Window_Scroll_Event: {
                using scroll_event := e.variant.(gfx.Window_Scroll_Event);
                handle_mouse_scroll(xscroll, yscroll);
            }
            case gfx.Window_Mouse_Move_Event: {
                using move_event := e.variant.(gfx.Window_Mouse_Move_Event);
                handle_mouse_move(xpos, ypos);
            }
            case: {
                gfx.window_events[i].handled = false;
            }
        }
    }
}

update_mods :: proc(input_mods : c.int) {
    mod_flags[glfw.MOD_ALT]       = (input_mods & glfw.MOD_ALT) != 0;
    mod_flags[glfw.MOD_CAPS_LOCK] = (input_mods & glfw.MOD_CAPS_LOCK) != 0;
    mod_flags[glfw.MOD_CONTROL]   = (input_mods & glfw.MOD_CONTROL) != 0;
    mod_flags[glfw.MOD_NUM_LOCK]  = (input_mods & glfw.MOD_NUM_LOCK) != 0;
    mod_flags[glfw.MOD_SHIFT]     = (input_mods & glfw.MOD_SHIFT) != 0;
    mod_flags[glfw.MOD_SUPER]     = (input_mods & glfw.MOD_SUPER) != 0;
}

handle_key :: proc(glfw_key, scancode, action, mods : c.int) {
    update_mods(mods);

    if action == glfw.PRESS || action == glfw.RELEASE do key_states[glfw_key] = action;
}
handle_mouse_button :: proc(glfw_button, action, mods : c.int) {
    update_mods(mods);

    if action == glfw.PRESS || action == glfw.RELEASE do button_states[glfw_button] = action;
}
handle_mouse_scroll :: proc(x, y : f32) {
    mouse_scroll_total += {x, y};
}
handle_mouse_move :: proc(x, y : f32) {
    mouse_pos = {x, y};
}

is_key_down :: proc(key : c.int, mod : c.int = 0) -> bool {
    assert(key >= 0 && key < cast(c.int)len(key_states), "Invalid glfw mouse button value");
    return key_states[key] == glfw.PRESS && (true if mod == 0 else mod_flags[mod]);
}
is_key_just_pressed :: proc(key : c.int, mod : c.int = 0) -> bool {
    assert(key >= 0 && key < cast(c.int)len(key_states), "Invalid glfw mouse button value");
    return key_states[key] == glfw.PRESS && last_key_states[key] == glfw.RELEASE && (true if mod == 0 else mod_flags[mod]);
}
is_key_just_released :: proc(key : c.int, mod : c.int = 0) -> bool {
    assert(key >= 0 && key < cast(c.int)len(key_states), "Invalid glfw mouse button value");
    return key_states[key] == glfw.RELEASE && last_key_states[key] == glfw.PRESS && (true if mod == 0 else mod_flags[mod]);
}
is_mouse_down :: proc(button : c.int, mod : c.int = 0) -> bool {
    assert(button >= 0 && button < cast(c.int)len(button_states), "Invalid glfw mouse button value");
    return button_states[button] == glfw.PRESS && (true if mod == 0 else mod_flags[mod]);
}
is_mouse_just_pressed :: proc(button : c.int, mod : c.int = 0) -> bool {
    assert(button >= 0 && button < cast(c.int)len(button_states), "Invalid glfw mouse button value");
    return button_states[button] == glfw.PRESS && last_button_states[button] == glfw.RELEASE && (true if mod == 0 else mod_flags[mod]);
}
is_mouse_just_released :: proc(button : c.int, mod : c.int = 0) -> bool {
    assert(button >= 0 && button < cast(c.int)len(button_states), "Invalid glfw mouse button value");
    return button_states[button] == glfw.RELEASE && last_button_states[button] == glfw.PRESS && (true if mod == 0 else mod_flags[mod]);
}

is_mod_active :: proc(mod : c.int) -> bool {
    return mod_flags[mod];
}

get_mouse_xscroll :: proc() -> f32 {
    return mouse_scroll_total.x - last_mouse_scroll_total.x;
}
get_mouse_yscroll :: proc() -> f32 {
    return mouse_scroll_total.y - last_mouse_scroll_total.y;
}
get_mouse_position :: proc() -> lin.Vector2 {
    return mouse_pos;
}
get_mouse_position_x :: proc() -> f32 {
    return mouse_pos.x;
}
get_mouse_position_y :: proc() -> f32 {
    return mouse_pos.y;
}
get_mouse_move :: proc() -> lin.Vector2 {
    return mouse_pos - last_mouse_pos;
}