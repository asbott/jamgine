package majs

import "jamgine:gfx"
import "jamgine:gfx/imm"

import "jamgine:console"
import "jamgine:bible"

import "vendor:glfw"


import "core:net"
import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:mem"
import "core:log"


running := true;

main :: proc() {
    gfx.init_and_open_window("Majs");

    imm.make_and_set_context();
    console.init(imm.get_current_context());

    context.logger = console.create_console_logger();

    console.bind_command("exit", proc() {
        running = false;
    });

    
    now := glfw.GetTime();
    last_time : f64;
    for !glfw.WindowShouldClose(gfx.window) && running {
        now = glfw.GetTime();
        delta := now-last_time;
        last_time = now;

        gfx.collect_window_events();

        console.update(cast(f32)delta);

        imm.begin2d();
        imm.clear_target(gfx.SOFT_GRAY);
        imm.flush();

        console.draw();

        gfx.update_window();
    }
}