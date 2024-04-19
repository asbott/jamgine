package imm_gui

import "core:math"
import "core:math/rand"
import "core:time"
import "core:hash"
import "core:strings"
import "core:slice"
import "core:intrinsics"
import "core:mem"
import "core:builtin"
import "core:c"
import "core:fmt"
import "core:sort"
import "core:strconv"
import "core:unicode"
import "core:unicode/utf8"

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:gfx/text"
import "jamgine:lin"

import "vendor:glfw"

Interp_Color :: struct {
    start_time : f32,
    start_color : lin.Vector4,

    interp_duration : f32,

    target_color : lin.Vector4,
}
make_interp_color :: proc(start, target : lin.Vector4, now, duration : f32) -> Interp_Color {
    c : Interp_Color;
    
    c.start_color = start;
    c.target_color = target;
    c.start_time = now;
    c.interp_duration = duration;

    return c;
}
get_interp_color :: proc(color : Interp_Color, now : f32) -> lin.Vector4 {
    passed := now - color.start_time;
    factor := passed/color.interp_duration;

    if factor <= 1 {
        return math.lerp(color.start_color, color.target_color, math.smoothstep(f32(0.0), f32(1.0), factor));
    }
    return color.target_color;
}
set_widget_color :: proc(widget : ^Widget_State, new_color : lin.Vector4, using ctx : ^Gui_Context) {
    if widget.color.target_color == new_color do return;
    now := get_time(ctx);
    now_color := get_interp_color(widget.color, now);
    widget.color.start_color = now_color;
    widget.color.target_color = new_color;
    widget.color.start_time = now;
    widget.color.interp_duration = style.color_shift_time;
}

Widget_Id :: int;

Any_Draw_Command :: union {
    Draw_Command_Rect,
    Draw_Command_Scissor,
    Draw_Command_Line,
    Draw_Command_Text,
    Draw_Command_Shadow_Rect,
}
Draw_Command :: struct {
    priority : int,
    variant : Any_Draw_Command,
}
Draw_Command_Rect :: struct {
    pos, size : lin.Vector2,
    color : lin.Vector4,
}
Draw_Command_Shadow_Rect :: struct {
    pos, size : lin.Vector2,
    color : lin.Vector4,
}
Draw_Command_Line :: struct {
    a, b : lin.Vector2,
    color : lin.Vector4,
}
Draw_Command_Scissor :: struct {
    L, R, B, T : f32,
}
Draw_Command_Text :: struct {
    pos : lin.Vector2,
    text : string,
    color : lin.Vector4,
}
get_widget_color :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> lin.Vector4 {
    return get_interp_color(widget.color, get_time(ctx));
}
get_widget_visual_bounds :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> (L, R, B, T : f32) {

    window_size := gfx.get_window_size();

    L, R, B, T = get_widget_functional_bounds(ctx, widget);

    parent : ^Widget_State;
    if widget.parent == -1 do return;

    next := &state.widgets[widget.parent];
    for next != nil {
        
        pL, pR, pB, pT := get_widget_functional_bounds(ctx, next);
        //pos := next.origin + next.pos;
        L = max(L, pL);
        B = max(B, pB);
        R = min(R, pR);
        T = min(T, pT);

        next = &state.widgets[next.parent] if next.parent != -1 else nil;
    }

    return;
}
has_any_parent_state_flags :: proc(using ctx : ^Gui_Context, widget : ^Widget_State, flags : Widget_State_Flags) -> bool {
    if widget.parent == -1 do return false;

    next := &state.widgets[widget.parent];
    for next != nil {

        if (flags & next.state) == flags do return true;

        next = &state.widgets[next.parent] if next.parent != -1 else nil;
    }

    return false;
}
set_absolute_pos :: proc(using ctx : ^Gui_Context, widget : ^Widget_State, pos : lin.Vector2) {
    
    if widget.parent == -1 {
        widget.pos = pos;
        return;
    }

    origin : lin.Vector2;

    next := &state.widgets[widget.parent];
    for next != nil {

        origin += next.pos;

        next = &state.widgets[next.parent] if next.parent != -1 else nil;
    }

    widget.pos = pos - origin;
}
get_absolute_pos :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> lin.Vector2 {
    if widget.parent == -1 {
        return widget.pos;
    }

    origin : lin.Vector2;

    next := &state.widgets[widget.parent];
    for next != nil {

        origin += next.pos;

        next = &state.widgets[next.parent] if next.parent != -1 else nil;
    }

    return origin + widget.pos;
}
adjust_pos_for_parent_scroll :: proc(using ctx : ^Gui_Context, parent : ^Widget_State, pos : ^lin.Vector2) {
    parent_pos := get_absolute_pos(ctx, parent);

    phs := parent.size/2;
    pL, pR, pB, pT := parent_pos.x-phs.x, parent_pos.x+phs.x, parent_pos.y-phs.y, parent_pos.y+phs.y;
    
    min_scroll_x := pL - parent.last_content_min.x;
    max_scroll_x := parent.last_content_max.x - pR;
    min_scroll_y := pB - parent.last_content_min.y;
    max_scroll_y := parent.last_content_max.y - pT;

    
    offset_left := pos.x - pL;
    offset_content_left := pos.x - parent.last_content_min.x;
    pos.x += offset_content_left - offset_left;
    total_x_overflow := pL - parent.last_content_min.x + parent.last_content_max.x - pR;
    pos.x -= total_x_overflow * parent.hscroll;

    offset_bot := pos.y - pB;
    offset_content_bot := pos.y - parent.last_content_min.y;
    pos.y += offset_content_bot - offset_bot;
    total_y_overflow := pB - parent.last_content_min.y + parent.last_content_max.y - pT;
    pos.y -= total_y_overflow * parent.vscroll;
}
get_final_pos :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> lin.Vector2 {
    if widget.parent == -1 {
        return widget.pos;
    }

    parent := &state.widgets[widget.parent];

    
    parent_pos := get_final_pos(ctx, parent);
    pos := parent_pos + widget.pos;
    hs := widget.size/2;
    if .ALLOW_OVERFLOW in parent.flags && .STICKY not_in widget.flags {
        adjust_pos_for_parent_scroll(ctx, parent, &pos);
    }
    

    abs_pos := get_absolute_pos(ctx, widget);
    L, R, B, T := abs_pos.x-hs.x, abs_pos.x+hs.x, abs_pos.y-hs.y, abs_pos.y+hs.y;
    left_overflow := parent.last_content_min.x - L;
    right_overflow := R - parent.last_content_max.x;
    bot_overflow := parent.last_content_min.y - B;
    top_overflow := T - parent.last_content_max.y;

    if (.ALLOW_OVERFLOW not_in parent.flags || .EAST not_in parent.overflow_flags) && right_overflow > 0 {
        pos.x -= right_overflow;
    }
    if (.ALLOW_OVERFLOW not_in parent.flags || .WEST not_in parent.overflow_flags) && left_overflow > 0 {
        pos.x += left_overflow;
    }
    if (.ALLOW_OVERFLOW not_in parent.flags || .NORTH not_in parent.overflow_flags) && top_overflow > 0 {
        pos.y -= top_overflow;
    }
    if (.ALLOW_OVERFLOW not_in parent.flags || .SOUTH not_in parent.overflow_flags) && bot_overflow > 0 {
        pos.y += bot_overflow;
    }

    return pos;
}
get_widget_functional_bounds :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> (L, R, B, T : f32) {
    p := get_final_pos(ctx, widget);
    hs := widget.size/2;
    
    L, R, B, T = p.x-hs.x, p.x+hs.x, p.y-hs.y, p.y+hs.y;

    return;

}
get_widget_absolute_bounds :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> (L, R, B, T : f32) {
    p := get_absolute_pos(ctx, widget);
    hs := widget.size/2;
    
    L, R, B, T = p.x-hs.x, p.x+hs.x, p.y-hs.y, p.y+hs.y;

    return;

}
bounds_to_rect :: proc(L, R, B, T : f32) -> lin.Vector4 {
    w := R - L;
    h := T - B;
    x := L + w/2;
    y := B + h/2;

    return {x, y, w, h};
}
get_widget_priority :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> int {
    prio := widget.priority;

    next := widget;
    for next.parent != -1 {
        next = &ctx.state.widgets[next.parent];
    }

    if next != widget do prio += next.priority;

    return prio;
}
add_draw_command :: proc(using ctx : ^Gui_Context, cmd_variant : Any_Draw_Command, priority : int = -1) {

    priority := priority;

    if priority == -1 {
        priority = draw_commands[len(draw_commands)-1].priority if len(draw_commands) > 0 else 0;
    }

    cmd : Draw_Command;
    cmd.variant = cmd_variant;
    cmd.priority = priority;
    append(&ctx.draw_commands, cmd);
}
clear_frame :: proc(using ctx := active_ctx) {
    clear(&ctx.draw_commands);
} 
draw :: proc(using ctx := active_ctx) {
    
    //fmt.println("\nunsorted");
    //for cmd in ctx.draw_commands {
    //    fmt.println(cmd);
    //}

    {
        // Need stability because commands of same priority needs to maintain
        // their order, hence merge sort. This one doesn't use a temporary
        // array so no extra memory usage, but a bit more computation.
        // #Speed
        sort.merge_sort_proc(draw_commands[:], proc(a, b : Draw_Command) -> int {
            return a.priority - b.priority;
        });
    }
    

    
    imm.begin2d();
    assert(len(imm.get_current_context().vertices) == 0);
    //fmt.println("cmd");
    for cmd in ctx.draw_commands {
        //fmt.println(cmd);
        switch v in cmd.variant {
            case Draw_Command_Rect: {
                imm.rectangle(lin.v3(v.pos), v.size, color=v.color);
            }
            case Draw_Command_Shadow_Rect: {
                imm.shadow_rectangle(lin.v3(v.pos), v.size, color=v.color);
            }
            case Draw_Command_Line: {
                imm.line(lin.v3(v.a), lin.v3(v.b), color=v.color);
            }
            case Draw_Command_Text: {
                imm.text(v.text, lin.v3(v.pos), color=v.color);
            }
            case Draw_Command_Scissor: {
                w := v.R - v.L;
                h := v.T - v.B;
                x := v.L + w / 2;
                y := v.B + h / 2;
                imm.set_scissor_box(x, y, w, h);
            }
        }
    }
    imm.flush();
    clear_frame();
}

