package invaders

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:gfx/text"
import "jamgine:input"
import "jamgine:utils"
import "jamgine:serial"
import jvk "jamgine:gfx/justvk"
import "jamgine:lin"
import "core:log"
import "core:builtin"
import "jamgine:data"
import "jamgine:console"

import "vendor:glfw"

import "core:runtime"
import "core:strings"
import "core:slice"
import "core:math"
import "core:unicode/utf16"
import "core:unicode/utf8"
import "core:mem"
import "core:fmt"
import "core:time"
import "core:os"
import "core:c"
import "core:intrinsics"
import "core:math/rand"
import "core:encoding/json"
import "core:os/os2"

DEVELOPER :: #config(DEVELOPER, true)
running := true;

frame_stopwatch      : time.Stopwatch;
frame_duration       : time.Duration;
delta_seconds        : f32;
elapsed_stopwatch    : time.Stopwatch;
elapsed_seconds      : f32;
elapsed_duration     : time.Duration;

scaled_delta_seconds : f32;
scaled_seconds       : f32;
last_imm_stats       : imm.Stats;

take_window_event :: proc($T : typeid) -> (^gfx.Window_Event) {
    for e,i in gfx.window_events {
        #partial switch v in e.variant {
            case T: {
                return &gfx.window_events[i];
            }
        }    
    }
    return nil;
}

main :: proc() {
    context.logger = console.create_console_logger();

    os2.Kill = proc() {
        context = runtime.default_context();
        fmt.println("Process killed");
        serial.sync_all();
    }
    os2.Interrupt = proc() {
        context = runtime.default_context();
        fmt.println("Process Interrupted");
        serial.sync_all();
    }

    fmt.println("Program started");

    init();

    time.stopwatch_start(&frame_stopwatch);
    time.stopwatch_start(&elapsed_stopwatch);
    for !glfw.WindowShouldClose(gfx.window) && running {

        frame_duration   = time.stopwatch_duration(frame_stopwatch);
        delta_seconds    = cast(f32)time.duration_seconds(frame_duration);
        elapsed_duration = time.stopwatch_duration(elapsed_stopwatch);
        elapsed_seconds  = cast(f32)time.duration_seconds(elapsed_duration);
        scaled_delta_seconds = delta_seconds * time_scale;
        scaled_seconds   += scaled_delta_seconds;

        time.stopwatch_reset(&frame_stopwatch);
        time.stopwatch_start(&frame_stopwatch);

        free_all(context.temp_allocator);
        gfx.collect_window_events();

        console.update(delta_seconds);
        input.update();

        
        when DEVELOPER {
            if input.is_key_just_pressed(glfw.KEY_ESCAPE, glfw.MOD_SHIFT) {
                running = false;
            }
        }


        update();

        draw();
        
        imm.set_render_target(gfx.window_surface);
        console.draw();
        
        gfx.swap_buffers();
        last_imm_stats = imm.get_current_context().stats;
        imm.reset_stats();
    }

    serial.sync_all();

    deinit();

    gfx.shutdown();

    fmt.println("Program exit as expected");
}

GAME_ARENA_WIDTH :: 440;
GAME_ARENA_HEIGHT :: 512;
GAME_ARENA_SIZE :: lin.Vector2{ GAME_ARENA_WIDTH, GAME_ARENA_HEIGHT }
GAME_ARENA_CENTER :: lin.Vector2{ GAME_ARENA_WIDTH/2, GAME_ARENA_HEIGHT/2 };

debug : struct {
    draw_arena_info : bool,
    draw_collision_info : bool,
    draw_stats : bool,
    unlock_constraints : bool,
};

