package justvk

import "core:log"
import "core:fmt"
import "core:strings"
import "core:builtin"
import "core:mem"
import "core:slice"
import "core:reflect"
import "core:os"

import vk "vendor:vulkan"
import "vendor:glfw"

Queue_Family_Set :: struct {
    graphics  : Maybe(u32),
    present  : Maybe(u32),
    transfer  : Maybe(u32),
}
Graphics_Device :: struct {
    vk_physical_device           : vk.PhysicalDevice,
    props                        : vk.PhysicalDeviceProperties,
    memory_props                 : vk.PhysicalDeviceMemoryProperties,
    extension_properties         : []vk.ExtensionProperties,
    features                     : vk.PhysicalDeviceFeatures,
    queue_family_properties      : []vk.QueueFamilyProperties,
    queue_family_surface_support : []bool, // Index is the queue family index
    device_name                  : string,
    vendor_name                  : string,
    driver_version_raw           : u32,
    driver_version_string        : string,
    depth_format                 : vk.Format,    
}
Swap_Chain_Support_Details :: struct {
    capabilities : vk.SurfaceCapabilitiesKHR,
    formats : []vk.SurfaceFormatKHR,
    present_modes : []vk.PresentModeKHR,
};
Vendor_Kind :: enum {
    NVIDIA   = 0x10DE,
    AMD      = 0x1002,
    INTEL    = 0x8086,
    ARM      = 0x13B5,
    IMGTEC   = 0x1010,
    QUALCOMM = 0x5143,
}

get_vendor_name :: proc(vendor_id : Vendor_Kind) -> string {
    switch vendor_id {
        case .NVIDIA:   return "Nvidia";
        case .AMD :     return "AMD";
        case .INTEL:    return "Intel";
        case .ARM:      return "ARM";
        case .IMGTEC:   return "ImgTec";
        case .QUALCOMM: return "Qualcomm";
        case: return "UNKNOWN VENDOR";
    }
}
format_driver_version :: proc(vendor_id: Vendor_Kind, driver_version: u32) -> string {
    #partial switch vendor_id {
        case .NVIDIA:
            major := (driver_version >> 22) & 0x3FF;
            minor := (driver_version >> 14) & 0xFF;
            patch := (driver_version >> 6) & 0xFF;
            build := driver_version & 0x3F;
            return fmt.tprintf("%i.%i.%i build %i", major, minor, patch, build); // #tprint
        case .INTEL: {
            when ODIN_OS == .Windows {
                major := (driver_version >> 14);
                minor := driver_version & 0x3FFF;
                return fmt.tprintf("%i.%i", major, minor); // #tprint
            } else {
                fallthrough;
            }
        }
        case:
            return fmt.tprintf("%i", driver_version); // #tprint
    }
}

get_graphics_device_count :: proc() -> int {
    device_count : u32;
    vk.EnumeratePhysicalDevices(vk_instance, &device_count, nil);
    return cast(int)device_count;
}

get_all_graphics_devices :: proc(result : ^[]Graphics_Device, loc := #caller_location) {
    
    device_count := get_graphics_device_count();
    assert(len(result) >= device_count, "When getting all graphics devices the result slice needs to be at least the length of 'get_graphics_device_count()'", loc=loc);

    physical_devices := make([]vk.PhysicalDevice, device_count);
    defer delete(physical_devices);
    vk.EnumeratePhysicalDevices(vk_instance, cast(^u32)&device_count, slice_to_multi_ptr(physical_devices));

    for d, i in physical_devices {
        (result^)[i] = query_physical_device(physical_devices[i]);
    }
}

select_supported_format :: proc(formats : []vk.Format, tiling : vk.ImageTiling, features : vk.FormatFeatureFlags, gd : Graphics_Device) -> (format : vk.Format, ok : bool) {
    for format in formats {
        props : vk.FormatProperties;
        vk.GetPhysicalDeviceFormatProperties(gd.vk_physical_device, format, &props);
        if tiling == .LINEAR && (features & props.linearTilingFeatures) == features   do return format, true;
        if tiling == .OPTIMAL && (features & props.optimalTilingFeatures) == features do return format, true;
    }
    return .A1R5G5B5_UNORM_PACK16, false;
}

