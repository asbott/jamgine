package app

import "jamgine:gfx"
import "jamgine:gfx/imm"
import igui "jamgine:gfx/imm/gui"
import "jamgine:gfx/text"
import "jamgine:console"
import "jamgine:input"
import "jamgine:serial"
import "jamgine:lin"

import "core:fmt"
import "core:time"
import "core:mem"
import "core:os"

import "vendor:glfw"

App_Callback_Proc :: #type proc() -> bool;

init_proc : App_Callback_Proc;
sim_proc : App_Callback_Proc;
draw_proc : App_Callback_Proc;
shutdown_proc : App_Callback_Proc;

running := true;
want_restart := false;

App_Config :: struct {
    should_draw_stats : bool,
    enable_imm_gui : bool,
    
    enable_depth_test : bool,

    do_serialize_config : bool,
}
config : App_Config;

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

    gfx.init_and_open_window("Jamgine App", enable_depth_test=config.enable_depth_test);

    imm.init();
    imm.make_and_set_context();

    igui.make_and_set_gui_context();

    console.init(imm.get_current_context());
    input.init(gfx.window);

    console.bind_command("exit", proc() {
        running = false;
    });
    console.bind_command("restart", proc() {
        running = false;
        want_restart = true;
    });
    console.bind_command("draw_stats", proc(value : bool) {
        config.should_draw_stats = value;
    });
    console.bind_command("enable_imm_gui", proc(value : bool) {
        config.enable_imm_gui = value;
    });

    //
    // Config default values here

    when ODIN_DEBUG {
        config.should_draw_stats = true;
        config.enable_imm_gui = true;
    } else {
        config.should_draw_stats = false;
        config.enable_imm_gui = false;
    }

    if init_proc != nil && !init_proc() do running = false;

    if config.do_serialize_config {
        serial.bind_struct_data_to_file(&config, "config.json", .WRITE_CHANGES_TO_DISK);
    }

    time.stopwatch_start(&frame_stopwatch);
    time.stopwatch_start(&elapsed_stopwatch);
    
    for !glfw.WindowShouldClose(gfx.window) && running {

        mem.free_all(context.temp_allocator);

        frame_duration   = time.stopwatch_duration(frame_stopwatch);
        delta_seconds    = cast(f32)time.duration_seconds(frame_duration);
        elapsed_duration = time.stopwatch_duration(elapsed_stopwatch);
        elapsed_seconds  = cast(f32)time.duration_seconds(elapsed_duration);
        time.stopwatch_reset(&frame_stopwatch);
        time.stopwatch_start(&frame_stopwatch);

        gfx.collect_window_events();
        console.update(delta_seconds);

        if config.enable_imm_gui do igui.new_frame();
        
        if sim_proc != nil && !sim_proc() {
            running = false;
            break;
        }
        
        
        if draw_proc != nil && !draw_proc() {
            running = false;
            break;
        }
        
        if config.enable_imm_gui do igui.update(delta_seconds);
        input.update();

        if config.should_draw_stats {
            imm.set_render_target(gfx.window_surface);
            imm.set_default_2D_camera(gfx.get_window_size().x, gfx.get_window_size().y);
            imm.begin2d();
            imm_stats := last_imm_stats;
            stats_string := fmt.tprintf(
`imm Vertices: %i,
imm Indices: %i
imm Scissors: %i
imm Draw Calls : %i,
Frametime: %fms.
FPS: %f `, imm_stats.num_vertices, imm_stats.num_indices, imm_stats.num_scissors, imm_stats.num_draw_calls, delta_seconds*1000, 1.0/delta_seconds);

            text_size := text.measure(imm.get_current_context().default_font, stats_string);
            imm.text(stats_string, { 5+1, 5-1, 0 } + lin.v3(text_size / 2.0), color=gfx.BLACK);
            imm.text(stats_string, { 5, 5, 0 } + lin.v3(text_size / 2.0));
            imm.flush();
        }
        imm.set_render_target(gfx.window_surface);
        imm.set_default_2D_camera(gfx.get_window_size().x, gfx.get_window_size().y);

        if config.enable_imm_gui do igui.draw();
        else              do igui.clear_frame(); // Clear gui calls without drawing if not enabled
        console.draw();
        igui.draw();

        gfx.update_window();

        last_imm_stats = imm.get_current_context().stats;
        imm.reset_stats();

    }

    serial.update_synced_data();

    if shutdown_proc != nil do shutdown_proc();

    console.shutdown();
    igui.destroy_current_context();
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();

    if want_restart {
        want_restart = false;
        fmt.println("Restarting app...");
        running = true;
        run();
    } else {
        fmt.println("App exited normally");
    }
}