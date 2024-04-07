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
import "core:fmt"

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

    window_size := gfx.get_window_size();
    imm.set_default_2D_camera(window_size.x, window_size.y);
    imm.set_render_target(gfx.window_surface);
    imm.begin2d();
    imm.clear_target({.13, .1, .3, 1.0});
    imm.flush();

    igui.begin_panel(1);
    
    igui.begin_panel(2);
    
    
    igui.end_panel();
    
    igui.end_panel();

    /*igui.begin_panel(842789);
    
    
    igui.end_panel();*/


    
    igui.draw();

    return true;
}
