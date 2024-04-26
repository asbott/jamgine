package audio

import "jamgine:utils"

import ma "vendor:miniaudio"

import "core:os"
import "core:strings"
import "core:c"
import "core:mem"
import "core:builtin"
import "core:log"
import "core:fmt"
import "core:time"
import "core:sync"
import "core:math"

Playback_Context :: struct {
    dc : ^Device_Context,

    mtx : sync.Mutex,

    simple_players : utils.Bucket_Array(Simple_Player),
    mixed_players  : utils.Bucket_Array(Mixed_Player),

    postprocess_mixer_proc : Mixer_Proc, // Optional

    output_format : Audio_Format,

    mix_buffer : rawptr, // #Memory
    conversion_buffer : rawptr, // #Memory
    mix_buffer_size : int,
}

make_playback_context :: proc(output_format : Audio_Format, postprocess_mixer_proc : Mixer_Proc = nil, using dc := target_dc) -> ^Playback_Context {
    pc := new(Playback_Context);

    pc.dc = dc;
    pc.output_format = output_format;
    pc.simple_players = utils.make_bucket_array_default_cap(Simple_Player);
    pc.mixed_players  = utils.make_bucket_array_default_cap(Mixed_Player);

    pc.postprocess_mixer_proc = postprocess_mixer_proc;

    add_sampler(proc(dc : ^Device_Context, output, input : rawptr, out_frame_count : int, user_data : rawptr) {
        pc := cast(^Playback_Context)user_data;

        if out_frame_count == 0 do return;
        
        sync.lock(&pc.mtx);
        defer sync.unlock(&pc.mtx);

        simp_len := utils.bucket_array_len(pc.simple_players);
        mix_len := utils.bucket_array_len(pc.mixed_players);

        comp_size := audio_format_sample_byte_size(pc.output_format.kind);
        frame_size := comp_size * pc.output_format.channels;
        output_size := frame_size * out_frame_count;

        sample_source :: proc(src : ^Source, first : int, n : int, output : rawptr, output_format : Audio_Format, update_pos : bool) {

            if first > src.total_frame_count do return;

            comp_size := audio_format_sample_byte_size(output_format.kind);
            frame_size := comp_size * output_format.channels;
            output_size := frame_size * n;

            first_byte_index := first * frame_size;

            if src.compression == .COMPRESSED {
                if update_pos {
                    ma.decoder_seek_to_pcm_frame(&src.ma_decoder, u64(first));
                }
                ma.decoder_read_pcm_frames(&src.ma_decoder, output, u64(n), nil);
            } else if src.kind == .MEMORY && src.compression == .PCM {
                mem.copy(output, mem.ptr_offset(cast(^byte)src.pcm, first_byte_index), min(output_size, src.pcm_size - first_byte_index));
            } else if src.kind == .FILE && src.compression == .PCM {
                if update_pos {
                    os.seek(src.file, i64(first * frame_size), 0);
                }
                os.read_ptr(src.file, output, output_size);
            } else {
                panic("Unimplemented source kind/compression");
            }
        }

        ensure_mix_buffer_size :: proc(pc : ^Playback_Context, sz : int) {
            if pc.mix_buffer_size < sz {
                if pc.mix_buffer != nil do free(pc.mix_buffer);
                if pc.conversion_buffer != nil do free(pc.conversion_buffer);

                new_size := utils.align_next_pow2(sz);

                pc.mix_buffer, _ = mem.alloc(new_size);
                pc.conversion_buffer, _ = mem.alloc(new_size);
                pc.mix_buffer_size = new_size;
            }
        }

        for i in 0..<simp_len {

            p := utils.bucket_array_get_ptr(&pc.simple_players, i);
            if !is_playing(p) do continue;
            if p.source == nil do continue;

            sample_rate_factor := f32(p.source.format.sample_rate)/f32(pc.output_format.sample_rate);
            source_frame_count := cast(int)math.round(f32(out_frame_count) * sample_rate_factor);
            source_sample_size := source_frame_count * frame_size;

            highest_frame_count := max(out_frame_count, source_frame_count);
            highest_sample_size := highest_frame_count * frame_size;

            ensure_mix_buffer_size(pc, highest_sample_size);

            now := get_player_seconds(p);


            // Need to zero this here, otherwise strange effects from mixing audio
            mem.set(pc.mix_buffer, 0, output_size);
            sample_source(p.source, p.current_frame_index, source_frame_count, pc.mix_buffer, pc.output_format, p.time_has_changed);
            p.time_has_changed = false;
            p.current_frame_index += source_frame_count;

            if pc.output_format != p.source.format {
                convert_frames(
                    pc.conversion_buffer,
                    out_frame_count,
                    pc.output_format,
                    pc.mix_buffer,
                    source_frame_count,
                    p.source.format,
                );
                mem.copy(pc.mix_buffer, pc.conversion_buffer, output_size);
            }

            mix_frames(output, pc.mix_buffer, out_frame_count, pc.output_format);
        }

        // #Incomplete
        // Mixed Player


    }, output_format, pc, dc);

    return pc;
}
destroy_playback_context :: proc(pc : ^Playback_Context) {

    using pc.dc;

    sync.lock(&pc.mtx);

    for i := utils.bucket_array_len(pc.simple_players)-1; i >= 0; i -= 1 {
        p := utils.bucket_array_get_ptr(&pc.simple_players, i);
        destroy_simple_player(p);
    }
    for i := utils.bucket_array_len(pc.mixed_players)-1; i >= 0; i -= 1 {
        p := utils.bucket_array_get_ptr(&pc.mixed_players, i);
        destroy_mixed_player(p);
    }

    utils.delete_bucket_array(&pc.simple_players);
    utils.delete_bucket_array(&pc.mixed_players);

    if pc.mix_buffer != nil do free(pc.mix_buffer);
    if pc.conversion_buffer != nil do free(pc.conversion_buffer);

    sync.unlock(&pc.mtx)

    free(pc);
} 

