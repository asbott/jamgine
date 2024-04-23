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
import "jamgine:serial"

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

    app.config.do_clear_window = true;
    app.config.window_clear_color = gfx.CORNFLOWER_BLUE;
    app.config.do_serialize_config = true;

    app.run();
}

init :: proc() -> bool {
    serial.bind_struct_data_to_file(&igui.get_current_context().style, "style.sync", .WRITE_CHANGES_TO_DISK);
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

    igui.show_style_editor();

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
        igui.columns(2);
        {
            @(static)
            vec2_value : lin.Vector2;
            igui.f32vec2_drag("Vector2 drag", &vec2_value, -1.0, 1.0);
        }
        {
            @(static)
            vec3_value : lin.Vector3;
            igui.f32vec3_field("Vector3 field", &vec3_value);
        }
        igui.columns(1);
        {
            @(static)
            vec4_value : lin.Vector4;
            igui.f32vec4_drag("Vector4 drag", &vec4_value);
        }
        {
            @(static)
            rgba_value : lin.Vector4;
            igui.f32rgba_drag("Color drag", &rgba_value, min=0.0);
        }
        {
            @(static)
            toggle : bool;

            igui.columns(3);
            if igui.button("Press Me") {
                toggle = true;
            }
            if igui.button("Reset") {
                toggle = false;
            }
            igui.button("Hey");
            igui.columns(1);
            if toggle {
                igui.label("Thanks!");
            } else {
                igui.label("Do what he says please ^");
            }
            
        }
        {
            NUM_COLUMNS :: 10;
            NUM_TOGGLES :: NUM_COLUMNS * 4
            igui.columns(NUM_COLUMNS);

            @(static)
            toggles :[]bool; 
            if toggles == nil do toggles = make([]bool, NUM_TOGGLES);

            for _, i in toggles {
                igui.checkbox(fmt.tprintf("V%i", i), &toggles[i]);
            }

            igui.columns(1);
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
