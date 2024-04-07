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

    /*{
        igui.begin_panel(cast(int)rand.int63(&id_rand), {.ALLOW_ACTIVE, .ALLOW_FOCUS, .ALLOW_HSCROLL, .ALLOW_VSCROLL, .ALLOW_MOVE, .ALLOW_OVERFLOW, .ALLOW_RESIZE});
        igui.set_widget_overflow_flags({.EAST, .SOUTH});
        igui.begin_panel(cast(int)rand.int63(&id_rand), {.ALLOW_ACTIVE, .ALLOW_FOCUS, .ALLOW_HSCROLL, .ALLOW_VSCROLL, .ALLOW_MOVE, .ALLOW_OVERFLOW, .ALLOW_RESIZE});
        igui.end_panel();
        
        igui.begin_panel(cast(int)rand.int63(&id_rand), {.ALLOW_FOCUS, .IGNORE_INPUT});
        igui.set_widget_pos(-100, -100);
        igui.end_panel();

        @(static)
        slider_value1 : f32 = 0.5;
        slider_value2 : f32 = 0.2;
        igui.slider_raw(cast(int)rand.int63(&id_rand), {100, 0}, .HORIZONTAL, 128, &slider_value1);
        igui.slider_raw(cast(int)rand.int63(&id_rand), {-100, 0}, .VERTICAL, 128, &slider_value2);

        
        igui.label_raw(cast(int)rand.int63(&id_rand), {100, 20}, "Label");
        if (igui.button_raw(cast(int)rand.int63(&id_rand), {100, 70}, {100, 25}, "Press Me")) {
            fmt.println("Horizontal slider value is", slider_value1);
            fmt.println("Vertical slider value is", slider_value2);
        }

        igui.begin_panel(cast(int)rand.int63(&id_rand), {.ALLOW_ACTIVE, .ALLOW_FOCUS, .BUTTON});
        igui.set_widget_pos(-200, 100);
        igui.set_widget_size(300, 300);
        igui.label_raw(cast(int)rand.int63(&id_rand), {}, "Stuck child");
        igui.end_panel();


        igui.end_panel();
    }

    {
        igui.begin_panel(cast(int)rand.int63(&id_rand), {.ALLOW_ACTIVE, .ALLOW_FOCUS, .ALLOW_HSCROLL, .ALLOW_VSCROLL, .ALLOW_MOVE, .ALLOW_OVERFLOW, .ALLOW_RESIZE});
        igui.set_widget_overflow_flags({.EAST, .SOUTH});
        igui.begin_panel(cast(int)rand.int63(&id_rand), {.ALLOW_ACTIVE, .ALLOW_FOCUS, .ALLOW_HSCROLL, .ALLOW_VSCROLL, .ALLOW_MOVE, .ALLOW_OVERFLOW, .ALLOW_RESIZE});
        igui.end_panel();
        
        igui.begin_panel(cast(int)rand.int63(&id_rand), {.ALLOW_FOCUS, .IGNORE_INPUT});
        igui.set_widget_pos(-100, -100);
        igui.end_panel();

        @(static)
        slider_value1 : f32 = 0.5;
        slider_value2 : f32 = 0.2;
        igui.slider_raw(cast(int)rand.int63(&id_rand), {100, 0}, .HORIZONTAL, 128, &slider_value1);
        igui.slider_raw(cast(int)rand.int63(&id_rand), {-100, 0}, .VERTICAL, 128, &slider_value2);

        
        igui.label_raw(cast(int)rand.int63(&id_rand), {100, 20}, fmt.tprintf("%.3f",slider_value1));
        
        @(static)
        builder : ^strings.Builder;
        if builder == nil {
            builder = new(strings.Builder);
            strings.builder_init(builder);
        }
        
        @(static)
        int_value : int;
        @(static)
        float_value : f32;

        if (igui.button_raw(cast(int)rand.int63(&id_rand), {100, 70}, {100, 25}, "Press Me")) {
            fmt.println("Horizontal slider value is", slider_value1);
            fmt.println("Vertical slider value is", slider_value2);
            fmt.println("Text field is", strings.to_string(builder^));
            fmt.println("Int field is", int_value);
            fmt.println("Float field is", float_value);
        }

        igui.text_field_raw(cast(int)rand.int63(&id_rand), {0, 150}, {150, 24}, builder, filter_proc = proc(char : rune) -> bool {
            return unicode.is_alpha(char);
        });
        igui.int_field_raw(cast(int)rand.int63(&id_rand), {0, 120}, {60, 24}, &int_value);
        igui.f32_field_raw(cast(int)rand.int63(&id_rand), {0, 90}, {90, 24}, &float_value);


        igui.end_panel();
    }*/

    {
        igui.begin_window("Sliders test");

        @(static)
        int_value : int;
        @(static)
        int_value2 : int;
        @(static)
        float_value : f32;
        @(static)
        float_value2 : f32;

        igui.int_slider_raw(cast(int)rand.int63(&id_rand), {0, 50}, {200, 18}, &int_value, -15000, 29000);
        igui.f32_slider_raw(cast(int)rand.int63(&id_rand), {0, 0}, {200, 18}, &float_value, -61.7654, 91.2176);
        
        igui.int_drag_raw(cast(int)rand.int63(&id_rand), {0, -50}, {200, 30}, &int_value2, 0);
        igui.f32_drag_raw(cast(int)rand.int63(&id_rand), {0, -100}, {200, 30}, &float_value2, 0, rate=0.14);

        igui.end_window();
    }
    
    {
        igui.begin_window("Window formatting test");

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

        /*igui.begin_window("Window formatting test##2");

        igui.label("I display the same title as the other one but still have a unique ID");

        igui.end_window();*/
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

    
    igui.draw();

    return true;
}