hdr_vert :: `#version 450
layout (location = 0) in vec3 a_Pos;
layout (location = 1) in vec4 a_Color;
layout (location = 2) in vec2 a_UV;
layout (location = 3) in vec3 a_Normal;
layout (location = 4) in ivec4 a_DataIndices;

layout (binding = 1) uniform Camera {
    mat4 u_Proj;
    mat4 u_View;
    vec2 u_Viewport;
};

layout (location = 0) flat out int v_TextureIndex;
layout (location = 1) out vec4 v_Color;
layout (location = 2) out vec2 v_UV;

void main()
{
    gl_Position = u_Proj * u_View * vec4(a_Pos, 1.0);

    v_Color = a_Color;
    v_UV = a_UV;
    v_TextureIndex = int(a_DataIndices[1]);
}
`
hdr_frag :: `#version 450

layout (location = 0) out vec4 result;
    
layout (location = 0) flat in int v_TextureIndex;
layout (location = 1) in vec4 v_Color;
layout (location = 2) in vec2 v_UV;

layout (binding = 0) uniform sampler2D samplers[MAX_SAMPLERS];
const int BLUR_SIZE = 4;
const float BLUR_OFFSET = 1.0 / 512.0;
void main()
{
    vec4 base_color = texture(samplers[v_TextureIndex], v_UV);
    vec4 bloom = vec4(0.0);

    for(int x = -BLUR_SIZE; x <= BLUR_SIZE; x++) {
        for(int y = -BLUR_SIZE; y <= BLUR_SIZE; y++) {
            vec2 sampleOffset = vec2(x, y) * BLUR_OFFSET;
            vec4 game_color = texture(samplers[v_TextureIndex], v_UV + sampleOffset);

            if (game_color.x > 1.0) bloom.x += game_color.x;
            if (game_color.y > 1.0) bloom.y += game_color.y;
            if (game_color.z > 1.0) bloom.z += game_color.z;
        }
    }

    bloom /= float((BLUR_SIZE * 2 + 1) * (BLUR_SIZE * 2 + 1));

    result = bloom + base_color;
}

`
Game_Frame :: struct {
    texture : jvk.Texture,
    target : jvk.Render_Target,
}
game_frames : []Game_Frame;
time_scale : f32 = 1.0;

camera : struct {
    pos : lin.Vector2,
    zoom : f32,
}

player_id : Object_Id = -1;

hdr_shader : jvk.Shader_Program;
hdr_pipeline : ^jvk.Pipeline;

panic_and_dump_info :: proc(panic_msg : string, loc := #caller_location) {

    fmt.println("PANIC INFO DUMP:");
    fmt.println("Objects:");

    for obj in objects {
        fmt.println(obj);
    }

    panic(fmt.tprintf("%s (%s)", panic_msg, loc));
}
slice_contains :: proc(slice : []$T, item : T) -> bool {
    for slice_time in slice {
        if slice_item == item do return true;
    }
    return false;
}
slice_contains_adress :: proc(slice : []$T, item : ^T) -> bool {
    for i in 0..<len(slice) {
        if &slice[i] == item do return true;
    }
    return false;
}

get_player_or_panic :: proc(loc := #caller_location) -> ^Player {
    player, player_ok := try_resolve_object_id(player_id, Player);
    if !player_ok do panic("Player is not OK :(", loc);
    return player;
}

