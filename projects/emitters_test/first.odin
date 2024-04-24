package emitters_test

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
import "core:unicode"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:builtin"
import "core:strings"
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

Any_Property :: union {
    ^pfx.Particle_Property_F32,
    ^pfx.Particle_Property_Vec2,
    ^pfx.Particle_Property_Vec3,
    ^pfx.Particle_Property_Vec4,
}

scene : struct {
    emitter : pfx.Emitter,
    orbit : lin.Vector2,
    orbit_center : lin.Vector3,
    orbit_pan_speed : f32,
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
current_prop : Any_Property;
current_prop_name : string;
emitter_serial_id : serial.Serial_Binding_Id;

init :: proc() -> bool {
    using scene;
    emitter.max_particles = 150000;

    clear_color = {0.1, 0.1, 0.1, 1.0};

    pfx.init_emitter_config(&emitter);

    emitter.seed = rand.float32_range(-2000, 2000);

    orbit = 0;
    cam_distance = 10;

    scene.orbit_pan_speed = 5.0;

    emitter_serial_id = serial.bind_struct_data_to_file(&scene, "emitter_test_scene.json", .WRITE_CHANGES_TO_DISK);

    pfx.compile_emitter(&emitter);

    if os.exists(current_texture_path) {
        load_particle_texture_from_path(current_texture_path);
    }

    gui_windows = slice.clone([]Gui_Window_Binding{
        {"Scene", true, do_scene_window, nil, false},
        {"Emitter", true, do_emitter_window, nil, false},
        {"Property Editor", true, do_property_window, nil, false},
    });

    console.bind_command("draw_gizmos", proc(yesno : bool) {
        scene.do_draw_gizmos = yesno;
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

    for e,i in gfx.window_events {
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

                            pan -= lin.Vector2{plane_width * mouse_delta_factor.x, plane_height * mouse_delta_factor.y} * 100 * math.pow_f32(cam_distance, 1.5);
                        }
                        case .ORBIT_3D: {
                            if input.is_mod_active(glfw.MOD_SHIFT) {
                                orbit_center.y += orbit_pan_speed * mouse_delta.y * 0.01;
                            } else {
                                orbit.x -= mouse_delta.x * 0.01;
                                orbit.y -= (mouse_delta.y * 0.01) * (window_size.y / window_size.x);
                            }
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
                            orbit_center = {0, 0, 0};
                            cam_distance = 10;
                        }
                    }
                }
            }
        }
    }


    yaw := orbit.x; 

    orbit_pan : lin.Vector3;

    if input.is_key_down(glfw.KEY_A) {
        orbit_pan.x += -math.cos(yaw);
        orbit_pan.z += -math.sin(yaw);
    }
    if input.is_key_down(glfw.KEY_D) {
        orbit_pan.x += math.cos(yaw);
        orbit_pan.z += math.sin(yaw);
    }

    if input.is_key_down(glfw.KEY_S) {
        orbit_pan.x += math.sin(yaw);
        orbit_pan.z += -math.cos(yaw);
    }
    if input.is_key_down(glfw.KEY_W) {
        orbit_pan.x += -math.sin(yaw);
        orbit_pan.z += math.cos(yaw);
    }

    orbit_center += orbit_pan * app.delta_seconds * orbit_pan_speed;
    
    return true;
}



