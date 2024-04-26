package gfx

import jvk "jamgine:gfx/justvk"
import "vendor:glfw"
import "core:log"
import "core:runtime"
import "core:fmt"
import "core:os"
import stb "vendor:stb/image"
import "core:strings"
import "core:c"
import "core:reflect"
import "core:slice"

import "jamgine:lin"
import img "jamgine:image_loader"

_ :: lin

inverse_color :: proc(color : lin.Vector4) -> lin.Vector4 {
    return {
        1.0 - color.r,
        1.0 - color.g,
        1.0 - color.b,
        color.a,
    };
}

TRANSPARENT :: lin.Vector4{ 0.0, 0.0, 0.0, 0.0 };
RED         :: lin.Vector4{ 1.0, 0.0, 0.0, 1.0 };
GREEN       :: lin.Vector4{ 0.0, 1.0, 0.0, 1.0 };
BLUE        :: lin.Vector4{ 0.0, 0.0, 1.0, 1.0 };
WHITE       :: lin.Vector4{ 1.0, 1.0, 1.0, 1.0 };
BLACK       :: lin.Vector4{ 0.0, 0.0, 0.0, 1.0 };
GRAY        :: lin.Vector4{ 0.5, 0.5, 0.5, 1.0 };
SILVER      :: lin.Vector4{ 0.75, 0.75, 0.75, 1.0 };
MAROON      :: lin.Vector4{ 0.5, 0.0, 0.0, 1.0 };
YELLOW      :: lin.Vector4{ 1.0, 1.0, 0.0, 1.0 };
OLIVE       :: lin.Vector4{ 0.5, 0.5, 0.0, 1.0 };
LIME        :: lin.Vector4{ 0.0, 1.0, 0.0, 1.0 };
AQUA        :: lin.Vector4{ 0.0, 1.0, 1.0, 1.0 };
TEAL        :: lin.Vector4{ 0.0, 0.5, 0.5, 1.0 };
NAVY        :: lin.Vector4{ 0.0, 0.0, 0.5, 1.0 };
FUCHSIA     :: lin.Vector4{ 1.0, 0.0, 1.0, 1.0 };
PURPLE      :: lin.Vector4{ 0.5, 0.0, 0.5, 1.0 };
ORANGE      :: lin.Vector4{ 1.0, 0.65, 0.0, 1.0 };
GOLD        :: lin.Vector4{ 1.0, 0.84, 0.0, 1.0 };
PINK        :: lin.Vector4{ 1.0, 0.75, 0.8, 1.0 };
PEACH       :: lin.Vector4{ 1.0, 0.85, 0.7, 1.0 };
MAGENTA     :: lin.Vector4{ 1.0, 0.0, 1.0, 1.0 };
LAVENDER    :: lin.Vector4{ 0.9, 0.9, 0.98, 1.0 };
PLUM        :: lin.Vector4{ 0.87, 0.63, 0.87, 1.0 };
TAN         :: lin.Vector4{ 0.82, 0.71, 0.55, 1.0 };
BEIGE       :: lin.Vector4{ 0.96, 0.96, 0.86, 1.0 };
MINT        :: lin.Vector4{ 0.24, 0.71, 0.54, 1.0 };
LIME_GREEN  :: lin.Vector4{ 0.2, 0.8, 0.2, 1.0 };
OLIVE_DRAB  :: lin.Vector4{ 0.42, 0.56, 0.14, 1.0 };
BROWN       :: lin.Vector4{ 0.43, 0.26, 0.06, 1.0 };
CHOCOLATE   :: lin.Vector4{ 0.82, 0.41, 0.12, 1.0 };
CORAL       :: lin.Vector4{ 1.0, 0.5, 0.31, 1.0 };
SALMON      :: lin.Vector4{ 0.98, 0.5, 0.45, 1.0 };
TOMATO      :: lin.Vector4{ 1.0, 0.39, 0.28, 1.0 };
CRIMSON     :: lin.Vector4{ 0.86, 0.08, 0.24, 1.0 };
TURQUOISE   :: lin.Vector4{ 0.25, 0.88, 0.82, 1.0 };
INDIGO      :: lin.Vector4{ 0.29, 0.0, 0.51, 1.0 };
VIOLET      :: lin.Vector4{ 0.93, 0.51, 0.93, 1.0 };
SKY_BLUE    :: lin.Vector4{ 0.53, 0.81, 0.92, 1.0 };
SOFT_GRAY   :: lin.Vector4{ 0.85, 0.70, 0.75, 1.0 };
CORNFLOWER_BLUE :: lin.Vector4{ 0.392, 0.584, 0.929, 1.0 };