@(private)
query_physical_device :: proc(pdevice : vk.PhysicalDevice) -> Graphics_Device {
    gdevice : Graphics_Device;

    // #Leaks

    vk.GetPhysicalDeviceProperties(pdevice, &gdevice.props);
    vk.GetPhysicalDeviceMemoryProperties(pdevice, &gdevice.memory_props);
    vk.GetPhysicalDeviceFeatures(pdevice, &gdevice.features);

    ext_count : u32;
    vk.EnumerateDeviceExtensionProperties(pdevice, nil, &ext_count, nil);
    gdevice.extension_properties = make([]vk.ExtensionProperties, ext_count); // #Leak
    vk.EnumerateDeviceExtensionProperties(pdevice, nil, &ext_count, slice_to_multi_ptr(gdevice.extension_properties));

    queue_family_count : u32;
    vk.GetPhysicalDeviceQueueFamilyProperties(pdevice, &queue_family_count, nil);
    gdevice.queue_family_properties = make([]vk.QueueFamilyProperties, queue_family_count);
    vk.GetPhysicalDeviceQueueFamilyProperties(pdevice, &queue_family_count, slice_to_multi_ptr(gdevice.queue_family_properties));

    gdevice.queue_family_surface_support = make([]bool, queue_family_count);
    for i in 0..<queue_family_count {
        value32 : b32;
        vk.GetPhysicalDeviceSurfaceSupportKHR(pdevice, i, temp_surface, &value32);
        gdevice.queue_family_surface_support[i] = cast(bool)value32;
    }


    gdevice.vk_physical_device = pdevice;

    cstrlen :: proc(bytes : []byte) -> int{
        counter := 0;
        for b in bytes {
            if b == 0 do break;
            counter += 1;
        }
        return counter;
    }

    cstring_len := cstrlen(gdevice.props.deviceName[:]);
    gdevice.device_name = strings.clone(string(gdevice.props.deviceName[:cstring_len])); // #Leak
    gdevice.vendor_name = get_vendor_name(cast(Vendor_Kind)gdevice.props.vendorID);
    gdevice.driver_version_raw = gdevice.props.driverVersion;
    gdevice.driver_version_string  = format_driver_version(cast(Vendor_Kind)gdevice.props.vendorID, gdevice.driver_version_raw);

    depth_formats := []vk.Format {
        .D32_SFLOAT,
        .D32_SFLOAT_S8_UINT,
        .D24_UNORM_S8_UINT,
        .D16_UNORM,
        .D16_UNORM_S8_UINT,
    };

    ok : bool;
    gdevice.depth_format, ok = select_supported_format(depth_formats, .OPTIMAL, {.DEPTH_STENCIL_ATTACHMENT}, gdevice);
    if !ok do panic("No suitable depth format found for device");

    return gdevice;
}

rate_graphics_device :: proc(gdevice : Graphics_Device) -> int {
    score := 0;

    type_scores := map[vk.PhysicalDeviceType]int {
        .INTEGRATED_GPU = 500,
        .DISCRETE_GPU = 1000,
        .VIRTUAL_GPU = 100,
        .CPU = 50,
    };
    for arg in os.args {
        if arg == "-prefer-integrated" do type_scores[.INTEGRATED_GPU] += 1000;
        if arg == "-prefer-discrete" do type_scores[.DISCRETE_GPU] += 1000;
        if arg == "-prefer-virtual" do type_scores[.VIRTUAL_GPU] += 1000;
        if arg == "-prefer-cpu" do type_scores[.CPU] += 1000;

        if arg == "-force-integrated" do type_scores[.INTEGRATED_GPU] = 9999999999;
        if arg == "-force-discrete" do type_scores[.DISCRETE_GPU] = 9999999999;
        if arg == "-force-virtual" do type_scores[.VIRTUAL_GPU] = 9999999999;
        if arg == "-force-cpu" do type_scores[.CPU] = 9999999999;
    }

    score += type_scores[gdevice.props.deviceType];

    score += cast(int)gdevice.props.limits.maxImageDimension2D;

    if gdevice.features.sampleRateShading do score += 100;

    if !gdevice.features.geometryShader do return 0;

    return score;
}