Gui_Context :: struct {
    sw : time.Stopwatch,
    style : Gui_Style,
    state : Gui_State,
    last_state : Gui_State,
    input : Gui_Input,
    delta_seconds : f32,
    

    draw_commands : [dynamic]Draw_Command,
}
Resize_Dir :: enum {
    SW, NW, NE, SE, W, N, E, S, NONE
}
Gui_State :: struct {
    widgets : map[Widget_Id]Widget_State,
    id_stack : [dynamic]Widget_Id,
    window_id_stack : [dynamic]Widget_Id,
    held_id : Widget_Id, // -1 if none
    hovered_id : Widget_Id,
    focused_id : Widget_Id,
    active_id : Widget_Id,
    active_resize : Resize_Dir,
    widget_activated_pos : lin.Vector2,
    cursor : glfw.CursorHandle,
    top_priority : int,
    last_widget : int,
    next_widget_flags : Widget_Flags,
    next_style_vars : Style_Vars,
}
Gui_Style :: struct {
    panel : Style_Vars,

    panel_resize_space    : f32,

    resize_color_active : lin.Vector4,
    resize_color_hovered : lin.Vector4,

    default_panel_size : lin.Vector2,
    default_panel_child_size : lin.Vector2,
    color_shift_time : f32,

    slider_thickness : f32,
    handle_thickness : f32,

    panel_shadow_width : f32,
    scrollbar_width : f32,

    field_padding : f32,
    widget_padding : f32,
    title_bar_height : f32,
    window_border_padding : f32,
    window_title_side_padding : f32,
    label_padding : f32,
    button_inner_padding : f32,

    default_spacing : f32,

    separator_color : lin.Vector4,

    checkbox_size : f32,
    checkmark_width : f32,
    checkmark_color : lin.Vector4,
}
Style_Vars :: struct {
    color_unfocused : lin.Vector4,
    color_focused   : lin.Vector4,
    color_hovered   : lin.Vector4,
    color_active    : lin.Vector4,
    color_focused_secondary : lin.Vector4,
    color_hovered_secondary : lin.Vector4,
    color_active_secondary  : lin.Vector4,
    border_color : lin.Vector4,
}
DEFAULT_GUI_STYLE :: Gui_Style {
    panel = {
        color_unfocused={.15, .15, .15, 1.0},
        color_focused={.05, .05, .05, 1.0},
        color_hovered={.1, .1, .1, 1.0},
        color_active ={.0, .0, .0, 0.95},
        color_focused_secondary={.075, .075, .075, 1.0},
        color_hovered_secondary={.115, .115, .115, 1.0},
        color_active_secondary ={.075, .075, .075, 1.0},
        border_color={0.9, 0.9, 0.9, 0.4},
    },
    resize_color_active={0.7, 0.7, 0.7, 1.0},
    resize_color_hovered={0.9, 0.9, 0.9, 1.0},
    default_panel_size={200, 400},
    default_panel_child_size={100, 100},
    color_shift_time=0.1,
    slider_thickness=16,
    handle_thickness=16,
    panel_shadow_width=8,
    scrollbar_width=16,
    field_padding=4,
    widget_padding=8,
    title_bar_height=28,
    window_border_padding=8,
    window_title_side_padding=16,
    label_padding=4,
    button_inner_padding=12,
    default_spacing=12,
    separator_color={0.8, 0.8, 0.8, 0.6},
    checkbox_size=24,
    checkmark_width=4,
    checkmark_color={0.9, 0.9, 0.9, 1.0},
}
Gui_Input :: struct {
    key_states              : [glfw.KEY_LAST + 1]bool,
    button_states           : [glfw.MOUSE_BUTTON_LAST+1]bool,
    last_key_states         : [glfw.KEY_LAST + 1]bool,
    last_button_states      : [glfw.MOUSE_BUTTON_LAST+1]bool,
    button_click_times      : [glfw.MOUSE_BUTTON_LAST+1]f32,
    button_click_positions  : [glfw.MOUSE_BUTTON_LAST+1]lin.Vector2,
    last_mouse_scroll_total : lin.Vector2,
    mouse_scroll_total      : lin.Vector2,
    mouse_scroll_delta      : lin.Vector2,
    last_mouse_pos          : lin.Vector2,
    mouse_pos               : lin.Vector2,
    mouse_down_pos          : lin.Vector2,
    mod_flags               : map[c.int]bool,
    chars                   : [dynamic]rune,
}

Widget_Flag :: enum {
    CAPTURES_TEXT, MOVE_CHILDREN_ON_OVERFLOW,
    ALLOW_RESIZE, ALLOW_MOVE, ALLOW_ACTIVE, 
    ALLOW_FOCUS, ALLOW_OVERFLOW, ALLOW_VSCROLL, 
    ALLOW_HSCROLL,

    SLIDER, HANDLE, BUTTON, LABEL, TEXT_FIELD,
    WINDOW, DRAG,

    STICKY,

    IGNORE_INPUT, FOCUS_REQUIRES_DOUBLE_CLICK,
}
Widget_Flags :: bit_set[Widget_Flag];

Widget_State_Flag :: enum {
    FOCUSED, HOVERED, ACTIVE,
    ANY_CHILD_FOCUSED, ANY_CHILD_HOVERED, ANY_CHILD_ACTIVE,

    HSCROLL_VISIBLE, VSCROLL_VISIBLE,
}
Widget_State_Flags :: bit_set[Widget_State_Flag];
Overflow_Flag :: enum {
    NORTH, EAST, SOUTH, WEST,
}
Overflow_Flags :: bit_set[Overflow_Flag];

Widget_State :: struct {
    parent : Widget_Id,
    begin_active : bool,
    pos : lin.Vector2,
    size : lin.Vector2,
    color : Interp_Color,
    flags : Widget_Flags,
    overflow_flags : Overflow_Flags,
    state : Widget_State_Flags,
    last_state : Widget_State_Flags,
    priority : int,
    style : Style_Vars,
    content_min : lin.Vector2,
    content_max : lin.Vector2,
    last_content_min : lin.Vector2,
    last_content_max : lin.Vector2,
    hscroll, vscroll : f32,
    first_frame : bool,

    // For text widgets
    caret_pos : int,

    // For numerical widgets wrapping around text widgets
    builder : ^strings.Builder,

    window : Maybe(Window_State),
}
Window_State :: struct {
    pen : lin.Vector2,
    current_row_top : f32,
    current_row_bot : f32,
    title : string,
    columns : int,
    current_column : int,
    open_ptr : ^bool,
}

Text_Filter_Proc :: #type proc(char : rune) -> bool;

active_ctx : ^Gui_Context;

get_time :: proc(using ctx : ^Gui_Context) -> f32 {
    return cast(f32)time.duration_seconds(time.stopwatch_duration(sw))
}

make_gui_context :: proc() -> ^Gui_Context {
    ctx := new(Gui_Context);
    ctx.style = DEFAULT_GUI_STYLE;
    ctx.draw_commands = make([dynamic]Draw_Command, 0, 2048);
    ctx.state.widgets = make(type_of(ctx.state.widgets), 2048);
    ctx.state.id_stack = make([dynamic]Widget_Id);
    ctx.state.window_id_stack = make([dynamic]Widget_Id);
    ctx.state.held_id = -1;
    ctx.state.hovered_id = -1;
    ctx.state.focused_id = -1;
    ctx.state.active_id = -1;
    ctx.state.last_widget = -1;
    ctx.state.active_resize = .NONE;
    ctx.last_state = ctx.state;
    ctx.input.mod_flags = make(map[c.int]bool);
    ctx.input.chars = make([dynamic]rune);
    ctx.style.panel_resize_space = 4;
    ctx.delta_seconds = 1.0 / 60.0;

    ctx.state.next_style_vars = ctx.style.panel;

    time.stopwatch_start(&ctx.sw);

    return ctx;
}
make_and_set_gui_context :: proc() {
    active_ctx = make_gui_context();
}
destroy_context :: proc(using ctx : ^Gui_Context) {
    delete(ctx.state.id_stack)
    delete(ctx.state.window_id_stack)
    delete(ctx.state.widgets);
    delete(ctx.draw_commands);
    free(ctx);
}
destroy_current_context :: proc() {
    destroy_context(get_current_context());
}
set_current_context :: proc(ctx : ^Gui_Context) {
    active_ctx = ctx;
}
get_current_context :: proc() -> ^Gui_Context {
    return active_ctx;
}

extract_id_and_label :: proc(label_id : string) -> (id : Widget_Id, label : string) {
    idx := strings.index(label_id, "##");
    if idx == -1 do idx = len(label_id);
    id = cast(Widget_Id)hash.murmur64b(mem.byte_slice(builtin.raw_data(label_id), len(label_id)));

    label = label_id[:idx];

    return;
}

begin_window :: proc(named_id : string, open_ptr : ^bool = nil, flags : Widget_Flags = {.WINDOW, .ALLOW_ACTIVE, .ALLOW_FOCUS, .ALLOW_HSCROLL, .ALLOW_VSCROLL, .ALLOW_MOVE, .ALLOW_OVERFLOW, .ALLOW_RESIZE}, using ctx := active_ctx) {
    id, title := extract_id_and_label(named_id);

    begin_panel(id, flags, ctx);

    {
        w := &state.widgets[id];        
        if w.window == nil do w.window = Window_State{};
        window := &w.window.(Window_State);
        window.pen.x = -w.size.x/2 + style.window_border_padding;
        window.pen.y = w.size.y/2 - style.title_bar_height - style.window_border_padding;
        window.current_row_top = window.pen.y;
        window.current_row_bot = window.pen.y;
        window.open_ptr = open_ptr;

        window.title = title;
        append(&state.window_id_stack, id); 
    }
}
end_window :: proc(using ctx := active_ctx) {
    assert(len(state.window_id_stack) > 0, "End was called on empty window stack");

    id := state.window_id_stack[len(state.window_id_stack)-1];
    window := state.widgets[id].window.(Window_State);

    begin_panel(id + 100, {.IGNORE_INPUT, .STICKY}, ctx);
    set_widget_pos(0, state.widgets[id].size.y / 2 - style.title_bar_height/2, ctx);
    set_widget_size(state.widgets[id].size.x, style.title_bar_height, ctx);

    title_size := text.measure(imm.get_current_context().default_font, window.title);
    label_raw(id + 110, {state.widgets[id].size.x/2 - title_size.x/2 - style.window_title_side_padding, 0}, window.title, ctx=ctx);

    if window.open_ptr != nil {
        side := style.title_bar_height - style.window_border_padding*2;
        close_button_size := lin.Vector2{side, side};
        if button_raw(id + 131, {-state.widgets[id].size.x/2 + style.window_title_side_padding + close_button_size.x/2 , 0}, close_button_size, text="x", ctx=ctx) {
            window.open_ptr^ = false;
        }
    }

    end_panel(ctx);

    invisible_panel_raw(id + 130, {0, window.pen.y - style.window_border_padding/2}, {state.widgets[id].size.x, style.window_border_padding}, ctx)


    end_panel(ctx);
    pop(&state.window_id_stack);
}

