package test

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:gfx/text"
import jvk "jamgine:gfx/justvk"
import "jamgine:input"
import "jamgine:utils"
import "jamgine:data"
import "jamgine:lin"

import "jamgine:console"

import "core:fmt"
import "core:time"
import "core:log"
import "core:os"
import "core:math"
import "core:math/rand"

import "vendor:glfw"

DEVELOPER :: #config(DEVELOPER, true)
running := true;

frame_stopwatch      : time.Stopwatch;
frame_duration       : time.Duration;
delta_seconds        : f32;
scaled_delta_seconds : f32;
elapsed_stopwatch    : time.Stopwatch;
elapsed_seconds      : f32;
scaled_seconds       : f32;
elapsed_duration     : time.Duration;
last_imm_stats       : imm.Stats;
time_scale :f32= 1.0;

main :: proc() {
    //context.logger = log.create_console_logger();
    context.logger = console.create_console_logger();

    fmt.println("Program started");

    gfx.init_and_open_window("Invaders");
    imm.make_and_set_context(8001);
    
    console.init(imm.get_current_context());
    
    input.init(gfx.window);
    
    test_text := "This text is pre-rendered";
    test_text_size := text.measure(imm.default_font, test_text);
    text_texture := jvk.make_texture(int(test_text_size.x), int(test_text_size.y), nil, .RGBA_HDR, {.SAMPLE, .DRAW});
    text_target := jvk.make_texture_render_target(text_texture);

    
    imm.set_render_target(text_target);
    imm.set_default_2D_camera(test_text_size.x, test_text_size.y);
    imm.begin2d();
    imm.clear_target(gfx.TRANSPARENT);
    imm.text(test_text, {test_text_size.x/2, test_text_size.y/2, 0});
    imm.flush();

    imm.set_render_target(gfx.window_surface);


    {
        w, h := glfw.GetWindowSize(gfx.window);
        imm.set_default_2D_camera(cast(f32)w, cast(f32)h);
    }


    num_textures := 200;
    textures := make([]jvk.Texture, num_textures);
    for i in 0..<len(textures) {
        texture, ok := gfx.load_texture_from_disk("test.png");
        if !ok do panic("Failed loading texture");
        textures[i] = texture;
    }

    console.bind_command("exit", proc () {
        running = false;
    }, help="Exit the program");
    console.bind_command("print_fps", proc () {
        log.infof("%-6f FPS | %-2fms", 1.0 / delta_seconds, delta_seconds * 1000.0);
    });
    console.bind_command("print_imm_stats", proc () -> string {
        return fmt.tprint(last_imm_stats);
    });

    time.stopwatch_start(&frame_stopwatch);
    time.stopwatch_start(&elapsed_stopwatch);
    for !glfw.WindowShouldClose(gfx.window) && running {

        
        frame_duration   = time.stopwatch_duration(frame_stopwatch);
        delta_seconds    = cast(f32)time.duration_seconds(frame_duration);
        scaled_delta_seconds = delta_seconds * time_scale;
        elapsed_duration = time.stopwatch_duration(elapsed_stopwatch);
        elapsed_seconds  = cast(f32)time.duration_seconds(elapsed_duration);
        scaled_seconds   += scaled_delta_seconds;

        time.stopwatch_reset(&frame_stopwatch);
        time.stopwatch_start(&frame_stopwatch);

        free_all(context.temp_allocator);
        gfx.collect_window_events();

        console.update(delta_seconds);
        input.update();

        
        when DEVELOPER {
            if input.is_key_just_pressed(glfw.KEY_ESCAPE, glfw.MOD_SHIFT) {
                running = false;
            }
        }
        
        for e in gfx.window_events {
            #partial switch event in e.variant {
                case gfx.Window_Resize_Event: {
                    imm.set_default_2D_camera(event.width, event.height);
                }
            }
        }
        
        imm.set_render_target(gfx.window_surface);
        
        imm.begin2d();
        imm.clear_target(gfx.RED);
        
        window_width, window_height := glfw.GetWindowSize(gfx.window);
        w := cast(f32)window_width;
        h := cast(f32)window_height;
        area := w * h;
        area_per_texture := area / cast(f32)num_textures;
        radius := math.sqrt_f32(area_per_texture);
        xcount := cast(int)(w / radius);
        ycount := cast(int)(h / radius);
        for texture, i in textures {
            x := f32(i % xcount) * radius;
            y := f32(i / xcount) * radius;
            imm.push_translation({x, y, 0});
            imm.push_rotation_z(elapsed_seconds + f32(i) * 0.1);
            imm.rectangle({0.0, 0.0, 0}, {64.0, 64.0}, texture=texture);
            //imm.rectangle({0.0, 0.0, 0}, {64.0, 64.0});
            imm.pop_transforms(2);
        }


        
        imm.text("Hey, Yey", {600, 100, 0});

        imm.rectangle({500, 300, 0} + {test_text_size.x/2.0, test_text_size.y/2.0, 0.0}, test_text_size, texture=text_texture, uv_range={0, 1, 1, 0});
        
        imm.flush();
        
        console.draw();
        
        //imm.set_render_target(gfx.window);
        
        gfx.update_window();
        last_imm_stats = imm.get_current_context().stats;
        imm.reset_stats();

        //os.exit(1);
    }

    console.shutdown();

    imm.delete_current_context();

    gfx.shutdown();

    fmt.println("Exit as expected");
}