check_graphics_device_extensions :: proc(gdevice : Graphics_Device, extensions : []cstring) -> bool {

    all_present := true;
    for required in extensions {
        match := false;
        for avail in gdevice.extension_properties {
            avail_name := vk_string_to_string(avail.extensionName);
            req_name := strings.clone_from_cstring(required);
            defer delete(avail_name);
            defer delete(req_name);
            if avail_name == req_name {
                match = true;
                break;
            }
        }
        if !match {
            all_present = false;
            log.errorf("Missing graphics device extension '%s'", required);
        }
    }

    return all_present;
}

check_physical_device_features :: proc(gdevice : Graphics_Device, required_features : vk.PhysicalDeviceFeatures) -> bool {
    log.debug("Querying Required features: ");

    struct_info := type_info_of(vk.PhysicalDeviceFeatures).variant.(reflect.Type_Info_Named).base.variant.(reflect.Type_Info_Struct);

    all_present := true;
    for name,i in struct_info.names {
        required := reflect.struct_field_value(required_features, reflect.struct_field_by_name(vk.PhysicalDeviceFeatures, name)).(b32);
        existing := reflect.struct_field_value(gdevice.features, reflect.struct_field_by_name(vk.PhysicalDeviceFeatures, name)).(b32);


        if required && !existing {
            log.debug("\t", name, " ... MISSING");
            all_present = false;
        } else if required && existing {
            log.debug("\t", name, " ... OK");
        }
    }
    return all_present;
}

get_swap_chain_support_details :: proc(gdevice : Graphics_Device, surface : vk.SurfaceKHR) -> (details : Swap_Chain_Support_Details) {

    pdevice := gdevice.vk_physical_device;
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(pdevice, surface, &details.capabilities);

    if surface != 0 {
        fmt_count : u32;
        vk.GetPhysicalDeviceSurfaceFormatsKHR(pdevice, surface, &fmt_count, nil);
        if (fmt_count != 0) {
            details.formats = make([]vk.SurfaceFormatKHR, fmt_count);
            vk.GetPhysicalDeviceSurfaceFormatsKHR(pdevice, surface, &fmt_count, slice_to_multi_ptr(details.formats));
        }
    }

    present_count : u32;
    vk.GetPhysicalDeviceSurfacePresentModesKHR(pdevice, surface, &present_count, nil);

    if (present_count != 0) {
        details.present_modes = make([]vk.PresentModeKHR, present_count);
        vk.GetPhysicalDeviceSurfacePresentModesKHR(pdevice, surface, &present_count, slice_to_multi_ptr(details.present_modes));
    }

    return;
}

get_most_suitable_graphics_device :: proc() -> (gdevice : Graphics_Device, any_suitable : bool) {
    
    log.debug("Querying available devices");
    device_count := get_graphics_device_count();
    if device_count <= 0 do return {}, false;
    all_graphics_devices := make([]Graphics_Device, device_count);
    get_all_graphics_devices(&all_graphics_devices);

    top_device := all_graphics_devices[0];
    top_score := rate_graphics_device(top_device);

    log.debug("\t", top_device.device_name);
    for i in 1..<len(all_graphics_devices) {
        candidate := all_graphics_devices[i];
        log.debug("\t", candidate.device_name);
        if candidate_score := rate_graphics_device(candidate); candidate_score > top_score {
            top_device = candidate;
            top_score = candidate_score;
        }
    }

    if top_score == 0 do return {}, false;

    return top_device, true;
}

get_format_props :: proc(format : vk.Format, gdevice : Graphics_Device) -> vk.FormatProperties {
    props : vk.FormatProperties;
    vk.GetPhysicalDeviceFormatProperties(gdevice.vk_physical_device, format, &props);
    return props;
}