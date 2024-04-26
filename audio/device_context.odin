package audio

import "jamgine:utils"

import ma "vendor:miniaudio"

import "core:log"
import "core:fmt"
import "core:slice"
import "core:mem"
import "core:runtime"
import "core:sync"
import "core:math"
import "core:time"

Device_Context :: struct {
    device : Audio_Device,
    ma_device : ma.device,
    format : Audio_Format,

    last_sample_duration_seconds : f32,

    next_sampler_id : int,

    mtx : sync.Mutex,

    // Result of these are added together
    sample_callbacks : [dynamic]struct {
        procedure : Device_Sample_Callback_Proc,
        temp_output_buffer : rawptr, // #Memory
        conversion_buffer : rawptr, // #Memory
        temp_output_buffer_size : int,
        output_format : Audio_Format,
        user_data : rawptr,
        id : int,
    },
}

Device_Sample_Callback_Proc :: #type proc(dc : ^Device_Context, output, input : rawptr, frame_count : int, user_data : rawptr);

set_target_device_context :: proc(dc : ^Device_Context) {
    target_dc = dc;
}
get_target_device_context :: proc() -> ^Device_Context {
    return target_dc;
}

get_device_format :: proc(dc := target_dc) -> Audio_Format  {
    return dc.format;
}

make_audio_format :: proc(kind : Audio_Format_Type_Flag, channels : int, sample_rate : int) -> Audio_Format {
    return {kind, channels, sample_rate}
}

add_sampler :: proc(callback : Device_Sample_Callback_Proc, output_format : Audio_Format, user_data : rawptr, using dc := target_dc) {
    sync.lock(&mtx);
    defer sync.unlock(&mtx);
    append(&sample_callbacks, type_of(sample_callbacks[0]) {
        procedure=callback,
        output_format=output_format,
        user_data=user_data,
        id=dc.next_sampler_id,
    });

    dc.next_sampler_id += 1;
}
remove_sampler :: proc(id : int, using dc := target_dc) {
    sync.lock(&mtx);
    defer sync.unlock(&mtx);
    for i in 0..<len(sample_callbacks) {
        sampler := sample_callbacks[i];
        if sampler.id == id  {
            unordered_remove(&sample_callbacks, i);
            break;
        }
    }
}

pick_format :: proc(device : Audio_Device) -> Maybe(Audio_Format) {
    best_score : int;
    best_match : Audio_Format;
    for format in device.formats {
        score : int;
        switch format.kind {
            case .F32: score += 1000;
            case .S32: score += 500;
            case .S16: score += 200;
            case .S24: score += 100;
            case .U8: score += 10;
            case .UNKNOWN: score -= 9999999999;
        }
        
        score += format.channels;
        score += int((f32(format.sample_rate) / 48000) * 5);

        if score > best_score {
            best_match = format;
            best_score = score;
        }
    }
    
    if best_score <= 0 do return nil;

    return best_match;
}

zero_frames :: proc(output : rawptr, )

