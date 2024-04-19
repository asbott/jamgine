package particles;

import "jamgine:lin"
import "jamgine:gfx"
import jvk "jamgine:gfx/justvk"

import "core:fmt"
import "core:log"
import "core:time"
import "core:reflect"
import "core:math"
import "core:c"
import "core:math/rand"
import "core:intrinsics"
import "core:builtin"

// ! STD140 !
Particle :: struct #align(16) {
    using _ : struct #align(16) { pos : lin.Vector3 },
    using _ : struct #align(16) { color : lin.Vector4 },
    using _ : struct #align(16) { size : lin.Vector3 },
    using _ : struct #align(16) { rotation : lin.Vector3 },
}
Particle_Vertex :: struct {
    particle_index : i32,
    local_pos : lin.Vector3,
}
Property_Kind :: enum i32 {
    CONSTANT,
    RANDOM,
    INTERPOLATE,
}
Interp_Kind :: enum i32 {
    LINEAR,
    SMOOTH,
}
Random_Distribution :: enum i32 {
    UNIFORM, NORMAL, EXTREMES, NEG_LOGX,
    X_SQUARED, X_CUBED, X_FOURTH, X_FIFTH,
    INV_X_SQUARED, INV_X_CUBED, INV_X_FOURTH, INV_X_FIFTH,
    TWO_DICE, THREE_DICE, FOUR_DICE,
    TWO_DICE_SQUARED, THREE_DICE_SQUARED, FOUR_DICE_SQUARED,
    OSCILLATE1, OSCILLATE2, OSCILLATE3, OSCILLATE4,
}
Scalar_Or_Component :: enum i32 {
    COMPONENT,
    SCALAR,
}
Particle_Kind :: enum i32 {
    RECTANGLE,
    CIRCLE,
    TRIANGLE,
    TEXTURE,
    SPHERE,
    CUBE,
}
 

// These property structs technically don't need to be std140 compliant,
// but it makes things much simpler if we explicitly align and pad to
// std140 both here and in glsl.

Particle_Property_Base :: struct #packed {
    kind : Property_Kind,
    distribution : Random_Distribution,
    interp_kind : Interp_Kind,
    seed : f32,
    scalar_or_component_rand : Scalar_Or_Component,
    using _soft_lock_rand_range : struct #align(4) { soft_lock_rand_range : bool },
    _ : [8]byte,
}
Particle_Property_F32 :: struct {
    using base : Particle_Property_Base,
    value1 : f32,
    value2 : f32,

    _ : [8]byte,
}
Particle_Property_Vec2 :: struct {
    using base : Particle_Property_Base,
    value1 : lin.Vector2,
    value2 : lin.Vector2,
}
Particle_Property_Vec3 :: struct {
    using base : Particle_Property_Base,
    value1 : lin.Vector3,
    _ : [4]byte,
    value2 : lin.Vector3,
    _ : [4]byte,
}
Particle_Property_Vec4 :: struct {
    using base : Particle_Property_Base,
    value1 : lin.Vector4,
    value2 : lin.Vector4,
}

// This is the part that's reflected in the ssbo
Emitter_Config :: struct {
    // 16-byte block!!
    emission_rate : f32,
    _ : [4]byte,
    seed : f32,
    particle_kind : Particle_Kind,
    // !!

    // 16-byte block!!
    random_map_size : lin.Vector2i,
    using _should_only_2D  : struct #align(4) { should_only_2D : bool },
    using _should_loop : struct #align(4) { should_loop : bool },
    // !!

    // Need unique names to be serialized correctly
    size     : Particle_Property_Vec3,
    color : Particle_Property_Vec4,
    position : Particle_Property_Vec3,
    velocity : Particle_Property_Vec3,
    acceleration : Particle_Property_Vec3,
    angular_velocity : Particle_Property_Vec2,
    angular_acceleration : Particle_Property_Vec2,
    rotation : Particle_Property_Vec3,
    lifetime : Particle_Property_F32,

    model : lin.Matrix4,
}


Emitter_State :: enum {
    PAUSED,
    RUNNING,
}

