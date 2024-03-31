package utils

import "core:math"

wrap :: proc(v, min, max : f32) -> f32 {
    if v < min do return max;
    if v > max do return min;
    return v;
}

norm_cos :: proc(v : f32) -> f32 {
    return (math.cos_f32(v) + 1.0) / 2.0;
}
norm_sin :: proc(v : f32) -> f32 {
    return (math.sin_f32(v) + 1.0) / 2.0;
}

noisy_sin_1 :: proc(v : f32) -> f32 {
    return (math.sin_f32(v*5.7-3) * math.sin_f32(v*0.37+5) * math.sin_f32(v*1.4*math.sin_f32(v*1.1)) * math.sin_f32(1*1.16+1));
}

// N normalized perfect sine waves between t=0 to t=1, wave height y=0 to y=1
oscillate :: proc(N : f32, t : f32) -> f32 {
    return (math.sin_f32(N*2*math.PI*(t-(1/(N*4))))+1) / 2;
}