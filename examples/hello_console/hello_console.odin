package hello_console

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:console"
import glfw "vendor:glfw"

import "core:fmt"

running := true;

main :: proc() {
    // Use the console for logging
    context.logger = console.create_console_logger();

    gfx.init_and_open_window("Hello, console!", width=600, height=400, enable_depth_test=true);

    // Init imm & make context. This is used in console  rendering.
    imm.init();
    imm.make_and_set_context();

    console.init(imm.get_current_context());

    // Bind functions directly to command names
    console.bind_command("exit", proc() {
        running = false;
    });
    console.bind_command("print_hello", proc(something : string) -> string {
        return fmt.tprintf("Hello, %s!", something);
    });

    last_time := glfw.GetTime();
    for !gfx.should_window_close() && running {

        now := glfw.GetTime();
        delta_seconds := f32(now - last_time);
        last_time = now;

        // Set 2D view & clear window
        window_size := gfx.get_window_size();
        imm.set_default_2D_camera(window_size.x, window_size.y);
        imm.begin2d();
        imm.clear_target(gfx.CORNFLOWER_BLUE);
        imm.flush();

        gfx.collect_window_events();

        // Input is handled here, so where you call this matters.
        console.update(delta_seconds);
        // For example if we want the console to handle input before
        // app handles input, we would call the app input handler after.
        // input.update();

        console.draw();
        
        gfx.swap_buffers();

        // Grab the first key event if there was one such last frame
        if e := gfx.take_window_event(gfx.Window_Key_Event); e != nil {
            if e.action == glfw.PRESS && e.key == glfw.KEY_ESCAPE do running = false;
        }
    }

    // Cleanup
    console.shutdown();
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();
}