Mixer_Proc :: #type proc(player : ^Mixed_Player, output, input : rawptr, frame_count : int, source_index : int);

Player_State :: enum {
    PLAYING,
    STOPPED,
}

DEFAULT_MAX_STREAM_MEMORY :: 1024

Player_Base :: struct {
    pc : ^Playback_Context,

    // Max amounts of bytes to stream at a time.
    // Only relevant for when source is compressed.
    // If this is larger than source size, then it's
    // effectively just a pcm memory source.
    max_streamed_memory_in_bytes : int, 

    sw : time.Stopwatch,

    current_frame_index : int,

    duration : f32,
    max_frame : int,

    time_has_changed : bool,

    looping : bool,
}
Simple_Player :: struct {
    using base : Player_Base,

    source : ^Source,
}
Mixed_Player :: struct {
    using base : Player_Base,

    sources : [dynamic]^Source,
    mixer_proc : Mixer_Proc,
}

init_player_base :: proc(p : ^Player_Base, pc : ^Playback_Context, max_streamed_memory_in_bytes : int) {
    p.pc = pc;
    p.max_streamed_memory_in_bytes = max_streamed_memory_in_bytes;
}
make_simple_player :: proc(pc : ^Playback_Context, max_streamed_memory_in_bytes := DEFAULT_MAX_STREAM_MEMORY) -> ^Simple_Player {
    p := utils.bucket_array_append_empty(&pc.simple_players);
    init_player_base(p, pc, max_streamed_memory_in_bytes);

    return p;
}
make_mixed_player :: proc(pc : ^Playback_Context, max_streamed_memory_in_bytes := DEFAULT_MAX_STREAM_MEMORY) -> ^Mixed_Player {
    p := utils.bucket_array_append_empty(&pc.mixed_players);
    init_player_base(p, pc, max_streamed_memory_in_bytes);

    p.sources = make([dynamic]^Source);

    return p;
}

destroy_player_base :: proc(p : ^Player_Base) {
}
destroy_simple_player :: proc(p : ^Simple_Player)  {
    // #Sync #Racecond #Crash #Bug
    // We might start destroying here, then wait in context sample proc, and then try
    // to sample this player. :(
    sync.lock(&p.pc.mtx);
    
    destroy_player_base(p);

    for i := utils.bucket_array_len(p.pc.simple_players)-1; i >= 0; i -= 1 {
        if p == utils.bucket_array_get_ptr(&p.pc.simple_players, i) {
            sync.unlock(&p.pc.mtx);
            utils.bucket_array_unordered_remove(&p.pc.simple_players, i);
            return;
        }
    }
    sync.unlock(&p.pc.mtx);
}
destroy_mixed_player :: proc(p : ^Mixed_Player)  {
    sync.lock(&p.pc.mtx);
    
    
    destroy_player_base(p);
    
    delete(p.sources);

    for i := utils.bucket_array_len(p.pc.mixed_players)-1; i >= 0; i -= 1 {
        if p == utils.bucket_array_get_ptr(&p.pc.mixed_players, i) {
            sync.unlock(&p.pc.mtx);
            utils.bucket_array_unordered_remove(&p.pc.mixed_players, i);
            return;
        }
    }
    sync.unlock(&p.pc.mtx);
}

