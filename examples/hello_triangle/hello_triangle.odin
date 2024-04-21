package hello_triangle

import "jamgine:gfx"
import jvk "jamgine:gfx/justvk"
import "jamgine:lin" // Linear algebra library

import glfw "vendor:glfw"

import "core:log"

running := true;

main :: proc() {
    // Set up a logger so we can see messages from libraries
    context.logger = log.create_console_logger();

    // Libraries output a lot of debug messages, so you may want to
    // disable them.
    // context.logger.lowest_level = .Info;
    
    // This initializes window, JustVK and the window_surface
    gfx.init_and_open_window("Hello, Triangle!", width=600, height=400);

    vert_src :: `
        #version 450

        void main() {
            const vec2 vertices[3] = {
                vec2( -0.5,  0.5 ),
                vec2(  0.5,  0.5 ),
                vec2(  0.0, -0.5 )
            };

            vec2 pos = vertices[gl_VertexIndex % 3];

            gl_Position = vec4(pos.x, pos.y, 0.0, 1.0);
        }
    `;
    frag_src :: `
        #version 450

        layout (location = 0) out vec4 f_color;

        void main() { f_color = vec4(1.0, 1.0, 1.0, 1.0); }
    `;

    // Compile shader program
    program, program_ok := jvk.make_shader_program(vert_src, frag_src);
    assert(program_ok, "Failed compiling program"); // Compile errors are logged to stdout

    pipeline := jvk.make_pipeline(program, gfx.window_surface.render_pass);

    for !gfx.should_window_close() && running {
        gfx.collect_window_events();

        // Begin gathering draw commands targetting the window surface
        jvk.begin_draw_surface(pipeline, gfx.window_surface);

        // Clear with black
        jvk.cmd_clear(pipeline, {.COLOR}, {0.0, 0.0, 0.0, 1.0});

        // Draw one instance of 3 vertices
        jvk.cmd_draw(pipeline, 3, 1);

        // Flush draw commands
        jvk.end_draw(pipeline);

        // Grab the first key event if there was one such last frame
        if key_event := gfx.take_window_event(gfx.Window_Key_Event); key_event != nil {
            if key_event.action == glfw.PRESS && key_event.key == glfw.KEY_ESCAPE do running = false;
        }

        // Swap buffers etc
        gfx.update_window();
    }

    // Cleanup
    jvk.destroy_pipeline(pipeline);
    jvk.destroy_shader_program(program);
    gfx.shutdown();
}