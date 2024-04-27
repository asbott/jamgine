package hello_imm

import "jamgine:gfx"
import glfw "vendor:glfw"
import "jamgine:gfx/imm"

import "core:log"

running := true;

main :: proc() {

    context.logger = log.create_console_logger();

    // We will do some 3D in this example, so enable depth testing in the window
    gfx.init_and_open_window("Hello, imm!", width=600, height=400, enable_depth_test=true);

    // Init imm & make context
    imm.init();
    imm.make_and_set_context();

    for !gfx.should_window_close() && running {
        gfx.collect_window_events();

        // Set up for 2D
        window_size := gfx.get_window_size();
        imm.set_default_2D_camera(window_size.x, window_size.y);
        imm.begin2d();

        imm.clear_target(gfx.CORNFLOWER_BLUE);

        imm.rectangle({ 100, 100, 0 }, {40, 40});

        // Rotating text
        imm.push_translation({300, 200, 0});
        imm.push_rotation_z(cast(f32)glfw.GetTime());
        imm.text("Hello, imm!", {});
        imm.pop_transforms(2);
        
        // Draw
        imm.flush();
        
        // Set up for 3D
        imm.set_default_3D_camera(window_size.x, window_size.y);
        imm.begin3d();

        imm.push_translation({4, 1, 0});
        imm.push_rotation({1, 1, 0}, cast(f32)glfw.GetTime());
        verts := imm.cube({}, { 1, 1, 1 });
        // Add some color variation so it looks more 3D
        verts[2].tint = gfx.RED;   verts[5].tint = gfx.GREEN;
        verts[8].tint = gfx.BLUE;  verts[11].tint = gfx.BLACK;
        verts[14].tint = gfx.PLUM; verts[17].tint = gfx.ORANGE;
        imm.pop_transforms(2);

        // Draw
        imm.flush();

        // Grab the first key event if there was one such last frame
        if e := gfx.take_window_event(gfx.Window_Key_Event); e != nil {
            if e.action == glfw.PRESS && e.key == glfw.KEY_ESCAPE do running = false;
        }

        gfx.swap_buffers();
    }

    // Cleanup
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();
}