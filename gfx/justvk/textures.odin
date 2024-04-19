package justvk

import vk "vendor:vulkan"

import "core:mem"
import "core:log"
import "core:fmt"

Texture_Format :: enum {
    SR, SRG, SRGB, SRGBA,

    R_UNORM, RG_UNORM, RGB_UNORM, RGBA_UNORM,

    R, RG, RGB,
    BGR, RGBA, BGRA,

    R_HDR, RG_HDR, RGB_HDR,
    RGBA_HDR,
}

Texture_Usage_Flag :: enum {
    READ, WRITE, DRAW, SAMPLE
}
Texture_Usage_Mask :: bit_set[Texture_Usage_Flag];
Sampler_Settings :: struct {
    mag_filter, min_filter : vk.Filter,
    mipmap_enable : bool,
    mipmap_mode : vk.SamplerMipmapMode,
    wrap_u, wrap_v, wrap_w : vk.SamplerAddressMode,
}
Texture :: struct {
    dc : ^Device_Context,
    vk_image : vk.Image,
    vk_image_view : vk.ImageView,
    width, height, channels : int,
    format : Texture_Format,
    usage_mask : Texture_Usage_Mask,
    sampler : vk.Sampler,
    desc_info : vk.DescriptorImageInfo,
    image_memory : Device_Memory_Handle, // 0 for swap chain images
}

DEFAULT_SAMPLER_SETTINGS :: Sampler_Settings {
    mag_filter=.LINEAR, 
    min_filter=.LINEAR, 
    mipmap_enable=false, 
    mipmap_mode=.LINEAR, 
    wrap_u=.CLAMP_TO_EDGE, 
    wrap_v=.CLAMP_TO_EDGE, 
    wrap_w=.CLAMP_TO_EDGE,
}

texture_format_to_vk_format :: proc(format : Texture_Format) -> vk.Format {
    switch format {
        case .SR: return .R8_SRGB;
        case .SRG: return .R8G8_SRGB;
        case .SRGB: return .R8G8B8_SRGB;
        case .SRGBA: return .R8G8B8A8_SRGB;

        case .R_UNORM: return .R8_UNORM;
        case .RG_UNORM: return .R8G8_UNORM;
        case .RGB_UNORM: return .R8G8B8_UNORM;
        case .RGBA_UNORM: return .R8G8B8A8_UNORM;

        case .R: return .R8_SINT;
        case .RG: return .R8G8_SINT;
        case .RGB: return .R8G8B8_SINT;
        case .BGR: return .B8G8R8_SINT;
        case .RGBA: return .R8G8B8A8_SINT;
        case .BGRA: return .B8G8R8A8_SINT;

        case .R_HDR: return .R32_SFLOAT;
        case .RG_HDR: return .R32G32_SFLOAT;
        case .RGB_HDR: return .R32G32B32_SFLOAT;
        case .RGBA_HDR: return .R32G32B32A32_SFLOAT;
    }
    panic("unhandled format");
}
get_texture_format_component_size :: proc(format : Texture_Format) -> int {
    switch format {
        case .R, .RG, .RGB, .BGR, .RGBA, .BGRA, .SR, .SRG, .SRGB, .SRGBA, .R_UNORM, .RG_UNORM, .RGB_UNORM, .RGBA_UNORM:
            return 1;
        case .R_HDR, .RG_HDR, .RGB_HDR, .RGBA_HDR:
            return 4;
    }
    panic("");
}
// #Incomplete
count_vk_format_channels :: proc(format : vk.Format) -> int {
    #partial switch format {
        case .R8_SINT, .R8_UINT, .R8_SNORM, .R8_UNORM, .R8_SRGB, .R8_SSCALED, .R8_USCALED,
             .R16_SFLOAT, .R16_SINT, .R16_UINT, .R16_SNORM, .R16_UNORM, .R16_SSCALED, .R16_USCALED,
             .R32_SFLOAT, .R32_SINT, .R32_UINT,
             .R64_SFLOAT, .R64_SINT, .R64_UINT,
             .D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D16_UNORM:
            return 1;
        case .R8G8_SINT, .R8G8_UINT, .R8G8_SNORM, .R8G8_UNORM, .R8G8_SRGB, .R8G8_SSCALED, .R8G8_USCALED,
             .R16G16_SFLOAT, .R16G16_SINT, .R16G16_UINT, .R16G16_SNORM, .R16G16_UNORM, .R16G16_SSCALED, .R16G16_USCALED,
             .R32G32_SFLOAT, .R32G32_SINT, .R32G32_UINT,
             .R64G64_SFLOAT, .R64G64_SINT, .R64G64_UINT:
            return 2;
        case .R8G8B8_SINT, .R8G8B8_UINT, .R8G8B8_SNORM, .R8G8B8_UNORM, .R8G8B8_SRGB, .R8G8B8_SSCALED, .R8G8B8_USCALED,
             .B8G8R8_SINT, .B8G8R8_UINT, .B8G8R8_SNORM, .B8G8R8_UNORM, .B8G8R8_SRGB, .B8G8R8_SSCALED, .B8G8R8_USCALED,
             .R16G16B16_SFLOAT, .R16G16B16_SINT, .R16G16B16_UINT, .R16G16B16_SNORM, .R16G16B16_UNORM, .R16G16B16_SSCALED, .R16G16B16_USCALED,
             .R32G32B32_SFLOAT, .R32G32B32_SINT, .R32G32B32_UINT,
             .R64G64B64_SFLOAT, .R64G64B64_SINT, .R64G64B64_UINT:
           return 3;
        case .R8G8B8A8_SINT, .R8G8B8A8_UINT, .R8G8B8A8_SNORM, .R8G8B8A8_UNORM, .R8G8B8A8_SRGB, .R8G8B8A8_SSCALED, .R8G8B8A8_USCALED,
             .B8G8R8A8_SINT, .B8G8R8A8_UINT, .B8G8R8A8_SNORM, .B8G8R8A8_UNORM, .B8G8R8A8_SRGB, .B8G8R8A8_SSCALED, .B8G8R8A8_USCALED,
             .R16G16B16A16_SFLOAT, .R16G16B16A16_SINT, .R16G16B16A16_UINT, .R16G16B16A16_SNORM, .R16G16B16A16_UNORM, .R16G16B16A16_SSCALED, .R16G16B16A16_USCALED,
             .R32G32B32A32_SFLOAT, .R32G32B32A32_SINT, .R32G32B32A32_UINT,
             .R64G64B64A64_SFLOAT, .R64G64B64A64_SINT, .R64G64B64A64_UINT:
           return 4;
        case: panic(fmt.tprint("Unhandled format", format));
    }
}
count_texture_format_channels :: proc(format : Texture_Format) -> int {
    switch format {
        case .SR, .R, .R_HDR, .R_UNORM:         return 1;
        case .SRG, .RG, .RG_HDR, .RG_UNORM:                return 2;
        case .SRGB, .RGB, .BGR, .RGB_HDR, .RGB_UNORM:      return 3;
        case .SRGBA, .RGBA, .BGRA, .RGBA_HDR, .RGBA_UNORM: return 4;
    }
    panic("unhandled format");
}
count_channels :: proc {
    count_vk_format_channels,
    count_texture_format_channels,
}

