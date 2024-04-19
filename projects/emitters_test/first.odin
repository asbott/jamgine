package imm_gui_test

import "jamgine:gfx"
import "jamgine:input"
import "jamgine:gfx/imm"
import "jamgine:console"
import "jamgine:app"
import "jamgine:entities"
import "jamgine:lin"
import "jamgine:utils"
import "jamgine:serial"
import img "jamgine:image_loader"
import jvk "jamgine:gfx/justvk"
import igui "jamgine:gfx/imm/gui"
import pfx "jamgine:gfx/particles"

import "core:time"
import "core:os"
import "core:math"
import "core:math/rand"
import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:builtin"
import "core:math/linalg"

import "vendor:glfw"

FOV :: 60.0;
MIN_CLIP :: 0.1;

main :: proc() {

    app.init_proc     = init;
    app.shutdown_proc = shutdown;
    app.sim_proc      = simulate_game;
    app.draw_proc     = draw_game;
    app.config.enable_depth_test = true;
    app.config.do_serialize_config = true;

    app.run();
}

Gui_Window_Binding :: struct {
    name : string,
    show : bool,
    show_proc : proc(^Gui_Window_Binding),
    ud : rawptr,
    want_center : bool,
}

Camera_Kind :: enum {
    ORBIT_3D,
    PANNING_2D,
}

scene : struct {
    emitter : pfx.Emitter,
    orbit : lin.Vector2,
    pan : lin.Vector2,
    cam_distance : f32,
    camera_kind : Camera_Kind,
    current_texture_path : string,
    clear_color : lin.Vector4,
    do_draw_gizmos : bool,
    using noserialize : struct {
        gui_windows : []Gui_Window_Binding,
    }
}
current_particle_texture : jvk.Texture;

init :: proc() -> bool {
    using scene;
    emitter.max_particles = 150000;

    clear_color = {0.1, 0.1, 0.1, 1.0};

    pfx.init_emitter_config(&emitter);

    emitter.seed = rand.float32_range(-2000, 2000);

    orbit = 0;
    cam_distance = 10;

    serial.bind_struct_data_to_file(&scene, "emitter_test_scene.json", .WRITE_CHANGES_TO_DISK);

    pfx.compile_emitter(&emitter);

    if os.exists(current_texture_path) {
        load_particle_texture_from_path(current_texture_path);
    }

    gui_windows = slice.clone([]Gui_Window_Binding{
        {"Scene", true, do_scene_window, nil, false},
        {"Emitter", true, do_emitter_window, nil, false},
    });

    return true;
}
shutdown :: proc() -> bool {
    using scene;
    pfx.destroy_emitter(&emitter);

    if current_particle_texture.vk_image != 0 {
        jvk.destroy_texture(current_particle_texture);
    }

    delete(gui_windows);

    return true;
}

