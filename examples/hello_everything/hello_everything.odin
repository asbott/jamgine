package hello_everything

import "jamgine:gfx"
import "jamgine:gfx/imm"
import igui "jamgine:gfx/imm/gui"
import "jamgine:app"
import "jamgine:input"
import "jamgine:lin"

import "vendor:glfw"

import "core:log"

main :: proc() {

    app.init_proc     = init;
    app.shutdown_proc = shutdown;
    app.sim_proc      = simulate_app;
    app.draw_proc     = draw_app;

    app.config.enable_depth_test = true;

    app.run();
}

init :: proc() -> bool {
    /* Initialize stuff */
    return true;
}
shutdown :: proc() -> bool {
    /* Free stuff */
    return true;
}

// Called once each frame
simulate_app :: proc() -> bool {

    if input.is_key_just_pressed(glfw.KEY_F) {
        log.error("You pressed F!!!");
    }

    igui.begin_window("A window");
    igui.button("Hey there");
    igui.end_window();

    return true;
}

// Called at the end of each frame right before swapping window buffers
// but before overlay things like the console or imm_gui.
draw_app :: proc() -> bool {

    // Here imm has default 2D camera set by default

    imm.begin2d();
    imm.clear_target(gfx.CORNFLOWER_BLUE);

    imm.push_translation(lin.v3(gfx.get_window_size()/2));
    imm.push_rotation_z(app.elapsed_seconds);
    imm.rectangle({}, {100, 100});
    imm.pop_transforms(2);

    imm.flush();

    return true;
}
