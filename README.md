# Introduction

My personal sandbox/portfolio.

I cannot offer you a fancy paper or fancy numbers in my CV, but I can offer  you quality software in a jungle of terrible software getting worse by each passing day.

This project is meant to showcase the real fruits of my efforts and competence in software. 

However, if you're not here as a recruiter, feel free to use anything you see. The goal is for everything to be self-contained with the only dependencies being part of the odin standard/vendor packages. Features are designed to be modular, so if you only want to use a single or a couple modules from this library that shouldn't be a problem. See [examples](/examples).


# Jamgine

This project can be summarized as a self-contained realtime graphical application engine, mainly designed for video games.

Everything is made from scratch with one temporary external dependency being shaderc. I am currently working on my own glsl to SPIR-v compiler.

Except for shaderc binaries, there are some unimplemented unix functions needed to compile on unix systems (osext/linux).

Vulkan backend is tested with a RTX 3060 Laptop GPU as well as 11th gen intel i5 integrated graphics.

I can be reached at charlie.malmqvist1@gmail.com.

## Table of contents
- [Build & Run](#build--run)
- [Note on self-containedness](#note-on-self-containedness)
- [Points of Interest](#points-of-interest)
- [Technical Points of Interest](#technical-points-of-interest)
- [Code Examples](#some-examples)
    - [Hello Window](#hello-window)
    - [Hello Triangle](#hello-triangle)
    - [Hello imm](#hello-imm)
    - [Hello imm_gui](#hello-imm_gui)
    - [Hello Console](#hello-console)
    - [Hello Everything](#hello-everything) (App configuration)
- [Upcoming Features](#upcoming-features)

## Build & Run
If you want to run this project you would need to be on a x64 Windows system because I'm using precompiled binaries for shaderc. The plan is to replace shaderc with my own GLSL compiler, making this project entirely self-contained.

Everything is written with odin lang, a modern take on C-like low-level programming. If you want to compile and run any of the code it's quite simple to install odin and get started ([odin-lang.org](https://odin-lang.org)).

To build and run the project:<br>
`odin run "path/to/project" collection:jamgine="path/to/jamgine/repo"`<br>
To run with debug information, including vulkan layers, just append `-debug` to the command.
By default odin compiles with minimal optimization. For an optimized build simply append `-o:aggressive` or `-o:speed`. If you only want to build the project without running, it's the same deal but replace `odin run` with `odin build`.

You can tell the engine to prioritize targetting some type of GPU over another with the following command-line arguments:
```
-prefer-integrated
-prefer-discrete
-prefer-virtual
-prefer-cpu

-force-integrated
-force-discrete
-force_virtual
-force-cpu
```
`prefer` simply boosts the "score" for the respective GPU type in the GPU selection algorithm while `force` guarantees to select a GPU of that type if possible.

## Note on self-containedness
This project aims to be completely self-contained but it's not 100% so just yet.
The one glaring problem at the moment is the shaderc dependency which currently limits us to modern x64 windows systems. I will reiterate that a self-contained glsl to spirv compiler is in the works but that's not likely to be ready any time soon.
Other than that, there are dependencies on odin packages from the standard vendor library. Thanks to Odin, this is not really a big issue but the idea is to be free from these dependencies as well. Such dependencies are:
- miniaudio
- Vulkan loader
- glfw

## Points of interest
Note: Some implementation pages contain more information and showcases.
### GPU Accelerated Particle emitter

(GIF might take a while to load)

![](/repo/emitters_spawn_area.gif)
![](/repo/emitter_v1_smoke.gif)

- Implementation: https://github.com/asbott/jamgine/tree/main/gfx/particles
- Test project: https://github.com/asbott/jamgine/tree/main/projects/emitters_test

### Immediate Mode GUI
Also seen in the particle emitter showcase.
```CPP
igui.begin_window("My Window");

igui.label("Hey there", color=gfx.GREEN);

@(static)
f32_value : f32;
igui.f32_drag("Float value: ", &f32_value);

if igui.button("Unset") {
    f32_value = 0;
}

igui.end_window();
``` 
![](/repo/simple_example.gif)

- Implementation: https://github.com/asbott/jamgine/tree/main/gfx/imm/gui
- Test project: https://github.com/asbott/jamgine/tree/main/projects/imm_gui_test

### Developer console
![](/repo/console_intro.gif)

- Implementation: https://github.com/asbott/jamgine/tree/main/console
- Test project: Active in most projects

## Technical points of interest
- [Vulkan Backend](/gfx/justvk)
- GLSL [Lexer](/gfx/justvk/glsl_lexer.odin), [Parser](/gfx/justvk/glsl_parser.odin) and [Introspection](/gfx/justvk/glsl_inspect.odin)



## Some Examples
More example are found in [examples](/examples).
- [Hello Window](#hello-window)
- [Hello Triangle](#hello-triangle)
- [Hello imm](#hello-imm)
- [Hello imm_gui](#hello-imm_gui)
- [Hello Console](#hello-console)
- [Hello Everything](#hello-everything) (App configuration)
### Hello Window
Opens a window which can be closed with the escape key.
```CPP
package hello_window

import "jamgine:gfx"
import glfw "vendor:glfw"

running := true;

main :: proc() {
    gfx.init_and_open_window("Hello, Window!", width=600, height=400);

    for !gfx.should_window_close() && running {
        gfx.collect_window_events();

        // Grab the first key event if there was one such last frame
        if e := gfx.take_window_event(gfx.Window_Key_Event); e != nil {
            if e.action == glfw.PRESS && e.key == glfw.KEY_ESCAPE do running = false;
        }

        // Swap buffers, etc
        gfx.update_window();
    }

    gfx.shutdown();
}
```
![](/repo/example_hello_window.png)
### Hello Triangle
Draws a hard-coded white triangle with instanced drawing the low-level way with JustVK.
```CPP
package hellow_triangle

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
```
![](/repo/example_hello_triangle.png)

### Hello imm
Using imm, a more high-level immediate mode renderer with a straight-forward API.
```CPP
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

        gfx.update_window();
    }

    // Cleanup
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();
}
```
![](/repo/example_hello_imm.gif)

### Hello, imm_gui
```CPP
package hello_imm_gui

import "jamgine:gfx"
import "jamgine:gfx/imm"
import igui "jamgine:gfx/imm/gui"

import glfw "vendor:glfw"

import "core:log"

running := true;

main :: proc() {
    context.logger = log.create_console_logger();

    gfx.init_and_open_window("Hello, imm_gui!", width=600, height=400, enable_depth_test=true);

    // Init imm & make context. This is used in imm_gui rendering.
    imm.init();
    imm.make_and_set_context();

    igui.make_and_set_gui_context();

    last_time := glfw.GetTime();
    for !gfx.should_window_close() && running {

        now := glfw.GetTime();
        delta_seconds := f32(now - last_time);
        last_time = now;

        gfx.collect_window_events();

        // Set 2D camera (will be used in imm_gui) and clear window-
        window_size := gfx.get_window_size();
        imm.set_default_2D_camera(window_size.x, window_size.y)
        imm.begin2d();
        imm.clear_target(gfx.CORNFLOWER_BLUE);
        imm.flush();

        igui.new_frame();

        igui.begin_window("Hello, gui window");

        igui.label("Hello, label!");

        @(static)
        value : f32;
        igui.f32_drag("Hello, float widget!", &value);

        igui.end_window();
        
        igui.update(delta_seconds);
        
        igui.draw();
        
        gfx.update_window();

        // Grab the first key event if there was one such last frame
        if e := gfx.take_window_event(gfx.Window_Key_Event); e != nil {
            if e.action == glfw.PRESS && e.key == glfw.KEY_ESCAPE do running = false;
        }
    }

    // Cleanup
    igui.destroy_current_context();
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();
}
```
![](/repo/example_hello_imm_gui.gif)

### Hello Console
Integrates the developer console into the app.
```CPP
package hello_console

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:console"
import glfw "vendor:glfw"

import "core:fmt"

running := true;

main :: proc() {
    // Use the console for logging
    context.logger = console.create_console_logger();

    gfx.init_and_open_window("Hello, console!", width=600, height=400, enable_depth_test=true);

    // Init imm & make context. This is used in console  rendering.
    imm.init();
    imm.make_and_set_context();

    console.init(imm.get_current_context());

    // Bind functions directly to command names
    console.bind_command("exit", proc() {
        running = false;
    });
    console.bind_command("print_hello", proc(something : string) -> string {
        return fmt.tprintf("Hello, %s!", something);
    });

    last_time := glfw.GetTime();
    for !gfx.should_window_close() && running {

        now := glfw.GetTime();
        delta_seconds := f32(now - last_time);
        last_time = now;

        // Set 2D view & clear window
        window_size := gfx.get_window_size();
        imm.set_default_2D_camera(window_size.x, window_size.y);
        imm.begin2d();
        imm.clear_target(gfx.CORNFLOWER_BLUE);
        imm.flush();

        gfx.collect_window_events();

        // Input is handled here, so where you call this matters.
        console.update(delta_seconds);
        // For example if we want the console to handle input before
        // app handles input, we would call the app input handler after.
        // input.update();

        console.draw();
        
        gfx.update_window();

        // Grab the first key event if there was one such last frame
        if e := gfx.take_window_event(gfx.Window_Key_Event); e != nil {
            if e.action == glfw.PRESS && e.key == glfw.KEY_ESCAPE do running = false;
        }
    }

    // Cleanup
    console.shutdown();
    imm.delete_current_context();
    imm.shutdown();
    gfx.shutdown();
}
```
![](/repo/example_hello_console.gif)

### Hello Everything
Configures a jamgine app which sets up all main features for you.
```CPP
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

```
![](/repo/example_hello_everything.gif)

## Upcoming features
- Audio playback library (miniaudio backend)
- Basic 3D models (v1)
    - .obj loading
    - Mesh animation
- Basic 3D rendering techniques
    - blinn-phong, basic casters
    - PBR?
    - Shadowmapping
    - Light baking
- Asset catalougues 
    - Hot reloading
- [Emitter optimizations](/gfx/particles/README.md#todo-list)
- Demo/Showcase FPS game
- Self-contained GLSL to spv compiler
- Technical improvements
    - Fast global allocator
    - Window system win32 backend
    - WASAPI backend
    - Fallback backends glfw/miniaudio
    - Unix support