simulate_game :: proc() -> bool {
    using scene;
    if emitter.is_compiled {
        pfx.simulate_emitter(&emitter)
    }
    
    mouse_delta := input.get_mouse_move();

    mouse_down := input.is_mouse_down(glfw.MOUSE_BUTTON_LEFT);

    window_size := gfx.get_window_size();

    for e in gfx.window_events {
        if e.handled do continue;
        #partial switch event in e.variant {
            case gfx.Window_Scroll_Event: {
                cam_distance -= event.yscroll * (cam_distance / 10);
            }
            case gfx.Window_Mouse_Move_Event: {
                if mouse_down {
                    switch camera_kind {
                        case .PANNING_2D: {
                            mouse_delta_factor := lin.Vector2{
                                (mouse_delta.x / window_size.x), 
                                (mouse_delta.y / window_size.y)
                            };

                            fov :f32= FOV * math.RAD_PER_DEG;
                            aspect := window_size.x / window_size.y;
                            plane_height := 2.0 * MIN_CLIP * math.tan_f32(fov / 2);
                            plane_width := plane_height * aspect;

                            fmt.println(mouse_delta_factor);
                            fmt.println(plane_width, plane_height);

                            pan -= lin.Vector2{plane_width * mouse_delta_factor.x, plane_height * mouse_delta_factor.y} * 100 * math.pow_f32(cam_distance, 1.5);
                        }
                        case .ORBIT_3D: {
                            orbit.x += mouse_delta.x * 0.01;
                            orbit.y += (mouse_delta.y * 0.01) * (window_size.y / window_size.x);
                        }
                    }
                }
            }
            case gfx.Window_Key_Event: {
                if event.action == glfw.PRESS && (event.mods & glfw.MOD_CONTROL) != 0{
                    switch event.key {
                        case glfw.KEY_G: {
                            app.config.enable_imm_gui = !app.config.enable_imm_gui;
                        }
                        case glfw.KEY_1: {
                            camera_kind = .ORBIT_3D;
                        }
                        case glfw.KEY_2: {
                            camera_kind = .PANNING_2D;
                        }
                        case glfw.KEY_O: {
                            do_draw_gizmos = !do_draw_gizmos;
                        }
                        case glfw.KEY_R: {
                            pan = {0, 0};
                            orbit = {0, 0};
                            cam_distance = 10;
                        }
                    }
                }
            }
        }
    }
    
    return true;
}



draw_game :: proc() -> bool {
    using scene;
    window_size := gfx.get_window_size();
    
    switch camera_kind {
        case .ORBIT_3D: {
            imm.set_projection_perspective(math.RAD_PER_DEG * FOV, window_size.x / window_size.y, MIN_CLIP, 1000.0);
            yaw := orbit.x;
            pitch := -orbit.y;
            center := lin.Vector3{0, 0, 0};
            cam_pos := center + lin.Vector3{
                cam_distance * math.sin(yaw) * math.cos(pitch), // X
                cam_distance * math.sin(pitch),                // Y (in Vulkan, negative Y is up)
                cam_distance * math.cos(yaw) * math.cos(pitch) // Z
            };
            imm.set_view_look_at(cam_pos, center, {0, -1, 0});
        }
        case .PANNING_2D: {
            aspect := window_size.x / window_size.y;
            height :f32= cam_distance;
            width := aspect * height;
            imm.set_default_2D_camera(width, height);
            imm.get_current_context().camera.view = lin.translate({-width/2 + pan.x / width, -height/2 + pan.y / height, 1});
        }
    }

    imm.set_render_target(gfx.window_surface);
    imm.begin3d();
    imm.clear_target(clear_color);
    imm.push_translation({2, 2, 0});
    imm.push_rotation_y(app.elapsed_seconds * 2);
    imm.rectangle({}, {1, 1}, color=gfx.GREEN if do_draw_gizmos else gfx.TRANSPARENT);
    imm.pop_transforms(2);
    imm.rectangle({-1000, -1000, -1000}, {1, 1}, color=gfx.TRANSPARENT);
    imm.flush();

    if emitter.is_compiled {
        cam := imm.get_current_context().camera;
        proj := cam.proj;
        view := cam.view;
        view_inv := lin.inverse(view);
        pfx.draw_emitter(&emitter, proj, view_inv);
    }

    for window,i in gui_windows {
        if window.show {
            igui.begin_window(fmt.tprint(window.name, "##Window"), open_ptr=&gui_windows[i].show);
            if window.want_center {
                igui.set_widget_pos(window_size.x/2, window_size.y/2);
                gui_windows[i].want_center = false;
            }
            window.show_proc(&gui_windows[i]);
            igui.end_window();
        }
    }

    @(thread_local)
    minimized : bool;
    igui.begin_window("Windows", flags={.WINDOW, .ALLOW_HSCROLL, .ALLOW_VSCROLL, .ALLOW_OVERFLOW});

    width :f32= 200;
    if minimized {
        width =50;
    }
    igui.set_widget_size(width, window_size.y);
    igui.set_widget_pos(window_size.x - width / 2, window_size.y / 2);

    if igui.button("+" if minimized else "-") {
        minimized = !minimized;
    }

    if !minimized {
        if igui.button("Open All") {
            for _,i in gui_windows {
                gui_windows[i].show = true;
            }
        }
        if igui.button("Close All") {
            for _,i in gui_windows {
                gui_windows[i].show = false;
            }
        }
        if igui.button("Center All") {
            for _,i in gui_windows {
                gui_windows[i].want_center = true;
            }
        }
        igui.separator();
        for _,i in gui_windows {
            window := &gui_windows[i];
            igui.label(window.name);
            igui.columns(2);
            if igui.button(fmt.tprint("Open##", window.name)) {
                window.show = true;
            }
            if igui.button(fmt.tprint("Close##", window.name)) {
                window.show = false;
            }
            igui.columns(1);
            if igui.button(fmt.tprint("Center##", window.name)) {
                window.want_center = true;
            }
            igui.separator();
        }
    }

    igui.end_window();

    return true;
}

