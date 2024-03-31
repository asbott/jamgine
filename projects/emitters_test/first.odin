package entity_test

import "jamgine:gfx"
import "jamgine:gfx/imm"
import jvk "jamgine:gfx/justvk"
import "jamgine:console"
import "jamgine:app"
import "jamgine:lin"
import "jamgine:utils"
import "jamgine:osext"

import "core:math"
import "core:math/rand"
import "core:fmt"
import "core:os"
import "core:time"
import "core:log"

import vk "vendor:vulkan"

main :: proc() {

    app.init_proc     = init;
    app.shutdown_proc = shutdown;
    app.sim_proc      = simulate_game;
    app.draw_proc     = draw_game;

    app.run();
}



compute_src :: `
#version 450

layout(local_size_x = MAX_COMPUTE_SIZE) in;

struct Particle {
    vec2 pos;
    float dir_angle;
    float birth_time;
    vec4 color;
    vec2 size;
};

layout(binding = 0) buffer Emitter {
    Particle particles[NUM_PARTICLES];

    vec4 start_color;
    vec4 end_color;

    vec2 size_from;
    vec2 size_to;

} emitter;

layout (binding = 1) uniform Time {
    float now;
};

float rand(float seed) {
    return fract(sin(dot(vec2(seed, seed), vec2(12.9898,78.233))) * 43758.5453);
}
float rand_range(float seed, float min, float max) {
    return min + (max-min) * rand(seed);
}

void main() {
    uint idx = gl_GlobalInvocationID.x;

    if (idx >= NUM_PARTICLES) {
        return;
    }

    Particle p = emitter.particles[idx];

    float life_time = mod(now - p.birth_time, 13);
    if (life_time <= 0) {
        return;
    }

    p.color = mix(emitter.start_color, emitter.end_color, life_time / 13);
    p.size = mix(emitter.size_from, emitter.size_to, life_time / 13);

    float angle = p.dir_angle + sin(life_time * rand(p.birth_time));

    vec2 dir = vec2(cos(angle), sin(angle));

    p.pos = dir * life_time * 50 * rand(p.birth_time);

    emitter.particles[idx] = p;
}
`;

particle_vert_src :: `

#version 450

layout (location = 0) in int a_particle_index;
layout (location = 1) in vec2 a_local_pos; // -1 to 1

struct Particle {
    vec2 pos;
    float dir_angle;
    float birth_time;
    vec4 color;
    vec2 size;
};


layout (binding = 0) uniform Camera_Transform {
    mat4 u_proj;
    mat4 u_view;
    vec2 u_viewport;
};
layout (binding = 1) uniform Emitter_Transform {
    mat4 u_model;
};
layout (binding = 2) buffer Emitter {
    Particle s_particles[NUM_PARTICLES];
};

layout (location = 0) out vec4 v_color;

void main() {

    Particle p = s_particles[a_particle_index];

    v_color = p.color;

    

    vec2 vert_pos = p.pos + a_local_pos * (p.size/2);
    gl_Position = (u_proj * u_view * u_model * vec4(vert_pos.x, vert_pos.y, 0.0, 1.0));
}

`
particle_frag_src :: `
#version 450

layout (location = 0) out vec4 o_result;

layout (location = 0) in vec4 v_color;

void main() {
    o_result = v_color;
}

`

NUM_PARTICLES :: 10000000;

Particle :: struct #align(16) {
    pos : lin.Vector2,
    dir_angle : f32,
    birth_time : f32,
    color : lin.Vector4,
    size : lin.Vector2,
}
Emitter :: struct #align(16) {
    particles : [NUM_PARTICLES]Particle,

    start_color : lin.Vector4,
    end_color : lin.Vector4,
    size_from : lin.Vector2,
    size_to : lin.Vector2,
}

Particle_Vertex :: struct {
    particle_index : i32,
    local_pos : lin.Vector2,
}


sbo : ^jvk.Storage_Buffer; // This is where the particle data will be
time_ubo : ^jvk.Uniform_Buffer; // Used for seed/life time tracking in compute shader
cs : jvk.Compute_Shader;
ctx : ^jvk.Compute_Context;
compute_sem : vk.Semaphore;

// Used in compute pipeline for simulating the particles
// and used in particles drawing pipeline to generate the
// geometry in the vertex shader
emitter_ubo : ^jvk.Uniform_Buffer;

// Pipeline & stuff for drawing the computed particles
particles_vbo : ^jvk.Vertex_Buffer;
particles_ibo : ^jvk.Index_Buffer;
camera_ubo : ^jvk.Uniform_Buffer;
particles_program : jvk.Shader_Program;
particles_pipeline : ^jvk.Pipeline;

emitter_transform : lin.Matrix4; // #Unused