invisible_panel :: proc(str_id : string, size : lin.Vector2, using ctx := active_ctx) {
    assert(len(state.window_id_stack) > 0, "Formatted widget call on window stack");
    window_id := state.window_id_stack[len(state.window_id_stack)-1];
    window := state.widgets[window_id].window.(Window_State);

    id, _ := extract_id_and_label(str_id);
    invisible_panel_raw(id, {window.pen.x + size.x/2, window.pen.y - size.y/2}, size, ctx);

    move_pen_after_widget(size, ctx);
}
invisible_panel_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, using ctx := active_ctx) {

    invisible_style : Style_Vars;
    set_next_widget_style(invisible_style, ctx);
    begin_panel(id, {.IGNORE_INPUT}, ctx);
    set_widget_pos(pos.x, pos.y, ctx);
    set_widget_size(size.x, size.y, ctx);
    end_panel(ctx);
}

@(private)
move_pen_after_widget :: proc(widget_size : lin.Vector2, using ctx := active_ctx) {
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");

    window_id := state.window_id_stack[len(state.window_id_stack)-1];
    window := state.widgets[window_id].window.(Window_State);

    window.current_row_bot = min(window.current_row_bot, window.pen.y - widget_size.y);
    
    if window.current_column >= window.columns {
        window.current_column = 0;
        window.pen.x = -state.widgets[window_id].size.x/2 + style.window_border_padding;
        //window.pen.y -= widget_size.y + style.widget_padding;
        window.pen.y = window.current_row_bot - style.widget_padding;
        window.current_row_top = window.pen.y;
    } else {
        window.pen.y = window.current_row_top;
        window.pen.x += state.widgets[window_id].size.x / f32(window.columns) - style.widget_padding;
    }

    window.current_column += 1;

    w := &state.widgets[window_id];
    w.window = window;
}

label :: proc(str : string, color := gfx.WHITE, using ctx := active_ctx) {
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");

    window_id := state.window_id_stack[len(state.window_id_stack)-1];
    label_id, label_str := extract_id_and_label(str);

    window := state.widgets[window_id].window.(Window_State);
    text_size := text.measure(imm.get_current_context().default_font, label_str);
    label_raw(label_id, window.pen + {text_size.x/2, -text_size.y/2}, label_str, color, ctx=ctx);
    defer move_pen_after_widget(text_size, ctx);

    w := &state.widgets[window_id];
    w.window = window;
}

@(private)
prepare_formatted_input_widget :: proc(label_id : string, using ctx : ^Gui_Context) -> (window_id : Widget_Id, id : Widget_Id, field_size : lin.Vector2){
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");
    window_id = state.window_id_stack[len(state.window_id_stack)-1];
    window := state.widgets[window_id].window.(Window_State);

    widget_style := state.next_style_vars;
    widget_flags := state.next_widget_flags;

    label : string;
    id, label = extract_id_and_label(label_id);

    widget := &state.widgets[id];

    field_size = lin.Vector2{state.widgets[window_id].size.x - style.window_border_padding * 2, imm.get_current_context().default_font.font_size + style.field_padding * 2};

    if window.columns > 1 {
        field_size.x /= f32(window.columns);
        field_size.x -= style.widget_padding;
    }

    if .VSCROLL_VISIBLE in state.widgets[window_id].state {
        field_size.x -= style.scrollbar_width;
    }

    label_size := text.measure(imm.get_current_context().default_font, label);
    label_raw(id + 300, { window.pen.x + field_size.x/2, window.pen.y - label_size.y/2 }, label, ctx=ctx);

    window.pen.y -= label_size.y + style.widget_padding;

    w := &state.widgets[window_id];
    w.window = window;

    set_next_widget_style(widget_style, ctx);
    add_next_widget_flags(widget_flags, ctx);

    return;
}

// Will overwrite string ptr & len so if current value is dynamically allocated
// and it is overwritten by the builder string, then it is leaked.
text_field :: proc(label_id : string, value : ^string, placeholder := "enter text...", filter_proc : Text_Filter_Proc = nil, using ctx := active_ctx) -> bool {
    
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");

    widget_style := state.next_style_vars;
    widget_flags := state.next_widget_flags;

    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    window := state.widgets[window_id].window.(Window_State);
    

    begin_panel(id, {}, ctx);
    end_panel(ctx);

    set_next_widget_style(widget_style, ctx);
    add_next_widget_flags(widget_flags, ctx);

    widget := &state.widgets[id];

    if widget.builder == nil {
        widget.builder = new(strings.Builder);
        strings.builder_init(widget.builder); // #Leak
    }

    value^ = strings.to_string(widget.builder^);

    defer move_pen_after_widget(field_size, ctx);
    return text_field_raw(id, window.pen + {field_size.x/2, -field_size.y/2}, field_size, widget.builder, placeholder, filter_proc, ctx);
}


int_field :: proc(label_id : string, value : ^int, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    return int_field_raw(id, state.widgets[window_id].window.(Window_State).pen + {field_size.x/2, -field_size.y/2}, field_size, value, ctx);
}
int_slider :: proc(label_id : string, value : ^int, min, max : int, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    return int_slider_raw(id, state.widgets[window_id].window.(Window_State).pen + {field_size.x/2, -field_size.y/2}, field_size, value, min, max, ctx);
}
int_drag :: proc(label_id : string, value : ^int, min : Maybe(int) = nil, max : Maybe(int) = nil, rate : f32 = 1.0, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    return int_drag_raw(id, state.widgets[window_id].window.(Window_State).pen + {field_size.x/2, -field_size.y/2}, field_size, value, min, max, rate, ctx);
}

f32_field :: proc(label_id : string, value : ^f32, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    return f32_field_raw(id, state.widgets[window_id].window.(Window_State).pen + {field_size.x/2, -field_size.y/2}, field_size, value, ctx);
}
f32_slider :: proc(label_id : string, value : ^f32, min, max : f32, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    return f32_slider_raw(id, state.widgets[window_id].window.(Window_State).pen + {field_size.x/2, -field_size.y/2}, field_size, value, min, max, ctx);
}
f32_drag :: proc(label_id : string, value : ^f32, min : Maybe(f32) = nil, max : Maybe(f32) = nil, rate : f32 = 0.5, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    return f32_drag_raw(id, state.widgets[window_id].window.(Window_State).pen + {field_size.x/2, -field_size.y/2}, field_size, value, min, max, rate, ctx);
}

@(private)
xvecn_field :: proc(label_id : string, value : ^[$N]$T, widget_proc : $P, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    width_per := (field_size.x - style.widget_padding * (N-1)) / (N);
    size := lin.Vector2{width_per, field_size.y};
    any_changed : bool;
    x := state.widgets[window_id].window.(Window_State).pen.x;
    y := state.widgets[window_id].window.(Window_State).pen.y;
    for i in 0..<N {
        any_changed = any_changed || widget_proc(id + i*1000, lin.Vector2{x + (width_per + style.widget_padding) * f32(i), y} + {size.x/2, -size.y/2}, size, &value[i], ctx);
    }
    return any_changed;
}
@(private)
xvecn_drag :: proc(label_id : string, value : ^[$N]$T, widget_proc : $P, min : Maybe(T) = nil, max : Maybe(T) = nil, rate : f32 = 1.0, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    width_per := (field_size.x - style.widget_padding * (N-1)) / (N);
    size := lin.Vector2{width_per, field_size.y};
    any_changed : bool;
    x := state.widgets[window_id].window.(Window_State).pen.x;
    y := state.widgets[window_id].window.(Window_State).pen.y;
    for i in 0..<N {
        any_changed = any_changed || widget_proc(id + i*1000, lin.Vector2{x + (width_per + style.widget_padding) * f32(i), y} + {size.x/2, -size.y/2}, size, &value[i], min=min, max=max, rate=rate, ctx=ctx);
    }
    return any_changed;
}
@(private)
xvecn_slider :: proc(label_id : string, value : ^[$N]$T, widget_proc : $P, min, max : T, using ctx := active_ctx) -> bool {
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);
    defer move_pen_after_widget(field_size, ctx);
    width_per := (field_size.x - style.widget_padding * (N-1)) / (N);
    size := lin.Vector2{width_per, field_size.y};
    any_changed : bool;
    x := state.widgets[window_id].window.(Window_State).pen.x;
    y := state.widgets[window_id].window.(Window_State).pen.y;
    for i in 0..<N {
        any_changed = any_changed || widget_proc(id + i*1000, lin.Vector2{x + (width_per + style.widget_padding) * f32(i), y} + {size.x/2, -size.y/2}, size, &value[i], min=min, max=max, ctx=ctx);
    }
    return any_changed;
}

