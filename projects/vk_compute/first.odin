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
import "core:fmt"
import "core:os"
import "core:time"
import "core:log"

main :: proc() {

    app.init_proc     = init;
    app.shutdown_proc = shutdown;
    app.sim_proc      = simulate_game;
    app.draw_proc     = draw_game;

    app.run();
}

N :: 512;
Compute_Data :: struct {
    values : [N * N * N]i32,
}

sbo : ^jvk.Storage_Buffer;
cs : jvk.Compute_Shader;
ctx : ^jvk.Compute_Context;

compute_src :: `
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(binding = 0) buffer Compute_Data {
    int values[N];
};

void main() {
    uint idx = gl_GlobalInvocationID.x + DIM * (gl_GlobalInvocationID.y + DIM * gl_GlobalInvocationID.z);

    values[idx] += int(idx);
}

`;

init :: proc() -> bool {
    
    

    data := new(Compute_Data);
    sbo = jvk.make_storage_buffer(Compute_Data, .VRAM_WITH_CONSTANT_STAGING_BUFFER);
    jvk.set_buffer_data(sbo, data, size_of(Compute_Data));
    ok : bool;
    cs, ok = jvk.compile_compute_shader(compute_src, {{"N", N*N*N}, {"DIM", N}});
    assert(ok, "Failed compiling compute shader");
    ctx = jvk.make_compute_context(cs);

    jvk.bind_compute_storage_buffer(ctx, sbo, 0);
    
    //fmt.println("Data before compute: ");
    //for i in data.values {
    //    fmt.println(i);
    //}

    total := N * N * N;
    fmt.println("Doing", total, "writes");

    sw : time.Stopwatch;

    time.stopwatch_start(&sw);
    jvk.do_compute(ctx, N, N, N);
    jvk.wait_compute_done(ctx);
    compute_duration := time.stopwatch_duration(sw);

    time.stopwatch_reset(&sw);
    time.stopwatch_start(&sw);
    jvk.read_buffer_data(sbo, data);
    read_duration := time.stopwatch_duration(sw);

    time.stopwatch_reset(&sw);
    time.stopwatch_start(&sw);
    for i in 0..<N*N*N {
        data.values[i] = cast(i32)i;
    }
    cpu_duration := time.stopwatch_duration(sw);
    
    compute_ms := time.duration_milliseconds(compute_duration);
    read_ms := time.duration_milliseconds(read_duration);
    cpu_ms := time.duration_milliseconds(cpu_duration); 

    log.infof("Compute call took %fms", compute_ms);
    log.infof("Readback took %fms", read_ms);
    log.infof("Total %fms", read_ms + compute_ms);
    log.infof("CPU write took %fms", cpu_ms);
    
    //fmt.println("Data after compute: ");
    //for i in data.values {
    //    fmt.println(i);
    //}
    
    return true;
}
shutdown :: proc() -> bool {

    jvk.destroy_compute_context(ctx);
    jvk.destroy_compute_shader(cs);
    jvk.destroy_storage_buffer(sbo);

    return true;
}

simulate_game :: proc() -> bool {

    return true;
}

draw_game :: proc() -> bool {

    imm.set_render_target(gfx.window_surface);
    imm.begin2d();
    imm.clear_target({0.2, 0.2, 0.3, 1.0});
    imm.rectangle({-100, -100, 0}, {1, 1});
    imm.flush();

    return true;
}