Emitter :: struct {
    using config : Emitter_Config,

    max_particles : int,
    compiled_max_particles : int,
    compiled_max_emission_time : f32,

    enable_depth_test : bool,
    enable_depth_write : bool,
    
    state : Emitter_State,
    sw : time.Stopwatch,

    using noserialize : struct {
        compute_context : ^jvk.Compute_Context,
        emitter_ubo : ^jvk.Uniform_Buffer,
        particles_sbo : ^jvk.Storage_Buffer,
        random_texture : jvk.Texture,
    
        draw_vbo : ^jvk.Vertex_Buffer,
        draw_ibo : ^jvk.Index_Buffer,
        draw_pipeline : ^jvk.Pipeline,
        particle_texture : jvk.Texture,
        is_compiled : bool,
    }
    
}

rand_seed :: proc() -> f32 {
    return rand.float32_range(-1000000, 1000000);
}

init_emitter_config :: proc(e : ^Emitter) {   

    e.config.seed = rand_seed();
    e.velocity.seed = rand_seed();
    e.acceleration.seed = rand_seed();
    e.angular_velocity.seed = rand_seed();
    e.angular_acceleration.seed = rand_seed();
    e.rotation.seed = rand_seed();
    e.lifetime.seed = rand_seed();
    e.color.seed = rand_seed();
    e.size.seed = rand_seed();
    e.position.seed = rand_seed();


    e.model = lin.identity(lin.Matrix4);
    e.config.emission_rate = 50000;
    e.enable_depth_test = true;
    e.enable_depth_write = true;

    e.config.size.base.kind = .CONSTANT;
    e.config.size.value1 = {0.1, 0.1, 0.1};
    e.config.size.value2 = {.2, .2, .2};

    e.config.velocity.base.kind = .RANDOM;
    e.config.velocity.base.distribution = .UNIFORM;
    e.config.velocity.value1 = {-1, -1, -1};
    e.config.velocity.value2 = {1, 1, 1};

    e.config.lifetime.base.kind = .CONSTANT;
    e.config.lifetime.value1 = 3;
    e.config.lifetime.value2 = 4;

    e.config.color.base.kind = .INTERPOLATE;
    e.config.color.value1 = {.3, .3, .8, 1.0};
    e.config.color.value2 = {1, 1, 1, 1};
}

start_emitter :: proc(e : ^Emitter) {
    time.stopwatch_start(&e.sw);
    e.state = Emitter_State.RUNNING;
}
pause_emitter :: proc(e : ^Emitter) {
    time.stopwatch_stop(&e.sw);
    e.state = Emitter_State.PAUSED;
}
reset_emitter :: proc(e : ^Emitter) {
    time.stopwatch_reset(&e.sw);

    if e.state == .RUNNING do time.stopwatch_start(&e.sw);
}
get_emitter_time :: proc(e : ^Emitter) -> f64 {
    return time.duration_seconds(time.stopwatch_duration(e.sw));
}