init :: proc() {

    gfx.init_and_open_window("Invaders");
    
    imm.init();
    imm.make_and_set_context();

    ok : bool;
    hdr_shader, ok = jvk.make_shader_program(hdr_vert, hdr_frag, constants={jvk.Shader_Constant{"MAX_SAMPLERS", 4}});
    assert(ok, "Failed hdr shader");
    hdr_pipeline = jvk.make_pipeline(hdr_shader, gfx.window_surface.render_pass);

    console.init(imm.get_current_context());
    input.init(gfx.window);
    init_object_manager();

    serial.bind_struct_data_to_file(&debug, "debug.sync", .WRITE_CHANGES_TO_DISK);

    window_size := gfx.get_window_size();
    console.bind_enum(Enemy_Kind);
    
    player_id = spawn_player().id;
    p := get_player_or_panic();

    sampling := jvk.DEFAULT_SAMPLER_SETTINGS;
    sampling.min_filter = .NEAREST;
    sampling.mag_filter = .NEAREST;

    game_frames = make([]Game_Frame, gfx.window_surface.number_of_frames);

    for _, i in game_frames {
        using frame := &game_frames[i];
        texture = jvk.make_texture(auto_cast GAME_ARENA_SIZE.x, auto_cast GAME_ARENA_SIZE.y, nil, .RGBA_HDR, {.SAMPLE, .DRAW}, sampler=sampling);
        target = jvk.make_texture_render_target(texture);
    }
    
    gfx.clear_color = gfx.BLACK;
    
    for i in 0..<len(arena_nodes) {
        n := &arena_nodes[i];
        n.objects = make([dynamic]Object_Id, 0, 32);
        n.pos = {f32(i % HNODES) * NODE_WIDTH, f32(i / HNODES) * NODE_HEIGHT} + { NODE_WIDTH/2.0, NODE_HEIGHT/2.0 };
    }

    init_game_effect_manager();

    bind_commands();

}
deinit :: proc() {
    shutdown_game_effect_manager();

    log.debug("Game shutdown");
    for game_frame in game_frames {
        jvk.destroy_render_target(game_frame.target);
        jvk.destroy_texture(game_frame.texture);
    }
    delete(game_frames);

    jvk.destroy_pipeline(hdr_pipeline);
    jvk.destroy_shader_program(hdr_shader);

    console.shutdown();

    imm.delete_current_context();
    imm.shutdown();
}

add_object_to_nodes :: proc(obj : Object_Id, nodes : []^Arena_Node) {
    for i in 0..<len(nodes) {
        n :=nodes[i];
        append(&n.objects, obj);
    }
}

get_stopwatch_seconds :: proc(watch : time.Stopwatch) -> f32{
    return cast(f32)time.duration_seconds(time.stopwatch_duration(watch));
}
player_v_bullet :: proc(player : ^Player, bullet : ^Bullet) {
    if bullet.allegiance == .ENEMY {
        player.last_hit_time = scaled_seconds;
    
        despawn(bullet);

        play_time_warp_effect_interp_pattern(1.0, 0.2, 0.5, .Wave_Up1, .Ease_In, .Ease_Out);
        play_zoom_effect_interp_pattern(0.0, 0.25, 0.5, .Wave_Up1, .Ease_In, .Ease_Out);
        pan_dir := lin.normalize_or_0(player.pos - GAME_ARENA_CENTER);
        play_pan_effect_interp_pattern(v2(0), pan_dir * 50, 0.5, .Wave_Up1, .Ease_Out, .Ease_Out);
    }
}
enemy_v_bullet :: proc(enemy : ^Enemy, bullet : ^Bullet) {
    if bullet.allegiance == .PLAYER {
        despawn(bullet);
        player := get_player_or_panic();
        enemy.health -= player.damage_factor * PLAYER_DAMAGE;
    }
}
player_v_enemy :: proc(player : ^Player, enemy : ^Enemy) {
}
enemy_v_enemy :: proc(enemy1, enemy2 : ^Enemy) {
}
bullet_v_bullet :: proc(bullet1, bullet2 : ^Bullet) {
}

