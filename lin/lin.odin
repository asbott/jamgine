package lin

import "core:math/linalg/glsl"

Vector2 :: glsl.vec2;
Vector3 :: glsl.vec3;
Vector4 :: glsl.vec4;

Vector2i :: glsl.ivec2;
Vector3i :: glsl.ivec3;
Vector4i :: glsl.ivec4;

Vector2u :: glsl.uvec2;
Vector3u :: glsl.uvec3;
Vector4u :: glsl.uvec4;

Matrix4 :: glsl.mat4;


identity :: glsl.identity

translate   :: proc{ glsl.mat4Translate }
rotate      :: proc{ glsl.mat4Rotate }
scale       :: proc{ glsl.mat4Scale }
perspective :: glsl.mat4Perspective
lookAt      :: glsl.mat4LookAt
inverse     :: glsl.inverse
transpose   :: glsl.transpose

length      :: glsl.length
cross       :: glsl.cross
normalize   :: glsl.normalize
dot         :: glsl.dot;

normalize_or_0 :: proc(v : $T) -> T { 
    if length(v) == 0 do return 0; 
    else do return normalize(v);  
}

ortho :: proc(L, R, B, T, near, far : f32) -> Matrix4 {
    proj := Matrix4{};
    proj[0][0] = 2.0 / (R - L);
    proj[1][1] = 2.0 / (B - T);
    proj[2][2] = -1.0 / (far - near);
    proj[3][3] = 1.0;
    proj[3][0] = -(R + L) / (R - L);
    proj[3][1] = -(B + T) / (B - T);
    proj[3][2] = near / (near - far);//-(far + near) / (far - near);
    return proj;
}

v2_xy :: proc(x, y : f32) -> Vector2 {
    return {x, y};
}
v2_identity :: proc() -> Vector2 { return {0, 0}; }
v2_scalar :: proc(s : f32) -> Vector2 { return {s, s}; }
v2 :: proc{v2_xy,v2_identity,v2_scalar}

v3_from_v2 :: proc(v2 : Vector2) -> Vector3 {
    return v3_xy(v2.x, v2.y);
}
v3_from_v2_z :: proc(v2 : Vector2, z : f32) -> Vector3 {
    return v3_xyz(v2.x, v2.y, z);
}
v3_xy :: proc(x, y : f32) -> Vector3 {
    return {x, y, 0};
}
v3_xyz :: proc(x, y, z : f32) -> Vector3 {
    return {x, y, z};
}
v3_identity :: proc() -> Vector3 { return {0, 0, 0}; }
v3_scalar :: proc(s : f32) -> Vector3 { return {s, s, s}; }
v3 :: proc{v3_xy,v3_xyz,v3_identity,v3_scalar,v3_from_v2,v3_from_v2_z}

v4_from_v2 :: proc(v : Vector2) -> Vector4 {
    return v4_xy(v.x, v.y);
}
v4_from_v2v2 :: proc(xy : Vector2, zw : Vector2) -> Vector4 {
    return v4_xyzw(xy.x, xy.y, zw.x, zw.y);
}
v4_from_v2z :: proc(xy : Vector2, z : f32) -> Vector4 {
    return v4_xyzw(xy.x, xy.y, z, 0);
}
v4_from_v2zw :: proc(xy : Vector2, z : f32, w : f32) -> Vector4 {
    return v4_xyzw(xy.x, xy.y, z, w);
}
v4_from_v3 :: proc(v : Vector3) -> Vector4 {
    return v4_xyz(v.x, v.y, v.z);
}
v4_xy :: proc(x, y : f32) -> Vector4 {
    return {x, y, 0, 0};
}
v4_xyz :: proc(x, y, z : f32) -> Vector4 {
    return {x, y, z, 0.0};
}
v4_xyzw :: proc(x, y, z, w : f32) -> Vector4 {
    return {x, y, z, w};
}
v4_identity :: proc() -> Vector4 { return {0, 0, 0, 0}; }
v4_scalar :: proc(s : f32) -> Vector4 { return {s, s, s, s}; }
v4 :: proc{v4_xy,v4_xyz,v4_xyzw,v4_identity,v4_scalar,v4_from_v2, v4_from_v3, v4_from_v2v2, v4_from_v2z, v4_from_v2zw}