start_player :: proc(p : ^Player_Base) {
    time.stopwatch_start(&p.sw);
}
stop_player :: proc(p : ^Player_Base) {
    time.stopwatch_stop(&p.sw);
}
reset_player :: proc(p : ^Player_Base) {
    set_player(p, 0);
    time.stopwatch_start(&p.sw);
}
set_player :: proc(p : ^Player_Base, timestamp : f32) {
    timestamp := max(timestamp, 0.0);

    now := time.tick_now();

    p.sw._start_time._nsec = now._nsec - i64(timestamp*1000000000);
    p.sw._accumulation = time.tick_diff(p.sw._start_time, now);

    p.time_has_changed = true;

    factor := get_player_seconds(p) / p.duration;
    p.current_frame_index = int(factor * cast(f32)p.max_frame)
}
is_playing :: proc(p : ^Player_Base) -> bool {
    return p.sw.running;
}
get_player_seconds :: proc(p : ^Player_Base) -> f32 {
    now := cast(f32)time.duration_seconds(time.stopwatch_duration(p.sw));
    if p.looping && now > p.duration {
        now = math.mod_f32(now, p.duration);

        set_player(p, now);
    }
    return min(now, p.duration);
}
set_player_looping :: proc(p : ^Player_Base, looping : bool) {
    p.looping = looping;
}
is_player_looping :: proc(p : ^Player_Base) -> bool {
    return p.looping;
}

set_player_source :: proc(p : ^Simple_Player, src : ^Source) {
    // #Sync #Speed
    // We could sync this per source instead if that's any better
    sync.lock(&p.pc.mtx);
    defer sync.unlock(&p.pc.mtx);
    p.source = src;
    if src != nil {
        p.duration = p.source.duration_seconds;
        p.max_frame = src.total_frame_count;
    } else {
        p.duration = 0;
        p.max_frame = 0;
    }
}
add_player_source :: proc(p : ^Mixed_Player, src : ^Source) {
    // #Sync #Speed
    // We could sync this per source instead if that's any better
    sync.lock(&p.pc.mtx);
    defer sync.unlock(&p.pc.mtx);

    append(&p.sources, src);

    p.duration = 0;
    for s in p.sources {
        if s.duration_seconds > p.duration do p.duration = s.duration_seconds;
    }
}
remove_player_source :: proc(p : ^Mixed_Player, src : ^Source) {
    // #Sync #Speed
    // We could sync this per source instead if that's any better
    sync.lock(&p.pc.mtx);
    defer sync.unlock(&p.pc.mtx);

    for i in 0..<len(p.sources) {
        if p.sources[i] == src {
            unordered_remove(&p.sources, i);
            break;
        }
    }

    p.duration = 0;
    for s in p.sources {
        if s.duration_seconds > p.duration do p.duration = s.duration_seconds;
    }
}

Source_Kind :: enum {
    FILE, MEMORY
}
Compression_State :: enum {
    COMPRESSED, PCM,
}
Source :: struct {
    kind : Source_Kind,
    compression : Compression_State,

    format : Audio_Format,

    total_frame_count : int,
    duration_seconds : f32,

    using _ : struct #raw_union {
        file : os.Handle, // For pcm file sources
        using _ : struct {pcm : rawptr, pcm_size : int}, // For pcm memory sources
        ma_decoder : ma.decoder, // For compressed file or memory sources
    },
}

Pcm_Result :: struct {
    pcm : rawptr,
    frame_count : int,
    byte_size : int,
}
decode_memory_to_pcm :: proc(ptr : rawptr, size : int, out_format : Audio_Format) -> (result : Pcm_Result, ok : bool) {
    cfg := ma.decoder_config_init_default();

    cfg.format = format_kind_to_ma(out_format.kind);
    cfg.channels = cast(u32)out_format.channels;
    cfg.sampleRate = cast(u32)out_format.sample_rate;

    frame_count_c : u64;
    res := ma.decode_memory(ptr, cast(c.size_t)size, &cfg, &frame_count_c, &result.pcm);

    if res != .SUCCESS {
        ok = false;
        return;
    }

    
    result.frame_count = int(frame_count_c);
    result.byte_size = result.frame_count * out_format.channels * audio_format_sample_byte_size(out_format.kind);

    ok = true;

    return;
}
decode_file_to_pcm :: proc(path : string, out_format : Audio_Format) -> (result : Pcm_Result, ok : bool) {
    bytes, file_ok := os.read_entire_file(path);
    if !file_ok do return {}, false;

    return decode_memory_to_pcm(builtin.raw_data(bytes), len(bytes), out_format);
}
delete_pcm :: proc(pcm : Pcm_Result) {
    ma.free(pcm.pcm, nil);
}

