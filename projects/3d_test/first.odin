package _3d_test

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
    app.enable_depth_test = true;

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
    imm.set_projection_perspective(math.RAD_PER_DEG * 60, window_size.x / window_size.y, 0.1, 1000.0);
    imm.set_view_look_at({0, 0, -3}, {0, 0, 0}, {0, -1, 0});
    imm.set_render_target(gfx.window_surface);
    imm.begin3d();
    imm.clear_target({.0, .0, 1.0, 1.0});

    imm.push_translation({1, 1, 2});
    imm.push_rotation_y(app.elapsed_seconds * 2);
    imm.rectangle({}, {1, 1}, color=gfx.GREEN);
    imm.pop_transforms(2);

    imm.push_translation({1, 0, 0});
    imm.push_rotation_y(app.elapsed_seconds);
    imm.rectangle({}, {1, 1});
    imm.pop_transforms(2);

    
    imm.push_translation({-1, 0, 0});
    imm.push_rotation_y(app.elapsed_seconds);
    imm.rectangle({}, {1, 1});
    imm.pop_transforms(2);

    imm.push_translation({-1, 1, 2});
    imm.push_rotation_y(app.elapsed_seconds * 2);
    imm.rectangle({}, {1, 1}, color=gfx.GREEN);
    imm.pop_transforms(2);


    imm.flush();

    return true;
}
