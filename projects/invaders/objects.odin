package invaders

import "jamgine:gfx"
import "jamgine:utils"
import "jamgine:lin"

import "core:math"
import "core:time"
import "core:intrinsics"
import "core:fmt"

PLAYER_START_LIVES :: 3;
PLAYER_DEFAULT_SPEED :: 250.0;
PLAYER_DEFAULT_SIZE :: lin.Vector2{32, 32};
PLAYER_MAX_Y_RATIO :: 0.3;
PLAYER_GUN_COOLDOWN :: 0.2;
PLAYER_HIT_SHAKE_TIME :: 0.2;
PLAYER_HIT_ROTATION_RANGE :: math.PI/2.0;
PLAYER_BULLET_SIZE :: 12
PLAYER_BULLET_SPEED_FACTOR :: 1.0;
PLAYER_DAMAGE :: 10;
// #Temporary will use sprite for player
BODY_HEIGHT_RATIO :: 0.4;
GUN_HEIGHT_RATIO  :: 1 - BODY_HEIGHT_RATIO;
GUN_WIDTH_RATIO   :: 0.4;
ENEMY_ENTER_ARENA_SECONDS :: 0.3;

ENEMY_SLOW_SIZE :: lin.Vector2{32, 32};
ENEMY_SLOW_SPEED :: 80;
ENEMY_SLOW_SHOOT_INTERVALL :: 1.0;
ENEMY_SLOW_BULLET_SIZE :: 18;
ENEMY_SLOW_BULLET_SPEED_FACTOR :: 0.3;
ENEMY_SLOW_HEALTH :: 20;

ENEMY_FAST_SIZE :: lin.Vector2{24, 14};
ENEMY_FAST_SPEED :: 200;
ENEMY_FAST_HOVER_DIST :: 100;
ENEMY_FAST_HOVER_FACTOR :: 5;
ENEMY_FAST_SHOOT_INTERVALL :: 0.4;
ENEMY_FAST_BULLET_SIZE :: 10;
ENEMY_FAST_BULLET_SPEED_FACTOR :: 0.7;
ENEMY_FAST_HEALTH :: 10;

ENEMY_ZOOM_SIZE :: lin.Vector2{18, 32};
ENEMY_ZOOM_SPEED :: 600;
ENEMY_ZOOM_WAIT_TIME :: 1.0;
ENEMY_ZOOM_SHOOT_TIME :: 0.75;
ENEMY_ZOOM_BULLET_SIZE :: 10;
ENEMY_ZOOM_BULLET_SPEED_FACTOR :: 2.0;
ENEMY_ZOOM_HEALTH :: 10;

BULLET_DEFAULT_PPS :: GAME_ARENA_SIZE.y;
BULLET_DEFAULT_SIZE :: 8;

objects : [dynamic]Object;
free_id_stack : [dynamic]Object_Id;
spawn_batch : [dynamic]Object;

Object_Id :: distinct int;

Allegiance :: enum {
    PLAYER, ENEMY,
}
Object_Variant :: union { Player, Enemy, Bullet, Emitter, Sonic_Boom }
Object :: struct {
    using pos : lin.Vector2,
    size : lin.Vector2,
    rotation : f32,
    any_collision : bool,
    spawn_time : f32,
    collision_shape : Collision_Shape,
    variant : Object_Variant,
    id : Object_Id,
    is_valid : bool,
    last_shoot_time : f32,
    bullet_size : f32,
    bullet_speed_factor : f32,
    health : f32,
    should_die_on_0_health : bool,
}
Player :: struct {
    using base : ^Object,
    lives : int,
    speed : f32,
    shoot_from_left : bool,
    last_hit_time : f32,
    damage_factor : f32,
}
Enemy_Kind :: enum {
    SLOW_BOY,
    FAST_BOY,
    ZOOM_BOY,
}
Enemy :: struct {
    using base : ^Object,
    spawn_pos : lin.Vector2,
    target_pos : lin.Vector2,
    kind : Enemy_Kind,
    speed : f32,
    target_reach_time : f32,
    is_moving : bool,
    aim_pos : lin.Vector2
}
Bullet :: struct {
    using base : ^Object,
    pixels_per_second : f32,
    direction : lin.Vector2,
    allegiance : Allegiance,
}
Sonic_Boom :: struct {
    using base : ^Object,
    radius : f32,
}
VFX_Kind :: enum {

}
Emitter :: struct {
    using base : ^Object,
    
}