// Takes pointer to either pcm or compressed memory to be decompressed on the fly
make_source_from_memory :: proc(ptr : rawptr, size : int, compression : Compression_State, sampled_format : Maybe(Audio_Format) = nil) -> (^Source, bool) {
    src : ^Source;

    switch compression {
        case .COMPRESSED: {
            cfg : ma.decoder_config;
            pcfg : ^ma.decoder_config
            if sampled_format != nil {
                src_format := sampled_format.(Audio_Format);
                cfg = ma.decoder_config_init_default();
                cfg.format = format_kind_to_ma(src_format.kind);
                cfg.sampleRate = cast(u32)src_format.sample_rate;
                cfg.channels = cast(u32)src_format.channels;
                pcfg = &cfg;
            }

            decoder : ma.decoder;
            result := ma.decoder_init_memory(ptr, cast(c.size_t)size, pcfg, &decoder);
        
            if result != .SUCCESS do return nil, false;

            src = new(Source);
            src.ma_decoder = decoder;

            src.format.kind = format_kind_from_ma(decoder.outputFormat);
            src.format.channels = cast(int)decoder.outputChannels;
            src.format.sample_rate = cast(int)decoder.outputSampleRate;
            frame_len : u64;
            res := ma.decoder_get_length_in_pcm_frames(&src.ma_decoder, &frame_len);
            assert(res == .SUCCESS);
            src.total_frame_count = cast(int)frame_len;
        }
        case .PCM: {

            if sampled_format == nil {
                log.error("When creating audio sources for raw PCM memory, you have to specify the format");
                return nil, false;
            }

            src = new(Source);
            src.pcm = ptr;
            src.pcm_size = size;
            src.format = sampled_format.(Audio_Format);
            src.total_frame_count = size / (src.format.channels * audio_format_sample_byte_size(src.format.kind));
        }
    }

    src.kind = .MEMORY;
    src.compression = compression;
    src.duration_seconds = f32(src.total_frame_count) / f32(src.format.sample_rate);

    return src, true;
}
// Streams memory from file, compressed or decompressed.
make_source_from_file :: proc(path : string, compression : Compression_State, sampled_format : Maybe(Audio_Format) = nil) -> (^Source, bool) {
    cpath := strings.clone_to_cstring(path, context.temp_allocator);

    src : ^Source;

    switch compression {
        case .COMPRESSED: {
            cfg : ma.decoder_config;
            pcfg : ^ma.decoder_config
            if sampled_format != nil {
                src_format := sampled_format.(Audio_Format);
                cfg = ma.decoder_config_init_default();
                cfg.format = format_kind_to_ma(src_format.kind);
                cfg.sampleRate = cast(u32)src_format.sample_rate;
                cfg.channels = cast(u32)src_format.channels;
                pcfg = &cfg;
            }

            src = new(Source);
            result := ma.decoder_init_file(cpath, pcfg, &src.ma_decoder);
        
            if result != .SUCCESS {
                free(src);
                return nil, false;
            }


            src.format.kind = format_kind_from_ma(src.ma_decoder.outputFormat);
            src.format.channels = cast(int)src.ma_decoder.outputChannels;
            src.format.sample_rate = cast(int)src.ma_decoder.outputSampleRate;
            frame_len : u64;
            res := ma.decoder_get_length_in_pcm_frames(&src.ma_decoder, &frame_len);
            assert(res == .SUCCESS);
            src.total_frame_count = cast(int)frame_len;
        }
        case .PCM: {

            if sampled_format == nil {
                log.error("When creating audio sources for a raw PCM file, you have to specify the format");
                return nil, false;
            }

            file, err := os.open(path);

            if err != os.ERROR_NONE do return nil, false;

            size_i64,_ := os.file_size(file);
            size := int(size_i64);

            src = new(Source);
            src.file = file;
            src.format = sampled_format.(Audio_Format);
            src.total_frame_count = size / (src.format.channels * audio_format_sample_byte_size(src.format.kind));
        }
    }

    src.kind = .FILE;
    src.compression = compression;
    src.duration_seconds = f32(src.total_frame_count) / f32(src.format.sample_rate);

    return src, true;
}

// If source is in use anywhere, this is underfined behaviour #UB
destroy_source :: proc(src : ^Source) {

    if src.compression == .COMPRESSED {
        ma.decoder_uninit(&src.ma_decoder);
    } else if src.kind == .MEMORY && src.compression == .PCM {
        /* Nothing to free, it just wrapped aroud raw pcm memory */
    } else if src.kind == .FILE && src.compression == .PCM {
        os.close(src.file);
    } else {
        panic("Unimplemented source kind/compression");
    }

    free(src);
}