do_scene_window :: proc(wnd : ^Gui_Window_Binding) {
    using scene;
    enum_selection("Camera", &camera_kind);
    igui.label(fmt.tprintf("Orbit: %.2v, Distance: %.2f", orbit, cam_distance));

    igui.f32vec3_drag("Background Color", cast(^lin.Vector3)&clear_color, rate=0.01);

    igui.checkbox("Draw Gizmos", &do_draw_gizmos);
}

do_emitter_window :: proc(wnd : ^Gui_Window_Binding) {
    using scene;
    config_before := emitter.config;

    igui.columns(3);
    if igui.button("Compile") {
        pfx.compile_emitter(&emitter);
    }
    if igui.button("Start" if emitter.state != .RUNNING else "Stop") {
        if emitter.state == .RUNNING do pfx.pause_emitter(&emitter);
        else do pfx.start_emitter(&emitter);
    }
    if igui.button("Reset") {
        pfx.reset_emitter(&emitter);
    }

    igui.columns(2);
    now := pfx.get_emitter_time(&emitter);
    igui.label(fmt.tprintf("Time: %.4f", now));
    igui.label(fmt.tprint("State:", emitter.state));
    
    igui.columns(3);
    igui.int_drag("Max Particles (!)", &emitter.max_particles, min=1);
    f32_rate := cast(f32)emitter.emission_rate;
    igui.f32_drag("Emission Rate", &f32_rate, min=0.001);
    emitter.emission_rate = cast(f64)f32_rate;
    seed_int := cast(int)(emitter.seed / 3000);
    igui.f32_drag("Seed##Emitter", &emitter.seed, min=-2000, max=2000, rate=1);

    igui.columns(2);

    igui.checkbox("Depth Testing (!)", &emitter.enable_depth_test);
    igui.checkbox("Depth Writing (!)", &emitter.enable_depth_write);
    igui.checkbox("2D Mode", &emitter.should_only_2D);
    igui.checkbox("Loop", &emitter.should_loop);

    igui.columns(1);

    enum_selection("Particle Kind", &emitter.config.particle_kind);
    if emitter.particle_kind == .TEXTURE {
        igui.columns(2);
        @(thread_local)
        texture_path : string;

        igui.text_field("Texture Path", &texture_path, placeholder="path/to/texture.png");

        if igui.button("Load") {
            load_particle_texture_from_path(texture_path);
        }

        igui.columns(1);
    }
    igui.separator();
    f32_property("Lifetime", &emitter.lifetime, min=0.001);
    igui.separator();
    vec4_property("Color", &emitter.color);
    igui.separator();
    vec3_property("Velocity", &emitter.velocity);
    igui.separator();
    vec3_property("Acceleration", &emitter.acceleration);
    igui.separator();
    vec2_property("Angular Velocity (Local Yaw Pitch)", &emitter.angular_velocity);
    igui.separator();
    vec2_property("Angular Acceleration (Local Yaw Pitch)", &emitter.angular_acceleration);
    igui.separator();
    vec3_property("Rotation (Z-only for billboards)", &emitter.rotation);
    igui.separator();
    vec3_property("size", &emitter.size, min=0.0001);
    igui.separator();
    vec3_property("position", &emitter.position);

    if emitter.is_compiled && config_before != emitter.config {
        pfx.update_emitter_config(&emitter);
        serial.update_synced_data();
    }
}

