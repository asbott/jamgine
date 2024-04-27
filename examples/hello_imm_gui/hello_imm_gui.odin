package hello_imm_gui

import "jamgine:gfx"
import "jamgine:gfx/imm"
import igui "jamgine:gfx/imm/gui"

import glfw "vendor:glfw"

import "core:log"

running := true;

main :: proc() {
    context.logger = log.create_console_logger();

    gfx.init_and_open_window("Hello, imm_gui!", width=600, height=400, enable_depth_test=true);

    // Init imm & make context. This is used in imm_gui rendering.
    imm.init();
    imm.make_and_set_context();

    igui.make_and_set_gui_context();

    last_time := glfw.GetTime();
    for !gfx.should_window_close() && running {

        now := glfw.GetTime();
        delta_seconds := f32(now - last_time);
        last_time = now;

        gfx.collect_window_events();

        // Set 2D camera (will be used in imm_gui) and clear window-
        window_size := gfx.get_window_size();
        imm.set_default_2D_camera(window_size.x, window_size.y)
        imm.begin2d();
        imm.clear_target(gfx.CORNFLOWER_BLUE);
        imm.flush();

        igui.new_frame();

        igui.begin_window("Hello, gui window");

        igui.label("Hello, label!");

        @(static)
        value : f32;
        igui.f32_drag("Hello, float widget!", &value);

        igui.end_window();
        
        igui.update(delta_seconds);
        
        igui.draw();
        
        gfx.swap_buffers();

        // Grab the first key event if there was one such last frame
        if e := gfx.take_window_event(gfx.Window_Key_Event); e != nil {
            if e.action == glfw.PRESS && e.key == glfw.KEY_ESCAPE do running = false;
        }
    }

    // Cleanup
    igui.destroy_current_context();
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();
}