f32vecn_field :: proc(label_id : string, value : ^[$N]f32, using ctx := active_ctx) -> bool {
    return xvecn_field(label_id, value, f32_field_raw, ctx=ctx);
}
f32vec2_field :: proc(label_id : string, value : ^lin.Vector2, using ctx := active_ctx) -> bool {
    return f32vecn_field(label_id, transmute(^[2]f32)(value), ctx=ctx);
}
f32vec3_field :: proc(label_id : string, value : ^lin.Vector3, using ctx := active_ctx) -> bool {
    return f32vecn_field(label_id, transmute(^[3]f32)(value), ctx=ctx);
}
f32vec4_field :: proc(label_id : string, value : ^lin.Vector4, using ctx := active_ctx) -> bool {
    return f32vecn_field(label_id, transmute(^[4]f32)(value), ctx=ctx);
}
f32vecn_drag :: proc(label_id : string, value : ^[$N]f32, min : Maybe(f32) = nil, max : Maybe(f32) = nil, rate : f32 = 0.5, using ctx := active_ctx) -> bool {
    return xvecn_drag(label_id, value, f32_drag_raw, min, max, rate, ctx=ctx);
}
f32vec2_drag :: proc(label_id : string, value : ^lin.Vector2, min : Maybe(f32) = nil, max : Maybe(f32) = nil, rate : f32 = 0.5, using ctx := active_ctx) -> bool {
    return f32vecn_drag(label_id, transmute(^[2]f32)(value), min, max, rate, ctx=ctx);
}
f32vec3_drag :: proc(label_id : string, value : ^lin.Vector3, min : Maybe(f32) = nil, max : Maybe(f32) = nil, rate : f32 = 0.5, using ctx := active_ctx) -> bool {
    return f32vecn_drag(label_id, transmute(^[3]f32)(value), min, max, rate, ctx=ctx);
}
f32vec4_drag :: proc(label_id : string, value : ^lin.Vector4, min : Maybe(f32) = nil, max : Maybe(f32) = nil, rate : f32 = 0.5, using ctx := active_ctx) -> bool {
    return f32vecn_drag(label_id, transmute(^[4]f32)(value), min, max, rate, ctx=ctx);
}

button :: proc(label_id : string, using ctx := active_ctx) -> bool {
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");
    window_id := state.window_id_stack[len(state.window_id_stack)-1];
    window := state.widgets[window_id].window.(Window_State);

    id, label := extract_id_and_label(label_id);

    widget := &state.widgets[id];

    
    label_size := text.measure(imm.get_current_context().default_font, label);
    button_size := lin.Vector2{state.widgets[window_id].size.x - style.window_border_padding * 2, label_size.y + style.button_inner_padding};
    if window.columns > 1 {
        button_size.x /= f32(window.columns);
        button_size.x -= style.widget_padding;
    }

    result := button_raw(id, window.pen + {button_size.x/2,-button_size.y/2}, button_size, label, gfx.WHITE, ctx);

    w := &state.widgets[window_id];
    w.window = window;

    move_pen_after_widget(button_size + {style.widget_padding, 0}, ctx);

    return result;
}
checkbox :: proc(label_id : string, value : ^bool, using ctx := active_ctx) -> bool {
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");
    window_id, id, field_size := prepare_formatted_input_widget(label_id, ctx);

    window := state.widgets[window_id].window.(Window_State);

    checkbox_size := lin.Vector2{style.checkbox_size, style.checkbox_size};

    result := checkbox_raw(id, window.pen + { field_size.x/2,-checkbox_size.y/2 }, checkbox_size, value, ctx);

    move_pen_after_widget(field_size + {style.widget_padding, 0}, ctx);

    return result;
}

columns :: proc(n : int, using ctx := active_ctx) {
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");
    window_id := state.window_id_stack[len(state.window_id_stack)-1];
    window := state.widgets[window_id].window.(Window_State);

    window.columns = n;
    
    w := &state.widgets[window_id];
    w.window = window;

    if window.current_column > window.columns {
        move_pen_after_widget({1, window.pen.y - window.current_row_bot}, ctx);
        window.current_column = 0;
    }
}

spacing :: proc(amount : f32 = -1, using ctx := active_ctx) {
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");
    window_id := state.window_id_stack[len(state.window_id_stack)-1];
    window := state.widgets[window_id].window.(Window_State);

    amount := amount;
    if amount == -1 {
        amount = style.default_spacing;
    }

    window.pen.y -= amount;

    move_pen_after_widget({0, amount}, ctx);

    w := &state.widgets[window_id];
    w.window = window;
}

separator :: proc(using ctx := active_ctx) {
    assert(len(state.window_id_stack) > 0, "Window stack is empty on formatted widget. Call begin_window() first.");
    window_id := state.window_id_stack[len(state.window_id_stack)-1];
    
    {
        window := state.widgets[window_id].window.(Window_State);
        // #Incomplete #Limitation
        // Need to handle vertical separators if we're doing columns
        spacing(ctx=ctx);
    }

    {
        window := state.widgets[window_id].window.(Window_State);
        window_pos := get_final_pos(ctx, &state.widgets[window_id]);
        cmd : Draw_Command_Line;
        cmd.a = window_pos + {window.pen.x - state.widgets[window_id].size.x/2 + style.window_border_padding, window.pen.y};
        cmd.b = window_pos + {state.widgets[window_id].size.x/2 - style.window_border_padding, window.pen.y};
        adjust_pos_for_parent_scroll(ctx, &state.widgets[window_id], &cmd.a);
        adjust_pos_for_parent_scroll(ctx, &state.widgets[window_id], &cmd.b);
        cmd.color = style.separator_color;
        add_draw_command(ctx, cmd, get_widget_priority(ctx, &state.widgets[window_id]));
        move_pen_after_widget({0, 1}, ctx);
    }
    spacing(style.widget_padding, ctx);
}

begin_panel :: proc(id : int, flags : Widget_Flags, using ctx := active_ctx) {
    
    if id not_in ctx.state.widgets {
        window_size := gfx.get_window_size();
        widget : Widget_State;
        widget.style = style.panel;
        widget.pos = {rand.float32_range(0, window_size.x), rand.float32_range(0, window_size.y)} if len(state.id_stack) == 0 else {};
        widget.size = {rand.float32_range(400, 500), rand.float32_range(400, 500)} if len(state.id_stack) == 0 else style.default_panel_child_size;
        widget.color = make_interp_color(widget.style.color_unfocused, widget.style.color_unfocused, get_time(ctx), 0.1);
        widget.vscroll = 1;
        widget.priority = 0;
        widget.first_frame = true;

        widget.overflow_flags = {.NORTH, .EAST, .SOUTH, .WEST};
        
        ctx.state.widgets[id] = widget;
    } else {
        w := ctx.state.widgets[id];
        w.first_frame = false;
        ctx.state.widgets[id] = w;
    }
    widget := &ctx.state.widgets[id];
    assert(!widget.begin_active, "Mismatch begin/end on widget; begin was called before end");
    widget.begin_active = true;

    widget.parent = state.id_stack[len(state.id_stack)-1] if len(state.id_stack) > 0 else -1;

    widget.flags = flags | state.next_widget_flags;
    state.next_widget_flags = {};

    widget.style = ctx.state.next_style_vars;
    ctx.state.next_style_vars = style.panel;
    
    {
        //L, R, B, T := get_widget_functional_bounds(ctx, widget);
        //rect := bounds_to_rect(L, R, B, T);
        // The functional bounds are based on content regions.
        // So the content regions needs to be based of positions
        // before that.
        origin : lin.Vector2;
        if widget.parent != -1 do origin = get_final_pos(ctx, &state.widgets[widget.parent]);

        pos := origin+widget.pos;
        hs := widget.size/2;
        L, R, B, T := pos.x-hs.x, pos.x+hs.x, pos.y-hs.y, pos.y+hs.y;

        widget.last_content_min = widget.content_min;
        widget.last_content_max = widget.content_max;

        widget.content_min.x = L;
        widget.content_min.y = B;
        widget.content_max.x = R;
        widget.content_max.y = T;
        
        if widget.parent != -1 {
            
            parent := &state.widgets[widget.parent];
            if .ALLOW_HSCROLL in parent.flags {
                parent.content_min.x = min(parent.content_min.x, L);
                parent.content_max.x = max(parent.content_max.x, R);
            }
            if .ALLOW_VSCROLL in parent.flags {
                parent.content_min.y = min(parent.content_min.y, B);
                parent.content_max.y = max(parent.content_max.y, T);
            }
        }
    }

    prio := get_widget_priority(ctx,widget);
    L, R, B, T := get_widget_visual_bounds(ctx, widget);
    rect := bounds_to_rect(L, R, B, T);
    
    if widget.parent == -1 {
        cmd : Draw_Command_Shadow_Rect;
        cmd.pos = {rect.x, rect.y};
        cmd.size = {rect.z+style.panel_shadow_width*2, rect.w+style.panel_shadow_width*2};
        cmd.color = gfx.BLACK;
        add_draw_command(ctx, cmd, prio);
    }
    {
        cmd : Draw_Command_Rect;
        cmd.pos = {rect.x, rect.y};
        cmd.size = {rect.z, rect.w};
        cmd.color = get_widget_color(ctx, widget);
        add_draw_command(ctx, cmd, prio);
    }
    {
        cmd : Draw_Command_Line;
        cmd.color = widget.style.border_color;
        
        cmd.a = {L, B};
        cmd.b = {L, T};
        add_draw_command(ctx, cmd, prio);
        cmd.a = {L, T};
        cmd.b = {R, T};
        add_draw_command(ctx, cmd, prio);
        cmd.a = {R, T};
        cmd.b = {R, B};
        add_draw_command(ctx, cmd, prio);
        cmd.a = {R, B};
        cmd.b = {L, B};
        add_draw_command(ctx, cmd, prio);
    }
    {
        cmd : Draw_Command_Scissor;
        cmd.L, cmd.R, cmd.B, cmd.T = L, R, B, T;
        
        add_draw_command(ctx, cmd, prio);
    }

    append(&state.id_stack, id);


    if .ACTIVE in widget.state {
        set_widget_color(widget, widget.style.color_active, ctx);
    } else if .FOCUSED in widget.state {
        set_widget_color(widget, widget.style.color_focused, ctx);
    } else if .HOVERED in widget.state {
        set_widget_color(widget, widget.style.color_hovered, ctx);
    } else if .ANY_CHILD_ACTIVE in widget.state {
        set_widget_color(widget, widget.style.color_active_secondary, ctx);
    } else if .ANY_CHILD_FOCUSED in widget.state {
        set_widget_color(widget, widget.style.color_focused_secondary, ctx);
    } else if .ANY_CHILD_HOVERED in widget.state {
        set_widget_color(widget, widget.style.color_hovered_secondary, ctx);
    } else {
        set_widget_color(widget, widget.style.color_unfocused, ctx);
    }

    widget.last_state = widget.state;


    if is_widget_hovered(ctx) {

        hovered : ^Widget_State;
        hovered_prio := -1;
        if state.hovered_id != -1 {
            assert(state.hovered_id in state.widgets);

            hovered = &state.widgets[state.hovered_id];
            hovered_prio = get_widget_priority(ctx, hovered);
        }

        my_prio := get_widget_priority(ctx, widget);

        if my_prio >= hovered_prio || .IGNORE_INPUT in hovered.flags {
            state.hovered_id = id;
            assert(.LABEL not_in widget.flags);
        }
    }
}
end_panel :: proc(using ctx := active_ctx) {
    
    id := state.id_stack[len(state.id_stack)-1]
    
    {
        // Needs to be a copy because array might resize for slider widgets
        widget := state.widgets[id];
        assert(widget.begin_active, "Mismatch begin/end on widget; end was called before begin");
        
        L, R, B, T := get_widget_absolute_bounds(ctx, &widget);
        rect := bounds_to_rect(L, R, B, T);
        
        has_hscroll, has_vscroll : bool;

        last_slider_thickness := style.slider_thickness;
        style.slider_thickness = style.scrollbar_width;
        if .ALLOW_VSCROLL in widget.flags && (widget.content_min.y < B || widget.content_max.y > T) {
            add_next_widget_flags({.STICKY}, ctx);
            if .WINDOW not_in widget.flags {
                slider_raw(id+20, { widget.size.x/2 - style.scrollbar_width/2, 0 }, .VERTICAL, rect.w, &widget.vscroll, ctx=ctx);
            } else {
                slider_raw(id+20, { widget.size.x/2 - style.scrollbar_width/2,  -style.title_bar_height/2 }, .VERTICAL, rect.w - style.title_bar_height, &widget.vscroll, ctx=ctx);
            }
            has_vscroll = true;
            
        }
        if .ALLOW_HSCROLL in widget.flags && (widget.content_min.x < L || widget.content_max.x > R) {
            add_next_widget_flags({.STICKY}, ctx);
            // Need to position and size bottom slider differently if there is a vertical
            // one in the way.
            if has_vscroll {
                slider_raw(id+10, { -style.scrollbar_width/2, -widget.size.y/2 + style.scrollbar_width/2 }, .HORIZONTAL, rect.z - style.scrollbar_width, &widget.hscroll, ctx=ctx);
            } else {
                slider_raw(id+10, { 0, -widget.size.y/2 + style.scrollbar_width/2 }, .HORIZONTAL, rect.z, &widget.hscroll, ctx=ctx);
            }
            has_hscroll = true;

        }

        style.slider_thickness = last_slider_thickness;

        if has_hscroll {
            widget.state |= {.HSCROLL_VISIBLE};
        } else {
            widget.state &~= {.HSCROLL_VISIBLE};
            widget.hscroll = 0;
        }
        if has_vscroll {
            widget.state |= {.VSCROLL_VISIBLE};
        } else {
            widget.state &~= {.VSCROLL_VISIBLE};
            widget.vscroll = 1;
        }

        state.widgets[id] = widget;
    }

    widget := &state.widgets[id];

    

    widget.begin_active = false;
    window_size := gfx.get_window_size();
    if widget.parent != -1 {
        assert(widget.parent in state.widgets);
        parent := &state.widgets[widget.parent];

        {
            cmd : Draw_Command_Scissor;
            cmd.L, cmd.R, cmd.B, cmd.T = get_widget_visual_bounds(ctx, parent);
            
            add_draw_command(ctx, cmd);
        }
    } else {
        cmd : Draw_Command_Scissor;
        cmd.L, cmd.R, cmd.B, cmd.T = 0, window_size.x, 0, window_size.y;
        add_draw_command(ctx, cmd);
    }


    pop(&state.id_stack);

    state.last_widget = id;
}

