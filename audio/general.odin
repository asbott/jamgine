package audio

import ma "vendor:miniaudio"

import "core:log"
import "core:slice"
import "core:c"

Audio_Format_Type_Flag :: enum {
    U8, S16, S24, S32, F32, UNKNOWN,
}
Audio_Format_Type_Mask :: bit_set[Audio_Format_Type_Flag];
Audio_Format :: struct {
    kind : Audio_Format_Type_Flag,
    channels : int,
    sample_rate : int,
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