compile_emitter :: proc(e : ^Emitter) -> bool {

    if e.max_particles <= 0 {
        log.error("Emitter compilation error: max_particles must be > 0");
        return false;
    }
    if e.emission_rate <= 0 {
        log.error("Emitter compilation error: emission_rate must be > 0");
        return false;
    }

    e.compiled_max_particles = e.max_particles;

    time_when_last_particle_is_emitted := f32(e.max_particles) / f32(e.config.emission_rate);
    
    e.compiled_max_emission_time = time_when_last_particle_is_emitted;

    if e.is_compiled {
        jvk.destroy_texture(e.random_texture);
        jvk.destroy_vertex_buffer(e.draw_vbo);
        jvk.destroy_index_buffer(e.draw_ibo);
        jvk.destroy_pipeline(e.draw_pipeline);
        jvk.destroy_shader_program(e.draw_pipeline.program);
        jvk.destroy_storage_buffer(e.particles_sbo);
        jvk.destroy_compute_shader(e.compute_context.shader);
        jvk.destroy_compute_context(e.compute_context);
    }

    shader_constants := make([dynamic]jvk.Shader_Constant);

    for name, i in reflect.enum_field_names(Property_Kind) {
        value := reflect.enum_field_values(Property_Kind)[i];
        fmt.println(name, value);
        append(&shader_constants, jvk.Shader_Constant{name, cast(int)value});
    }
    for name, i in reflect.enum_field_names(Interp_Kind) {
        value := reflect.enum_field_values(Interp_Kind)[i];
        append(&shader_constants, jvk.Shader_Constant{name, cast(int)value});
    }
    for name, i in reflect.enum_field_names(Random_Distribution) {
        value := reflect.enum_field_values(Random_Distribution)[i];
        append(&shader_constants, jvk.Shader_Constant{name, cast(int)value});
    }
    for name, i in reflect.enum_field_names(Particle_Kind) {
        value := reflect.enum_field_values(Particle_Kind)[i];
        append(&shader_constants, jvk.Shader_Constant{name, cast(int)value});
    }
    for name, i in reflect.enum_field_names(Scalar_Or_Component) {
        value := reflect.enum_field_values(Scalar_Or_Component)[i];
        append(&shader_constants, jvk.Shader_Constant{name, cast(int)value});
    }
    append(&shader_constants, jvk.Shader_Constant{"NUM_PARTICLES", e.max_particles});
    max_compute_size := cast(int)jvk.get_target_device_context().graphics_device.props.limits.maxComputeWorkGroupInvocations;
    append(&shader_constants, jvk.Shader_Constant{"MAX_COMPUTE_SIZE", max_compute_size});

    //
    // Compute resources

    compute_src := fmt.tprint(particle_src_types, particle_compute_src);

    cs, ok := jvk.compile_compute_shader(compute_src, constants=shader_constants[:]);
    assert(ok, "Failed compiling emitter compute shader");

    e.compute_context = jvk.make_compute_context(cs);
    
    e.particles_sbo = jvk.make_storage_buffer(size_of(Particle) * e.max_particles, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    
    side := max(cast(int)math.ceil(math.sqrt(f32(e.max_particles))), 1024);
    // align to next power of 2
    side = int(1 << cast(uint)math.ceil(math.log2(f32(side))));

    random_data := make([]f32, side * side * 4);
    defer delete(random_data);
    for _, i in random_data {
        random_data[i] = cast(f32)rand.float64();
    }

    sampler := jvk.DEFAULT_SAMPLER_SETTINGS;
    sampler.min_filter = .NEAREST;
    sampler.mag_filter = .NEAREST;
    // #Memory #Videomem
    e.random_texture = jvk.make_texture(side, side, builtin.raw_data(random_data), .R_HDR, {.SAMPLE, .WRITE}, sampler);

    e.random_map_size = {cast(i32)side, cast(i32)side};

    if !e.is_compiled {
        // #Speed
        // In some cases we may want to update the emitter config every frame, in
        // which case we should store the UBO with .RAM_SYNCED.
        e.emitter_ubo = jvk.make_uniform_buffer(Emitter_Config, .VRAM_WITH_CONSTANT_STAGING_BUFFER);
    }
    
    jvk.bind_compute_uniform_buffer(e.compute_context, e.emitter_ubo, 0);
    jvk.bind_compute_storage_buffer(e.compute_context, e.particles_sbo, 1);
    jvk.bind_compute_texture(e.compute_context, e.random_texture, 2);
    
    jvk.set_buffer_data(e.emitter_ubo, &e.config, size_of(Emitter_Config));

    //
    // Draw resources

    vert_src := fmt.tprint(particle_src_types, particle_vert_src);
    frag_src := fmt.tprint(particle_src_types, particle_frag_src);

    draw_program, draw_ok := jvk.make_shader_program(vert_src, frag_src, constants=shader_constants[:]);
    assert(draw_ok, "Failed compiling emitter draw program");
    e.draw_pipeline = jvk.make_pipeline(draw_program, gfx.window_surface.render_pass, enable_depth_test=(e.enable_depth_test || e.enable_depth_write));
    
    verts := make([]Particle_Vertex, e.max_particles * 4);
    indices := make([]u32, e.max_particles * 6);


    for i := 0; i < len(verts); i += 4 {
        v0 := &verts[i + 0];
        v1 := &verts[i + 1];
        v2 := &verts[i + 2];
        v3 := &verts[i + 3];

        v0.particle_index = cast(i32)i;
        v1.particle_index = cast(i32)i;
        v2.particle_index = cast(i32)i;
        v3.particle_index = cast(i32)i;

        v0.local_pos = { -1, -1, 0 };
        v1.local_pos = { -1,  1, 0 };
        v2.local_pos = {  1,  1, 0 };
        v3.local_pos = {  1, -1, 0 };

        particle_index := (i / 4) * 6;
        indices[particle_index + 0] = cast(u32)i + 0;
        indices[particle_index + 1] = cast(u32)i + 1;
        indices[particle_index + 2] = cast(u32)i + 2;
        indices[particle_index + 3] = cast(u32)i + 0;
        indices[particle_index + 4] = cast(u32)i + 2;
        indices[particle_index + 5] = cast(u32)i + 3;
    }

    e.draw_vbo = jvk.make_vertex_buffer(verts, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);
    e.draw_ibo = jvk.make_index_buffer(indices, .VRAM_WITH_IMPROVISED_STAGING_BUFFER);

    jvk.set_buffer_data(e.draw_vbo, builtin.raw_data(verts), size_of(Particle_Vertex) * len(verts));
    jvk.set_buffer_data(e.draw_ibo, builtin.raw_data(indices), size_of(u32) * len(indices));

    jvk.bind_storage_buffer(e.draw_pipeline, e.particles_sbo, 0);
    jvk.bind_uniform_buffer(e.draw_pipeline, e.emitter_ubo, 1);

    if e.particle_texture.vk_image != 0 {
        jvk.bind_texture(e.draw_pipeline, e.particle_texture, 2);
    }

    e.is_compiled = true;

    return true;
}

destroy_emitter :: proc(e : ^Emitter) {
    if e.is_compiled {
        jvk.destroy_texture(e.random_texture);
        jvk.destroy_vertex_buffer(e.draw_vbo);
        jvk.destroy_index_buffer(e.draw_ibo);
        jvk.destroy_pipeline(e.draw_pipeline);
        jvk.destroy_shader_program(e.draw_pipeline.program);
        jvk.destroy_storage_buffer(e.particles_sbo);
        jvk.destroy_uniform_buffer(e.emitter_ubo);
        jvk.destroy_compute_shader(e.compute_context.shader);
        jvk.destroy_compute_context(e.compute_context);
    }
    e.is_compiled = false;
}

update_emitter_config :: proc(e : ^Emitter) {
    assert(e.is_compiled, "Emitter must be compiled before updating config, but it wasn't.");
    jvk.set_buffer_data(e.emitter_ubo, &e.config, size_of(Emitter_Config));
}

simulate_emitter :: proc(e : ^Emitter) {
    assert(e.is_compiled, "Emitter must be compiled before simulation, but it wasn't.");
    now := cast(f32)get_emitter_time(e);
    state := struct {now : f32} {now};

    jvk.do_compute(e.compute_context, e.compiled_max_particles, push_constant=&state);

    // #Speed
    // We could signal a semaphore in the emitter and wait for it when doing
    // the draw call, but that would require use to make one draw call per
    // simulation step. So we could just pass an optional semaphore and default
    // to waiting here if no semaphore is passed, thus leaving the synchronization
    // responsibility to the caller.
    jvk.wait_compute_done(e.compute_context);
}

draw_emitter_to_window :: proc(e : ^Emitter, proj, view : lin.Matrix4) {
    // #Speed
    if e.particle_texture.vk_image != 0 {
        jvk.bind_texture(e.draw_pipeline, e.particle_texture, 2);
    }
    jvk.begin_draw_surface(e.draw_pipeline, gfx.window_surface, write_depth=e.enable_depth_write, test_depth=e.enable_depth_test);

    cmd_draw_emitter(e, proj, view);

    jvk.end_draw(e.draw_pipeline);
}
draw_emitter_to_target :: proc(e : ^Emitter, target : jvk.Render_Target, proj, view : lin.Matrix4) {
    // #Speed
    if e.particle_texture.vk_image != 0 {
        jvk.bind_texture(e.draw_pipeline, e.particle_texture, 2);
    }
    jvk.begin_draw(e.draw_pipeline, target, write_depth=e.enable_depth_write, test_depth=e.enable_depth_test);

    cmd_draw_emitter(e, proj, view);

    jvk.end_draw(e.draw_pipeline);
}
draw_emitter :: proc {
    draw_emitter_to_target,
    draw_emitter_to_window,
}

@(private)
cmd_draw_emitter :: proc(e : ^Emitter, proj, view : lin.Matrix4) {
    //jvk.cmd_clear(particles_pipeline, clear_color={.05, .05, .1, 1.0});

    Transform_Push_Constant :: struct {
        proj : lin.Matrix4,
        view : lin.Matrix4,
    }
    ps : Transform_Push_Constant;
    ps.proj = proj;
    ps.view = view;

    jvk.cmd_set_push_constant(e.draw_pipeline, &ps, 0, size_of(Transform_Push_Constant));

    jvk.cmd_draw_indexed(e.draw_pipeline, e.draw_vbo, e.draw_ibo);
}

set_particle_texture :: proc(e : ^Emitter, texture : jvk.Texture) {
    e.particle_texture = texture;
    jvk.bind_texture(e.draw_pipeline, texture, 2);
}