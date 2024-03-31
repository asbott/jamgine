package utils

clone_slice :: proc(s : []$T, allocator := context.allocator) -> []T{
    context.allocator = allocator;
    cp := make([]T, len(s));

    for i in 0..<len(s) {
        cp[i] = s[i];
    }

    return cp;
}