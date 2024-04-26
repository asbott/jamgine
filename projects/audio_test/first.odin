package audio_test

import "jamgine:app"
import "jamgine:gfx"
import "jamgine:gfx/imm"
import igui "jamgine:gfx/imm/gui"
import "jamgine:audio"

import "core:fmt"
import "core:mem"
import "core:os"

main :: proc() {

    app.config.name = "Jamgine Audio Test";
    app.config.do_serialize_config = true;
    app.config.do_clear_window = true;
    app.config.window_clear_color = gfx.CORNFLOWER_BLUE;

    app.init_proc = init;
    app.shutdown_proc = shutdown;
    app.sim_proc = update;
    app.draw_proc = draw;

    app.run();
}

pc : ^audio.Playback_Context;
player : ^audio.Simple_Player;
player2 : ^audio.Simple_Player;
effect : ^audio.Source;
effect_pcm : audio.Pcm_Result;
song : ^audio.Source;
song_raw : ^audio.Source;

init :: proc() -> bool {

    audio.init();
    audio.set_target_device_context(audio.make_device_context());

    test_format : audio.Audio_Format;
    test_format.kind = .S24;
    test_format.channels = 2;
    test_format.sample_rate = 48000;

    // Recommended to just use this to avoid conversions altogether
    test_format = audio.get_device_format();

    pc = audio.make_playback_context(test_format);
    player = audio.make_simple_player(pc);
    player2 = audio.make_simple_player(pc);

    ok : bool;
    effect_pcm, ok = audio.decode_file_to_pcm("bruh.wav", test_format);
    assert(ok, "Effect decode fail");
    effect, ok = audio.make_source_from_memory(effect_pcm.pcm, effect_pcm.byte_size, .PCM, test_format);
    assert(ok, "Effect source make fail");
    
    song, ok = audio.make_source_from_file("song.mp3", .COMPRESSED, test_format);
    assert(ok, "Song source make fail");

    if !os.is_file("song.pcm") {
        song_pcm_result, ok := audio.decode_file_to_pcm("song.mp3", audio.get_device_format());
        assert(ok, "Decode song fail");
        os.write_entire_file("song.pcm", mem.byte_slice(song_pcm_result.pcm, song_pcm_result.byte_size));
        audio.delete_pcm(song_pcm_result);
    }
    song_raw, ok = audio.make_source_from_file("song.pcm", .PCM, audio.get_device_format());
    assert(ok, "Song source pcm make fail");

    audio.set_player_source(player, song_raw);
    audio.set_player_source(player2, effect);

    audio.start_player(player);
    //audio.start_player(player2);

    return true;
}
shutdown :: proc() -> bool {

    audio.set_player_source(player, nil);
    audio.set_player_source(player2, nil);

    audio.destroy_source(song);
    audio.destroy_source(song_raw);
    audio.destroy_source(effect);
    audio.delete_pcm(effect_pcm);
    audio.destroy_simple_player(player);
    audio.destroy_simple_player(player2);
    audio.destroy_playback_context(pc);
    audio.destroy_target_device_context();
    audio.shutdown();

    return true;
}

do_player_gui :: proc(p : ^audio.Player_Base) {
    unique_name :: proc(label : string, p : ^audio.Player_Base) -> string {
        return fmt.tprint(label, "##", cast(uintptr)cast(rawptr)p, sep="");
    }

    igui.begin_window(unique_name("Player", p));

    now := cast(f32)audio.get_player_seconds(p);
    
    if igui.f32_slider(unique_name("Time", p), &now, min=0, max=p.duration) {
        audio.set_player(p, now);
    }

    if igui.button(unique_name("Play", p)) do audio.start_player(p);
    if igui.button(unique_name("Stop", p)) do audio.stop_player(p);
    if igui.button(unique_name("Reset", p)) do audio.reset_player(p);

    looping := audio.is_player_looping(p);
    if igui.checkbox(unique_name("Loop", p), &looping) {
        audio.set_player_looping(p, looping);
    }

    igui.end_window();
}

update :: proc() -> bool {
    
    do_player_gui(player);
    do_player_gui(player2);
    
    return true;
}

draw :: proc() -> bool {

    imm.begin2d();

    window_size := gfx.get_window_size();

    imm.text(fmt.tprintf("Audio sample time: %.4fms", audio.get_target_device_context().last_sample_duration_seconds * 1000.0), {window_size.x/2, 100, 0});

    imm.flush();

    return true;
}