update_player :: proc(player : ^Player) {
    // Player movement
    //
    move_axes : lin.Vector2;
    if input.is_key_down(glfw.KEY_A) do move_axes.x -= 1.0;
    if input.is_key_down(glfw.KEY_D) do move_axes.x += 1.0;
    if input.is_key_down(glfw.KEY_S) do move_axes.y -= 1.0;
    if input.is_key_down(glfw.KEY_W) do move_axes.y += 1.0;

    move_dir := lin.normalize_or_0(move_axes);

    player.pos += move_dir * player.speed * scaled_delta_seconds;

    max_player_y := PLAYER_MAX_Y_RATIO * GAME_ARENA_SIZE.y;

    PL := player.x - player.size.x / 2.0;
    PR := player.x + player.size.x / 2.0;
    PB := player.y - player.size.y / 2.0;
    PT := player.y + player.size.y / 2.0;

    if !debug.unlock_constraints {
        //if PL < 0 do player.x = player.size.x / 2.0;
        //if PR >= GAME_ARENA_SIZE.x do player.x = GAME_ARENA_SIZE.x - player.size.x / 2.0;
        if PB < 0 do player.y = player.size.y / 2.0;
        if PT >= max_player_y do player.y = max_player_y - player.size.y / 2.0;
    }

    player.x = utils.wrap(player.x, 0, GAME_ARENA_SIZE.x);

    if input.is_key_down(glfw.KEY_SPACE) {

        time_since_last_shot := scaled_seconds - player.last_shoot_time;

        if time_since_last_shot > PLAYER_GUN_COOLDOWN {

            pos := player.pos + lin.Vector2{player.size.x/2.0-4, player.size.y/2.0};
            if player.shoot_from_left {
                pos.x = player.x - player.size.x/2.0+4
            }

            pos.x = utils.wrap(pos.x, 0, GAME_ARENA_SIZE.x);
            spawn_new_bullet(pos, { 0, 1 }, player.bullet_size, player.bullet_speed_factor, .PLAYER);

            player.shoot_from_left = !player.shoot_from_left;
            player.last_shoot_time = scaled_seconds;
        }
    }

    time_since_hit := scaled_seconds - player.last_hit_time;
    if time_since_hit < PLAYER_HIT_SHAKE_TIME {
        factor := 1.0 - (time_since_hit / PLAYER_HIT_SHAKE_TIME);
        player.rotation = utils.norm_sin(time_since_hit * 60) * (PLAYER_HIT_ROTATION_RANGE*factor) - ((PLAYER_HIT_ROTATION_RANGE/2.0)*factor);
    } else {
        player.rotation = 0;
    }
}