// Returns weak pointer
spawn_empty_object :: proc($T : typeid) -> ^Object where intrinsics.type_is_subtype_of(T, ^Object){
    when ODIN_DEBUG do validate_base_pointers_or_panic();
    obj : ^Object;
    if len(free_id_stack) <= 0 {
        id := len(objects) + len(spawn_batch);
        append(&spawn_batch, Object{});
        obj = &spawn_batch[len(spawn_batch)-1];
        obj.id = cast(Object_Id)id;
    } else {
        id := free_id_stack[len(free_id_stack)-1];
        pop(&free_id_stack);
        obj = &objects[id];
        obj^ = {};
        obj.id = id;
    }
    obj.is_valid = true;
    obj.variant = T{};
    obj.spawn_time = scaled_seconds;

    var := &obj.variant.(T);
    var.base = obj;

    when ODIN_DEBUG do validate_base_pointers_or_panic();


    return obj;
}
spawn_player :: proc() -> ^Object{
    player := &spawn_empty_object(Player).variant.(Player);
    player.lives = PLAYER_START_LIVES;
    player.speed = PLAYER_DEFAULT_SPEED;
    player.size = PLAYER_DEFAULT_SIZE;
    player.pos = {GAME_ARENA_SIZE.x / 2.0, 64};
    player.last_hit_time = -1;
    player.last_shoot_time = -99999;
    player.bullet_size = PLAYER_BULLET_SIZE;
    player.bullet_speed_factor = PLAYER_BULLET_SPEED_FACTOR;
    player.should_die_on_0_health = false;
    player.damage_factor = 1.0;

    // #Temporary
    sz := player.size;
    body_height := BODY_HEIGHT_RATIO * sz.y;
    body_y := -sz.y / 2.0 + body_height / 2.0;
    gun_width := GUN_WIDTH_RATIO * sz.x;
    left_gun_x  := -sz.x/2.0 + gun_width / 2.0;
    right_gun_x := sz.x/2.0 - gun_width / 2.0;
    gun_height  := sz.y-body_height;
    guns_y      := body_y + body_height / 2.0 + gun_height / 2.0;
    left := -sz.x / 2.0;
    right := sz.x / 2.0;
    bot := -sz.y / 2.0;
    top := sz.y / 2.0;
    body_top := body_y + body_height / 2.0;
    player.collision_shape = make_polygon(utils.clone_slice([]lin.Vector2{
        {left, bot},
        {left, body_top},
        {left_gun_x, top},
        {left_gun_x + gun_width / 2.0, body_top},
        {right_gun_x - gun_width / 2.0, body_top},
        {right_gun_x, top},
        {right, body_top},
        {right, bot},
    }));;

    return player;
}
init_enemy :: proc(e : ^Enemy, pos : lin.Vector2, kind : Enemy_Kind) -> ^Enemy {
    e.pos = pos;
    e.kind = kind;
    e.spawn_pos = pos;
    e.pos = e.spawn_pos;
    e.target_pos = e.spawn_pos;
    e.last_shoot_time = -99999;
    e.should_die_on_0_health = true;
    switch kind {
        case .FAST_BOY: {
            e.speed = ENEMY_FAST_SPEED;
            e.size = ENEMY_FAST_SIZE;
            e.bullet_size = ENEMY_FAST_BULLET_SIZE;
            e.bullet_speed_factor = ENEMY_FAST_BULLET_SPEED_FACTOR;
            e.health = ENEMY_FAST_HEALTH;
            e.collision_shape = make_polygon(utils.clone_slice([]lin.Vector2 {
                {-e.size.x/2.0, -e.size.y/2.0},
                {0,  e.size.y/2.0},
                { e.size.x/2.0,  -e.size.y/2.0},
            }));
        }
        case .SLOW_BOY: {
            e.speed = ENEMY_SLOW_SPEED;
            e.size = ENEMY_SLOW_SIZE;
            e.bullet_size = ENEMY_SLOW_BULLET_SIZE;
            e.bullet_speed_factor = ENEMY_SLOW_BULLET_SPEED_FACTOR;
            e.health = ENEMY_SLOW_HEALTH;
            e.collision_shape = make_polygon(utils.clone_slice([]lin.Vector2 {
                {-e.size.x/2.0, -e.size.y/2.0},
                {-e.size.x/2.0,  e.size.y/2.0},
                { e.size.x/2.0,  e.size.y/2.0},
                { e.size.x/2.0, -e.size.y/2.0},
            }));
        }
        case .ZOOM_BOY: {
            e.speed = ENEMY_ZOOM_SPEED;
            e.size = ENEMY_ZOOM_SIZE;
            e.bullet_size = ENEMY_ZOOM_BULLET_SIZE;
            e.bullet_speed_factor = ENEMY_ZOOM_BULLET_SPEED_FACTOR;
            e.health = ENEMY_ZOOM_HEALTH;
            e.collision_shape = make_polygon(utils.clone_slice([]lin.Vector2 {
                {-e.size.x/2.0, -e.size.y/2.0},
                {0,  e.size.y/2.0},
                { e.size.x/2.0,  -e.size.y/2.0},
            }));
        }
    }

    return e;
}
spawn_new_enemy :: proc(pos : lin.Vector2, kind : Enemy_Kind) -> ^Object {
    obj := spawn_empty_object(Enemy);
    init_enemy(&obj.variant.(Enemy), pos, kind);

    return obj;
}
init_bullet :: proc(b : ^Bullet, start_pos, dir, sz : lin.Vector2, speed_factor : f32, allegiance : Allegiance) -> ^Bullet {
    b.pixels_per_second = BULLET_DEFAULT_PPS * speed_factor;
    b.pos = start_pos;
    b.direction = dir;
    b.size = sz;
    b.allegiance = allegiance;

    radius := sz.x;
    segments := 10;
    segment_rad := math.TAU / cast(f32)segments;

    /*b.collision_shape = make(Polygon, segments);

    for i in 0..<segments {
        angle := f32(i) * segment_rad;
        dir := lin.Vector2{math.cos(angle), math.sin(angle)};
        b.collision_shape.(Polygon)[i] = dir * radius;
    }*/
    b.collision_shape = Circle{radius=radius, center={}};

    return b;
}
spawn_new_bullet :: proc(start_pos, dir, sz : lin.Vector2, speed_factor : f32, allegiance : Allegiance) -> ^Object {
    obj := spawn_empty_object(Bullet);
    init_bullet(&obj.variant.(Bullet), start_pos, dir, sz, speed_factor, allegiance);

    return obj;
}