init :: proc() -> bool {
    
    emitter := new(Emitter);
    defer free(emitter);
    emitter.start_color = {.01, .01, 1.2, 1.0};
    emitter.end_color = {1.0, 1.0, 1.0, 0.0};
    emitter.size_from = {0.8, 0.8};
    emitter.size_to = {3.0, 3.0};

    for _, i in emitter.particles {
        p := &emitter.particles[i];

        p.birth_time = app.elapsed_seconds;
        p.dir_angle = rand.float32_range(0, math.TAU);    
        p.birth_time = rand.float32_range(0, 13);    
    }

    sbo = jvk.make_storage_buffer(Emitter, .VRAM_WITH_CONSTANT_STAGING_BUFFER);
    jvk.set_buffer_data(sbo, emitter, size_of(Emitter));
    ok : bool;
    max_compute_size := cast(int)jvk.get_target_device_context().graphics_device.props.limits.maxComputeWorkGroupInvocations;
    assert(max_compute_size == 1024); // #Debug #Temporary
    cs, ok = jvk.compile_compute_shader(compute_src, {{"MAX_COMPUTE_SIZE", max_compute_size}, {"NUM_PARTICLES", NUM_PARTICLES}});
    assert(ok, "Failed compiling compute shader");
    ctx = jvk.make_compute_context(cs);
    compute_sem = jvk.make_semaphore(jvk.get_target_device_context());

    _float :: struct {_ : f32};
    time_ubo = jvk.make_uniform_buffer(_float, .RAM_SYNCED);

    jvk.bind_compute_storage_buffer(ctx, sbo, 0);
    jvk.bind_compute_uniform_buffer(ctx, time_ubo, 1);

    verts := make([]Particle_Vertex, NUM_PARTICLES * 4);
    indices := make([]u32, NUM_PARTICLES * 6);


    for i := 0; i < len(verts); i += 4 {
        v0 := &verts[i + 0];
        v1 := &verts[i + 1];
        v2 := &verts[i + 2];
        v3 := &verts[i + 3];

        v0.particle_index = cast(i32)i;
        v1.particle_index = cast(i32)i;
        v2.particle_index = cast(i32)i;
        v3.particle_index = cast(i32)i;

        v0.local_pos = { -1, -1 };
        v1.local_pos = { -1,  1 };
        v2.local_pos = {  1,  1 };
        v3.local_pos = {  1, -1 };

        particle_index := (i / 4) * 6;
        indices[particle_index + 0] = cast(u32)i + 0;
        indices[particle_index + 1] = cast(u32)i + 1;
        indices[particle_index + 2] = cast(u32)i + 2;
        indices[particle_index + 3] = cast(u32)i + 0;
        indices[particle_index + 4] = cast(u32)i + 2;
        indices[particle_index + 5] = cast(u32)i + 3;
    }

    particles_vbo = jvk.make_vertex_buffer(verts, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    particles_ibo = jvk.make_index_buffer(indices, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    camera_ubo = jvk.make_uniform_buffer(imm.Camera, .VRAM_WITH_CONSTANT_STAGING_BUFFER);
    emitter_ubo = jvk.make_uniform_buffer(lin.Matrix4, .VRAM_WITH_CONSTANT_STAGING_BUFFER);
    

    particles_program, ok = jvk.make_shader_program(particle_vert_src, particle_frag_src, constants={{"NUM_PARTICLES", NUM_PARTICLES}});
    assert(ok, "Failed compiling program");
    particles_pipeline = jvk.make_pipeline(particles_program, gfx.window_surface.render_pass);

    jvk.bind_uniform_buffer(particles_pipeline, camera_ubo, 0);
    jvk.bind_uniform_buffer(particles_pipeline, emitter_ubo, 1);
    jvk.bind_storage_buffer(particles_pipeline, sbo, 2);

    window_size := gfx.get_window_size();

    emitter_transform = lin.identity(lin.Matrix4) * lin.translate({window_size.x/2, window_size.y/2, 0});
    
    imm.set_default_2D_camera(window_size.x, window_size.y);
    cam := imm.get_current_context().camera;
    cam.view = lin.inverse(cam.view);
    jvk.set_buffer_data(camera_ubo, &cam, size_of(cam)); // This syncs with transfer queue
    jvk.set_buffer_data(emitter_ubo, &emitter_transform, size_of(emitter_transform)); // This syncs with transfer queue

    return true;
}
shutdown :: proc() -> bool {

    jvk.destroy_uniform_buffer(time_ubo);
    jvk.destroy_uniform_buffer(camera_ubo);
    jvk.destroy_uniform_buffer(emitter_ubo);
    jvk.destroy_pipeline(particles_pipeline);
    jvk.destroy_shader_program(particles_program);
    jvk.destroy_index_buffer(particles_ibo);
    jvk.destroy_vertex_buffer(particles_vbo);
    jvk.destroy_semaphore(compute_sem, jvk.get_target_device_context());
    jvk.destroy_compute_context(ctx);
    jvk.destroy_compute_shader(cs);
    jvk.destroy_storage_buffer(sbo);

    return true;
}

simulate_game :: proc() -> bool {
    
    return true;
}

draw_game :: proc() -> bool {

    // This buffer is stored in RAM so this is jsut an instant set
    jvk.set_buffer_data(time_ubo, &app.elapsed_seconds, size_of(f32)); 
    
    jvk.do_compute(ctx, NUM_PARTICLES, signal_sem=compute_sem);

    window_size := gfx.get_window_size();

    jvk.begin_draw_surface(particles_pipeline, gfx.window_surface);

        jvk.cmd_clear(particles_pipeline, clear_color={.05, .05, .1, 1.0});

        jvk.cmd_draw_indexed(particles_pipeline, particles_vbo, particles_ibo);

    jvk.end_draw(particles_pipeline, wait_sem=compute_sem); // This syncs with graphics queue

    return true;
}
