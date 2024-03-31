package invaders

import "jamgine:utils"
import "jamgine:lin"

import "core:math"
import "core:log"

Game_Effect_Interp_Proc :: #type proc(t : f32) -> f32

Interp_Func :: enum {
    Ease_In, Ease_Out,
    Linear,
}
Interp_Pattern :: enum {
    Linear_Up, Linear_Down, Flat_High, Flat_Low,
    Wave_Up1, Wave_Up2, Wave_Up3, Wave_Up4,
    Wave_Down1, Wave_Down2, Wave_Down3, Wave_Down4,
}
// 0.0 <= t <= 1.0
ease_in :: proc(t : f32) -> f32 {
    return t * t;
}
ease_out :: proc(t : f32) -> f32 {
    return t * (2-t)
}



interpolate_in :: proc(t : f32, kind : Interp_Func) -> f32 {
    switch kind {
        case .Linear: return t;
        case .Ease_In: return ease_out(t);
        case .Ease_Out: return ease_in(t);
    }
    panic("Unhandled interp func (should not be possible)");
}
interpolate_out :: proc(t : f32, kind : Interp_Func) -> f32 {
    switch kind {
        case .Linear: return t;
        case .Ease_In: return ease_in(t);
        case .Ease_Out: return ease_out(t);
    }
    panic("Unhandled interp func (should not be possible)");
}

Game_Effect :: struct {
    duration   : f32,
    start_time : f32,

    // Custom interpolation, should return value between 0-1
    // based on input time.
    interp_proc : Game_Effect_Interp_Proc,

    // Relevant if proc is not set
    interp_pattern : Interp_Pattern,
    interp_in      : Interp_Func,
    interp_out     : Interp_Func,

    variant : Any_Game_Effect,
}

Any_Game_Effect :: union {
    Game_Effect_Time_Warp,
    Game_Effect_Zoom,
    Game_Effect_Pan,
    Game_Effect_Screen_Shake,
}

Game_Effect_Time_Warp :: struct {
    using base : ^Game_Effect,

    from, to : f32,

    time_scale_on_spawn : f32,
}
Game_Effect_Zoom :: struct {
    using base : ^Game_Effect,

    from, to : f32,
}
Game_Effect_Pan :: struct {
    using base : ^Game_Effect,

    from, to : lin.Vector2,
}
Game_Effect_Screen_Shake :: struct {
    using base : ^Game_Effect,

    low_intensity, high_intensity : lin.Vector2,
}

GAME_EFFECT_BUCKET_SIZE :: 128;
effects : utils.Bucket_Array(Game_Effect, GAME_EFFECT_BUCKET_SIZE);

init_game_effect_manager :: proc() {
    effects = utils.make_bucket_array(Game_Effect, GAME_EFFECT_BUCKET_SIZE);
}
shutdown_game_effect_manager :: proc() {
    log.debug("Game effect manager shutdown");
    utils.delete_bucket_array(&effects);
}


@(private)
spawn_game_effect_base :: proc($T : typeid, start_time, duration : f32, interp_proc : Game_Effect_Interp_Proc = nil, interp_pattern : Interp_Pattern = .Linear_Up, interp_in: Interp_Func = .Linear, interp_out: Interp_Func = .Linear) -> ^T{
    effect := utils.bucket_array_append(&effects);
    effect.variant = T{};
    pvar := &effect.variant.(T);
    pvar.base = effect;
    effect.interp_proc = interp_proc;
    effect.interp_in = interp_in;
    effect.interp_out = interp_out;
    effect.interp_pattern = interp_pattern;
    effect.start_time = start_time;
    effect.duration = duration;

    return pvar;
}


play_time_warp_effect_interp_pattern :: proc(from, to, duration : f32, interp_pattern : Interp_Pattern, interp_in, interp_out : Interp_Func) -> ^Game_Effect_Time_Warp{
    effect := spawn_game_effect_base(Game_Effect_Time_Warp, elapsed_seconds, duration, interp_pattern=interp_pattern, interp_in=interp_in, interp_out=interp_out);
    effect.from = from;
    effect.to = to;
    effect.time_scale_on_spawn = time_scale;
    return effect;    
}
play_time_warp_effect_interp_proc :: proc(from, to, duration : f32, interp : Game_Effect_Interp_Proc) -> ^Game_Effect_Time_Warp{
    effect := spawn_game_effect_base(Game_Effect_Time_Warp, elapsed_seconds, duration, interp_proc=interp);
    effect.from = from;
    effect.to = to;
    effect.time_scale_on_spawn = time_scale;
    return effect;    
}
play_time_warp_effect :: proc{
    play_time_warp_effect_interp_pattern,
    play_time_warp_effect_interp_proc,
}

