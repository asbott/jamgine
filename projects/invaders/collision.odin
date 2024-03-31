package invaders

import "jamgine:lin"

import "core:math"
import "core:slice"
import "core:log"

Polygon :: struct {
    ps_local : []lin.Vector2,
    ps_world : []lin.Vector2,
}

Rect :: struct {
    pos, size : lin.Vector2,
}
Circle :: struct {
    center : lin.Vector2,
    radius : f32,
}

Collision_Shape :: union {
    Polygon, Rect, Circle
}

make_polygon :: proc(ps_local : []lin.Vector2) -> Polygon {
    poly : Polygon;

    poly.ps_local = ps_local;
    poly.ps_world = slice.clone(ps_local);

    return poly;
}

transform_points :: proc(ps : []lin.Vector2, transform : lin.Matrix4, allocator := context.allocator) -> []lin.Vector2 {
    context.allocator = allocator;

    cp := slice.clone(ps);

    for p, i in ps {
        cp[i] = (transform * v4(p, 0, 1)).xy;
    }

    return cp;
}
t_transform_points:: proc(ps : []lin.Vector2, transform : lin.Matrix4) -> []lin.Vector2 {
    return transform_points(ps, transform, context.temp_allocator);
}

polygons_overlap :: proc(a, b : Polygon) -> bool{
    // #Speed
    // Could use grid to only test necessary lines
    assert(len(a.ps_world) >= 3 && len(b.ps_world) >= 3, "Polygon under 3 points");

    // #Speed
    alines := make([]lin.Vector4, len(a.ps_world), allocator=context.temp_allocator);
    blines := make([]lin.Vector4, len(b.ps_world), allocator=context.temp_allocator);

    for i in 0..<len(a.ps_world) {
        prev := (a.ps_world[i-1] if i > 0 else a.ps_world[len(a.ps_world)-1]);
        p := a.ps_world[i];
        alines[i] = {prev.x, prev.y, p.x, p.y};
    }
    for i in 0..<len(b.ps_world) {
        prev := (b.ps_world[i-1] if i > 0 else b.ps_world[len(b.ps_world)-1]);
        p := b.ps_world[i];
        blines[i] = {prev.x, prev.y, p.x, p.y};
    }

    for aline in alines {
        for bline in blines {
            if line_segments_intersect(aline.xy, aline.zw, bline.xy, bline.zw) do return true;
        }
    }
    return false;
}