make_texture :: proc(width, height : int, data : rawptr, format : Texture_Format, usage := Texture_Usage_Mask{.SAMPLE, .WRITE}, sampler := DEFAULT_SAMPLER_SETTINGS, using dc := target_dc) -> Texture {
    texture : Texture;
    init_texture(&texture, width, height, data, format, usage, sampler, dc=dc);
    return texture;
}
make_texture_from_vk_image :: proc(image : vk.Image, width, height : int, format : Texture_Format, usage : Texture_Usage_Mask, sampler := DEFAULT_SAMPLER_SETTINGS, using dc := target_dc) -> Texture {
    texture : Texture;
    init_texture_from_vk_image(&texture, image, width, height, format, usage, sampler, dc=dc);
    return texture;
}
init_texture :: proc(texture : ^Texture, width, height : int, data : rawptr, format : Texture_Format, usage := Texture_Usage_Mask{.SAMPLE, .WRITE}, sampler := DEFAULT_SAMPLER_SETTINGS, using dc := target_dc) {
    assert(width > 0 && height > 0, "When creating a sampled texture the widht and height must be > 0");

    texture.dc = dc;
    texture.width = width;
    texture.height = height;
    texture.format = format;
    texture.channels = count_channels(format);
    texture.usage_mask = usage;

    comp_size := get_texture_format_component_size(format);
    size := cast(vk.DeviceSize)(width * height * texture.channels * comp_size);

    image_info : vk.ImageCreateInfo;
    image_info.sType = .IMAGE_CREATE_INFO;
    image_info.imageType = .D2;
    image_info.extent.width = cast(u32)texture.width;
    image_info.extent.height = cast(u32)texture.height;
    
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = texture_format_to_vk_format(format);
    image_info.tiling = .OPTIMAL;
    image_info.initialLayout = .UNDEFINED;
    vk_usage_mask : vk.ImageUsageFlags = {};
    if .READ   in usage do vk_usage_mask |= {.TRANSFER_SRC};
    if .WRITE  in usage do vk_usage_mask |= {.TRANSFER_DST};
    if .DRAW   in usage do vk_usage_mask |= {.COLOR_ATTACHMENT};
    if .SAMPLE in usage do vk_usage_mask |= {.SAMPLED};

    image_info.usage = vk_usage_mask;
    image_info.sharingMode = .EXCLUSIVE;
    image_info.samples = {._1};
    image_info.flags = {};
    if vk.CreateImage(vk_device, &image_info, nil, &texture.vk_image) != .SUCCESS {
        panic("Failed to create image");
    }

    texture.image_memory = request_and_bind_device_memory(texture.vk_image, {.DEVICE_LOCAL}, texture.dc);

    if data != nil {
        if .WRITE not_in texture.usage_mask {
            log.errorf("Non-nil data was passed to init_texture/make_texture even though usage bit .WRITE was not set in usage mask. %s", texture.usage_mask);
        }
        transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .UNDEFINED, .TRANSFER_DST_OPTIMAL, {.COLOR}, dc=dc);
        if data != nil do transfer_data_to_device_image_improvised(data, 0, 0, width, height, texture.vk_image, size, dc);
        transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, {.COLOR}, dc=dc);
    } else {
        transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .UNDEFINED, .SHADER_READ_ONLY_OPTIMAL, {.COLOR}, dc=dc);
    }

    init_texture_from_vk_image(texture, texture.vk_image, width, height, format, usage, sampler, dc);
}
init_texture_from_vk_image :: proc(texture : ^Texture, image : vk.Image, width, height : int, format : Texture_Format, usage : Texture_Usage_Mask, sampler := DEFAULT_SAMPLER_SETTINGS, using dc := target_dc) {
    
    texture.vk_image = image;
    texture.usage_mask = usage;

    view_info : vk.ImageViewCreateInfo;
    view_info.sType = .IMAGE_VIEW_CREATE_INFO;
    view_info.image = texture.vk_image;
    view_info.viewType = .D2;
    view_info.format = texture_format_to_vk_format(texture.format);
    view_info.subresourceRange.aspectMask = {.COLOR};
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    if vk.CreateImageView(vk_device, &view_info, nil, &texture.vk_image_view) != .SUCCESS {
        panic("Failed to create texture image view");
    }

    // #Bad
    // The sampler should only be created if the textures has
    // the .SAMPLE flag set in the usage mask.
    sampler_info : vk.SamplerCreateInfo;
    sampler_info.sType = .SAMPLER_CREATE_INFO;
    sampler_info.magFilter = sampler.mag_filter;
    sampler_info.minFilter = sampler.min_filter;
    sampler_info.addressModeU = sampler.wrap_u;
    sampler_info.addressModeV = sampler.wrap_v;
    sampler_info.addressModeW = sampler.wrap_w;
    sampler_info.mipmapMode = sampler.mipmap_mode;
    sampler_info.anisotropyEnable = true;
    sampler_info.maxAnisotropy = graphics_device.props.limits.maxSamplerAnisotropy;
    sampler_info.unnormalizedCoordinates = false;
    sampler_info.compareEnable = false;
    sampler_info.compareOp = .ALWAYS;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = 0.0;

    if vk.CreateSampler(vk_device, &sampler_info, nil, &texture.sampler) != .SUCCESS {
        panic("Failed to create texture sampler");
    }

    texture.desc_info.imageLayout = .SHADER_READ_ONLY_OPTIMAL;
    texture.desc_info.imageView = texture.vk_image_view;
    texture.desc_info.sampler = texture.sampler;

    log.info("Created a texture");
}