Slider_Alignment :: enum {
    VERTICAL, HORIZONTAL
}
slider_raw :: proc(id : int, pos : lin.Vector2, align : Slider_Alignment, length : f32, value : ^f32, using ctx := active_ctx) -> bool {

    size : lin.Vector2;
    handle_size : lin.Vector2;

    switch align {
        case .HORIZONTAL: {
            size.x = length;
            size.y = style.slider_thickness;

            handle_size.x = style.handle_thickness;
            handle_size.y = size.y;
        }
        case .VERTICAL: {
            size.x = style.slider_thickness;
            size.y = length;
            handle_size.x = size.x;
            handle_size.y = style.handle_thickness;
        }
    }

    value^ = clamp(value^, 0, 1);

    slider_id := id + 1;
    handle_id := id + 2;

    // Slider
    begin_panel(slider_id, {.MOVE_CHILDREN_ON_OVERFLOW}, ctx);
    add_widget_flags({.SLIDER}, ctx);
    set_widget_size(size.x, size.y);
    set_widget_pos(pos.x, pos.y, ctx);

    // Handle
    begin_panel(handle_id, {.ALLOW_ACTIVE, .ALLOW_MOVE, .ALLOW_FOCUS}, ctx);
    add_widget_flags({.HANDLE}, ctx);
    handle_pos := get_widget_local_pos(ctx);
    
    set_widget_size(handle_size.x, handle_size.y);
    
    slider := &state.widgets[slider_id];

    last_value := value^;
    start, end, current : f32;
    switch align {
        case .HORIZONTAL: {
            start = -length/2 + handle_size.x/2;
            end   =  length/2 - handle_size.x/2;
            current = handle_pos.x;
        }
        case .VERTICAL: {
            start = -length/2 + handle_size.y/2;
            end   =  length/2 - handle_size.y/2;
            current = handle_pos.y;
        }
    }
    if is_widget_active(ctx) {
        value^ = clamp((current-start) / (end-start), 0, 1);
    }
    switch align {
        case .HORIZONTAL: set_widget_x(start + (end - start) * value^);
        case .VERTICAL:   set_widget_y(start + (end - start) * value^);
    }
    
    end_panel(ctx); // Handle

    end_panel(ctx); // Slider

    return last_value != value^;
}

// Does not copy the string, so it needs to be kept alive until draw
label_raw :: proc(id : int, pos : lin.Vector2, str : string, color := gfx.WHITE, using ctx := active_ctx) {

    // #Limitation #Incomplete this locks us into using default font in imm
    text_size := text.measure(imm.get_current_context().default_font, str);

    if len(state.id_stack) <= 0 do return;

    parent_id := state.id_stack[len(state.id_stack)-1];
    parent := &state.widgets[parent_id];

    parent_pos := get_final_pos(ctx, parent);

    {
        cmd : Draw_Command_Text;
        cmd.text = str;
        cmd.color = color;
        cmd.pos = parent_pos + pos;
        adjust_pos_for_parent_scroll(ctx, parent, &cmd.pos);
        add_draw_command(ctx, cmd);
    }

    /*
    // Zero colors
    label_panel_style : Style_Vars;
    set_next_widget_style(label_panel_style);
    add_next_widget_flags({.IGNORE_INPUT, .LABEL, .ALLOW_OVERFLOW});
    begin_panel(id, {}, ctx=ctx);
    set_widget_pos(pos.x, pos.y, ctx);
    set_widget_size(text_size.x, text_size.y, ctx);
    
    widget := &state.widgets[id];

    rect := bounds_to_rect(get_widget_functional_bounds(ctx, widget));

    cmd : Draw_Command_Text;
    cmd.color = color;
    cmd.pos = rect.xy;
    cmd.text = str;
    add_draw_command(ctx, cmd);

    end_panel(ctx);*/
}

button_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, text : string, text_color := gfx.WHITE, using ctx := active_ctx) -> bool {

    begin_panel(id, {.ALLOW_ACTIVE, .ALLOW_FOCUS, .BUTTON}, ctx);
    set_widget_pos(pos.x, pos.y, ctx);
    set_widget_size(size.x, size.y, ctx);

    clicked := is_widget_clicked(ctx);
    
    label_raw(id+30, {}, text, color=text_color, ctx=ctx);

    end_panel(ctx);

    return clicked;
}
checkbox_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, value : ^bool, using ctx := active_ctx) -> bool {

    begin_panel(id, {.ALLOW_ACTIVE, .ALLOW_FOCUS, .BUTTON}, ctx);
    set_widget_pos(pos.x, pos.y, ctx);
    set_widget_size(size.x, size.y, ctx);

    clicked := is_widget_clicked(ctx);
    if clicked {
        value^ = !value^;
    }

    if value^ {
        /*cmd : Draw_Command_Rect;
        cmd.pos = get_widget_pos(ctx);
        cmd.size = get_widget_size(ctx);
        cmd.color = gfx.WHITE;
        add_draw_command(ctx, cmd);*/

        visual_pos := get_final_pos(ctx, &state.widgets[id]);

        // Classic checkmark shape
        p1 := visual_pos + lin.Vector2{-size.x/2 + style.field_padding, 0};
        p2 := visual_pos + lin.Vector2{0, -size.y/2 + style.field_padding};
        p3 := visual_pos + lin.Vector2{size.x/2 - style.field_padding, size.y/2 - style.field_padding};

        cmd : Draw_Command_Line;
        cmd.color = style.checkmark_color;

        cmd.a = p1;
        cmd.b = p2;
        add_draw_command(ctx, cmd);
        cmd.a = p2;
        cmd.b = p3;
        add_draw_command(ctx, cmd);
    }

    end_panel(ctx);

    return clicked;
}

