package majs

import "jamgine:gfx"
import "jamgine:console"
import "jamgine:gfx/imm"
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
    context.logger = console.create_console_logger();

    gfx.init_and_open_window("Majs");

    imm.init();
    imm.make_and_set_context();
    console.init(imm.get_current_context());


    console.bind_command("exit", proc() {
        running = false;
    });

    atlas := imm.make_text_atlas(300, 400);

    single_line := "sinjjgle_line";
    double_line := "doujjble\nline";

    single_line_text, _ := imm.render_text(&atlas, single_line);
    double_line_text, _ := imm.render_text(&atlas, double_line);
    imm.render_text(&atlas, "Meow");
    imm.render_text(&atlas, "Meow");
    imm.render_text(&atlas, "Meow");
    
    now := glfw.GetTime();
    last_time : f64;
    for !glfw.WindowShouldClose(gfx.window) && running {
        now = glfw.GetTime();
        delta := now-last_time;
        last_time = now;

        gfx.collect_window_events();

        console.update(cast(f32)delta);

        imm.set_render_target(gfx.window_surface);
        imm.set_default_2D_camera(gfx.get_window_size().x, gfx.get_window_size().y);
        imm.begin2d();
        imm.clear_target(gfx.OLIVE_DRAB);

        imm.text(single_line, {130, 300, 0});
        imm.text(double_line, {130, 200, 0});

        imm.text(single_line_text, {400, 300, 0});
        imm.text(double_line_text, {400, 200, 0});

        imm.rectangle({900, 400, 0}, {300, 400}, texture=atlas.texture);

        imm.flush();

        console.draw();

        gfx.swap_buffers();
    }
}