update_enemy :: proc(enemy : ^Enemy) {

    player := get_player_or_panic();

    life_time := scaled_seconds - enemy.spawn_time;
    distance_to_top := GAME_ARENA_SIZE.y - enemy.spawn_pos.y;
    yoffset : f32 = 0;
    
    is_entering := life_time < ENEMY_ENTER_ARENA_SECONDS;
    
    if is_entering {
        yoffset = distance_to_top - (distance_to_top * (life_time/ENEMY_ENTER_ARENA_SECONDS));
        enemy.pos = enemy.spawn_pos + {0, yoffset};
    } else {
        life_time -= ENEMY_ENTER_ARENA_SECONDS;

        distance := enemy.target_pos - enemy.pos;
        move := lin.normalize_or_0(distance) * enemy.speed * scaled_delta_seconds;

        target_reached := math.abs(lin.length(distance)) == 0.0 || math.abs(lin.length(move)) > math.abs(lin.length(distance));
        target_just_reached := false;

        if target_reached {
            enemy.pos = enemy.target_pos;
            if enemy.is_moving {
                enemy.target_reach_time = life_time;
                target_just_reached = true;
            }
            enemy.is_moving = false;
            move = {0, 0};
        } else {
            enemy.is_moving = true;
        }
        hs := enemy.size / 2.0;

        time_since_shoot := life_time - enemy.last_shoot_time;

        switch enemy.kind {
            case .FAST_BOY: {
                if target_reached {
                    enemy.target_pos.x = rand.float32_range(hs.x, GAME_ARENA_SIZE.x-hs.x);
                }
                enemy.pos.x += move.x;
                enemy.pos.y = enemy.spawn_pos.y + utils.norm_sin(((life_time * ENEMY_FAST_HOVER_FACTOR)-1.56)) * ENEMY_FAST_HOVER_DIST;

                dir := lin.normalize_or_0(player.pos - enemy.pos);
                enemy.rotation = math.atan2_f32(-dir.y, dir.x) + math.PI / 2.0;

                if time_since_shoot >= ENEMY_FAST_SHOOT_INTERVALL {
                    dir := lin.normalize_or_0(player.pos - enemy.pos);
                    spawn_new_bullet(enemy.pos + dir * lin.length(hs), dir, v2(enemy.bullet_size), enemy.bullet_speed_factor, .ENEMY);
                    enemy.last_shoot_time = life_time;
                }
            }
            case .SLOW_BOY: {
                if target_reached {
                    enemy.target_pos.x = rand.float32_range(hs.x, GAME_ARENA_SIZE.x-hs.x);
                }
                enemy.pos += move;
                enemy.rotation = life_time;

                if time_since_shoot >= ENEMY_SLOW_SHOOT_INTERVALL {
                    spawn_new_bullet(enemy.pos + { 0, -hs.y }, { 0, -1 }, v2(enemy.bullet_size), enemy.bullet_speed_factor, .ENEMY)
                    enemy.last_shoot_time = life_time;
                }
            }
            case .ZOOM_BOY: {
                
                
                if target_reached {
                    time_paused := life_time - enemy.target_reach_time;
                    
                    if target_just_reached do enemy.aim_pos = player.pos;
                    
                    dir := lin.normalize_or_0(enemy.aim_pos - enemy.pos);
                    enemy.rotation = math.atan2_f32(-dir.y, dir.x) + math.PI / 2.0;
                    
                    if time_paused > ENEMY_ZOOM_WAIT_TIME {
                        enemy.target_pos = {rand.float32_range(hs.x, GAME_ARENA_SIZE.x-hs.x), rand.float32_range(GAME_ARENA_SIZE.y*PLAYER_MAX_Y_RATIO+hs.y, GAME_ARENA_SIZE.y-hs.y)};
                    }
                    
                    if time_paused > ENEMY_ZOOM_SHOOT_TIME && enemy.last_shoot_time < enemy.target_reach_time {
                        spawn_new_bullet(enemy.pos + dir * lin.length(hs), dir, v2(enemy.bullet_size), enemy.bullet_speed_factor, .ENEMY);
                        enemy.last_shoot_time = life_time;
                        
                    }
                } else {
                    dir := lin.normalize_or_0(player.pos - enemy.pos);
                    enemy.rotation = math.atan2_f32(-dir.y, dir.x) + math.PI / 2.0;
                }
                enemy.pos += move;
            }
        }
    }
}

update_bullet :: proc(bullet : ^Bullet) {
    bullet.pos += lin.normalize_or_0(bullet.direction) * bullet.pixels_per_second * scaled_delta_seconds;

    if !is_in_bounds(bullet.pos, bullet.size) {
        despawn(bullet);
    }
}

update_emitter :: proc(emitter : ^Emitter) {

}
update_sonic_boom :: proc(sonic : ^Sonic_Boom) {

}

update :: proc() {

    sim_game_effects();

    update_object_manager();
    player := get_player_or_panic();
    if e := take_window_event(gfx.Window_Resize_Event); e != nil {
        using resize_event := e.variant.(gfx.Window_Resize_Event);
        imm.set_default_2D_camera(resize_event.width, resize_event.height);
        e.handled = true;
    }

    find_collisions();

    for i in 0..<len(objects) {
        obj := &objects[i];
        if !obj.is_valid do continue;

        if obj.should_die_on_0_health && obj.health <= 0 {
            despawn_by_id(obj.id);
            continue;
        }

        switch shape in &obj.collision_shape {
            case Polygon: {
                transform : lin.Matrix4 = lin.translate(v3(obj.pos)) * lin.rotate({0, 0, -1}, obj.rotation);

                // #Speed
                shape.ps_world = slice.clone(t_transform_points(shape.ps_local, transform));
            }
            case Rect: {
                shape.pos = obj.pos;
            }
            case Circle: {
                shape.center = obj.pos;
            }
        }
        switch obj_typed in &obj.variant {
            case Player: update_player(&obj_typed);
            case Enemy:  update_enemy(&obj_typed);
            case Bullet: update_bullet(&obj_typed);
            case Emitter: update_emitter(&obj_typed);
            case Sonic_Boom: update_sonic_boom(&obj_typed);
        }
    }

    
}