despawn_by_pointer :: proc(obj : ^$T)  {
    #assert(intrinsics.type_is_subtype_of(T, ^Object) || T == Object);

    when T != Object {
        assert(obj.id == obj.base.id);
        base_obj := obj.base;
    } else {
        base_obj := obj;
    }
    
    when ODIN_DEBUG do validate_base_pointers_or_panic();

    assert(&objects[obj.id] == base_obj);
    despawn_by_id(obj.id);
}
despawn_by_id :: proc(obj_id : Object_Id)  {
    when ODIN_DEBUG do validate_base_pointers_or_panic();
    obj := resolve_object_id(obj_id);
    obj.is_valid = false;
    #partial switch shape in obj.collision_shape {
        case Polygon: {
            delete(shape.ps_local);
            delete(shape.ps_world);
        }
    }
    obj.collision_shape = nil;
    append(&free_id_stack, obj_id);
}
despawn :: proc {despawn_by_id, despawn_by_pointer}

try_resolve_object_id_agnostic :: proc(id : Object_Id) -> (^Object, bool) {
    return try_resolve_object_id_typed(id, Object);
}
try_resolve_object_id_typed :: proc(id : Object_Id, $T : typeid) -> (^T, bool) where intrinsics.type_is_subtype_of(T, ^Object) || T == Object {
    when ODIN_DEBUG do validate_base_pointers_or_panic();
    obj : ^Object;
    if cast(int)id >= len(objects) {
        spawn_id := cast(int)id - len(objects);
        if spawn_id < len(spawn_batch) do obj = &spawn_batch[spawn_id];
        else do return nil, false;

    } else {
        if cast(int)id < 0 do return nil, false;
        obj = &objects[cast(int)id];
    }
    when T != Object {
        if !utils.variant_is(obj.variant, T) do return nil, false;
        return &obj.variant.(T), obj.is_valid;
    } else {
        return obj, obj.is_valid;
    }
}