text_field_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, builder : ^strings.Builder, placeholder := "enter text...", filter_proc : Text_Filter_Proc = nil, using ctx := active_ctx) -> bool {

    begin_panel(id, {.ALLOW_ACTIVE, .ALLOW_FOCUS, .TEXT_FIELD, .CAPTURES_TEXT}, ctx);
    set_widget_pos(pos.x, pos.y, ctx);
    set_widget_size(size.x, size.y, ctx);
    
    should_capture := last_state.focused_id == id;

    has_input_changed := false;
    color := gfx.WHITE; // #Magic
    display := strings.to_string(builder^);
    final_pos : lin.Vector2;
    caret_x : f32;
    text_offset_x : f32;
    {
        // Pointer may be invalid after label_raw() !
        widget := &state.widgets[id];
        final_pos = get_final_pos(ctx, widget);
        widget.caret_pos = clamp(widget.caret_pos, 0, len(display));

        if len(display) <= 0 && !is_widget_focused(ctx) {
            display = placeholder;
            color = {.5, .5, .5, 1.0}; // #Magic
        }

        if should_capture {

            remove_char :: proc(builder : ^strings.Builder, pos : int) {
                old_str := fmt.tprint(strings.to_string(builder^));
                strings.builder_reset(builder);
                
                i := 0;
                for existing_char in old_str {
                    if i != pos {
                        strings.write_rune(builder, existing_char);
                    }
                    
                    i += 1;
                }
            }

            if len(input.chars) > 0 {
                num_added := 0;
                if widget.caret_pos < utf8.rune_count(strings.to_string(builder^)) {

                    old_string := strings.clone(strings.to_string(builder^), allocator=context.temp_allocator);
                    strings.builder_reset(builder);
            
                    i := 0;
                    for existing_char in old_string {
                        if i == widget.caret_pos do for char in input.chars {
                            if filter_proc == nil || filter_proc(char) {
                                num_added += 1;
                                strings.write_rune(builder, char);
                                has_input_changed = true;
                            }
                        }
                        strings.write_rune(builder, existing_char);
    
                        i += 1;
                    }
                } else {
                    for char in input.chars {
                        if filter_proc == nil || filter_proc(char) {
                            num_added += 1;
                            strings.write_rune(builder, char);
                            has_input_changed = true;
                        }
                    }
                }

                widget.caret_pos += num_added;
            }

            display = strings.to_string(builder^);

            if widget.caret_pos > 0 && input.key_states[glfw.KEY_BACKSPACE] {
                widget.caret_pos -= 1;
                remove_char(builder, widget.caret_pos);
                has_input_changed = true;
            }
            if widget.caret_pos < utf8.rune_count(display) && input.key_states[glfw.KEY_DELETE] {
                remove_char(builder, widget.caret_pos);
                has_input_changed = true;
            }

            jump_word := glfw.MOD_CONTROL in input.mod_flags;
            if input.key_states[glfw.KEY_LEFT] {
                widget.caret_pos -= 1;
                if input.mod_flags[glfw.MOD_CONTROL] do for widget.caret_pos > 0 {
                    if !unicode.is_white_space(utf8.rune_at_pos(display, widget.caret_pos)) && unicode.is_white_space(utf8.rune_at_pos(display, widget.caret_pos-1)) do break;
                    widget.caret_pos -= 1;
                }
            }
            if input.key_states[glfw.KEY_RIGHT] {
                widget.caret_pos += 1;
                if input.mod_flags[glfw.MOD_CONTROL] do for widget.caret_pos < utf8.rune_count(display) {
                    if widget.caret_pos > 0 && unicode.is_white_space(utf8.rune_at_pos(display, widget.caret_pos)) && !unicode.is_white_space(utf8.rune_at_pos(display, widget.caret_pos-1)) do break;
                    widget.caret_pos += 1;
                }
            }

            if input.key_states[glfw.KEY_HOME] {
                widget.caret_pos = 0;
            }
            if input.key_states[glfw.KEY_END] {
                widget.caret_pos = utf8.rune_count(display);
            }
        }

        L, R, B, T := get_widget_functional_bounds(ctx, widget);
        display_size := text.measure(imm.get_current_context().default_font, display);

        widget.caret_pos = clamp(widget.caret_pos, 0, utf8.rune_count(display));

        caret_x = final_pos.x - display_size.x / 2;
        i := 0;
        for char in display {
            if i >= widget.caret_pos do break;
            info := text.get_glyph_info(imm.get_current_context().default_font, char);
            caret_x += info.advance;
            i += 1;
        }

        // #Magic
        if caret_x <= L {
            underflow := L - caret_x;
            text_offset_x = underflow;
            caret_x += text_offset_x;
        }
        if (caret_x - 4) > R {
            overflow := caret_x - R;
            text_offset_x = -overflow;
            caret_x += text_offset_x;
        }

        if is_widget_held(ctx) {
            last_x := final_pos.x - display_size.x/2 - text_offset_x;
            i := 0;

            mouse := input.mouse_pos;

            for char in display {
                info := text.get_glyph_info(imm.get_current_context().default_font, char);
                
                now_x := last_x + info.advance;

                if abs(mouse.x - now_x) > abs(mouse.x - last_x) {
                    break;
                }

                last_x = now_x;
                i += 1;
            }

            widget.caret_pos = i;
        }

        widget.caret_pos = clamp(widget.caret_pos, 0, utf8.rune_count(display));
    }

    label_raw(id+40, {-text_offset_x, 0}, display, color=color, ctx=ctx);

    is_focused := is_widget_focused(ctx);
    if is_focused {
        cmd : Draw_Command_Rect;
        // #Magic
        CARET_WIDTH :: 2;
        CARET_BLINK_RATE :: 10;
        cmd.color = gfx.WHITE if math.sin(f32(glfw.GetTime() * CARET_BLINK_RATE)) > -0.5 else gfx.TRANSPARENT;
        cmd.size = {CARET_WIDTH, imm.get_current_context().default_font.font_size};
        cmd.pos = {caret_x + CARET_WIDTH/2, final_pos.y};
        add_draw_command(ctx, cmd);
    }

    end_panel(ctx);

    return has_input_changed;
}

int_field_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, value : ^int, using ctx := active_ctx) -> bool {

    widget_style := state.next_style_vars;
    widget_flags := state.next_widget_flags;

    begin_panel(id, {}, ctx);
    end_panel(ctx);

    set_next_widget_style(widget_style, ctx);
    add_next_widget_flags(widget_flags, ctx);

    widget := &state.widgets[id];

    if widget.builder == nil {
        widget.builder = new(strings.Builder);
        strings.builder_init(widget.builder); // #Leak kinda not really
    }

    if (.FOCUSED not_in widget.state) {
        strings.builder_reset(widget.builder);
        strings.write_int(widget.builder, value^);
    }

    if text_field_raw(id, pos, size, widget.builder, "", proc(char : rune) -> bool {
        return unicode.is_digit(char) || char == '-';
    }, ctx) {
        str := strings.to_string(widget.builder^);
        if str != "" {
            new_value, parse_ok := strconv.parse_int(str);
            if parse_ok {
                value^ = new_value;
                return true;
            }
        }
    }
    return false;
}
f32_field_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, value : ^f32, using ctx := active_ctx) -> bool {

    widget_style := state.next_style_vars;
    widget_flags := state.next_widget_flags;

    begin_panel(id, {}, ctx);
    end_panel(ctx);

    set_next_widget_style(widget_style, ctx);
    add_next_widget_flags(widget_flags, ctx);

    widget := &state.widgets[id];

    if widget.builder == nil {
        widget.builder = new(strings.Builder);
        strings.builder_init(widget.builder); // #Leak kinda not really
    }

    if (.FOCUSED not_in widget.state) {
        strings.builder_reset(widget.builder);
        fmt.sbprintf(widget.builder, "%.4f", value^); // #Magic
    }

    if text_field_raw(id, pos, size, widget.builder, "", proc(char : rune) -> bool {
        return unicode.is_digit(char) || char == '.' || char == '-';
    }, ctx) {
        str := strings.to_string(widget.builder^);
        if str != "" {
            new_value, parse_ok := strconv.parse_f32(str);
            if parse_ok {
                value^ = new_value;
                return true;
            }
        }
    }
    return false;
}

int_slider_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, value : ^int, min, max : int, using ctx := active_ctx) -> bool {

    fnt := imm.get_current_context().default_font;
    min_text_size := text.measure(fnt, fmt.tprint(min));
    max_text_size := text.measure(fnt, fmt.tprint(max));
    field_text_size := max_text_size if max_text_size.x > min_text_size.x else min_text_size;
    field_size := lin.Vector2{field_text_size.x + style.field_padding * 2, fnt.font_size + style.field_padding*2};
    field_pos := lin.Vector2{pos.x + size.x/2 - field_size.x/2, pos.y};
    add_next_widget_flags({.FOCUS_REQUIRES_DOUBLE_CLICK}, ctx);
    
    int_drag_raw(id, field_pos, field_size, value, rate=math.max(f32(max-min)/1000, 1.0), ctx=ctx);
    
    safe_space := style.widget_padding;

    factor := f32(value^-min) / f32(max-min);
    slider_size := lin.Vector2{size.x - field_size.x - safe_space, size.y};
    slider_pos := lin.Vector2{pos.x - size.x/2 + slider_size.x/2, pos.y};
    slider_raw(id + 80, slider_pos, .HORIZONTAL, slider_size.x, &factor, ctx);

    last_value := value^;
    value^ = cast(int)(f32(max-min) * factor + f32(min));

    return value^ != last_value;
}

f32_slider_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, value : ^f32, min, max : f32, using ctx := active_ctx) -> bool {

    fnt := imm.get_current_context().default_font;
    min_text_size := text.measure(fnt, fmt.tprint(min));
    max_text_size := text.measure(fnt, fmt.tprint(max));
    field_text_size := max_text_size if max_text_size.x > min_text_size.x else min_text_size;
    field_size := lin.Vector2{field_text_size.x + style.field_padding * 2, fnt.font_size + style.field_padding*2};
    field_pos := lin.Vector2{pos.x + size.x/2 - field_size.x/2, pos.y};
    add_next_widget_flags({.FOCUS_REQUIRES_DOUBLE_CLICK}, ctx);
    f32_drag_raw(id, field_pos, field_size, value, rate=(max-min)/1000, ctx=ctx);
    
    safe_space := style.widget_padding;

    factor := (value^-min) / (max-min);
    slider_size := lin.Vector2{size.x - field_size.x - safe_space, size.y};
    slider_pos := lin.Vector2{pos.x - size.x/2 + slider_size.x/2, pos.y};
    slider_raw(id + 80, slider_pos, .HORIZONTAL, slider_size.x, &factor, ctx);

    last_value := value^;
    value^ = (max-min) * factor + min;

    return value^ != last_value;
}

