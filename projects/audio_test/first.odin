package audio_test

import "jamgine:app"
import "jamgine:gfx"
import igui "jamgine:gfx/imm/gui"

import "jamgine:audio"

main :: proc() {
    app.config.name = "Jamgine Audio Test";
    app.config.do_serialize_config = true;
    app.config.do_clear_window = true;
    app.config.window_clear_color = gfx.CORNFLOWER_BLUE;

    app.init_proc = init;
    app.shutdown_proc = shutdown;
    app.sim_proc = update;
    app.draw_proc = draw;

    app.run();
}



init :: proc() -> bool {

    audio.init();
    audio.set_target_device_context(audio.make_device_context(proc(dc : ^audio.Device_Context, output, input : rawptr, frame_count : int) {

    }));

    return true;
}
shutdown :: proc() -> bool {

    audio.destroy_target_device_context();
    audio.shutdown();

    return true;
}

update :: proc() -> bool {

    igui.begin_window("Window");
    igui.label("Hey there");
    igui.end_window();

    return true;
}

draw :: proc() -> bool {
    return true;
}