line_segments_intersect :: proc(a1, a2, b1, b2 : lin.Vector2) -> bool {
    orientation :: proc(p, q, r: lin.Vector2) -> int {
        val := (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
        if val == 0 {
            return 0  // colinear
        }
        if val > 0 {
            return 1  // clockwise
        }
        return 2  // counterclockwise
    }

    on_segment :: proc(p, q, r: lin.Vector2) -> bool {
        return q.x <= max(p.x, r.x) && q.x >= min(p.x, r.x) &&
               q.y <= max(p.y, r.y) && q.y >= min(p.y, r.y)
    }

    o1 := orientation(a1, a2, b1)
    o2 := orientation(a1, a2, b2)
    o3 := orientation(b1, b2, a1)
    o4 := orientation(b1, b2, a2)

    if o1 != o2 && o3 != o4 {
        return true
    }

    // a1, a2, and b1 are colinear and b1 lies on segment a1a2
    if o1 == 0 && on_segment(a1, b1, a2) { return true }

    // a1, a2 and b2 are colinear and b2 lies on segment a1a2
    if o2 == 0 && on_segment(a1, b2, a2) { return true }

    // b1, b2 and a1 are colinear and a1 lies on segment b1b2
    if o3 == 0 && on_segment(b1, a1, b2) { return true }

    // b1, b2 and a2 are colinear and a2 lies on segment b1b2
    if o4 == 0 && on_segment(b1, a2, b2) { return true }

    return false
}

polygon_overlap_circle :: proc(p : Polygon, c : Circle) -> bool {
    for i in 0..<len(p.ps_world) {
        p1 := p.ps_world[i]

        if lin.length(p1 - c.center) <= c.radius {
            return true;
        }

        p2 := p.ps_world[(i+1) % len(p.ps_world)];
        
        if line_segment_circle_intersect(p1, p2, c.center, c.radius) {
            return true
        }
    }
    
    return false
}
is_point_in_circle :: proc(p : lin.Vector2, center : lin.Vector2, radius : f32) -> bool {
    return lin.length(p - center) <= radius;
}
line_segment_circle_intersect :: proc(a, b, center: lin.Vector2, radius: f32) -> bool {
    // Project center onto line segment, then check distance to the projected point
    closest := project_point_line_segment(center, a, b)
    return is_point_in_circle(closest, center, radius);
}
project_point_line_segment :: proc(p, l0, l1 : lin.Vector2) -> lin.Vector2 {
    l2 := l1 - l0;
    t := lin.dot(p - l0, l2) / lin.dot(l2, l2);
    t = max(0.0, min(1.0, t));
    return l0 + t * l2;
}
polygon_overlap_rect :: proc(p: Polygon, r: Rect) -> bool {

    L, R, B, T := unpack_box({r.pos.x, r.pos.y, r.size.x, r.size.y});

    rect_poly : Polygon;

    rect_poly.ps_world = []lin.Vector2 {
        {L, B},
        {L, T},
        {R, T},
        {R, B},
    }

    return polygons_overlap(p, rect_poly);
}
rect_overlap_circle :: proc(r: Rect, c: Circle) -> bool {
    closest_point : lin.Vector2;

    if c.center.x < r.pos.x {
        closest_point.x = r.pos.x;
    } else if c.center.x > r.pos.x + r.size.x {
        closest_point.x = r.pos.x + r.size.x;
    } else {
        closest_point.x = c.center.x;
    }

    if c.center.y < r.pos.y {
        closest_point.y = r.pos.y;
    } else if c.center.y > r.pos.y + r.size.y {
        closest_point.y = r.pos.y + r.size.y;
    } else {
        closest_point.y = c.center.y;
    }

    distance_x := c.center.x - closest_point.x;
    distance_y := c.center.y - closest_point.y;
    distance_squared := distance_x * distance_x + distance_y * distance_y;

    return distance_squared <= c.radius * c.radius;
}
circles_overlap :: proc(a, b : Circle) -> bool {
    distance := lin.length(a.center - b.center);
    return distance <= (a.radius + b.radius);
}
rects_overlap :: proc(a, b : Rect) -> bool {
    L0, R0, B0, T0 := unpack_box({a.pos.x, a.pos.y, a.size.x, a.size.y});
    L1, R1, B1, T1 := unpack_box({b.pos.x, b.pos.y, b.size.x, b.size.y});

    return R1 >= L0 && L1 <= R1 && T1 >= B0 && B1 <= T1;
}

unpack_box :: proc(b : lin.Vector4) -> (L, R, B, T : f32) {
    bw := b.z;
    bh := b.w;

    L = b.x - bw/2.0;
    R = b.x + bw/2.0;
    B = b.y - bh/2.0;
    T = b.y + bh/2.0;

    return
}
box_contains_point :: proc(b : lin.Vector4, p : lin.Vector2) -> bool {
    L, R, B, T := unpack_box(b);
    return p.x >= L && p.x < R && p.y >= B && p.y < T;
}
boxes_overlap :: proc(b1, b2 : lin.Vector4) -> bool {
    L1, R1, B1, T1 := unpack_box(b1);
    L2, R2, B2, T2 := unpack_box(b2);

    xintersects := R1 >= L2 && L1 < R2;
    yintersects := T1 >= B2 && B1 < T2;

    return xintersects && yintersects;
}

is_in_bounds :: proc(pos : lin.Vector2, size := lin.Vector2{}) -> bool {
    return pos.x < GAME_ARENA_SIZE.x + size.x/2.0 && pos.x >= -size.x/2.0 &&
           pos.y < GAME_ARENA_SIZE.y + size.y/2.0 && pos.y >= -size.y/2.0
}

collision_checks := 0;
collisions := 0;




HNODES :: 15;
VNODES :: 20;
NODE_WIDTH  :: (GAME_ARENA_SIZE.x / HNODES);
NODE_HEIGHT :: (GAME_ARENA_SIZE.y / VNODES);

Arena_Node :: struct {
    objects : [dynamic]Object_Id, // #Memory #Speed
    pos : lin.Vector2,
}
arena_nodes : [HNODES * VNODES]Arena_Node;

get_arena_node_at_point :: proc(p : lin.Vector2) ->^Arena_Node {
    return get_arena_node_at_xy_index(cast(int)(p.x / NODE_WIDTH), cast(int)(p.y / NODE_HEIGHT));
}
get_arena_node_at_xy_index :: proc(x, y : int) ->^Arena_Node {
    return get_arena_node_at_index(y * HNODES + x);
}
get_arena_node_at_index :: proc(i : int) ->^Arena_Node {
    assert(i >= 0 && i < len(arena_nodes), "Arena node index out of range");

    return &arena_nodes[i];
}
get_arena_node :: proc {get_arena_node_at_index, get_arena_node_at_point, get_arena_node_at_xy_index}

get_arena_nodes :: proc(bounds : lin.Vector4, allocator := context.allocator) ->[]^Arena_Node {
    context.allocator = allocator;
    L, R, B, T := unpack_box(bounds);

    w := R - L;
    h := T - B;

    L = max(0, L);
    R = min(GAME_ARENA_SIZE.x - w/2.0, R);
    B = max(0, B);
    T = min(GAME_ARENA_SIZE.y - h/2.0, T);

    xindex_left  := cast(int)(L / NODE_WIDTH);
    xindex_right := cast(int)math.ceil_f32(R / NODE_WIDTH);
    yindex_bot   := cast(int)(B / NODE_HEIGHT);
    yindex_top   := cast(int)math.ceil_f32(T / NODE_HEIGHT);
    xcount       := xindex_right - xindex_left;
    ycount       := yindex_top   - yindex_bot;

    
    if xcount <= 0 || ycount <= 0 do return nil;
    nodes := make([dynamic]^Arena_Node, 0, xcount * ycount)

    for xindex := xindex_left; xindex < xindex_right; xindex += 1 {
        for yindex := yindex_bot; yindex < yindex_top; yindex += 1 {
            x := cast(f32)xindex * NODE_WIDTH;
            y := cast(f32)yindex * NODE_HEIGHT;
            append(&nodes, get_arena_node(lin.Vector2{x, y}));
        }   
    }

    return nodes[:];
}

get_polygon_bounds :: proc(poly : Polygon) -> lin.Vector4 {
    min_x, min_y :f32= 99999999999,99999999999;
    max_x, max_y :f32= -99999999999,-99999999999;

    for p in poly.ps_world {
        if p.x < min_x do min_x = p.x;
        if p.x > max_x do max_x = p.x;
        if p.y < min_y do min_y = p.y;
        if p.y > max_y do max_y = p.y;
    }

    center_x := min_x + (max_x - min_x) / 2.0
    center_y := min_y + (max_y - min_y) / 2.0

    return { center_x, center_y, max_x-min_x, max_y-min_y };
}

get_shape_bounds :: proc(shape_base : Collision_Shape) -> lin.Vector4 {
    switch shape in shape_base {
        case Polygon: {
            return get_polygon_bounds(shape);
        }
        case Rect: {
            return {shape.pos.x, shape.pos.y, shape.size.x, shape.size.y};
        }
        case Circle: {
            return {shape.center.x, shape.center.y, shape.radius*2, shape.radius*2 }
        }
    }
    panic("What");
}

find_collisions :: proc() {
    collision_checks = 0;
    collisions = 0;
    
    for i in 0..<len(arena_nodes) {
        n := &arena_nodes[i];
        clear(&n.objects);
    }
    // Add objects to collision grid
    for i in 0..<len(objects) {
        obj := &objects[i];
        if !obj.is_valid do continue;
        obj.any_collision = false;
        add_object_to_nodes(obj.id, get_arena_nodes(get_shape_bounds(obj.collision_shape), allocator=context.temp_allocator));
    }

    // Check collisions
    for n in arena_nodes {
        for i in 0..<len(n.objects) {
            a, a_valid := try_resolve_object_id(n.objects[i]);
            if !a_valid do continue;

            for j in i+1..<len(n.objects) {
                b, b_valid := try_resolve_object_id(n.objects[j]);
                if !b_valid do continue;

                collision_checks += 1;

                atransform := lin.rotate({0, 0, -1}, a.rotation);
                btransform := lin.rotate({0, 0, -1}, b.rotation);

                collide : bool;

                switch ashape in a.collision_shape {
                    case Polygon: {
                        switch bshape in b.collision_shape {
                            case Polygon: collide = polygons_overlap(ashape, bshape);
                            case Rect: {
                                collide = polygon_overlap_rect(ashape, bshape);
                            }
                            case Circle: {
                                collide = polygon_overlap_circle(ashape, bshape);
                            }
                        }
                    }
                    case Rect: {
                        switch bshape in b.collision_shape {
                            case Polygon: {
                                collide = polygon_overlap_rect(bshape, ashape);
                            }
                            case Rect: {
                                collide = rects_overlap(bshape, ashape);
                            }
                            case Circle: {
                                collide = rect_overlap_circle(ashape, bshape);
                            }
                        }
                    }
                    case Circle: {
                        switch bshape in b.collision_shape {
                            case Polygon: {
                                collide = polygon_overlap_circle(bshape, ashape);
                            }
                            case Rect: {
                                collide = rect_overlap_circle(bshape, ashape);
                            }
                            case Circle: {
                                collide = circles_overlap(bshape, ashape);
                            }
                        }
                    }
                }

                if collide {
                    collisions += 1;
                        a.any_collision = true;
                        b.any_collision = true;
                        #partial switch v1 in a.variant {
                            case Player: #partial switch v2 in b.variant {
                                case Player: assert(false, "Player collide player");
                                case Enemy:  player_v_enemy(&v1.variant.(Player), &v2.variant.(Enemy));
                                case Bullet: player_v_bullet(&v1.variant.(Player), &v2.variant.(Bullet));
                            }
                            case Enemy: #partial switch v2 in b.variant {
                                case Player: player_v_enemy(&v2.variant.(Player), &v1.variant.(Enemy));
                                case Enemy:  enemy_v_enemy(&v1.variant.(Enemy), &v2.variant.(Enemy));
                                case Bullet: enemy_v_bullet(&v1.variant.(Enemy), &v2.variant.(Bullet));
                            }
                            case Bullet: #partial switch v2 in b.variant {
                                case Player: player_v_bullet(&v2.variant.(Player), &v1.variant.(Bullet));
                                case Enemy:  enemy_v_bullet(&v2.variant.(Enemy), &v1.variant.(Bullet));
                                case Bullet: bullet_v_bullet(&v1.variant.(Bullet), &v2.variant.(Bullet));
                            }
                        }
                }
                
            }   
        }
    }
}