draw_player_image :: proc(sz : lin.Vector2, any_collisions : bool) {
    
    // #Temporary
    body_height := BODY_HEIGHT_RATIO * sz.y;
    body_y := -sz.y / 2.0 + body_height / 2.0;
    gun_width := GUN_WIDTH_RATIO * sz.x;
    left_gun_x  := -sz.x/2.0 + gun_width / 2.0;
    right_gun_x := sz.x/2.0 - gun_width / 2.0;
    gun_height  := sz.y-body_height;
    guns_y      := body_y + body_height / 2.0 + gun_height / 2.0;

    imm.triangle_isosceles({left_gun_x,  guns_y, 0}, {gun_width, gun_height}, color=gfx.WHITE);
    imm.triangle_isosceles({right_gun_x, guns_y, 0}, {gun_width, gun_height}, color=gfx.WHITE);
    imm.rectangle({0, body_y, 0}, {sz.x, body_height}, color=gfx.WHITE);
}
draw_player :: proc(player : ^Player) {
    draw_player_image(player.size, player.any_collision);

    PL := player.x - player.size.x / 2.0;
    PR := player.x + player.size.x / 2.0;
    PB := player.y - player.size.y / 2.0;
    PT := player.y + player.size.y / 2.0;

    image_pos : lin.Vector2;
    should_draw_overlap_image := true;
    if PL < 0 {
        image_pos = {GAME_ARENA_SIZE.x + math.abs(PR) - player.size.x/2.0, player.y};
    } else if PR >= GAME_ARENA_SIZE.x {
        image_pos = {PR - GAME_ARENA_SIZE.x - player.size.x/2.0, player.y};
    } else do should_draw_overlap_image = false;

    if should_draw_overlap_image {
        imm.push_inverse_transform();
        imm.push_translation(v3(image_pos));
        imm.push_rotation_z(player.rotation);
        draw_player_image(player.size, player.any_collision);
        imm.pop_transforms(3);
    }
}
draw_enemy :: proc(enemy : ^Enemy) {
    life_time := scaled_seconds - enemy.spawn_time - ENEMY_ENTER_ARENA_SECONDS;

    player := get_player_or_panic();

    switch enemy.kind {
        case .SLOW_BOY: {
            imm.rectangle({}, ENEMY_SLOW_SIZE);
        }
        case .FAST_BOY: {
            imm.triangle_isosceles({}, enemy.size, v3(0, 1));
        }
        case .ZOOM_BOY: {

            time_paused := life_time - enemy.target_reach_time;

            if time_paused <= ENEMY_ZOOM_SHOOT_TIME {
                until_shoot_factor := time_paused / ENEMY_ZOOM_SHOOT_TIME;

                imm.line({}, {0, lin.length(GAME_ARENA_SIZE), 0}, 8 * (1.0-until_shoot_factor)+5*utils.noisy_sin_1(life_time*15.0), color={1.0 + time_paused/ENEMY_ZOOM_SHOOT_TIME, .1, .1, .7});
            }
            imm.triangle_isosceles({}, enemy.size, v3(0, 1));
        }
    }
}
draw_bullet :: proc(bullet : ^Bullet) {
    imm.circle({}, bullet.size.x, color=gfx.BLACK);
}
draw_emitter :: proc(emitter : ^Emitter) {
    
}
draw_sonic_boom :: proc(sonic : ^Sonic_Boom) {

}

