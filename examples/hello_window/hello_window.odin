package hello_window

import "jamgine:gfx"
import glfw "vendor:glfw"

running := true;

main :: proc() {
    gfx.init_and_open_window("Hello, Window!", width=600, height=400);

    for !gfx.should_window_close() && running {
        gfx.collect_window_events();

        // Grab the first key event if there was one such last frame
        if e := gfx.take_window_event(gfx.Window_Key_Event); e != nil {
            if e.action == glfw.PRESS && e.key == glfw.KEY_ESCAPE do running = false;
        }
    }

    gfx.shutdown();
}