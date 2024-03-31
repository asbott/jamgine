package justvk

import "core:fmt"
import "core:log"
import "core:os"
import "core:c"
import "core:math"
import "core:time"
import "core:mem"


import "vendor:glfw"
import stb "vendor:stb/image"

import "jamgine:lin"
import img "jamgine:image_loader"

// #Temporary
import "core:sys/windows"
foreign import gdi32 "system:gdi32.lib"
foreign gdi32 {
	SetDIBitsToDevice :: proc "stdcall" (
         hdc : windows.HDC             ,
         xDest : c.int             ,
         yDest : c.int             ,
         w : windows.DWORD           ,
         h : windows.DWORD           ,
         xSrc : c.int             ,
         ySrc : c.int             ,
         StartScan : windows.UINT            ,
         cLines : windows.UINT            ,
         lpvBits : rawptr      ,
         lpbmi : ^windows.BITMAPINFO,
         ColorUse : windows.UINT            ,
    ) -> c.int ---
}

WINDOW_WIDTH :: 400;
WINDOW_HEIGHT :: 400;

delta_seconds : f32;

main :: proc() {
    fmt.println("Program started");

    context.logger = log.create_console_logger();

    if !glfw.Init() {
        fmt.println("Failed to initialize glfw");
        os.exit(-1);
    }
    
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API);
    glfw_window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Vulkan", nil, nil);

    init();
    dc := make_device_context();
    set_target_device_context(dc);

    test_texture_write_draw_read();

    

    vert_src := `
        #version 450

        // IN
        layout (location = 0) in vec3 a_pos;
        layout (location = 1) in vec2 a_uv;

        // OUT
        layout (location = 0) out vec2 v_uv;

        layout (binding = 0) uniform Camera {
            mat4 proj;
            mat4 view;
        };

        layout (push_constant) uniform Transform {
            mat4 model;
        };
        

        void main() {
            gl_Position = proj * view * model  * vec4(a_pos, 1.0);
            v_uv = a_uv;
        }
    `

    frag_src := `
        #version 450


        // OUT
        layout(location = 0) out vec4 o_color;

        // INT
        layout(location = 0) in vec2 v_uv;

        // UNIFORMS
        layout(binding = 1) uniform sampler2D u_Texture;

        void main() {
            vec4 texture_color = texture(u_Texture, v_uv);
            o_color = texture_color;
        }
    `

    Vertex :: struct {
        pos : lin.Vector3,
        uv : lin.Vector2,
    }
    vertices := []Vertex{
        {{-50.00, -50.00, 0}, {0, 0}},
        {{-50.00,  50.00, 0}, {0, 1}},
        {{ 50.00,  50.00, 0}, {1, 1}},
        {{ 50.00, -50.00, 0}, {1, 0}},
    };
    indices := []u32 {
        0, 1, 2,
        0, 2, 3,
    }
    color : struct {
        color : lin.Vector4,
    }
    camera : struct {
        proj, view : lin.Matrix4,
    }
    transform : struct {
        model : lin.Matrix4,
    }
    color.color = {1.0, 1.0, 1.0, 1.0};

    test_pixels, w, h, c, img_ok := img.decode_image_file_to_srgb_f32("test.png", 4);

    assert(img_ok, "Failed loading image");

    surface := make_draw_surface(glfw_window);
    
    program, ok := make_shader_program(vert_src, frag_src);
    if !ok do panic("Failed compiling shader");
    //if true do os.exit(1);

    pipeline := make_pipeline(program, surface.render_pass);

    sprite_texture := make_texture(cast(int)w, cast(int)h, slice_to_multi_ptr(test_pixels), .RGBA_HDR, {.SAMPLE, .WRITE});
    vbo := make_vertex_buffer(vertices, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    ibo := make_index_buffer(indices, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    camera_ubo := make_uniform_buffer(type_of(camera), .VRAM_WITH_CONSTANT_STAGING_BUFFER);


    
    bind_uniform_buffer(pipeline, camera_ubo, 0);
    bind_texture(pipeline, sprite_texture, 1);
    
    camera.proj = lin.ortho(-200, 200, -200, 200, 0.1, 10.0);
    camera.view = lin.translate({0, 0, 1});
    camera.view = lin.inverse(camera.view);
    set_buffer_data(camera_ubo, &camera, size_of(camera));


    last_time : f64;
    for (!glfw.WindowShouldClose(glfw_window)) {
        
        free_all(context.temp_allocator);

        now := glfw.GetTime();
        delta_seconds = f32(now - last_time);
        last_time = glfw.GetTime();
        glfw.PollEvents();
        x := math.sin_f32(cast(f32)now);
        
        if glfw.GetKey(glfw_window, glfw.KEY_F) == glfw.PRESS {
            fmt.printf("%-10f FPS / %fms\n", 1.0 / delta_seconds, delta_seconds * 1000.0);
        }
        
        
        {
            transform.model = lin.translate({x * 50.0, 0, 0});
            //set_buffer_data(ubo_transform, &transform, size_of(transform));
        
            begin_draw_surface(pipeline, surface);

            cmd_clear(pipeline, {.COLOR}, {0.0, 0.0, 1.0, 1.0});
            cmd_set_push_constant(pipeline, &transform, 0, size_of(transform));
            cmd_draw_indexed(pipeline, vbo, ibo);

            end_draw(pipeline);
        }
        {
            transform.model = lin.translate({x * -50.0, 0, 0});
            //set_buffer_data(ubo_transform, &transform, size_of(transform));
        
            begin_draw_surface(pipeline, surface);

            cmd_set_push_constant(pipeline, &transform, 0, size_of(transform));
            cmd_draw_indexed(pipeline, vbo, ibo);

            end_draw(pipeline);
        }

        present_surface(surface);
    }

    
    destroy_uniform_buffer(camera_ubo);
    destroy_index_buffer(ibo);
    destroy_vertex_buffer(vbo);
    destroy_texture(sprite_texture);
    destroy_draw_surface(surface);
    destroy_pipeline(pipeline);
    destroy_shader_program(program);
    destroy_device_context(dc);

    shutdown();

    glfw.DestroyWindow(glfw_window);
    glfw.Terminate();

    fmt.println("Program exited normally");
}

test_texture_write_draw_read :: proc() {
    vert_src := `
        #version 450

        // IN
        layout (location = 0) in vec3 a_pos;
        layout (location = 1) in vec2 a_uv;

        // OUT
        layout (location = 0) out vec2 v_uv;

        void main() {
            gl_Position = vec4(a_pos, 1.0);
            v_uv = a_uv;
        }
    `

    frag_src := `
        #version 450

        // OUT
        layout(location = 0) out vec4 o_color;

        // INT
        layout(location = 0) in vec2 v_uv;

        // UNIFORMS
        layout(binding = 0) uniform Color {
            vec4 color;
        };
        layout(binding = 1) uniform sampler2D u_Texture;

        void main() {
            o_color = color * texture(u_Texture, v_uv);
        }
    `

    Vertex :: struct {
        pos : lin.Vector3,
        uv : lin.Vector2,
    }
    vertices := []Vertex{
        {{-.5, -.5, 0}, {0, 0}},
        {{-.5,  .5, 0}, {0, 1}},
        {{ .5,  .5, 0}, {1, 1}},
        {{ .5, -.5, 0}, {1, 0}},
    };
    indices := []u32 {
        0, 1, 2,
        0, 2, 3,
    }
    color : struct {
        color : lin.Vector4,
    }
    color.color = {0.0, 1.0, 0.0, 1.0};

    test_pixels, w, h, c, img_ok := img.decode_image_file_to_srgb_f32("test.png", 4);
    assert(w == 400 && h == 400);

    
    program, ok := make_shader_program(vert_src, frag_src);
    if !ok do panic("Failed compiling shader");

    target_texture := make_texture(400, 400, nil, .RGBA_HDR, {.WRITE, .SAMPLE, .DRAW, .READ});
    render_target := make_texture_render_target(target_texture);
    render_target_pipeline := make_pipeline(program, render_target.render_pass);
    sprite_texture := make_texture(cast(int)w, cast(int)h, slice_to_multi_ptr(test_pixels), .RGBA_HDR, {.SAMPLE, .WRITE});
    vbo := make_vertex_buffer(vertices, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    ibo := make_index_buffer(indices, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    ubo := make_uniform_buffer(type_of(color), .VRAM_WITH_CONSTANT_STAGING_BUFFER);


    defer destroy_uniform_buffer(ubo);
    defer destroy_index_buffer(ibo);
    defer destroy_vertex_buffer(vbo);
    defer destroy_pipeline(render_target_pipeline);
    defer destroy_render_target(render_target);
    defer destroy_texture(sprite_texture);
    defer destroy_texture(target_texture);
    defer destroy_shader_program(program);

    set_buffer_data(ubo, &color, size_of(color));
    
    bind_uniform_buffer(render_target_pipeline, ubo, 0);
    bind_texture(render_target_pipeline, sprite_texture, 1);
    
    
    write_texture(target_texture, slice_to_multi_ptr(test_pixels), 0, 0, cast(int)w, cast(int)h);
    
    total_sw : time.Stopwatch;
    time.stopwatch_start(&total_sw);

    draw_sw : time.Stopwatch;
    time.stopwatch_start(&draw_sw);

    begin_draw(render_target_pipeline, render_target);
    cmd_draw_indexed(render_target_pipeline, vbo, ibo);
    end_draw(render_target_pipeline);


    time.stopwatch_stop(&draw_sw);

    read_sw : time.Stopwatch;
    time.stopwatch_start(&read_sw);
    hdr_components := make([]f32, 400 * 400 * 4);
    read_texture(target_texture, 0, 0, 400, 400, slice_to_multi_ptr(hdr_components));
    time.stopwatch_stop(&read_sw);

    conv_sw : time.Stopwatch;
    time.stopwatch_start(&conv_sw);
    ldr_components := make([]byte, len(hdr_components));
    for p, i in hdr_components {
        // Clamp values to [0, 1] range
        val := min(1.0, max(0.0, hdr_components[i]));
        ldr_components[i] = cast(byte)(255.0 * val);
    }
    time.stopwatch_stop(&conv_sw);
    
    write_sw : time.Stopwatch;
    time.stopwatch_start(&write_sw);
    result := stb.write_png("test_pixels.png", 400, 400, 4, slice_to_multi_ptr(ldr_components), 400 * 4);
    assert(result == 1, "Failed writing image");
    result = stb.write_hdr("test_pixels.hdr", 400, 400, 4, slice_to_multi_ptr(hdr_components));
    assert(result == 1, "Failed writing image");
    time.stopwatch_stop(&write_sw);

    time.stopwatch_stop(&total_sw);

    log_time :: proc(sw : time.Stopwatch, name : string) {
        log.debugf("%s took %fms", name, time.duration_milliseconds(time.stopwatch_duration(sw)));
    }

    log_time(draw_sw, "Drawing");
    log_time(read_sw, "Reading");
    log_time(conv_sw, "Converting");
    log_time(write_sw, "Writing");
    log_time(total_sw, "Total");
}