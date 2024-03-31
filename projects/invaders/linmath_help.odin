package invaders

import "jamgine:lin"

v2_xy :: proc(x, y : f32) -> lin.Vector2 {
    return {x, y};
}
v2_identity :: proc() -> lin.Vector2 { return {0, 0}; }
v2_scalar :: proc(s : f32) -> lin.Vector2 { return {s, s}; }
v2 :: proc{v2_xy,v2_identity,v2_scalar}

v3_from_v2 :: proc(v2 : lin.Vector2) -> lin.Vector3 {
    return v3_xy(v2.x, v2.y);
}
v3_from_v2_z :: proc(v2 : lin.Vector2, z : f32) -> lin.Vector3 {
    return v3_xyz(v2.x, v2.y, z);
}
v3_xy :: proc(x, y : f32) -> lin.Vector3 {
    return {x, y, 0};
}
v3_xyz :: proc(x, y, z : f32) -> lin.Vector3 {
    return {x, y, z};
}
v3_identity :: proc() -> lin.Vector3 { return {0, 0, 0}; }
v3_scalar :: proc(s : f32) -> lin.Vector3 { return {s, s, s}; }
v3 :: proc{v3_xy,v3_xyz,v3_identity,v3_scalar,v3_from_v2,v3_from_v2_z}

v4_from_v2 :: proc(v : lin.Vector2) -> lin.Vector4 {
    return v4_xy(v.x, v.y);
}
v4_from_v2v2 :: proc(xy : lin.Vector2, zw : lin.Vector2) -> lin.Vector4 {
    return v4_xyzw(xy.x, xy.y, zw.x, zw.y);
}
v4_from_v2z :: proc(xy : lin.Vector2, z : f32) -> lin.Vector4 {
    return v4_xyzw(xy.x, xy.y, z, 0);
}
v4_from_v2zw :: proc(xy : lin.Vector2, z : f32, w : f32) -> lin.Vector4 {
    return v4_xyzw(xy.x, xy.y, z, w);
}
v4_from_v3 :: proc(v : lin.Vector3) -> lin.Vector4 {
    return v4_xyz(v.x, v.y, v.z);
}
v4_xy :: proc(x, y : f32) -> lin.Vector4 {
    return {x, y, 0, 0};
}
v4_xyz :: proc(x, y, z : f32) -> lin.Vector4 {
    return {x, y, z, 0.0};
}
v4_xyzw :: proc(x, y, z, w : f32) -> lin.Vector4 {
    return {x, y, z, w};
}
v4_identity :: proc() -> lin.Vector4 { return {0, 0, 0, 0}; }
v4_scalar :: proc(s : f32) -> lin.Vector4 { return {s, s, s, s}; }
v4 :: proc{v4_xy,v4_xyz,v4_xyzw,v4_identity,v4_scalar,v4_from_v2, v4_from_v3, v4_from_v2v2, v4_from_v2z, v4_from_v2zw}
