package app

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:gfx/text"
import "jamgine:console"
import "jamgine:input"
import "jamgine:serial"
import "jamgine:lin"

import "core:fmt"
import "core:time"

import "vendor:glfw"

App_Callback_Proc :: #type proc() -> bool;

init_proc : App_Callback_Proc;
sim_proc : App_Callback_Proc;
draw_proc : App_Callback_Proc;
shutdown_proc : App_Callback_Proc;

running := true;
when ODIN_DEBUG {
    should_draw_stats := true;
} else {
    should_draw_stats := false;
}

frame_stopwatch      : time.Stopwatch;
frame_duration       : time.Duration;
delta_seconds        : f32;
elapsed_stopwatch    : time.Stopwatch;
elapsed_seconds      : f32;
elapsed_duration     : time.Duration;
last_imm_stats       : imm.Stats;

run :: proc() {
    fmt.println("App started");

    context.logger = console.create_console_logger();

    gfx.init_and_open_window("Majs");

    imm.init();
    imm.make_and_set_context();
    console.init(imm.get_current_context());
    input.init(gfx.window);

    console.bind_command("exit", proc() {
        running = false;
    });
    console.bind_command("draw_stats", proc(value : bool) {
        should_draw_stats = value;
    });

    if init_proc != nil && !init_proc() do running = false;

    time.stopwatch_start(&frame_stopwatch);
    time.stopwatch_start(&elapsed_stopwatch);
    for !glfw.WindowShouldClose(gfx.window) && running {

        frame_duration   = time.stopwatch_duration(frame_stopwatch);
        delta_seconds    = cast(f32)time.duration_seconds(frame_duration);
        elapsed_duration = time.stopwatch_duration(elapsed_stopwatch);
        elapsed_seconds  = cast(f32)time.duration_seconds(elapsed_duration);
        time.stopwatch_reset(&frame_stopwatch);
        time.stopwatch_start(&frame_stopwatch);

        gfx.collect_window_events();

        console.update(delta_seconds);
        input.update();

        if sim_proc != nil && !sim_proc() {
            running = false;
            break;
        }

        if draw_proc != nil && !draw_proc() {
            running = false;
            break;
        }

        if should_draw_stats {
            imm.set_render_target(gfx.window_surface);
            imm.set_default_2D_camera(gfx.get_window_size().x, gfx.get_window_size().y);
            imm.begin2d();
            imm_stats := last_imm_stats;
            stats_string := fmt.tprintf(
`imm Vertices: %i,
imm Indices: %i
Frametime: %f.
FPS: %f `, imm_stats.num_vertices, imm_stats.num_indices, delta_seconds, 1.0/delta_seconds);

            text_size := text.measure(imm.get_current_context().default_font, stats_string);
            imm.text(stats_string, { 5+1, 5-1, 0 } + lin.v3(text_size / 2.0), color=gfx.BLACK);
            imm.text(stats_string, { 5, 5, 0 } + lin.v3(text_size / 2.0));
            imm.flush();
        }
        console.draw();

        gfx.update_window();

        last_imm_stats = imm.get_current_context().stats;
        imm.reset_stats();
    }

    serial.update_synced_data();

    if shutdown_proc != nil do shutdown_proc();

    console.shutdown();
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();

    fmt.println("App exited normally");
}