int_drag_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, value : ^int, min : Maybe(int) = nil, max : Maybe(int) = nil, rate : f32 = 1.0, using ctx := active_ctx) -> bool {

    add_next_widget_flags({.FOCUS_REQUIRES_DOUBLE_CLICK, .DRAG}, ctx);
    result := int_field_raw(id, pos, size, value, ctx);
    
    widget := &state.widgets[id];

    if .ACTIVE in widget.state && .FOCUSED not_in widget.state && last_state.active_id == id {
        mouse_delta := input.mouse_pos - input.last_mouse_pos;
        
        value^ += int((mouse_delta.x) * rate);
    }

    if min != nil do if value^ < min.(int) do value^ = min.(int);
    if max != nil do if value^ > max.(int) do value^ = max.(int);

    return result;
}

f32_drag_raw :: proc(id : int, pos : lin.Vector2, size : lin.Vector2, value : ^f32, min : Maybe(f32) = nil, max : Maybe(f32) = nil, rate : f32 = 0.5, using ctx := active_ctx) -> bool {

    add_next_widget_flags({.FOCUS_REQUIRES_DOUBLE_CLICK, .DRAG}, ctx);
    result := f32_field_raw(id, pos, size, value, ctx);
    
    widget := &state.widgets[id];

    if .ACTIVE in widget.state && .FOCUSED not_in widget.state && last_state.active_id == id {
        mouse_delta := input.mouse_pos - input.last_mouse_pos;
        
        value^ += (mouse_delta.x) * rate;
    }

    if min != nil do if value^ < min.(f32) do value^ = min.(f32);
    if max != nil do if value^ > max.(f32) do value^ = max.(f32);

    return result;
}

is_widget_clicked :: proc(using ctx := active_ctx, mb : c.int = glfw.MOUSE_BUTTON_LEFT) -> bool {
    if len(state.id_stack) <= 0 do return false;
    id := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[id];

    return is_widget_hovered(ctx) && is_mouse_clicked(ctx=ctx) && last_state.hovered_id == id && .ACTIVE in widget.state;
}
is_widget_double_clicked :: proc(using ctx := active_ctx, mb : c.int = glfw.MOUSE_BUTTON_LEFT) -> bool {
    if len(state.id_stack) <= 0 do return false;

    last_pos := input.button_click_positions[mb];
    return is_pos_in_widget_rect(last_pos) && is_widget_clicked(ctx) && is_mouse_double_clicked(ctx=ctx);
}
is_widget_held :: proc(using ctx := active_ctx, mb : c.int = glfw.MOUSE_BUTTON_LEFT) -> bool {
    if len(state.id_stack) <= 0 do return false;

    return is_widget_hovered(ctx) && input.button_states[mb];
}
is_widget_active :: proc(using ctx := active_ctx) -> bool {
    if len(state.id_stack) <= 0 do return false;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    return .ACTIVE in widget.state;
}
is_widget_focused :: proc(using ctx := active_ctx) -> bool {
    if len(state.id_stack) <= 0 do return false;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    return .FOCUSED in widget.state;
}

is_widget_hovered :: proc(using ctx := active_ctx) -> bool {
    if len(state.id_stack) <= 0 do return false;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    if .IGNORE_INPUT in widget.flags do return false;

    L, R, B, T := get_widget_visual_bounds(ctx, widget);

    mouse := input.mouse_pos;

    return mouse.x >= L && mouse.x < R && mouse.y >= B && mouse.y < T;
}

set_widget_pos :: proc(x, y : f32, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.pos.x = x;
    widget.pos.y = y;
}
set_widget_x :: proc(x : f32, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.pos.x = x;
}
set_widget_y :: proc(y : f32, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.pos.y = y;
}
get_widget_local_pos :: proc(using ctx := active_ctx) -> lin.Vector2 {
    assert(len(state.id_stack) > 0, "No active widget!");

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    return widget.pos;
}
set_widget_size :: proc(width, height : f32, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.size.x = width;
    widget.size.y = height;
}
set_widget_width :: proc(width : f32, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.size.x = width;
}
set_widget_height :: proc(height : f32, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.size.y = height;
}
set_widget_overflow_flags :: proc(flags : Overflow_Flags, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.overflow_flags = flags;
}
add_widget_flags :: proc(flags : Widget_Flags, using ctx := active_ctx) {
    if len(state.id_stack) <= 0 do return;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    widget.flags |= flags;
}
add_next_widget_flags :: proc(flags : Widget_Flags, using ctx := active_ctx) {
    state.next_widget_flags = flags;
}
set_next_widget_style :: proc(vars : Style_Vars, using ctx := active_ctx) {
    state.next_style_vars = vars;
}

new_frame :: proc(using ctx := active_ctx) {
    using input;

    for _,button in button_states {
        if last_button_states[button] && !button_states[button] {
            button_click_times[button] = get_time(ctx);
            button_click_positions[button] = mouse_pos;
        }
    }

    copy(last_key_states[:], key_states[:]);
    copy(last_button_states[:], button_states[:]);

    for _, i in key_states do key_states[i] = false;

    last_mouse_pos = mouse_pos;
    last_mouse_scroll_total = mouse_scroll_total;

    mouse_scroll_delta = {0,0};
    clear(&chars);

    for e,i in gfx.window_events {
        if e.handled do continue;
        #partial switch v in e.variant {
            case gfx.Window_Key_Event: {
                using key_event := e.variant.(gfx.Window_Key_Event);
                handle_key(key, scancode, action, mods, ctx);

                if state.focused_id != -1 {
                    assert(state.focused_id in state.widgets);
                    widget := state.widgets[state.focused_id];
                    gfx.window_events[i].handled = .CAPTURES_TEXT in widget.flags;
                }
            }
            case gfx.Window_Button_Event: {
                using button_event := e.variant.(gfx.Window_Button_Event);
                handle_mouse_button(button, action, mods, ctx);
                gfx.window_events[i].handled = state.hovered_id != -1;
            }
            case gfx.Window_Scroll_Event: {
                using scroll_event := e.variant.(gfx.Window_Scroll_Event);
                handle_mouse_scroll(xscroll, yscroll, ctx);
                gfx.window_events[i].handled = state.hovered_id != -1;
            }
            case gfx.Window_Mouse_Move_Event: {
                using move_event := e.variant.(gfx.Window_Mouse_Move_Event);
                handle_mouse_move(xpos, ypos, ctx);
                gfx.window_events[i].handled = state.hovered_id != -1;
            }
            case gfx.Window_Char_Event: {
                handle_char(v.char, ctx);
                if state.focused_id != -1 {
                    focused := state.widgets[state.focused_id];
                    gfx.window_events[i].handled = .CAPTURES_TEXT in focused.flags;
                }
            }
        }
    }
    glfw.SetCursor(gfx.window, state.cursor);
    state.cursor = nil;

    mouse := mouse_pos;
    if !last_button_states[glfw.MOUSE_BUTTON_LEFT] && button_states[glfw.MOUSE_BUTTON_LEFT] {
        mouse_down_pos = mouse;
    }

    if state.hovered_id != -1 {
        widget := &state.widgets[state.hovered_id];

        

        if .ALLOW_RESIZE in widget.flags {
            // #Copypaste
            L, R, B, T := get_widget_functional_bounds(ctx, widget);
    
            t := style.panel_resize_space;
            ht := t/2;
            sz := widget.size;
            hsz := sz/2;
    
            resize_rects := []lin.Vector4{
                { L+ht, B+ht, t, t }, // BL corner
                { L+ht, T-ht, t, t }, // TL corner
                { R-ht, T-ht, t, t }, // TR corner
                { R-ht, B+ht, t, t }, // BR corner
                
                { L+ht, B + hsz.y, t, sz.y-t*2 }, // Left
                { L+hsz.x, T-ht, sz.x-t*2, t }, // Top
                { R-ht, B + hsz.y, t, sz.y-t*2 }, // Right
                { L+hsz.x, B+ht, sz.x-t*2, t }, // Bottom
            };
    
            for rect,i in resize_rects {
                L := rect.x - rect.z/2;
                R := rect.x + rect.z/2;
                B := rect.y - rect.w/2;
                T := rect.y + rect.w/2;
                if last_mouse_pos.x >= L && last_mouse_pos.x < R && last_mouse_pos.y >= B && last_mouse_pos.y < T {
                    cmd : Draw_Command_Rect;
                    cmd.pos = rect.xy;
                    cmd.size = rect.zw;
                    cmd.color = style.resize_color_hovered if state.active_id != state.hovered_id else style.resize_color_active;
                    add_draw_command(ctx, cmd, get_widget_priority(ctx, widget));

                    switch cast(Resize_Dir)i {
                        case .N, .S: state.cursor = gfx.CURSOR_VRESIZE;
                        case .E, .W: state.cursor = gfx.CURSOR_HRESIZE;
                        case .NE, .SW: state.cursor = gfx.CURSOR_CROSSHAIR;
                        case .NW, .SE: state.cursor = gfx.CURSOR_CROSSHAIR;
                        case .NONE: {}
                    }
                }
            }
        }
    }

    if state.active_id != -1 {
        mouse_drag := mouse - mouse_down_pos;

        widget := &state.widgets[state.active_id];

        if state.active_resize == .NONE {

            if .ALLOW_MOVE in widget.flags {
                offset := mouse_down_pos - state.widget_activated_pos;
                set_absolute_pos(ctx, widget, mouse-offset)
                //widget.pos = (mouse - offset) - widget.origin;
            }

        } else {
            half_size := mouse - get_final_pos(ctx, widget);
            half_size.x = abs(half_size.x)+style.panel_resize_space/2;
            half_size.y = abs(half_size.y)+style.panel_resize_space/2;
            switch state.active_resize {
                case .N, .S: widget.size.y = half_size.y * 2;
                case .W, .E: widget.size.x = half_size.x * 2;
                case .NE, .SE, .SW, .NW: widget.size = half_size * 2;
                case .NONE: panic("what");
            }
        }
    }

    last_state = state;
    
    
    if !button_states[glfw.MOUSE_BUTTON_LEFT] do state.active_id = -1;
    
    click := is_mouse_clicked(ctx=ctx);
    if click && state.hovered_id == -1 {
        state.focused_id = -1;
    }

    state.hovered_id = -1;
}