make_device_context :: proc(specific_device : Maybe(Audio_Device) = nil, specific_format : Maybe(Audio_Format) = nil) -> ^Device_Context {
    dc := new (Device_Context);
    dc.sample_callbacks = make(type_of(dc.sample_callbacks));

    device : Audio_Device;
    format : Audio_Format;

    if (specific_device != nil) {
        device = device;
    } else {
        assert(default_device != nil, "No default device reported; you must pass a specific device to make_device_context");
        device = default_device.(Audio_Device);
    }

    log.info("Making a audio device context targetting:", device.name);

    if specific_format != nil {
        format = specific_format.(Audio_Format);
    } else {
        picked_format := pick_format(device);
        assert(picked_format != nil, "No suitable format found for targetted device");
        format = picked_format.(Audio_Format);
    }

    log.info("Picked audio format", format);

    match : bool;
    for available_format in device.formats {
        if available_format == format {
            match = true;
            break;
        }
    }
    assert(match, "Format passed to audio.make_device_context must be from the passed device.formats");

    dc.device = device;
    dc.format = format;

    cfg := ma.device_config_init(.playback);
    cfg.playback.format = format_kind_to_ma(format.kind);
    cfg.playback.channels = cast(u32)format.channels;
    cfg.sampleRate = cast(u32)format.sample_rate;
    cfg.pUserData = dc;
    cfg.dataCallback = proc "c" (ma_device: ^ma.device, output, input: rawptr, frame_count: u32) {
        context = runtime.default_context();

        dc := cast(^Device_Context)ma_device.pUserData;

        sw : time.Stopwatch;
        time.stopwatch_start(&sw);

        defer dc.last_sample_duration_seconds = cast(f32)time.duration_seconds(time.stopwatch_duration(sw));


        sync.lock(&dc.mtx);
        defer sync.unlock(&dc.mtx);

        out_frame_count := int(frame_count);

        comp_size := audio_format_sample_byte_size(dc.format.kind);
        frame_size := comp_size * dc.format.channels;
        output_size := out_frame_count * frame_size;


        // #Speed
        // We could avoid this when we know we have at least one sampler that will write to it
        // and just make the first sampler set rather than add.
        mem.set(output, 0, output_size);


        for _,i in dc.sample_callbacks {
            sample_callback := & dc.sample_callbacks[i];

            samp_format := sample_callback.output_format;

            sample_rate_factor := f32(samp_format.sample_rate)/f32(dc.format.sample_rate);
            sampler_frame_count := cast(int)math.round(f32(out_frame_count) * sample_rate_factor);
            sample_size := sampler_frame_count * frame_size;

            highest_frame_count := max(out_frame_count, sampler_frame_count);
            highest_sample_size := highest_frame_count * frame_size;
            
            if highest_sample_size > sample_callback.temp_output_buffer_size {
                // #Memory
                new_size := utils.align_next_pow2(cast(int)highest_sample_size);

                if sample_callback.temp_output_buffer != nil {
                    free(sample_callback.temp_output_buffer);
                    free(sample_callback.conversion_buffer);
                }

                alloc_err : mem.Allocator_Error;
                sample_callback.temp_output_buffer,alloc_err = mem.alloc(new_size);
                assert(alloc_err == .None);
                sample_callback.conversion_buffer,alloc_err = mem.alloc(new_size);
                assert(alloc_err == .None);
                sample_callback.temp_output_buffer_size = new_size;
            }

            mem.set(sample_callback.temp_output_buffer, 0, output_size);


            sample_callback.procedure(dc, sample_callback.temp_output_buffer, input, cast(int)sampler_frame_count, sample_callback.user_data);

            if sample_callback.output_format != dc.format {
                // #Speed
                // So much copying
                convert_frames(
                    sample_callback.conversion_buffer, 
                    out_frame_count,
                    dc.format,
                    sample_callback.temp_output_buffer, 
                    sampler_frame_count,
                    samp_format,
                );
                mem.copy(sample_callback.temp_output_buffer, sample_callback.conversion_buffer, output_size)
            }

            mix_frames(output, sample_callback.temp_output_buffer, out_frame_count, dc.format);
        }

        // #Speed
        get_sample_norm :: proc(sample_raw : rawptr, format : Audio_Format) -> f32 {
            as :: proc(p : rawptr, $T : typeid) -> T {
                return (cast(^T)p)^;
            }
            switch format.kind {
                case .F32: return as(sample_raw, f32);
                case .S32: return f32(f32(as(sample_raw, s32) + S32_MIN) / f32(S32_MAX + S32_MIN)) * 2 - 1;
                case .S24: 
                    as_int : int;
                    mem.copy(&as_int, sample_raw, 3);

                    as_int <<= 40; 
                    as_int >>= 40; 
                    return f32(f32(as_int + S24_MIN) / f32(S24_MAX + S24_MIN)) * 2 - 1;
                case .S16: return f32(f32(as(sample_raw, s16) + S16_MIN) / f32(S16_MAX + S16_MIN)) * 2 - 1;
                case .U8: return f32(f32(as(sample_raw, u8)) / f32(U8_MAX)) * 2 - 1;
                case .UNKNOWN: return 0;
            }
            return 0;
        }
        set_sample_norm :: proc(sample_raw : rawptr, format : Audio_Format, norm : f32) {
            switch format.kind {
                case .F32:
                    (cast(^f32)sample_raw)^ = norm;
                case .S32:
                    (cast(^s32)sample_raw)^ = s32(norm * 0.5 * f32(S32_MAX - S32_MIN) + f32(S32_MIN + S32_MAX) * 0.5);
                case .S24:
                    int24 := s32(norm * 0.5 * f32(S24_MAX - S24_MIN) + f32(S24_MIN + S24_MAX) * 0.5);
                    mem.copy(sample_raw, &int24, 3);
                case .S16:
                    (cast(^s16)sample_raw)^ = s16(norm * 0.5 * f32(S16_MAX - S16_MIN) + f32(S16_MIN + S16_MAX) * 0.5);
                case .U8:
                    (cast(^u8)sample_raw)^ = u8((norm + 1.0) * 0.5 * f32(U8_MAX));
                case .UNKNOWN:
                    return;
            }
        }

        // I tried some kind of normalization but not sure if it does anything ?
        /*PEAK :: 0.01;
        peak_amplitude : f32 = 0.0;

        // #Speed
        for i in 0..<out_frame_count {
            for c in 0..<dc.format.channels {
                samp := get_sample_norm(mem.ptr_offset(cast(^byte)output, i * frame_size + c * comp_size), dc.format);

                if abs(samp) > peak_amplitude do peak_amplitude = samp;
            }
        }

        if peak_amplitude != 0.0 {
            norm_factor := PEAK / peak_amplitude;

            for i in 0..<out_frame_count {
                for c in 0..<dc.format.channels {
                    samp_ptr := mem.ptr_offset(cast(^byte)output, i * frame_size + c * comp_size);
                    samp := get_sample_norm(samp_ptr, dc.format);
    
                    set_sample_norm(samp_ptr, dc.format, samp);
                }
            }
        }*/
    }

    ok := expect_ma_success(ma.device_init(&ma_context, &cfg, &dc.ma_device), "Failed creating ma device");
    assert(ok);

    ok = expect_ma_success(ma.device_start(&dc.ma_device));
    assert(ok);

    return dc;
}

destroy_device_context :: proc(using dc : ^Device_Context) {
    sync.lock(&mtx);
    for callback in dc.sample_callbacks {
        if callback.temp_output_buffer != nil do free(callback.temp_output_buffer);
        if callback.conversion_buffer != nil do free(callback.conversion_buffer);
    }
    delete(dc.sample_callbacks);
    ma.device_uninit(&ma_device);
    sync.unlock(&mtx);
    free(dc);
}
destroy_target_device_context :: proc() {
    destroy_device_context(target_dc);
    target_dc = nil;
}