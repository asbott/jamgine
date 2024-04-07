package imm_gui_test

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:console"
import "jamgine:app"
import "jamgine:entities"
import "jamgine:lin"
import "jamgine:utils"
import jvk "jamgine:gfx/justvk"
import igui "jamgine:gfx/imm/gui"

import "core:math"
import "core:math/rand"
import "core:fmt"
import "core:strings"
import "core:unicode"

main :: proc() {

    app.init_proc     = init;
    app.shutdown_proc = shutdown;
    app.sim_proc      = simulate_game;
    app.draw_proc     = draw_game;

    app.run();
}

init :: proc() -> bool {
    
    return true;
}
shutdown :: proc() -> bool {


    return true;
}

simulate_game :: proc() -> bool {

    return true;
}

draw_game :: proc() -> bool {

    RAND_SEED :: 109481094;
    id_rand := rand.create(RAND_SEED);

    window_size := gfx.get_window_size();
    imm.set_default_2D_camera(window_size.x, window_size.y);
    imm.set_render_target(gfx.window_surface);
    imm.begin2d();
    imm.clear_target({.7, .7, .7, 1.0});
    imm.flush();

    {
        igui.begin_window("Test");

        igui.label("I am a label");
        igui.label("And I am a red label", color=gfx.RED);
        {
            @(static)
            str_value : string;
            igui.text_field("Text field", &str_value);
        }
        {
            @(static)
            int_value : int;
            igui.int_slider("Int slider", &int_value, -12, 182);
        }
        {
            @(static)
            int_value : int;
            igui.int_field("Int field", &int_value);
        }
        {
            @(static)
            int_value : int;
            igui.int_drag("Int drag", &int_value);
        }
        {
            @(static)
            f32_value : f32;
            igui.f32_field("Float field", &f32_value);
        }
        {
            @(static)
            f32_value : f32;
            igui.f32_slider("Float slider", &f32_value, -9.82, 8.1537);
        }
        {
            @(static)
            f32_value : f32;
            igui.f32_drag("Float drag", &f32_value);
        }
        {
            @(static)
            toggle : bool;
            if igui.button("Press Me") {
                toggle = true;
            }
            if toggle {
                igui.label("Thanks!");
            } else {
                igui.label("Do what he says please ^");
            }
            if igui.button("Reset") {
                toggle = false;
            }
        }
        
        igui.end_window();

    }

    {
        igui.begin_window("My Window");

        igui.label("Hey there", color=gfx.GREEN);

        @(static)
        f32_value : f32;
        igui.f32_drag("Float value: ", &f32_value);

        if igui.button("Unset") {
            f32_value = 0;
        }

        igui.end_window();
    }

    return true;
}