draw_game :: proc() -> bool {
    using scene;
    window_size := gfx.get_window_size();
    
    switch camera_kind {
        case .ORBIT_3D: {
            imm.set_projection_perspective(math.RAD_PER_DEG * FOV, window_size.x / window_size.y, MIN_CLIP, 1000.0);
            yaw := orbit.x;
            pitch := orbit.y;
            cam_pos := orbit_center + lin.Vector3{
                cam_distance * math.sin(yaw) * math.cos(pitch),
                cam_distance * math.sin(pitch),
                cam_distance * math.cos(yaw) * -math.cos(pitch) 
            };
            imm.set_view_look_at(cam_pos, orbit_center, {0, -1, 0});
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
    imm.push_translation({2, 2, 0} if do_draw_gizmos else {-99999, -99999, -999999});
    imm.push_rotation_y(app.elapsed_seconds * 2);
    imm.cube({}, {1, 1, 1}, color=gfx.GREEN);
    imm.sphere({2, 2, 2}, 1, color=gfx.GREEN);
    imm.pop_transforms(2);
    
    
    if emitter.is_compiled {
        cam := imm.get_current_context().camera;
        proj := cam.proj;
        view := cam.view;
        view_inv := lin.inverse(view);
        pfx.draw_emitter(&emitter, proj, view_inv);
    }
    
    config_before := emitter.config;
    
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

    if do_draw_gizmos {
        p := lin.Vector3{-4, 4, 0};
        length := cam_distance / 7;
        // Y axis
        imm.line(p, p + {0, length, 0}, color=gfx.GREEN, thickness=cam_distance/50);
        // X Axis
        imm.line(p, p + {length, 0, 0}, color=gfx.RED, thickness=cam_distance/50);
        // Z Axis
        imm.line(p, p + {0, 0, length}, color=gfx.BLUE, thickness=cam_distance/50);

        imm.sphere(orbit_center, cam_distance/100, color=gfx.RED);
    }

    imm.flush();

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

    if emitter.is_compiled && config_before != emitter.config {
        pfx.update_emitter_config(&emitter);
        serial.sync_one(emitter_serial_id);
    }

    return true;
}

do_scene_window :: proc(wnd : ^Gui_Window_Binding) {
    using scene;
    enum_selection("Camera", &camera_kind);
    igui.label(fmt.tprint("Orbit:", orbit));
    igui.label(fmt.tprint("Orbit center:", orbit_center));
    igui.label(fmt.tprint("2D Pan:", pan));

    igui.f32_drag("Orbit pan speed", &orbit_pan_speed);

    igui.f32vec3_drag("Background Color", cast(^lin.Vector3)&clear_color, rate=0.01);

    igui.checkbox("Draw Gizmos", &do_draw_gizmos);
}

do_emitter_window :: proc(wnd : ^Gui_Window_Binding) {
    using scene;
    
    igui.columns(3);

    @(static)
    path : string;
    igui.text_field("File##EmitterEditor", &path);

    if igui.button("Load##EmitterEditor") {
        if os.is_file(path) {
            current := emitter.noserialize;
            ok : bool;
            emitter, ok = serial.json_file_to_struct(path, pfx.Emitter);
            if !ok do log.error("Could not load json from file", path);
            emitter.noserialize = current;
        }
    }
    if igui.button("Save##EmitterEditor") {
        serial.struct_to_json_file(emitter, path);
    }

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
    igui.f32_drag("Emission Rate", &emitter.emission_rate, min=0.001);
    igui.f32_drag("Seed##Emitter", &emitter.seed, rate=1);

    

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

    igui.label("Spawning");
    enum_selection("Kind##SpawnArea", &emitter.spawn_area.kind, display_only_last_word=true);
    if emitter.spawn_area.kind != .AREA_POINT {
        enum_selection("Distribution##SpawnArea", &emitter.spawn_area.spawn_distribution, display_only_last_word=true);
        if emitter.spawn_area.spawn_distribution == .SPAWN_DIST_RANDOM {
            enum_selection("Random Distribtion##SpawnArea", &emitter.spawn_area.rand_spawn_distribution);
            enum_selection("Rand Per##SpawnArea", &emitter.spawn_area.scalar_or_component_rand);
        }
    }
    igui.checkbox("Absolute Spawn Position", &emitter.is_start_pos_absolute);
    igui.f32vec3_drag("Position", &emitter.spawn_area.pos, rate=0.05);

    line_width := cam_distance / 300;

    switch emitter.spawn_area.kind {
        case .AREA_POINT: {
        }
        case .AREA_RECTANGLE: {
            igui.f32vec2_drag("Size", cast(^lin.Vector2)&emitter.spawn_area.size, rate=0.01);
            // Rad
            igui.f32vec3_drag("Euler", &emitter.spawn_area.rotation, rate=0.01);

            if do_draw_gizmos {
                imm.push_translation(emitter.spawn_area.pos);
                imm.push_rotation_x(emitter.spawn_area.rotation.x);
                imm.push_rotation_y(-emitter.spawn_area.rotation.y);
                imm.push_rotation_z(emitter.spawn_area.rotation.z);
                imm.rectangle_lined(p={}, size=emitter.spawn_area.size.xy, color=gfx.GREEN, thickness=line_width);
                imm.pop_transforms(4);
            }
        }
        case .AREA_CIRCLE: {
            igui.f32_drag("Radius", cast(^f32)&emitter.spawn_area.size, rate=0.01);
            // Rad
            igui.f32vec3_drag("Euler", &emitter.spawn_area.rotation, rate=0.01);

            if do_draw_gizmos {
                imm.push_translation(emitter.spawn_area.pos);
                imm.push_rotation_x(emitter.spawn_area.rotation.x);
                imm.push_rotation_y(-emitter.spawn_area.rotation.y);
                imm.push_rotation_z(emitter.spawn_area.rotation.z);
                imm.circle(p={}, radius=emitter.spawn_area.size.x, color={0, 1, 0, 0.5});
                imm.pop_transforms(4);
            }
        }
        case .AREA_CUBE: {
            igui.f32vec3_drag("Size", &emitter.spawn_area.size, rate=0.01);
            // Rad
            igui.f32vec3_drag("Euler", &emitter.spawn_area.rotation, rate=0.01);

            if do_draw_gizmos {
                imm.push_translation(emitter.spawn_area.pos);
                imm.push_rotation_x(emitter.spawn_area.rotation.x);
                imm.push_rotation_y(-emitter.spawn_area.rotation.y);
                imm.push_rotation_z(emitter.spawn_area.rotation.z);
                imm.cube_lined(p={}, size=emitter.spawn_area.size, color=gfx.GREEN, thickness=line_width);
                imm.pop_transforms(4);
            }
        }
        case .AREA_SPHERE: {
            igui.f32_drag("Radius", cast(^f32)&emitter.spawn_area.size, rate=0.01);

            if do_draw_gizmos {
                imm.push_translation(emitter.spawn_area.pos);
                imm.push_rotation_x(emitter.spawn_area.rotation.x);
                imm.push_rotation_y(-emitter.spawn_area.rotation.y);
                imm.push_rotation_z(emitter.spawn_area.rotation.z);
                imm.sphere_lined(p={}, radius=emitter.spawn_area.size.x, color=gfx.GREEN, thickness=line_width);
                imm.pop_transforms(4);
            }
        }
        case .AREA_ELLIPSOID: {
            igui.f32vec3_drag("Size", &emitter.spawn_area.size, rate=0.01);
            // Rad
            igui.f32vec3_drag("Euler", &emitter.spawn_area.rotation, rate=0.01);

            if do_draw_gizmos {
                imm.push_translation(emitter.spawn_area.pos);
                imm.push_rotation_x(emitter.spawn_area.rotation.x);
                imm.push_rotation_y(-emitter.spawn_area.rotation.y);
                imm.push_rotation_z(emitter.spawn_area.rotation.z);
                imm.ellipsoid_lined(p={}, size=emitter.spawn_area.size, color=gfx.GREEN, thickness=line_width);
                imm.pop_transforms(4);
            }
        }
    }

    property_selector(&emitter.lifetime, &emitter.lifetime.base, "Lifetime");
    property_selector(&emitter.color, &emitter.color.base, "Color");
    property_selector(&emitter.velocity, &emitter.velocity.base, "Velocity");
    property_selector(&emitter.acceleration, &emitter.acceleration.base, "Acceleration");
    property_selector(&emitter.angular_velocity, &emitter.angular_velocity.base, "Angular Velocity");
    property_selector(&emitter.angular_acceleration, &emitter.angular_acceleration.base, "Angular Acceleration");
    property_selector(&emitter.rotation, &emitter.rotation.base, "Rotation");
    property_selector(&emitter.rotation_velocity, &emitter.rotation_velocity.base, "Rotation Velocity");
    property_selector(&emitter.rotation_acceleration, &emitter.rotation_acceleration.base, "Rotation Acceleration");
    property_selector(&emitter.size, &emitter.size.base, "Size");


    
}

do_property_window :: proc(wnd : ^Gui_Window_Binding) {
    using scene;
    if current_prop == nil {
        igui.label("Select a property to edit");
        return;
    }

    igui.label(fmt.tprint("Editing: ", current_prop_name));

    switch prop in current_prop {
        case ^pfx.Particle_Property_F32: {
            f32_property(current_prop_name, prop);
        }
        case ^pfx.Particle_Property_Vec2: {
            vec2_property(current_prop_name, prop);
        }
        case ^pfx.Particle_Property_Vec3: {
            vec3_property(current_prop_name, prop);
        }
        case ^pfx.Particle_Property_Vec4: {
            vec4_property(current_prop_name, prop, color=true);
        }
    }
}


property_selector :: proc(any_prop : Any_Property, base : ^pfx.Particle_Property_Base, name : string) {
    igui.separator();
    igui.label(fmt.tprint(name, ": ", base.kind));
    if igui.button(fmt.tprint("Edit##", name)) {
        current_prop = any_prop;
        current_prop_name = name;
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
vec4_property :: proc(name : string, prop : ^pfx.Particle_Property_Vec4, min : Maybe(f32) = nil, max : Maybe(f32) = nil, color := false) {
    
    widget_proc := igui.f32vec4_drag if !color else igui.f32rgba_drag;

    igui.label(name);
    enum_selection(fmt.tprintf("Property type##%s", name), &prop.kind);
    switch prop.kind {
        case .CONSTANT: {
            widget_proc(fmt.tprint("Constant Value##", name), &prop.value1, rate=0.05);
        }
        case .RANDOM: {
            enum_selection(fmt.tprintf("Distribution##%s", name), &prop.distribution);
            enum_selection(fmt.tprintf("Rand Per##%s", name), &prop.scalar_or_component_rand);
            igui.columns(2);
            igui.f32_drag(fmt.tprint("Seed##", name), &prop.seed, rate=1);
            if igui.button(fmt.tprint("Randomize##", name)) do prop.seed = pfx.rand_seed();
            igui.columns(1);
            igui.checkbox("Soft-lock range", &prop.soft_lock_rand_range);
            widget_proc(fmt.tprint("min##", name), &prop.value1, rate=0.05);
            widget_proc(fmt.tprint("max##", name), &prop.value2, rate=0.05);
        }
        case .INTERPOLATE: {
            enum_selection(fmt.tprintf("Interpolation Curve##%s", name), &prop.interp_kind);
            widget_proc(fmt.tprint("from##", name), &prop.value1, rate=0.05);
            widget_proc(fmt.tprint("to##", name), &prop.value2, rate=0.05);
        }
    }
}

enum_selection :: proc(name : string, value : ^$T, display_only_last_word := false) {
    igui.columns(2);
    igui.label(name);

    shortify :: proc(value : $T) -> string {
        str := fmt.tprint(value);
        last_separator := strings.last_index_any(str, "_");
        if last_separator != -1  {
            return str[last_separator+1:];
        } else {
            return str;
        }
    }
    
    lbl := fmt.tprint(":", value^, "##", name)
    igui.label(shortify(lbl) if display_only_last_word else lbl);

    igui.columns(min(len(T), 4));
    for field_name,i in reflect.enum_field_names(T) {
        field_value := reflect.enum_field_values(T)[i];
        if igui.button(fmt.tprintf("%s##%s", shortify(field_name) if display_only_last_word else field_name, name)) {
            value^ = cast(T)field_value;
        }
    }
    igui.columns(1);
}