draw_game :: proc() {

    game_frame := &game_frames[gfx.window_surface.frame_index];

    imm.set_render_target(game_frame.target);

    imm.set_default_2D_camera(auto_cast GAME_ARENA_SIZE.x, auto_cast GAME_ARENA_SIZE.y);
    view := lin.translate(v3(camera.pos, 1)) *
            lin.translate(v3(GAME_ARENA_SIZE/2, 0)) * 
            lin.scale(v3(1 - camera.zoom)) *
            lin.translate(-v3(GAME_ARENA_SIZE/2, 0));
    imm.get_current_context().camera.view = view;

    imm.begin2d();
    imm.clear_target({0.2, 0.2, 0.3, 1.0});

    for i in 0..<len(objects) {
        obj := objects[i]; // Copy because when drawing we should not write anyways
        if !obj.is_valid do continue;
        
        imm.push_translation(v3(obj.pos));
        imm.push_rotation_z(obj.rotation);
        switch obj_variant in &obj.variant {
            case Player: draw_player(&obj_variant);
            case Enemy:  draw_enemy(&obj_variant);
            case Bullet: draw_bullet(&obj_variant);
            case Emitter: draw_emitter(&obj_variant);
            case Sonic_Boom: draw_sonic_boom(&obj_variant);
        }
        if debug.draw_collision_info {
            bounds := get_shape_bounds(obj.collision_shape);

            imm.rectangle_lined({}, lin.Vector2(bounds.zw), color=gfx.GRAY);
            /*imm.push_inverse_transform();
            imm.push_translation(v3(obj.pos));
            imm.pop_transforms(2);*/
            
            switch shape in obj.collision_shape {
                case Polygon: {
                    draw_polygon(shape, color=gfx.GREEN if !obj.any_collision else gfx.RED);
                }
                case Rect: {
                    imm.rectangle({}, shape.size, color=gfx.GREEN);
                }
                case Circle: {
                    imm.circle({}, shape.radius, color=gfx.GREEN);
                }
            }
        }
        imm.pop_transforms(2);
    }

    if debug.draw_arena_info {
        max_player_y := PLAYER_MAX_Y_RATIO * GAME_ARENA_SIZE.y;
        imm.line({0, max_player_y, 0}, {GAME_ARENA_SIZE.x, max_player_y, 0});
    }

    if debug.draw_collision_info {
        for x : f32 = 0; x < GAME_ARENA_SIZE.x; x += NODE_WIDTH {
            imm.line(v3(x, 0), v3(x, GAME_ARENA_SIZE.y));
        }
        for y : f32 = 0; y < GAME_ARENA_SIZE.y; y += NODE_HEIGHT {
            imm.line(v3(0, y), v3(GAME_ARENA_SIZE.x, y));
        }

        for n in arena_nodes {
            for obj_id in n.objects {
                obj, is_valid := try_resolve_object_id(obj_id);
                if !is_valid do continue;
                imm.line(v3(n.pos), v3(obj.pos), color=gfx.YELLOW);
            }

            str := fmt.tprint(len(n.objects));
            imm.rectangle(v3(n.pos), text.measure(imm.get_current_context().default_font, str));
            imm.text(str, v3(n.pos), color=gfx.BLACK);
        }
    }

    imm.flush();
}
draw_polygon :: proc(poly : Polygon, color := gfx.GREEN) {
    last : Maybe(lin.Vector2);
    for p, i in poly.ps_local {
        if last != nil {
            imm.line(v3(last.(lin.Vector2)), v3(p), color=color);
        }
        if i == len(poly.ps_local)-1 {
            imm.line(v3(poly.ps_local[0]), v3(p), color=color);
        }
        last = p;
    }
}
draw :: proc() {

    game_frame := &game_frames[gfx.window_surface.frame_index];
    draw_game();

    // Draw the game texture in the center of the window
    window_size := gfx.get_window_size();
    imm.set_render_target(gfx.window_surface);
    imm.set_default_2D_camera(window_size.x, window_size.y);
    imm.begin(hdr_pipeline);
    imm.clear_target(gfx.BLACK);
    //imm.begin2d();
    
    aspect := GAME_ARENA_SIZE.x / GAME_ARENA_SIZE.y;

    height := window_size.y;
    width := height * aspect;
    x := window_size.x / 2.0;
    y := window_size.y / 2.0;

    imm.rectangle({x, y, 0}, {width, height}, texture=game_frame.texture, uv_range={0, 1, 1, 0});

    imm.flush();

    
    if debug.draw_stats {
        imm.begin2d();
        imm_stats := last_imm_stats;
        stats_string := fmt.tprintf(
`Vertices: %i,
Indices: %i
Allocated Objects: %i
Valid Objects : %i
Enemies: %i
Bullets: %i
Collision checks: %i
Collisions: %i
Time scale: %f
Frametime: %f.
FPS: %f `, imm_stats.num_vertices, imm_stats.num_indices, len(objects), number_of_valid_objects(), count_objects_of_type(Enemy), count_objects_of_type(Bullet), collision_checks, collisions, time_scale, delta_seconds, 1.0/delta_seconds);

        text_size := text.measure(imm.get_current_context().default_font, stats_string);
        imm.text(stats_string, { 5, 5, 0 } + v3(text_size / 2.0));
        imm.flush();
    }

}