load_particle_texture_from_path :: proc(texture_path : string) {
    using scene;
    if !os.exists(texture_path) {
        log.error("Texture file not found: ", texture_path);
        return;
    }
    data, w, h, c, ok := img.decode_image_file_to_argb_bytes(texture_path, desired_channels=4);
    if ok {
        defer img.delete_image_argb(data);

        if current_particle_texture.vk_image != 0 {
            jvk.destroy_texture(current_particle_texture);
        }

        current_particle_texture = jvk.make_texture(w, h, builtin.raw_data(data), .SRGBA);
        current_texture_path = texture_path;

        pfx.set_particle_texture(&emitter, current_particle_texture);
    } else {
        log.error("Couldn't load texture at ", texture_path);
    }
}

f32_property :: proc(name : string, prop : ^pfx.Particle_Property_F32, min : Maybe(f32) = nil, max : Maybe(f32) = nil) {
    
    
    igui.label(name);
    enum_selection(fmt.tprintf("Property type##%s", name), &prop.kind);
    switch prop.kind {
        case .CONSTANT: {
            igui.f32_drag(fmt.tprint("Constant Value##", name), &prop.value1, min=min, max=max, rate=0.05);
        }
        case .RANDOM: {
            enum_selection(fmt.tprintf("Distribution##%s", name), &prop.distribution);
            igui.columns(2);
            igui.f32_drag(fmt.tprint("Seed##", name), &prop.seed, rate=1);
            if igui.button(fmt.tprint("Randomize##", name)) do prop.seed = pfx.rand_seed();
            igui.columns(1);
            igui.checkbox("Soft-lock range", &prop.soft_lock_rand_range);
            igui.columns(2);
            igui.f32_drag(fmt.tprint("min##", name), &prop.value1, min=min, max=max, rate=0.05);
            igui.f32_drag(fmt.tprint("max##", name), &prop.value2, min=min, max=max, rate=0.05);
            igui.columns(1);
        }
        case .INTERPOLATE: {
            enum_selection(fmt.tprintf("Interpolation Curve##%s", name), &prop.interp_kind);
            igui.columns(2);
            igui.f32_drag(fmt.tprint("from##", name), &prop.value1, min=min, max=max, rate=0.05);
            igui.f32_drag(fmt.tprint("to##", name), &prop.value2, min=min, max=max, rate=0.05);
            igui.columns(1);
        }
    }

}
vec2_property :: proc(name : string, prop : ^pfx.Particle_Property_Vec2, min : Maybe(f32) = nil, max : Maybe(f32) = nil) {
    
    igui.label(name);
    enum_selection(fmt.tprintf("Property type##%s", name), &prop.kind);
    switch prop.kind {
        case .CONSTANT: {
            igui.f32vec2_drag(fmt.tprint("Constant Value##", name), &prop.value1, rate=0.05);
        }
        case .RANDOM: {
            enum_selection(fmt.tprintf("Distribution##%s", name), &prop.distribution);
            enum_selection(fmt.tprintf("Rand Per##%s", name), &prop.scalar_or_component_rand);
            igui.columns(2);
            igui.f32_drag(fmt.tprint("Seed##", name), &prop.seed, rate=1);
            if igui.button(fmt.tprint("Randomize##", name)) do prop.seed = pfx.rand_seed();
            igui.columns(1);
            igui.checkbox("Soft-lock range", &prop.soft_lock_rand_range);
            igui.columns(2);
            igui.f32vec2_drag(fmt.tprint("min##", name), &prop.value1, rate=0.05);
            igui.f32vec2_drag(fmt.tprint("max##", name), &prop.value2, rate=0.05);
            igui.columns(1);
        }
        case .INTERPOLATE: {
            enum_selection(fmt.tprintf("Interpolation Curve##%s", name), &prop.interp_kind);
            igui.columns(2);
            igui.f32vec2_drag(fmt.tprint("from##", name), &prop.value1, rate=0.05);
            igui.f32vec2_drag(fmt.tprint("to##", name), &prop.value2, rate=0.05);
            igui.columns(1);
        }
    }
}
vec3_property :: proc(name : string, prop : ^pfx.Particle_Property_Vec3, min : Maybe(f32) = nil, max : Maybe(f32) = nil) {
    
    igui.label(name);
    enum_selection(fmt.tprintf("Property type##%s", name), &prop.kind);
    switch prop.kind {
        case .CONSTANT: {
            igui.f32vec3_drag(fmt.tprint("Constant Value##", name), &prop.value1, rate=0.05);
        }
        case .RANDOM: {
            enum_selection(fmt.tprintf("Distribution##%s", name), &prop.distribution);
            enum_selection(fmt.tprintf("Rand Per##%s", name), &prop.scalar_or_component_rand);
            igui.columns(2);
            igui.f32_drag(fmt.tprint("Seed##", name), &prop.seed, rate=1);
            if igui.button(fmt.tprint("Randomize##", name)) do prop.seed = pfx.rand_seed();
            igui.columns(1);
            igui.checkbox("Soft-lock range", &prop.soft_lock_rand_range);
            igui.f32vec3_drag(fmt.tprint("min##", name), &prop.value1, rate=0.05);
            igui.f32vec3_drag(fmt.tprint("max##", name), &prop.value2, rate=0.05);
        }
        case .INTERPOLATE: {
            enum_selection(fmt.tprintf("Interpolation Curve##%s", name), &prop.interp_kind);
            igui.f32vec3_drag(fmt.tprint("from##", name), &prop.value1, rate=0.05);
            igui.f32vec3_drag(fmt.tprint("to##", name), &prop.value2, rate=0.05);
        }
    }
}
vec4_property :: proc(name : string, prop : ^pfx.Particle_Property_Vec4, min : Maybe(f32) = nil, max : Maybe(f32) = nil) {
    
    igui.label(name);
    enum_selection(fmt.tprintf("Property type##%s", name), &prop.kind);
    switch prop.kind {
        case .CONSTANT: {
            igui.f32vec4_drag(fmt.tprint("Constant Value##", name), &prop.value1, rate=0.05);
        }
        case .RANDOM: {
            enum_selection(fmt.tprintf("Distribution##%s", name), &prop.distribution);
            enum_selection(fmt.tprintf("Rand Per##%s", name), &prop.scalar_or_component_rand);
            igui.columns(2);
            igui.f32_drag(fmt.tprint("Seed##", name), &prop.seed, rate=1);
            if igui.button(fmt.tprint("Randomize##", name)) do prop.seed = pfx.rand_seed();
            igui.columns(1);
            igui.checkbox("Soft-lock range", &prop.soft_lock_rand_range);
            igui.f32vec4_drag(fmt.tprint("min##", name), &prop.value1, rate=0.05);
            igui.f32vec4_drag(fmt.tprint("max##", name), &prop.value2, rate=0.05);
        }
        case .INTERPOLATE: {
            enum_selection(fmt.tprintf("Interpolation Curve##%s", name), &prop.interp_kind);
            igui.f32vec4_drag(fmt.tprint("from##", name), &prop.value1, rate=0.05);
            igui.f32vec4_drag(fmt.tprint("to##", name), &prop.value2, rate=0.05);
        }
    }
}

enum_selection :: proc(name : string, value : ^$T) {
    igui.columns(2);
    igui.label(name);
    igui.label(fmt.tprint(":", value^, "##", name));
    igui.columns(min(len(T), 4));
    for field_name,i in reflect.enum_field_names(T) {
        field_value := reflect.enum_field_values(T)[i];
        if igui.button(fmt.tprintf("%s##%s", field_name, name)) {
            value^ = cast(T)field_value;
        }
    }
    igui.columns(1);
}