Window_Event :: struct {
    handled : bool,
    variant : Window_Event_Variant,
}
Window_Resize_Event :: struct {
    width, height : f32,
}
Window_Char_Event :: struct {
    char : rune,
}
Window_Key_Event :: struct {
    key, scancode, action, mods: c.int,
}
Window_Button_Event :: struct {
    button, action, mods: c.int,
}
Window_Scroll_Event :: struct {
    xscroll, yscroll : f32,
}
Window_Mouse_Move_Event :: struct {
    xpos, ypos : f32,
}
Window_Event_Variant :: union {
    Window_Resize_Event,
    Window_Char_Event,
    Window_Key_Event,
    Window_Button_Event,
    Window_Scroll_Event,
    Window_Mouse_Move_Event
}
make_window_event :: proc(thing : $T) -> Window_Event {
    e : Window_Event;
    e.handled = false;
    e.variant = thing;

    return e;
}

window_events : [dynamic]Window_Event;

window_event_is :: proc(e : Window_Event, $T : typeid) -> bool {
    return reflect.union_variant_typeid(e.variant) == T;
}

env : struct {
    max_texture_size : int,
};
window : glfw.WindowHandle;
CURSOR_HRESIZE : glfw.CursorHandle;
CURSOR_VRESIZE : glfw.CursorHandle;
CURSOR_ARROW   : glfw.CursorHandle;
CURSOR_IBEAM   : glfw.CursorHandle;
CURSOR_HAND    : glfw.CursorHandle;
CURSOR_CROSSHAIR    : glfw.CursorHandle;
window_surface : ^jvk.Draw_Surface;
default_context : runtime.Context;
clear_color := lin.Vector4{0.2, 0.2, 0.3, 1.0};

should_window_close :: proc() -> bool {
    return cast(bool)glfw.WindowShouldClose(window);
}

// Potentially slow. If #Speed is a concern, prefer polling window events
// for latest framebuffer size instead.
get_window_size :: proc() -> lin.Vector2 {
    width, height := glfw.GetFramebufferSize(window);
    for (width == 0 || height == 0) {
        width, height = glfw.GetFramebufferSize(window);
        fmt.println("Hey");
        glfw.WaitEvents();
    };
    return { cast(f32)width, cast(f32)height };
}
get_current_mouse_pos :: proc() -> lin.Vector2 {
    x, y := glfw.GetCursorPos(window);

    return {cast(f32)x, get_window_size().y-cast(f32)y};
}