bind_commands :: proc() {
    console.bind_command("exit", proc () {
        running = false;
    });


    console.bind_command("toggle_debug", proc(var : string) -> string {
        Debug_Type :: type_of(debug);
        tinfo := type_info_of(Debug_Type);
        sinfo := tinfo.variant.(runtime.Type_Info_Struct);

        for type, i in sinfo.types {
            name := sinfo.names[i];
            offset := sinfo.offsets[i];

            if name == var {
                p := cast([^]bool)&debug;
                p[offset] = !p[offset];

                console.push_entry(fmt.tprint(debug));
                return fmt.tprintf("%s = %t", name, p[offset]);
            }
        }

        console.push_entry(fmt.tprintf("No such debug flag '%s'", var), .Error);
        return "";
    }, 
    `toggle_debug:
        Toggles a debug flag in the debug struct.
            debug_flag : string - the name of the flag to toggle`,);

    console.bind_command("print_imm_stats", proc() -> string {
        return fmt.tprint(last_imm_stats);
    });
    console.bind_command("print_num_objects", proc() -> string {
        return fmt.tprintf("Number of objects in arena:\nBullets: %i\nEnemies: %i", count_objects_of_type(Bullet), count_objects_of_type(Enemy));
    });

    console.bind_command("spawn_enemy", proc(x, y : f32, kind : Enemy_Kind) -> string {        
        spawn_new_enemy({x, y}, kind);

        return fmt.tprintf("Spawned %s at [X: %f, Y: %f]", kind, x, y);
    });
    console.bind_command("clear_enemies", proc() {
        for i := cast(Object_Id)len(objects)-1; i >= 0; i -= 1 {
            if obj, is_enemy := try_resolve_object_id(i, Enemy); is_enemy {
                despawn(obj);
            }
        }
    });
    console.bind_command("set_time_scale", proc(scale : f32) {
        time_scale = scale;
    });
    console.bind_command("spawn_enemies", proc(num_enemies : int, kind : Enemy_Kind) {
        for i in 0..<num_enemies {
            pos := v2(rand.float32_range(32, GAME_ARENA_SIZE.x-32), rand.float32_range(32, GAME_ARENA_SIZE.y-32));

            spawn_new_enemy(pos, kind);
        }
    });

    console.bind_enum(Interp_Func);
    console.bind_enum(Interp_Pattern);
    console.bind_command("effect_time_warp", proc(from, to, duration : f32, pattern : Interp_Pattern, interp_in, interp_out : Interp_Func)  {
        play_time_warp_effect(from, to, duration, pattern, interp_in, interp_out);
    });
    console.bind_command("effect_zoom", proc(from, to, duration : f32, pattern : Interp_Pattern, interp_in, interp_out : Interp_Func)  {
        play_zoom_effect(from, to, duration, pattern, interp_in, interp_out);
    });
    console.bind_command("save_editor", proc() {
        serial.sync_all();
    });
}

