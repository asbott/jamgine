package utils

import "core:fmt"
import "core:unicode/utf16"
import "core:unicode/utf8"
import "core:unicode"
import "core:builtin"
import "core:sort"

tprint16 :: proc(args : ..any, sep := " ") -> [^]u16 {
    context.allocator = context.temp_allocator;
    str := fmt.tprint(..args, sep=sep)
    dest := make([]u16, len(str) * 2 + 1);
    utf16.encode_string(dest, str);

    return cast([^]u16)builtin.raw_data(dest);
}

alpha_sort :: proc(string_array : []string) {
    sort.bubble_sort_proc(string_array, proc(a, b : string) -> int {
        afirst := unicode.to_lower(utf8.rune_at_pos(a, 0));
        bfirst := unicode.to_lower(utf8.rune_at_pos(b, 0));
        return cast(int)afirst - cast(int)bfirst;
    });
}

sprint :: proc(args : ..any, sep := " ") -> string {
    context.temp_allocator = context.allocator;
    return fmt.tprint(..args, sep=sep);
}
sprintf :: proc(format : string, args : ..any) -> string {
    context.temp_allocator = context.allocator;
    return fmt.tprintf(format, ..args);
}