set_window_event_callbacks :: proc() {
    glfw.SetFramebufferSizeCallback(window, proc "c" (window: glfw.WindowHandle, width, height: i32) {
        context = default_context;

        //jvk.resize_draw_surface(window_surface, cast(uint)width, cast(uint)height);

        append(&window_events, make_window_event(Window_Resize_Event{cast(f32)width, cast(f32)height}));
    });

    glfw.SetCharCallback(window, proc "c" (window: glfw.WindowHandle, char: rune) {
        context = default_context;

        append(&window_events, make_window_event(Window_Char_Event{char}));
    });
    glfw.SetKeyCallback(window, proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
        context = default_context;

        append(&window_events, make_window_event(Window_Key_Event{key, scancode, action, mods}));
    });
    glfw.SetMouseButtonCallback(window, proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
        context = default_context;

        append(&window_events, make_window_event(Window_Button_Event{button, action, mods}));
    });
    glfw.SetScrollCallback(window, proc "c" (window: glfw.WindowHandle, xoffset, yoffset : f64) {
        context = default_context;

        append(&window_events, make_window_event(Window_Scroll_Event{cast(f32)xoffset, cast(f32)yoffset}));
    });
    glfw.SetCursorPosCallback(window, proc "c" (window: glfw.WindowHandle, xoffset, yoffset : f64) {
        context = default_context;

        append(&window_events, make_window_event(Window_Mouse_Move_Event{cast(f32)xoffset, get_window_size().y-cast(f32)yoffset}));
    });
}

init_and_open_window :: proc(title : cstring = "JAMGINE APP by CMQV", width := 1280, height := 720, enable_depth_test := false) -> bool {

    
    if glfw.Init() != true {
        log.error("Failed initializing glfw");
        return false;
    }
    
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API);
    window = glfw.CreateWindow(cast(i32)width, cast(i32)height, title, nil, nil);
    jvk_init_result := jvk.init(string(title));
    assert(jvk_init_result, "Failed initializing jvk");
    device_context := jvk.make_device_context();
    jvk.set_target_device_context(device_context);
    window_surface = jvk.make_draw_surface(window, enable_depth_test=enable_depth_test);
    
    env.max_texture_size = cast(int)device_context.graphics_device.props.limits.maxImageDimension2D;

    window_events = make([dynamic]Window_Event);

    set_window_event_callbacks();

    CURSOR_HRESIZE = glfw.CreateStandardCursor(glfw.HRESIZE_CURSOR);
    CURSOR_VRESIZE = glfw.CreateStandardCursor(glfw.VRESIZE_CURSOR);
    CURSOR_ARROW = glfw.CreateStandardCursor(glfw.ARROW_CURSOR);
    CURSOR_IBEAM = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR);
    CURSOR_HAND = glfw.CreateStandardCursor(glfw.HAND_CURSOR);
    CURSOR_CROSSHAIR = glfw.CreateStandardCursor(glfw.CROSSHAIR_CURSOR);

    return true;
}
take_window_event :: proc($T : typeid) -> (^T) {
    for e,i in window_events {
        if e.handled do continue;
        #partial switch v in e.variant {
            case T: {
                return &window_events[i].variant.(T);
            }
        }    
    }
    return nil;
}


collect_window_events :: proc() {
    glfw.PollEvents();
}
// Clears events, swaps buffers, and clears front buffer
// #Rename
update_window :: proc() {    
    default_context = context;
    clear(&window_events);

    jvk.present_surface(window_surface);
}

shutdown :: proc() {
    log.debug("Gfx shutdown");
    glfw.DestroyWindow(window);
    jvk.destroy_draw_surface(window_surface);
    jvk.destroy_device_context(jvk.get_target_device_context());
    jvk.shutdown();
    glfw.Terminate();
}



load_texture_from_disk :: proc(path : string, sampler := jvk.DEFAULT_SAMPLER_SETTINGS, usage : jvk.Texture_Usage_Mask = {.SAMPLE, .WRITE}) -> (texture: jvk.Texture, ok: bool) {

    if !os.exists(path) do return {}, false;

    stb.set_flip_vertically_on_load(1);
    // #Videomem #Redundant all textures don't need to be 128-bit hdr
    data, w, h, c, img_ok := img.decode_image_file_to_srgb_f32(path, 4);
    ok = img_ok;

    if !ok do return;

    defer img.delete_image_argb(data);

    return jvk.make_texture(cast(int)w, cast(int)h, slice.as_ptr(data), .RGBA_HDR, usage=usage, sampler=sampler), true;
}