destroy_texture :: proc(texture : Texture) {
    using texture.dc;
    vk.DeviceWaitIdle(vk_device);

    // #Sync
    for p in pipelines {
        for record,record_i in p.bind_records {
            for item, i in record.bound_resources {
                #partial switch resource in item {
                    case Texture: bind_texture(p, null_texture_srgb, record.binding_location, i);
                }
            }
        }
    }

    vk.DestroySampler(vk_device, texture.sampler, nil);
    vk.DestroyImageView(vk_device, texture.vk_image_view, nil);
    vk.DestroyImage(vk_device, texture.vk_image, nil);
    free_device_memory(texture.image_memory);
}


// #Syncs
transfer_data_to_device_image_improvised :: proc(data : rawptr, x, y, width, height : int, dst_image : vk.Image, size : vk.DeviceSize, using dc : ^Device_Context) {
    staging_buffer, staging_memory := make_staging_buffer(size, .TRANSFER_SRC, dc);
    staging_ptr : rawptr;
    // #Sync #Devicememory
    vk.MapMemory(vk_device, staging_memory.page, staging_memory.byte_index, size, {}, &staging_ptr);
    mem.copy(staging_ptr, data, cast(int)size);
    vk.UnmapMemory(vk_device, staging_memory.page);
    command_buffer := begin_single_use_command_buffer(dc);
    
    copy_region :  vk.BufferImageCopy;
    copy_region.bufferOffset = 0;
    copy_region.bufferRowLength = 0;
    copy_region.bufferImageHeight = 0;
    copy_region.imageSubresource.aspectMask = {.COLOR};
    copy_region.imageSubresource.mipLevel = 0;
    copy_region.imageSubresource.baseArrayLayer = 0;
    copy_region.imageSubresource.layerCount = 1;
    copy_region.imageOffset = {cast(i32)x, cast(i32)y, 0};
    copy_region.imageExtent = {cast(u32)width,cast(u32)height,1};

    vk.CmdCopyBufferToImage(command_buffer, staging_buffer, dst_image, .TRANSFER_DST_OPTIMAL, 1, &copy_region);
    
    submit_and_destroy_single_use_command_buffer(command_buffer, dc=dc);
    destroy_staging_buffer(staging_buffer, staging_memory, dc);
}

