package audio

import ma "vendor:miniaudio"

import "core:log"
import "core:c"
import "core:slice"
import "core:strings"


Audio_Device :: struct {
    id : ma.device_id,
    is_system_default : bool,
    name : string,
    format_mask : Audio_Format_Type_Mask,
    formats : []Audio_Format,
}

ma_context : ma.context_type;

devices : []Audio_Device;
default_device : Maybe(Audio_Device);

@(require_results)
expect_ma_success :: proc(result : ma.result, fail_msg := "") -> bool {
    if result != .SUCCESS {
        if fail_msg != "" {
            log.errorf("Miniaudio error '%s': %s", result, fail_msg);
            return false;
        } else {
            log.errorf("Miniaudio error '%s'", result);
            return false;
        }
    }
    return true;
}

query_audio_device :: proc(ma_info : ma.device_info) -> Audio_Device {

    ma_info := ma_info;
    ma.context_get_device_info(&ma_context, .playback, &ma_info.id, &ma_info);

    ad : Audio_Device;

    ad.id = ma_info.id;
    ad.is_system_default = cast(bool)ma_info.isDefault;


    formats := make([dynamic]Audio_Format);
    for i in 0..<cast(int)ma_info.nativeDataFormatCount {
        ma_format := ma_info.nativeDataFormats[i];

        format_kind : Audio_Format_Type_Flag;

        switch ma_format.format {
            case .u8:  format_kind = .U8;
            case .s16: format_kind = .S16;
            case .s24: format_kind = .S24;
            case .s32: format_kind = .S32;
            case .f32: format_kind = .F32;
            case .unknown: format_kind = .UNKNOWN;
        }

        ad.format_mask |= {format_kind};

        format : Audio_Format;
        format.kind = format_kind;
        format.channels = cast(int)ma_format.channels;
        format.sample_rate = cast(int)ma_format.sampleRate;

        append(&formats, format);
    }

    ad.formats = formats[:];

    name_raw := ma_info.name;
    name_cstring := cstring(cast([^]c.char)slice.as_ptr(name_raw[:]));
    ad.name = strings.clone_from_cstring(name_cstring);

    return ad;
} 