package audio

import ma "vendor:miniaudio"

import "core:log"
import "core:fmt"

Device_Context :: struct {
    device : Audio_Device,
    ma_device : ma.device,
    format : Audio_Format,
    sample_callback : Device_Sample_Callback_Proc,
}

Device_Sample_Callback_Proc :: #type proc(dc : ^Device_Context, output, input : rawptr, frame_count : int);

set_target_device_context :: proc(dc : ^Device_Context) {
    target_dc = dc;
}
get_target_device_context :: proc() -> ^Device_Context {
    return target_dc;
}

format_kind_from_ma :: proc(fmt : ma.format) -> Audio_Format_Type_Flag {
    switch fmt {
        case .f32: return .F32;
        case .s32: return .S32;
        case .s24: return .S24;
        case .s16: return .S16;
        case .u8: return .U8;
        case .unknown: return .UNKNOWN;
    }
    panic("");
}
format_kind_to_ma :: proc(fmt : Audio_Format_Type_Flag) -> ma.format {
    switch fmt {
        case .F32: return .f32;
        case .S32: return .s32;
        case .S24: return .s24;
        case .S16: return .s16;
        case .U8: return .u8;
        case .UNKNOWN: return .unknown;
    }
    panic("");
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

make_device_context :: proc(sample_callback : Device_Sample_Callback_Proc, specific_device : Maybe(Audio_Device) = nil, specific_format : Maybe(Audio_Format) = nil) -> ^Device_Context {
    dc := new (Device_Context);
    dc.sample_callback = sample_callback;

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
        dc := cast(^Device_Context)ma_device.pUserData;
        dc.sample_callback(dc, output, input, cast(int)frame_count);
    }

    ok := expect_ma_success(ma.device_init(&ma_context, &cfg, &dc.ma_device), "Failed creating ma device");
    assert(ok);

    return dc;
}

destroy_device_context :: proc(using dc : ^Device_Context) {
    ma.device_uninit(&ma_device);
    free(dc);
}
destroy_target_device_context :: proc() {
    destroy_device_context(target_dc);
    target_dc = nil;
}