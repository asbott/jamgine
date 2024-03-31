package image_loader

import "core:os"
import "core:strings"
import "core:math"
import "core:mem"
import "core:slice"
import "core:fmt"
import "core:builtin"

import stb "vendor:stb/image"

decode_image_file_to_argb_bytes :: proc(file_path : string, desired_channels := 0) -> (data : []byte, width : int, height : int, channels : int, ok : bool) {
    cstr, alloc_err := strings.clone_to_cstring(file_path, allocator=context.temp_allocator);
    assert(alloc_err == .None);

    bytes : []byte;
    bytes, ok = os.read_entire_file(file_path);
    if !ok do return;

    return decode_image_to_argb_bytes(slice.as_ptr(bytes), len(bytes), desired_channels);
}
decode_image_to_argb_bytes :: proc(encoded : rawptr, encoded_len : int, desired_channels := 0) -> (data : []byte, width : int, height : int, channels : int, ok : bool) {
    stb.set_flip_vertically_on_load(1);
    stb.flip_vertically_on_write(true);
    decoded := stb.load_from_memory(cast([^]u8)encoded, cast(i32)encoded_len, cast(^i32)&width, cast(^i32)&height, cast(^i32)&channels, cast(i32)desired_channels);

    if decoded == nil {
        ok = false;
        return;
    }

    if desired_channels > 0 do channels = desired_channels;

    data = slice.from_ptr(decoded, width * height * channels);

    ok = true;
    return;
}


convert_argb_bytes_to_srgb_f16 :: proc(result : ^[]f16, bytes : []byte) {
    assert(len(result) >= len(bytes), "Result is not big enough");

    for b, i in bytes {
        norm := cast(f16)b / 255.0;
        if (norm <= 0.04045) {
            result[i] = norm / 12.92;
        } else {
            result[i] = math.pow_f16((norm + 0.055) / 1.055, 2.4);
        }
    }
}
decode_image_file_to_srgb_f16 :: proc(file_path : string, desired_channels := 0) -> (data : []f16, width : int, height : int, channels : int, ok : bool) {
    bytes : []byte;
    bytes, width, height, channels, ok = decode_image_file_to_argb_bytes(file_path, desired_channels);
    if !ok do return;
    defer delete_image_argb(bytes);

    data = make([]f16, len(bytes));
    convert_argb_bytes_to_srgb_f16(&data, bytes);
    return;
}
decode_image_to_srgb_f16 :: proc(encoded : rawptr, encoded_len : int, desired_channels := 0) -> (data : []f16, width : int, height : int, channels : int, ok : bool) {
    bytes : []byte;
    bytes, width, height, channels, ok = decode_image_to_argb_bytes(encoded, encoded_len, desired_channels);
    if !ok do return;
    defer delete_image_argb(bytes);

    data = make([]f16, len(bytes));
    convert_argb_bytes_to_srgb_f16(&data, bytes);
    return;
}


convert_argb_bytes_to_srgb_f32 :: proc(result : ^[]f32, bytes : []byte) {
    assert(len(result) >= len(bytes), "Result is not big enough");
    
    for b, i in bytes {
        norm := cast(f32)b / 255.0;
        if (norm <= 0.04045) {
            result[i] = norm / 12.92;
        } else {
            result[i] = math.pow_f32((norm + 0.055) / 1.055, 2.4);
        }
    }
}
decode_image_file_to_srgb_f32 :: proc(file_path : string, desired_channels := 0) -> (data : []f32, width : int, height : int, channels : int, ok : bool) {
    bytes : []byte;
    bytes, width, height, channels, ok = decode_image_file_to_argb_bytes(file_path, desired_channels);
    if !ok do return;
    defer delete_image_argb(bytes);

    data = make([]f32, len(bytes));
    convert_argb_bytes_to_srgb_f32(&data, bytes);
    return;
}
decode_image_to_srgb_f32 :: proc(encoded : rawptr, encoded_len : int, desired_channels := 0) -> (data : []f32, width : int, height : int, channels : int, ok : bool) {
    bytes : []byte;
    bytes, width, height, channels, ok = decode_image_to_argb_bytes(encoded, encoded_len, desired_channels);
    if !ok do return;
    defer delete_image_argb(bytes);

    data = make([]f32, len(bytes));
    convert_argb_bytes_to_srgb_f32(&data, bytes);
    return;
}


delete_image_argb_bytes :: proc(data : []byte) {
    stb.image_free(builtin.raw_data(data));
}
delete_image_srgb_f16 :: proc(data : []f16) {
    delete(data);
}
delete_image_srgb_f32 :: proc(data : []f32) {
    delete(data);
}

delete_image_argb :: proc{
    delete_image_argb_bytes,
    delete_image_srgb_f16,
    delete_image_srgb_f32,
}