try_resolve_object_id :: proc { try_resolve_object_id_agnostic, try_resolve_object_id_typed }

resolve_object_id_agnostic :: proc(id : Object_Id, loc := #caller_location) -> (^Object) {
    return resolve_object_id_typed(id, Object, loc=loc);
}
resolve_object_id_typed :: proc(id : Object_Id, $T : typeid, loc := #caller_location) -> (^T) where intrinsics.type_is_subtype_of(T, ^Object) || T == Object {
    obj, ok := try_resolve_object_id(id, T);
    assert(ok, fmt.tprintf("Invalid object ID (%s)", loc));
    return obj;
}

resolve_object_id :: proc { resolve_object_id_agnostic, resolve_object_id_typed }

count_objects_of_type :: proc($T : typeid) -> int {
    counter := 0;
    for obj in objects do if obj.is_valid && utils.variant_is(obj.variant, T) do counter += 1;
    return counter;
}
number_of_valid_objects :: proc() -> int {
    return len(objects) - len(free_id_stack);
}

init_object_manager :: proc() {
    objects = make([dynamic]Object, 0, 16);
    free_id_stack = make([dynamic]Object_Id, 0, 16);
    spawn_batch = make([dynamic]Object, 0, 16);
}

validate_base_pointers_or_panic :: proc(loc := #caller_location) {
    for i in 0..<len(objects) {
        obj := &objects[i];
        switch v in obj.variant {
            case Player: if v.base != obj do panic_and_dump_info(fmt.tprintf("Object pointers mismatch. OBJECT:\n%s\n\nVARIANT BASE:\n\n", obj, v), loc);
            case Enemy:  if v.base != obj do panic_and_dump_info(fmt.tprintf("Object pointers mismatch. OBJECT:\n%s\n\nVARIANT BASE:\n\n", obj, v), loc);
            case Bullet: if v.base != obj do panic_and_dump_info(fmt.tprintf("Object pointers mismatch. OBJECT:\n%s\n\nVARIANT BASE:\n\n", obj, v), loc);
            case Emitter: if v.base != obj do panic_and_dump_info(fmt.tprintf("Object pointers mismatch. OBJECT:\n%s\n\nVARIANT BASE:\n\n", obj, v), loc);
            case Sonic_Boom: if v.base != obj do panic_and_dump_info(fmt.tprintf("Object pointers mismatch. OBJECT:\n%s\n\nVARIANT BASE:\n\n", obj, v), loc);
        }
    }
}

update_object_manager :: proc() {
    if len(spawn_batch) > 0 {
        when ODIN_DEBUG do validate_base_pointers_or_panic();
        cp_index := len(objects);
        resize(&objects, len(objects) + len(spawn_batch));
        copy_slice(objects[cp_index:], spawn_batch[:]);
        clear(&spawn_batch);


        for i in 0..<len(objects) {
            obj := &objects[i];
            // #Refactor
            switch v in obj.variant {
                case Player: {
                    var := &obj.variant.(Player);
                    var.base = obj;
                }
                case Enemy: {
                    var := &obj.variant.(Enemy);
                    var.base = obj;
                }
                case Bullet: {
                    var := &obj.variant.(Bullet);
                    var.base = obj;
                }
                case Emitter: {
                    var := &obj.variant.(Emitter);
                    var.base = obj;
                }
                case Sonic_Boom: {
                    var := &obj.variant.(Emitter);
                    var.base = obj;
                }
            }
        }
        when ODIN_DEBUG do validate_base_pointers_or_panic();
    }
}