write_texture :: proc(texture : Texture, data : rawptr, x, y, w, h : int) {

    if .WRITE not_in texture.usage_mask {
        log.errorf("Tried writing to texture even though usage bit .WRITE was not set in usage mask. %s", texture.usage_mask);
    }

    L := cast(int)(x);
    R := cast(int)(x + w);
    B := cast(int)(y);
    T := cast(int)(y + h);

    // #Errormessage
    assert(R > L && L >= 0 && R <= texture.width, "Texture region out of range");
    assert(T > B && B >= 0 && T <= texture.height, "Texture region out of range");

    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_DST_OPTIMAL, {.COLOR}, 0, texture.dc);
    transfer_data_to_device_image_improvised(
        data, x, y, w, h,
        texture.vk_image, 
        cast(vk.DeviceSize)(w * h * texture.channels * get_texture_format_component_size(texture.format)),
        texture.dc,
    );
    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, {.COLOR}, 0, texture.dc);
}
read_texture :: proc(texture : Texture, x, y, w, h : int, pixels : rawptr) {

    // #Speed
    // Here we allocate and free a lot of command buffer for single uses.
    // Could buffer everything in one command buffer.

    if .READ not_in texture.usage_mask {
        log.error("Tried reading pixels from a texture without the .READ usage flag in creation");
        return;
    }

    using texture.dc;

    size := w * h * texture.channels * get_texture_format_component_size(texture.format);

    staging_buffer, staging_memory := make_staging_buffer(cast(vk.DeviceSize)size, .TRANSFER_DST, texture.dc);
    defer destroy_staging_buffer(staging_buffer, staging_memory, dc=texture.dc);

    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_SRC_OPTIMAL, {.COLOR}, 0, texture.dc);

    command_buffer := begin_single_use_command_buffer(texture.dc);
    
    copy_region :  vk.BufferImageCopy;
    copy_region.bufferOffset = 0;
    copy_region.bufferRowLength = 0;
    copy_region.bufferImageHeight = 0;
    copy_region.imageSubresource.aspectMask = {.COLOR};
    copy_region.imageSubresource.mipLevel = 0;
    copy_region.imageSubresource.baseArrayLayer = 0;
    copy_region.imageSubresource.layerCount = 1;
    copy_region.imageOffset = {cast(i32)x, cast(i32)y, 0};
    copy_region.imageExtent = {cast(u32)w,cast(u32)h,1};

    vk.CmdCopyImageToBuffer(command_buffer, texture.vk_image, .TRANSFER_SRC_OPTIMAL, staging_buffer, 1, &copy_region);
    
    submit_and_destroy_single_use_command_buffer(command_buffer, dc=texture.dc);
    
    staging_ptr : rawptr;
    // #Sync #Devicememory
    vk.MapMemory(vk_device, staging_memory.page, staging_memory.byte_index, cast(vk.DeviceSize)size, {}, &staging_ptr);
    mem.copy(pixels, staging_ptr, cast(int)size);
    vk.UnmapMemory(vk_device, staging_memory.page);

    transition_image_layout(texture.vk_image, texture_format_to_vk_format(texture.format), .TRANSFER_SRC_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, {.COLOR}, 0, texture.dc);
}