update :: proc(delta_time : f32, using ctx := active_ctx) {
    using input;

    delta_seconds = delta_time;

    set_widget_flag :: proc(ctx : ^Gui_Context, widget : ^Widget_State, flag : Widget_State_Flag, parent_flag : Widget_State_Flag) {
        widget.state |= {flag};

        if widget.parent != -1 {
            next := &ctx.state.widgets[widget.parent];
            for next != nil {
                
                next.state |= {parent_flag};
                next = &ctx.state.widgets[next.parent] if next.parent != -1 else nil;
            }
        }
    }
    unset_widget_flag :: proc(ctx : ^Gui_Context, widget : ^Widget_State, flag : Widget_State_Flag, parent_flag : Widget_State_Flag) {
        widget.state &~= {flag};

        if widget.parent != -1 {
            next := &ctx.state.widgets[widget.parent];
            for next != nil {
                
                next.state &~= {parent_flag};
                next = &ctx.state.widgets[next.parent] if next.parent != -1 else nil;
            }
        }
    }

    if last_state.hovered_id != state.hovered_id {
        if last_state.hovered_id != -1 {
            assert(last_state.hovered_id in last_state.widgets);
            last_focused := &last_state.widgets[last_state.hovered_id];
            unset_widget_flag(ctx, last_focused, .HOVERED, .ANY_CHILD_HOVERED);
        }
        if state.hovered_id != -1 {
            assert(state.hovered_id in state.widgets);
            widget := &state.widgets[state.hovered_id];
            set_widget_flag(ctx, widget, .HOVERED, .ANY_CHILD_HOVERED);
        }
    }


    if state.hovered_id != -1 {
        hovered := &state.widgets[state.hovered_id];

        if .DRAG in hovered.flags do state.cursor = gfx.CURSOR_HRESIZE; 

        if .CAPTURES_TEXT in hovered.flags {
            if .FOCUS_REQUIRES_DOUBLE_CLICK not_in hovered.flags || .FOCUSED in hovered.state {
                state.cursor = gfx.CURSOR_IBEAM;
            }
        }

        if .BUTTON in hovered.flags do state.cursor = gfx.CURSOR_HAND;


        SCROLL_SPEED :: 50;
        content_size_x := hovered.content_max.x - hovered.content_min.x;
        content_size_y := hovered.content_max.y - hovered.content_min.y;
        scroll_factor_x := SCROLL_SPEED / content_size_x;
        scroll_factor_y := SCROLL_SPEED / content_size_y;

        hovered.hscroll = clamp(hovered.hscroll + input.mouse_scroll_delta.x * scroll_factor_x, 0, 1);
        hovered.vscroll = clamp(hovered.vscroll + input.mouse_scroll_delta.y * scroll_factor_y, 0, 1);

        if .ALLOW_ACTIVE in hovered.flags && !last_button_states[glfw.MOUSE_BUTTON_LEFT] && button_states[glfw.MOUSE_BUTTON_LEFT] {

            get_top_parent :: proc(using ctx : ^Gui_Context, widget : ^Widget_State) -> ^Widget_State {
                next := widget;
                for next.parent != -1 {
                    next = &state.widgets[next.parent];
                }
                return next;
            }

            hovered_top := get_top_parent(ctx, hovered);
            hovered_top.priority = state.top_priority;
            state.top_priority += 1;

            state.active_id = state.hovered_id;
        }

        last_pos := input.button_click_positions[glfw.MOUSE_BUTTON_LEFT];
        L, R, B, T := get_widget_visual_bounds(ctx, hovered);
        if .ALLOW_FOCUS in hovered.flags && (is_mouse_clicked(ctx=ctx) if (.FOCUS_REQUIRES_DOUBLE_CLICK not_in hovered.flags) else (is_mouse_double_clicked(ctx=ctx) && last_pos.x >= L && last_pos.x < R && last_pos.y >= B && last_pos.y < T)) {
            state.focused_id = state.hovered_id;
        }
    }

    if last_state.focused_id != state.focused_id {
        if last_state.focused_id != -1 {
            assert(last_state.focused_id in last_state.widgets);
            last_focused := &last_state.widgets[last_state.focused_id];
            unset_widget_flag(ctx, last_focused, .FOCUSED, .ANY_CHILD_FOCUSED);
        }
        if state.focused_id != -1 {
            assert(state.focused_id in state.widgets);
            widget := &state.widgets[state.focused_id];
            set_widget_flag(ctx, widget, .FOCUSED, .ANY_CHILD_FOCUSED);
        }
    }


    if last_state.active_id != state.active_id {
        if last_state.active_id != -1 {
            assert(last_state.active_id in last_state.widgets);
            last_focused := &last_state.widgets[last_state.active_id];
            unset_widget_flag(ctx, last_focused, .ACTIVE, .ANY_CHILD_ACTIVE);
        }
        state.active_resize = .NONE;
        if state.active_id != -1 {
            assert(state.active_id in state.widgets);
            widget := &state.widgets[state.active_id];
            set_widget_flag(ctx, widget, .ACTIVE, .ANY_CHILD_ACTIVE);

            state.widget_activated_pos = get_absolute_pos(ctx, widget);

            if .ALLOW_RESIZE in widget.flags {
    
                // #Copypaste
                L, R, B, T := get_widget_functional_bounds(ctx, widget);
    
                t := style.panel_resize_space;
                ht := t/2;
                sz := widget.size;
                hsz := sz/2;
    
                resize_rects := []lin.Vector4{
                    { L+ht, B+ht, t, t }, // BL corner
                    { L+ht, T-ht, t, t }, // TL corner
                    { R-ht, T-ht, t, t }, // TR corner
                    { R-ht, B+ht, t, t }, // BR corner
                    
                    { L+ht, B + hsz.y, t, sz.y-t*2 }, // Left
                    { L+hsz.x, T-ht, sz.x-t*2, t }, // Top
                    { R-ht, B + hsz.y, t, sz.y-t*2 }, // Right
                    { L+hsz.x, B+ht, sz.x-t*2, t }, // Bottom
                };
    
                for rect,i in resize_rects {
                    L := rect.x - rect.z/2;
                    R := rect.x + rect.z/2;
                    B := rect.y - rect.w/2;
                    T := rect.y + rect.w/2;
                    if last_mouse_pos.x >= L && last_mouse_pos.x < R && last_mouse_pos.y >= B && last_mouse_pos.y < T {
                        state.active_resize = cast(Resize_Dir)i;
                    }
                }
            }
        }
    }

    
    
    switch state.active_resize {
        case .N, .S: state.cursor = gfx.CURSOR_VRESIZE;
        case .E, .W: state.cursor = gfx.CURSOR_HRESIZE;
        case .NE, .SW: state.cursor = gfx.CURSOR_CROSSHAIR;
        case .NW, .SE: state.cursor = gfx.CURSOR_CROSSHAIR;
        case .NONE: {}
    }
}

is_mouse_clicked :: proc(mb : c.int = glfw.MOUSE_BUTTON_LEFT, using ctx := active_ctx) -> bool {
    return input.last_button_states[glfw.MOUSE_BUTTON_LEFT] && !input.button_states[glfw.MOUSE_BUTTON_LEFT];
}
is_pos_in_widget_rect :: proc(pos : lin.Vector2, using ctx := active_ctx) -> bool {
    if len(state.id_stack) <= 0 do return false;

    wid := state.id_stack[len(state.id_stack)-1];
    widget := &state.widgets[wid];

    L, R, B, T := get_widget_visual_bounds(ctx, widget);

    return pos.x >= L && pos.x < R && pos.y >= B && pos.y < T;
}
is_mouse_double_clicked :: proc(mb : c.int = glfw.MOUSE_BUTTON_LEFT, using ctx := active_ctx) -> bool {
    now := get_time(ctx);
    last_time := input.button_click_times[mb];
    time_since := now - last_time;
    DOUBLE_CLICK_TIME :: 0.3; // #Magic
    
    return time_since < DOUBLE_CLICK_TIME && is_mouse_clicked(mb, ctx);
}

update_mods :: proc(input_mods : c.int, using ctx : ^Gui_Context) {
    using input;
    mod_flags[glfw.MOD_ALT]       = (input_mods & glfw.MOD_ALT) != 0;
    mod_flags[glfw.MOD_CAPS_LOCK] = (input_mods & glfw.MOD_CAPS_LOCK) != 0;
    mod_flags[glfw.MOD_CONTROL]   = (input_mods & glfw.MOD_CONTROL) != 0;
    mod_flags[glfw.MOD_NUM_LOCK]  = (input_mods & glfw.MOD_NUM_LOCK) != 0;
    mod_flags[glfw.MOD_SHIFT]     = (input_mods & glfw.MOD_SHIFT) != 0;
    mod_flags[glfw.MOD_SUPER]     = (input_mods & glfw.MOD_SUPER) != 0;
}

handle_key :: proc(glfw_key, scancode, action, mods : c.int, using ctx := active_ctx) {
    using input;
    update_mods(mods, ctx);

    if action == glfw.PRESS || action == glfw.REPEAT {
        key_states[glfw_key] = true;
    } else {
        key_states[glfw_key] = false;
    }
    
}
handle_mouse_button :: proc(glfw_button, action, mods : c.int, using ctx := active_ctx) {
    using input;
    update_mods(mods, ctx);

    if action == glfw.PRESS || action == glfw.REPEAT {
        button_states[glfw_button] = true;
    } else {
        button_states[glfw_button] = false;
    }
}
handle_mouse_scroll :: proc(x, y : f32, using ctx := active_ctx) {
    using input;
    mouse_scroll_total += {x, y};
    mouse_scroll_delta = {x, y};
}
handle_mouse_move :: proc(x, y : f32, using ctx := active_ctx) {
    using input;
    mouse_pos = {x, y};
}
handle_char :: proc(char : rune, using ctx := active_ctx) {
    using input;
    append(&chars, char);
}