play_zoom_effect_interp_pattern :: proc(from, to, duration : f32, interp_pattern : Interp_Pattern, interp_in, interp_out : Interp_Func) -> ^Game_Effect_Zoom{
    effect := spawn_game_effect_base(Game_Effect_Zoom, elapsed_seconds, duration, interp_pattern=interp_pattern, interp_in=interp_in, interp_out=interp_out);
    effect.to = to;
    effect.from = from;
    return effect;    
}
play_zoom_effect_interp_proc :: proc(from, to, duration : f32, interp : Game_Effect_Interp_Proc) -> ^Game_Effect_Zoom{
    effect := spawn_game_effect_base(Game_Effect_Zoom, elapsed_seconds, duration, interp_proc=interp);
    effect.to = to;
    effect.from = from;
    return effect;    
}
play_zoom_effect :: proc{
    play_zoom_effect_interp_pattern,
    play_zoom_effect_interp_proc,
}

play_pan_effect_interp_pattern :: proc(from, to : lin.Vector2, duration : f32, interp_pattern : Interp_Pattern, interp_in, interp_out : Interp_Func) -> ^Game_Effect_Pan{
    effect := spawn_game_effect_base(Game_Effect_Pan, elapsed_seconds, duration, interp_pattern=interp_pattern, interp_in=interp_in, interp_out=interp_out);
    effect.to = to;
    effect.from = from;
    return effect;
}
play_pan_effect_interp_proc :: proc(from, to : lin.Vector2, duration : f32, interp : Game_Effect_Interp_Proc) -> ^Game_Effect_Pan{
    effect := spawn_game_effect_base(Game_Effect_Pan, elapsed_seconds, duration, interp_proc=interp);
    effect.to = to;
    effect.from = from;
    return effect;    
}
play_pan_effect :: proc{
    play_pan_effect_interp_pattern,
    play_pan_effect_interp_proc,
}

sim_game_effects :: proc() {
    
    for i := utils.bucket_array_len(effects)-1; i >= 0; i -= 1 {
        effect_base := utils.bucket_array_get_ptr(&effects, i);

        passed := elapsed_seconds - effect_base.start_time;

        if passed >= effect_base.duration {
            utils.bucket_array_unordered_remove(&effects, i);
            switch effect in effect_base.variant {
                case Game_Effect_Time_Warp: {
                    using effect;
                    //time_scale = effect.time_scale_on_spawn;
                    time_scale = 1;
                }
                case Game_Effect_Zoom: {
                    using effect;
                    camera.zoom = 0.0;
                }
                case Game_Effect_Pan: {
                    camera.pos = v2(0);
                }
                case Game_Effect_Screen_Shake: {
                    camera.pos = v2(0);
                }
            }
            continue;
        }

        interp_factor : f32;

        t := passed/effect_base.duration; // 0.0 to 1.0
        pattern_t : f32;

        if effect_base.interp_proc != nil {
            interp_factor = effect_base.interp_proc(t);
        } else {
            switch effect_base.interp_pattern {
                case .Linear_Up: {
                    pattern_t = 1.0 - t;
                }
                case .Linear_Down: {
                    pattern_t = t;
                }
                case .Wave_Up1: {
                    pattern_t = utils.oscillate(1, t); // 0.0 to 1.0 to 0.0
                }
                case .Wave_Up2: {
                    pattern_t = utils.oscillate(2, t); // 0.0 to 1.0 to 0.0 to 1.0 to 0.0....
                }
                case .Wave_Up3: {
                    pattern_t = utils.oscillate(3, t);
                }
                case .Wave_Up4: {
                    pattern_t = utils.oscillate(4, t);
                }
                case .Wave_Down1: {
                    pattern_t = 1.0 - utils.oscillate(1, t); // 1.0 to 0.0 to 1.0
                }
                case .Wave_Down2: {
                    pattern_t = 1.0 - utils.oscillate(2, t);
                }
                case .Wave_Down3: {
                    pattern_t = 1.0 - utils.oscillate(3, t);
                }
                case .Wave_Down4: {
                    pattern_t = 1.0 - utils.oscillate(4, t);
                }
                case .Flat_High: {
                    pattern_t = 1.0;
                }
                case .Flat_Low: {
                    pattern_t = 0.0;
                }
            }
            if t <= 0.5 {
                interp_factor = interpolate_in(pattern_t, effect_base.interp_in);
            } else {
                interp_factor = interpolate_out(pattern_t, effect_base.interp_out);
            }
        }
                
        switch effect in effect_base.variant {
            case Game_Effect_Time_Warp: {
                using effect;
                time_scale = math.lerp(from, to, interp_factor) * effect.time_scale_on_spawn;
            }
            case Game_Effect_Zoom: {
                using effect;
                camera.zoom = math.lerp(from, to, interp_factor);
            }
            case Game_Effect_Pan: {
                using effect;
                camera.pos = math.lerp(from, to, interp_factor);
            }
            case Game_Effect_Screen_Shake: {
            }
        }
    }
}