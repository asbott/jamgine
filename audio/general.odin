package audio

import ma "vendor:miniaudio"

import "core:log"
import "core:slice"
import "core:c"

import "core:mem"
import "core:fmt"
import "core:math"

Audio_Format_Type_Flag :: enum {
    U8, S16, S24, S32, F32, UNKNOWN,
}
Audio_Format_Type_Mask :: bit_set[Audio_Format_Type_Flag];
Audio_Format :: struct {
    kind : Audio_Format_Type_Flag,
    channels : int,
    sample_rate : int,
}

s8 :: i8;
s16 :: i16;
s32 :: i32;

U8_MAX :: 255;
S16_MIN :: -32768;
S16_MAX :: 32767;
S24_MIN :: -8388608;
S24_MAX :: 8388607;
S32_MIN :: -2147483648;
S32_MAX :: 2147483647;



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
audio_format_sample_byte_size :: proc(format : Audio_Format_Type_Flag) -> int {
    switch format {
        case .F32: return 4;
        case .S32: return 4;
        case .S24: return 3;
        case .S16: return 2;
        case .U8: return 1;
        case .UNKNOWN: return 0;
    }
    panic("");
}

mix_frames :: proc(dst, src : rawptr, frame_count : int, format : Audio_Format) {
    comp_size := audio_format_sample_byte_size(format.kind);
    frame_size := comp_size * format.channels;
    output_size := int(frame_count) * frame_size;
    // #Speed #Simd
    // #Incomplete
    // QUality:
    // - Dithering
    // - Clipping. Dynamic Range Compression?
    for frame in 0..<cast(int)frame_count {
        
        for c in 0..<format.channels {

            src_sample : rawptr = mem.ptr_offset(cast(^byte)src, frame * frame_size + c * comp_size);
            dst_sample : rawptr = mem.ptr_offset(cast(^byte)dst, frame * frame_size + c * comp_size);

            switch (format.kind) {
                case .F32: 
                    (cast(^f32)dst_sample)^ = ((cast(^f32)dst_sample)^ + (cast(^f32)src_sample)^);
                case .S32: 
                    dst_int := int((cast(^s32)dst_sample)^);
                    src_int := int((cast(^s32)src_sample)^);
                    (cast(^s32)dst_sample)^ = cast(s32)clamp(dst_int + src_int, S32_MIN, S32_MAX);
                case .S24: 
                    src_int : int;
                    mem.copy(&src_int, src_sample, 3);

                    src_int <<= 40; 
                    src_int >>= 40; 

                    dst_int : int;
                    mem.copy(&dst_int, dst_sample, 3); 

                    dst_int <<= 40;
                    dst_int >>= 40;

                    sum := clamp(src_int + dst_int, S24_MIN, S24_MAX);
                    mem.copy(dst_sample, &sum, 3);
                case .S16: 
                    dst_int := int((cast(^s16)dst_sample)^);
                    src_int := int((cast(^s16)src_sample)^);
                    (cast(^s16)dst_sample)^ = cast(s16)clamp(dst_int + src_int, S16_MIN, S16_MAX);
                case .U8:  
                    dst_int := int((cast(^u8)dst_sample)^);
                    src_int := int((cast(^u8)src_sample)^);
                    (cast(^u8)dst_sample)^ = cast(u8)clamp(dst_int + src_int, 0, int(U8_MAX));
                case .UNKNOWN: break;
            }
        }
    }
}
convert_frames :: proc(dst : rawptr, dst_frame_count : int, dst_format : Audio_Format, src : rawptr, src_frame_count : int, src_format : Audio_Format) {
    // This will suck to implement when we move away from miniaudio :(
    // #Incomplete #Bad 
    // ma by default uses linear interpolation for resampling, resulting in terrible audio.
    // You should probably just always decode audio to have same sample rate as the device
    // but I think we should have the option to convert if necessary.
    ma.convert_frames(
        dst, 
        cast(u64)dst_frame_count,
        format_kind_to_ma(dst_format.kind),
        cast(u32)dst_format.channels,
        cast(u32)dst_format.sample_rate,
        src, 
        cast(u64)src_frame_count,
        format_kind_to_ma(src_format.kind),
        cast(u32)src_format.channels,
        cast(u32)src_format.sample_rate,
    );
    
}

target_dc : ^Device_Context;

init :: proc() -> bool {
    expect_ma_success(ma.context_init(nil, 0, nil, &ma_context), "Failed context init") or_return;

    device_infos_ptr : [^]ma.device_info;
    device_count : c.uint;
    expect_ma_success(ma.context_get_devices(&ma_context, &device_infos_ptr, &device_count, nil, nil), "Failed device query") or_return;

    device_infos := slice.from_ptr(device_infos_ptr, cast(int)device_count);

    devices = make([]Audio_Device, len(device_infos));

    log.debug("Querying audio playback devices...");
    for info,i in device_infos {
        devices[i] = query_audio_device(info);
        log.debug("", devices[i].name);
        log.debug("\tFormat mask: ", devices[i].format_mask);
        log.debug("\tFormats:");
        for fmt in devices[i].formats {
            log.debug("\t\t", fmt);
        }

        if devices[i].is_system_default {
            if default_device != nil do log.warn("Multiple default playback devices detected?");
            default_device = devices[i];
        }
    }

    if default_device != nil {
        log.info("Default audio playback device is", default_device.(Audio_Device).name);
    }

    return true;
}

shutdown :: proc() {

    for device in devices {
        delete(device.name);
        delete(device.formats);
    }

    ma.context_uninit(&ma_context);
}