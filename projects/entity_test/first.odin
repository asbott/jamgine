package entity_test

import "jamgine:gfx"
import "jamgine:gfx/imm"
import "jamgine:console"
import "jamgine:app"
import "jamgine:entities"
import "jamgine:lin"
import "jamgine:utils"

import "core:math"

Any_Entity :: union {
    Triangle_Boy, Rectangle_Boy, Circle_Boy
}
Entity_Base_Data :: struct {
    using pos : lin.Vector2,
    spawn_time : f32,
    life_duration : f32,
}
Entity :: entities.Entity_Type(Any_Entity, Entity_Base_Data);
Entity_Manager :: entities.Entity_Manager(Entity);

Triangle_Boy :: struct {
    using base : ^Entity,
}
Rectangle_Boy :: struct {
    using base : ^Entity,
}
Circle_Boy :: struct {
    using base : ^Entity,
}

main :: proc() {

    app.init_proc     = init;
    app.shutdown_proc = shutdown;
    app.sim_proc      = simulate_game;
    app.draw_proc     = draw_game;

    app.run();
}

manager : Entity_Manager;

init :: proc() -> bool {

    entities.init_entity_manager(&manager);

    Entity_Kind :: enum {
        Triangle, Rectangle, Circle
    }
    console.bind_enum(Entity_Kind);
    console.bind_command("spawn", proc(kind : Entity_Kind, life_duration : f32) {
        e : ^Entity;
        switch kind {
            case .Triangle:  e = entities.spawn(&manager, Triangle_Boy);
            case .Rectangle: e = entities.spawn(&manager, Rectangle_Boy);
            case .Circle:    e = entities.spawn(&manager, Circle_Boy);
        }
        e.spawn_time = app.elapsed_seconds;
        e.life_duration = life_duration;
    });
    

    return true;
}
shutdown :: proc() -> bool {

    entities.destroy_entity_manager(&manager);

    return true;
}

simulate_game :: proc() -> bool {

    window_size := gfx.get_window_size();

    for e,i in manager.entities {
        life_time := app.elapsed_seconds - e.spawn_time;
        if life_time > e.life_duration {
            manager.entities[i].despawn_flag = true;
            continue;
        }
        switch entity in e.variant {
            case Triangle_Boy: {
                // Move up and down in waves, back and forth horizontally
                entity.x = utils.norm_sin(life_time) * window_size.x;
                entity.y = utils.oscillate(4, life_time) * window_size.y;
            }
            case Rectangle_Boy: {
                entity.x = window_size.x/2 + abs(math.floor(math.sin(life_time))) * 100;
                entity.y = window_size.y/2 + abs(math.floor(math.sin(life_time))) * 100;
            }
            case Circle_Boy: {
                entity.x = utils.norm_cos(life_time) * window_size.x;
                entity.y = utils.norm_sin(life_time) * window_size.y;
            }
        }
    }

    entities.purge(&manager);

    return true;
}

draw_game :: proc() -> bool {

    imm.set_render_target(gfx.window_surface);
    imm.begin2d();
    imm.clear_target({0.2, 0.2, 0.3, 1.0});

    imm.rectangle({-100, -100, 0}, {1, 1});

    for e,i in manager.entities {
        switch entity in e.variant {
            case Triangle_Boy: {
                imm.triangle_isosceles(lin.v3(entity.pos), {64, 64});
            }
            case Rectangle_Boy: {
                imm.rectangle(lin.v3(entity.pos), lin.Vector2{64, 64});
            }
            case Circle_Boy: {
                imm.circle(lin.v3(entity.pos), 64);
            }
        }
    }

    imm.flush();

    return true;
}
