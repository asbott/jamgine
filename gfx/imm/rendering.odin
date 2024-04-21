package imm

import jvk "jamgine:gfx/justvk"
import "vendor:glfw"
import "core:log"
import "../../gfx"
import "core:builtin"
import "jamgine:data"
import "core:mem"
import "core:os"
import "core:math"
import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"

import gfxtext "jamgine:gfx/text"
import "jamgine:lin"

import vk "vendor:vulkan"

// The maxPerStageDescriptorSamplers may be a lot higher (~1000000 on my device) but
// it can also be a lot lower (64 on my integrated graphics). So the actual max per
// pipelines will be the lowest of this or the maxPerStageDescriptorSamplers.
MAX_TEXTURES_PER_PIPELINE :: 128

MAX_SCISSOR_BOXES_PER_PIPELINE :: 256

DEFAULT_FONT_SIZE :: 16;

Camera :: struct #packed {
    proj : lin.Matrix4,
    view : lin.Matrix4,
    viewport : lin.Vector2,
}

Text_Atlas :: struct {
    texture : jvk.Texture,
    target : jvk.Render_Target,

    pen : lin.Vector2,

    free_boxes : [dynamic]lin.Vector4,

    rendered_text : map[string]Rendered_Text,
}
Rendered_Text :: struct {
    atlas_texture : jvk.Texture,
    uv_range : lin.Vector4,
    text : string,
    size : lin.Vector2,
}

VERTEX_TYPE_REGULAR :: 0
VERTEX_TYPE_TEXT :: 1
VERTEX_TYPE_CIRCLE :: 2
VERTEX_TYPE_SHADOW_RECT :: 3

DATA_INDEX_SCISSOR_INDEX :: 0
DATA_INDEX_TEXTURE_INDEX :: 1
DATA_INDEX_VERTEX_TYPE :: 2


Vertex :: struct #packed {
    pos          : lin.Vector3,
    tint         : lin.Vector4,
    uv           : lin.Vector2,
    normal       : lin.Vector3,
    data_indices : [4]i32,
}

Stats :: struct {
    num_draw_calls : int,
    num_quads : int,
    num_triangles : int,
    num_vertices : int,
    num_indices : int,
    num_textures : int,
    num_scissors : int,
}
Clear_Request :: struct {
    aspect : vk.ImageAspectFlags,
    color : lin.Vector4,
}
Imm_Context :: struct {

    // One buffer per window frame so they can be stored in ram and reflected on gpu without screen flickering
    vbos                  : []^jvk.Vertex_Buffer,
    ibos                  : []^jvk.Index_Buffer,
    camera_ubos           : []^jvk.Uniform_Buffer,
    scissor_ubos          : []^jvk.Uniform_Buffer,

    current_vbo_size      : int,
    current_ibo_size      : int,

    pipeline_2d           : ^jvk.Pipeline,
    pipeline_2d_offscreen : ^jvk.Pipeline,
    pipeline_3d           : ^jvk.Pipeline,
    pipeline_3d_offscreen : ^jvk.Pipeline,

    text_atlas_pipeline   : ^jvk.Pipeline,
    text_atlas_pass       : jvk.Render_Pass,

    active_pipeline       : ^jvk.Pipeline,
    active_target         : Maybe(jvk.Render_Target), // if nil, we are targeting gfx.window_surface

    // #Memory #Fragmentation
    vertices              : [dynamic]Vertex, // #Memory #Speed
    indices               : [dynamic]u32, 
    texture_slots         : [dynamic]jvk.Texture,
    transforms            : [dynamic]lin.Matrix4,
    transform_stack       : [dynamic]lin.Matrix4,
    scissor_boxes         : [dynamic]lin.Vector4,
    front_transform       : lin.Matrix4,
    next_transform_index  : int,
    next_texture_slot     : i32,

    camera : Camera,

    stats           :  Stats,

    target_fbo      : c.uint,

    default_font_family : ^gfxtext.Font_Family,
    default_font : ^gfxtext.Font_Variation,

    current_scissor_index : int,

    max_textures_per_pipeline : int,
}


imm_context : ^Imm_Context;


transform_pos_vec3 :: proc(transform : lin.Matrix4, pos : lin.Vector3) -> lin.Vector3{
    return (transform * lin.Vector4{pos.x, pos.y, pos.z, 1.0}).xyz;
}
transform_pos :: proc{transform_pos_vec3}

_make_vertex :: proc(using ctx : ^Imm_Context, pos : lin.Vector3, tint := gfx.WHITE, uv := lin.Vector2{0, 0}, texture_index : i32 = -1, vertex_type :i32= VERTEX_TYPE_REGULAR) -> Vertex{
    assert(active_pipeline != nil, "begin/flush mismatch; please call imm.begin() before drawing");
    v : Vertex;
    v.pos = pos;
    v.tint = tint;
    v.uv = uv;

    v.data_indices[DATA_INDEX_SCISSOR_INDEX] = cast(i32)current_scissor_index;
    v.data_indices[DATA_INDEX_VERTEX_TYPE] = vertex_type;
    v.data_indices[DATA_INDEX_TEXTURE_INDEX] = texture_index;

    stats.num_vertices += 4;

    return v;
}

init_text_atlas :: proc(atlas : ^Text_Atlas, width, height : int) {
    sampler := jvk.DEFAULT_SAMPLER_SETTINGS;
    sampler.min_filter = .NEAREST;
    sampler.mag_filter = .NEAREST;
    // #Temporary #Debug
    // Should not have .READ flag
    atlas.texture = jvk.make_texture(width, height, nil, .R_UNORM, {.SAMPLE, .DRAW, .READ}, sampler=sampler);
    atlas.target = jvk.make_texture_render_target(atlas.texture);

    atlas.free_boxes = make([dynamic]lin.Vector4);
    atlas.rendered_text = make(map[string]Rendered_Text);
}
make_text_atlas :: proc(width, height : int) -> Text_Atlas {
    atlas : Text_Atlas;
    init_text_atlas(&atlas, width, height);
    return atlas;
}
destroy_text_atlas :: proc(atlas : Text_Atlas) {
    jvk.destroy_render_target(atlas.target);
    jvk.destroy_texture(atlas.texture);
    delete(atlas.free_boxes);

    for k,_ in atlas.rendered_text {
        delete(k);
    }
    delete(atlas.rendered_text);
}
// !!!! Returns already rendered text no matter what font it was rendered with
// because we don't and won't keep track of that. Passed font will only be used
// if passed string is not render and we need to render it now.
get_or_render_text :: proc(atlas : ^Text_Atlas, str : string, font := imm_context.default_font, using ctx := imm_context) -> (Rendered_Text, bool) {
    if str in atlas.rendered_text {
        return atlas.rendered_text[str], true;
    } else {
        return render_text(atlas, str, font, ctx);
    }
}
render_text :: proc(atlas : ^Text_Atlas, str : string, font := imm_context.default_font, using ctx := imm_context) -> (Rendered_Text, bool) {
    using atlas;
    text_size := gfxtext.measure(font, str);
    if text_size.x > f32(texture.width) || text_size.y > f32(texture.height) {
        return {}, false;        
    }
    rendered : Rendered_Text;
    rendered.atlas_texture = atlas.texture;

    
    
    camera_backup := camera;
    target_backup := active_target;
    backup_pipeline := active_pipeline;

    set_render_target(atlas.target, ctx);
    set_default_2D_camera(f32(texture.width), f32(texture.height), ctx);
    active_pipeline = nil;

    best_match := -1;
    diff_area : f32 = 0;
    for free_box, i in free_boxes {
        diffx := free_box.x - text_size.x;
        diffy := free_box.y - text_size.y;

        if text_size.x <= free_box.z && text_size.y <= free_box.w && diffy * diffx > diff_area {
            diff_area = diffy * diffx;
            best_match = i;
        }
    }
    
    if best_match == -1 {
        remaining_height := f32(texture.height) - pen.y;
        if text_size.y > remaining_height do return {}, false;

        begin(text_atlas_pipeline, ctx);
        text(str, {math.floor(pen.x + text_size.x/2), math.floor(pen.y+text_size.y/2), 0}, gfx.WHITE, ctx=ctx, font=font);
        flush(ctx);
        uv_start := lin.Vector2{pen.x / f32(texture.width), 1.0 - pen.y / f32(texture.height)};
        pen.y += text_size.y;
        uv_end := lin.Vector2{(pen.x+text_size.x) / f32(texture.width), 1.0 - pen.y / f32(texture.height)};
        rendered.uv_range = {uv_start.x, uv_start.y, uv_end.x, uv_end.y};

        if text_size.y <= font.font_size {
            free_pos := lin.Vector2{pen.x+text_size.x, pen.y - text_size.y};
            free_size := lin.Vector2{f32(texture.width)-free_pos.x, font.font_size};
            if free_size.x > font.font_size {
                append(&free_boxes, lin.Vector4{free_pos.x, free_pos.y, free_size.x, free_size.y});
            }
        }
    } else {
        box := free_boxes[best_match];
        unordered_remove(&free_boxes, best_match);

        begin(text_atlas_pipeline, ctx);
        text(str, {math.floor(box.x + text_size.x/2), math.floor(box.y+text_size.y/2), 0}, gfx.WHITE, ctx=ctx, font=font);
        flush(ctx);
        uv_start := lin.Vector2{box.x / f32(texture.width), 1.0 - box.y / f32(texture.height)};
        uv_end := lin.Vector2{(box.x+text_size.x) / f32(texture.width), 1.0 - (box.y + text_size.y) / f32(texture.height)};
        rendered.uv_range = {uv_start.x, uv_start.y, uv_end.x, uv_end.y};

        remaining_box_width := box.z - text_size.x;

        if remaining_box_width > font.font_size {
            append(&free_boxes, lin.Vector4{ box.x+text_size.x, box.y, remaining_box_width, box.w });
        }
    }

    
    camera = camera_backup;
    if target_backup != nil do set_render_target(target_backup.(jvk.Render_Target), ctx);
    active_pipeline = backup_pipeline;

    // #Leak #Fragmentation #Unused ?
    rendered.text = strings.clone(str);
    rendered.size = text_size;

    if str not_in atlas.rendered_text {
        // #Memory #Fragmentation
        // This string is not leaked BUT it causes lots of fragmentation
        atlas.rendered_text[strings.clone(str)] = rendered;
    }

    return rendered, true;
}
clear_text_atlas :: proc(using atlas : ^Text_Atlas, using ctx := imm_context) {
    target_backup := active_target;
    pipeline_backup := active_pipeline;

    jvk.begin_draw(text_atlas_pipeline, atlas.target);
    jvk.cmd_clear(text_atlas_pipeline, {.COLOR}, gfx.TRANSPARENT);
    jvk.end_draw(text_atlas_pipeline);

    if target_backup != nil do set_render_target(target_backup.(jvk.Render_Target), ctx);
    active_pipeline = pipeline_backup;
    atlas.pen = {};
    clear(&free_boxes);
    for k,_ in rendered_text {
        delete(k);
    }
    clear(&rendered_text);
}


reset_stats :: proc(using ctx := imm_context) {
    stats.num_draw_calls = 0;
    stats.num_quads      = 0;
    stats.num_triangles  = 0;
    stats.num_indices    = 0;
    stats.num_vertices   = 0;
    stats.num_textures   = 0;
    stats.num_scissors   = 0;
}

set_render_target_ :: proc(target : jvk.Render_Target, using ctx := imm_context) {
    active_target = target;
}
set_render_target_surface :: proc(surface : ^jvk.Draw_Surface, using ctx := imm_context) {
    // #Incomplete
    assert(surface == gfx.window_surface, "Multiple surfaces not supported");
    active_target = nil;
}
set_render_target :: proc{
    set_render_target_,
    set_render_target_surface,
}

set_projection_ortho :: proc(L, R, B, T : f32, near :f32= 0.1, far :f32= 10, using ctx := imm_context) {
    camera.proj = lin.ortho(L,R,B,T,near,far);
}
set_projection_perspective :: proc(fov, aspect, near, far : f32, using ctx := imm_context) {
    camera.proj = lin.perspective(fov, aspect, near, far);
}

set_default_2D_camera :: proc(width, height : f32, using ctx := imm_context) {
    set_projection_ortho(0, width, 0, height);
    camera.view = lin.identity(lin.Matrix4) * lin.translate({0, 0, 1});
}
set_default_3D_camera :: proc(width, height : f32, using ctx := imm_context) {
    set_projection_perspective(60, width/height, 0.1, 100);
    camera.view = lin.identity(lin.Matrix4) * lin.translate({0, 0, 2});
}

set_view_look_at :: proc(eye, center, up : lin.Vector3, using ctx := imm_context) {
    camera.view = lin.inverse(lin.look_at(eye, center, up));
}

push_transform :: proc(transform : lin.Matrix4, using ctx := imm_context) {
    append(&transform_stack, transform);
    front_transform *= transform;
}
push_translation :: proc(p : lin.Vector3, using ctx := imm_context) {
    push_transform(lin.translate(p), ctx);
}
push_rotation :: proc(axis : lin.Vector3, angle_rads : f32, using ctx := imm_context) {
    push_transform(lin.rotate(axis, angle_rads), ctx);
}
push_rotation_x :: proc(angle_rads : f32, using ctx := imm_context) {
    push_transform(lin.rotate({1, 0, 0}, angle_rads), ctx);
}
push_rotation_y :: proc(angle_rads : f32, using ctx := imm_context) {
    push_transform(lin.rotate({0, 1, 0}, angle_rads), ctx);
}
push_rotation_z :: proc(angle_rads : f32, using ctx := imm_context) {
    push_transform(lin.rotate({0, 0, -1}, angle_rads), ctx);
}
push_scale :: proc(scale : lin.Vector3, using ctx := imm_context) {
    push_transform(lin.scale(scale), ctx);
}
// Pushes current transform inversed, useful for resetting without
// popping the tranform stack
push_inverse_transform :: proc(using ctx := imm_context) {
    push_transform(lin.inverse(front_transform), ctx);
}
pop_one_transform :: proc(using ctx := imm_context) {
    assert(len(transform_stack) > 0, "Pop empty transform stack");
    pop(&transform_stack);

    front_transform = lin.identity(lin.Matrix4);
    for transform in transform_stack {
        front_transform *= transform;
    }
}
pop_transforms :: proc(n : int, using ctx := imm_context) {
    assert(len(transform_stack) > n-1, "Pop empty transform stack");
    for i in 0..<n do pop(&transform_stack);

    front_transform = lin.identity(lin.Matrix4);
    for transform in transform_stack {
        front_transform *= transform;
    }
}
clear_transforms :: proc(using ctx := imm_context) {
    clear(&transforms);
    clear(&transform_stack);
    front_transform = lin.identity(lin.Matrix4);
}

bind_texture_and_flush_if_needed :: proc(using ctx : ^Imm_Context, texture : jvk.Texture) -> (texture_index : i32){

    texture_index = -1;

    if cast(int)next_texture_slot >= max_textures_per_pipeline {
        _internal_flush(ctx);
        _rebegin(ctx);
    }

    for i in 0..<next_texture_slot {
        if texture.vk_image_view == texture_slots[i].vk_image_view {
            return cast(i32)i;
        }
    }
    
    if texture_index == -1 {
        texture_slots[next_texture_slot] = texture;
        texture_index = cast(i32)next_texture_slot;
        next_texture_slot += 1;
        stats.num_textures += 1;
    }

    return  texture_index;
}

clear_target :: proc(color : lin.Vector4, using ctx := imm_context) {
    assert(active_pipeline != nil, "imm.clear_target was called before imm.begin");
    if active_target != nil {
        jvk.begin_draw(active_pipeline, active_target.(jvk.Render_Target));
    } else {
        jvk.begin_draw_surface(active_pipeline, gfx.window_surface);
    }

    if active_pipeline.current_target.depth_image != 0 {
        jvk.cmd_clear(active_pipeline, clear_color={0, 0, 0, 1.0}, clear_mask={.DEPTH});
    }
    jvk.cmd_clear(active_pipeline, clear_color=color, clear_mask={.COLOR});
    jvk.end_draw(active_pipeline);
}

set_scissor_box :: proc(x, y, width, height : f32, using ctx := imm_context) {

    if len(scissor_boxes) >= MAX_SCISSOR_BOXES_PER_PIPELINE {
        _internal_flush(ctx);
        _rebegin(ctx);
    }

    append(&scissor_boxes, lin.Vector4{x, y, width, height});
    current_scissor_index = len(scissor_boxes)-1;

    stats.num_scissors += 1;
}


rectangle_by_bounds :: proc(p : lin.Vector3, size : lin.Vector2, using ctx := imm_context, color := gfx.WHITE, texture : Maybe(jvk.Texture) = nil, uv_range := lin.Vector4{0, 0, 1, 1}, vertex_type :i32= VERTEX_TYPE_REGULAR) -> []Vertex {
    hs := size / 2;
    return rectangle_by_aabb(
        p + { -hs.x, -hs.y, p.z },
        p + { -hs.x,  hs.y, p.z },
        p + {  hs.x,  hs.y, p.z },
        p + {  hs.x, -hs.y, p.z },
        color=color,
        ctx=ctx,
        texture=texture,
        uv_BL={uv_range.x, uv_range.y},
        uv_TL={uv_range.x, uv_range.w},
        uv_TR={uv_range.z, uv_range.w},
        uv_BR={uv_range.z, uv_range.y},
        vertex_type=vertex_type,
    );
}

rectangle_by_aabb :: proc(BL, TL, TR, BR : lin.Vector3, color := gfx.WHITE, using ctx := imm_context, texture : Maybe(jvk.Texture) = nil, uv_BL := lin.Vector2{0, 0}, uv_TL := lin.Vector2{0, 1}, uv_TR := lin.Vector2{1, 1}, uv_BR := lin.Vector2{1, 0}, vertex_type :i32= VERTEX_TYPE_REGULAR) -> []Vertex {
    reserve_vertices(ctx, len(ctx.vertices)+4);

    stats.num_quads += 1;
    stats.num_indices += 6;

    texture_index : i32 = -1;
    
    if texture != nil {
        texture_index = bind_texture_and_flush_if_needed(ctx, texture.(jvk.Texture));
    }

    start_index := cast(u32)len(ctx.vertices);

    append_elems(&ctx.vertices,
        _make_vertex(ctx, transform_pos(front_transform, BL) if len(transform_stack) > 0 else BL, tint=(color), texture_index=texture_index, uv=uv_BL, vertex_type=vertex_type),
        _make_vertex(ctx, transform_pos(front_transform, TL) if len(transform_stack) > 0 else TL, tint=(color), texture_index=texture_index, uv=uv_TL, vertex_type=vertex_type),
        _make_vertex(ctx, transform_pos(front_transform, TR) if len(transform_stack) > 0 else TR, tint=(color), texture_index=texture_index, uv=uv_TR, vertex_type=vertex_type),
        _make_vertex(ctx, transform_pos(front_transform, BR) if len(transform_stack) > 0 else BR, tint=(color), texture_index=texture_index, uv=uv_BR, vertex_type=vertex_type),
    );

    append_elems(&ctx.indices,
        start_index + 0,
        start_index + 1,
        start_index + 2,

        start_index + 0,
        start_index + 2,
        start_index + 3,
    );
    
    return vertices[len(vertices)-4:];
}
rectangle :: proc { rectangle_by_bounds, rectangle_by_aabb }

rectangle_by_bounds_lined :: proc(p : lin.Vector3, size : lin.Vector2, using ctx := imm_context, color := gfx.WHITE, thickness :f32=1) -> []Vertex {
    hs := size / 2;
    return rectangle_by_aabb_lined(
        p + { -hs.x, -hs.y, p.z },
        p + { -hs.x,  hs.y, p.z },
        p + {  hs.x,  hs.y, p.z },
        p + {  hs.x, -hs.y, p.z },
        color=color,
        ctx=ctx,
        thickness=thickness
    );
}

rectangle_by_aabb_lined :: proc(BL, TL, TR, BR : lin.Vector3, color := gfx.WHITE, using ctx := imm_context, thickness :f32=1) -> []Vertex {
    first_index := len(vertices);
    
    line(BL, TL, thickness, color, ctx);
    line(TL, TR, thickness, color, ctx);
    line(TR, BR, thickness, color, ctx);
    line(BR, BL, thickness, color, ctx);

    return vertices[first_index:];
}
rectangle_lined :: proc { rectangle_by_bounds_lined, rectangle_by_aabb_lined }




cube :: proc(p : lin.Vector3, size : lin.Vector3, color := gfx.WHITE, using ctx := imm_context) -> []Vertex {
    BL  := p + {-size.x/2, -size.y/2, -size.z/2};
    TL  := p + {-size.x/2,  size.y/2, -size.z/2};
    TR  := p + { size.x/2,  size.y/2, -size.z/2};
    BR  := p + { size.x/2, -size.y/2, -size.z/2};
    BL2 := p + {-size.x/2, -size.y/2,  size.z/2};
    TL2 := p + {-size.x/2,  size.y/2,  size.z/2};
    TR2 := p + { size.x/2,  size.y/2,  size.z/2};
    BR2 := p + { size.x/2, -size.y/2,  size.z/2};
    return cuboid(BL, TL, TR, BR, BL2, TL2, TR2, BR2, color, ctx);
}

// "Cube" by 8 points i.e. cuboid
cuboid :: proc(BL, TL, TR, BR, BL2, TL2, TR2, BR2 : lin.Vector3, color := gfx.WHITE, using ctx := imm_context) -> []Vertex {
    reserve_vertices(ctx, len(ctx.vertices)+24);

    start_index := cast(u32)len(ctx.vertices);

    rectangle_by_aabb(BL, TL, TR, BR, color, ctx); // Back face
    rectangle_by_aabb(BL2, TL2, TR2, BR2, color, ctx); // Front face
    rectangle_by_aabb(BL, TL, TL2, BL2, color, ctx); // Left face
    rectangle_by_aabb(BR, TR, TR2, BR2, color, ctx); // Right face
    rectangle_by_aabb(BL, BR, BR2, BL2, color, ctx); // Bottom face
    rectangle_by_aabb(TL, TR, TR2, TL2, color, ctx); // Top face

    return vertices[start_index:];
}

cube_lined :: proc(p : lin.Vector3, size : lin.Vector3, color := gfx.WHITE, thickness :f32=1, using ctx := imm_context) -> []Vertex {
    BL  := p + {-size.x/2, -size.y/2, -size.z/2};
    TL  := p + {-size.x/2,  size.y/2, -size.z/2};
    TR  := p + { size.x/2,  size.y/2, -size.z/2};
    BR  := p + { size.x/2, -size.y/2, -size.z/2};
    BL2 := p + {-size.x/2, -size.y/2,  size.z/2};
    TL2 := p + {-size.x/2,  size.y/2,  size.z/2};
    TR2 := p + { size.x/2,  size.y/2,  size.z/2};
    BR2 := p + { size.x/2, -size.y/2,  size.z/2};
    return cuboid_lined(BL, TL, TR, BR, BL2, TL2, TR2, BR2, color, thickness, ctx);
}

cuboid_lined :: proc(BL, TL, TR, BR, BL2, TL2, TR2, BR2 : lin.Vector3, color := gfx.WHITE, thickness :f32=1, using ctx := imm_context) -> []Vertex {
    first_index := len(vertices);
    
    line(BL, TL, thickness, color, ctx);
    line(TL, TR, thickness, color, ctx);
    line(TR, BR, thickness, color, ctx);
    line(BR, BL, thickness, color, ctx);

    line(BL2, TL2, thickness, color, ctx);
    line(TL2, TR2, thickness, color, ctx);
    line(TR2, BR2, thickness, color, ctx);
    line(BR2, BL2, thickness, color, ctx);

    line(BL, BL2, thickness, color, ctx);
    line(TL, TL2, thickness, color, ctx);
    line(TR, TR2, thickness, color, ctx);
    line(BR, BR2, thickness, color, ctx);

    return vertices[first_index:];
}

sphere :: proc(p : lin.Vector3, radius : f32, color := gfx.WHITE, segments := 16, using ctx := imm_context) -> []Vertex {
    return ellipsoid(p, {radius*2, radius*2, radius*2}, color=color, segments=segments);
}

sphere_lined :: proc(p : lin.Vector3, radius : f32, color := gfx.WHITE, segments := 16, thickness :f32=1, using ctx := imm_context) -> []Vertex {
    return ellipsoid_lined(p, {radius*2, radius*2, radius*2}, color=color, segments=segments, thickness=thickness);
}

ellipsoid :: proc(p : lin.Vector3, size : lin.Vector3, color := gfx.WHITE, segments := 16, using ctx := imm_context) -> []Vertex {
    reserve_vertices(ctx, len(ctx.vertices) + segments * segments * 6);

    start_index := cast(u32)len(ctx.vertices);

    for i in 0..<segments {
        for j in 0..<segments {
            u0 := cast(f32)i / cast(f32)segments;
            u1 := cast(f32)(i+1) / cast(f32)segments;
            v0 := cast(f32)j / cast(f32)segments;
            v1 := cast(f32)(j+1) / cast(f32)segments;

            ellipsoidal_to_cartesian :: proc(p : lin.Vector3, size : lin.Vector3, theta, phi : f32) -> lin.Vector3 {
                return p + lin.Vector3{
                    size.x * math.sin(theta) * math.cos(phi),
                    size.y * math.cos(theta),
                    size.z * math.sin(theta) * math.sin(phi)
                };
            }

            p0 := ellipsoidal_to_cartesian(p, size/2, u0 * math.PI, v0 * 2 * math.PI);
            p1 := ellipsoidal_to_cartesian(p, size/2, u1 * math.PI, v0 * 2 * math.PI);
            p2 := ellipsoidal_to_cartesian(p, size/2, u1 * math.PI, v1 * 2 * math.PI);
            p3 := ellipsoidal_to_cartesian(p, size/2, u0 * math.PI, v1 * 2 * math.PI);

            triangle_abc(p + p0, p + p1, p + p2, color, ctx);
            triangle_abc(p + p0, p + p2, p + p3, color, ctx);
        }
    }

    return vertices[start_index:];
}

ellipsoid_lined :: proc(p : lin.Vector3, size : lin.Vector3, color := gfx.WHITE, segments := 16, thickness :f32 = 1, using ctx := imm_context) -> []Vertex {
    reserve_vertices(ctx, len(ctx.vertices) + segments * segments * 6);

    start_index := cast(u32)len(ctx.vertices);

    for i in 0..<segments {
        for j in 0..<segments {
            u0 := cast(f32)i / cast(f32)segments;
            u1 := cast(f32)(i+1) / cast(f32)segments;
            v0 := cast(f32)j / cast(f32)segments;
            v1 := cast(f32)(j+1) / cast(f32)segments;

            ellipsoidal_to_cartesian :: proc(p : lin.Vector3, size : lin.Vector3, theta, phi : f32) -> lin.Vector3 {
                return p + lin.Vector3{
                    size.x * math.sin(theta) * math.cos(phi),
                    size.y * math.cos(theta),
                    size.z * math.sin(theta) * math.sin(phi)
                };
            }

            p0 := ellipsoidal_to_cartesian(p, size/2, u0 * math.PI, v0 * 2 * math.PI);
            p1 := ellipsoidal_to_cartesian(p, size/2, u1 * math.PI, v0 * 2 * math.PI);
            p2 := ellipsoidal_to_cartesian(p, size/2, u1 * math.PI, v1 * 2 * math.PI);
            p3 := ellipsoidal_to_cartesian(p, size/2, u0 * math.PI, v1 * 2 * math.PI);

            line(p + p0, p + p1, thickness, color, ctx);
            line(p + p1, p + p2, thickness, color, ctx);
            line(p + p2, p + p3, thickness, color, ctx);
            line(p + p3, p + p0, thickness, color, ctx);
        }
    }

    return vertices[start_index:];
}

shadow_rectangle :: proc(p : lin.Vector3, size : lin.Vector2, smoothness : f32  = 0.05, width : f32 = 0.1, color := gfx.BLACK, using ctx := imm_context) -> []Vertex {
    return rectangle_by_bounds(p, size, ctx=ctx, color=color, vertex_type = VERTEX_TYPE_SHADOW_RECT);    
}

triangle_isosceles :: proc(p : lin.Vector3, size : lin.Vector2, dir := lin.Vector3{0, 1, 0}, color := gfx.WHITE, using ctx := imm_context, texture : Maybe(jvk.Texture) = nil, uva := lin.Vector2{0, 0}, uvb := lin.Vector2{0, 1}, uvc := lin.Vector2{1, 0}) -> []Vertex {
    dir_norm := lin.normalize(dir);
    
    arbitrary_perpendicular := lin.Vector3{1, 0, 0};
    if dir_norm == arbitrary_perpendicular {
        arbitrary_perpendicular = lin.Vector3{0, 0, 1};
    }
    base_dir := lin.cross(dir_norm, arbitrary_perpendicular);
    base_dir  = lin.normalize(lin.cross(base_dir, dir_norm));
    
    base_half_width := base_dir * (size.x / 2.0);
    
    up := dir_norm;
    top := p + (up * size.y/2.0);
    bot_center := p - (up * size.y/2.0); 
    
    bot_left := bot_center - base_half_width;
    bot_right := bot_center + base_half_width;
    
    return triangle_abc(bot_left, top, bot_right, color, ctx, texture, uva, uvb, uvc);
}
triangle_abc :: proc(a, b, c : lin.Vector3, color := gfx.WHITE, using ctx := imm_context, texture : Maybe(jvk.Texture) = nil, uva := lin.Vector2{0, 0}, uvb := lin.Vector2{0, 1}, uvc := lin.Vector2{1, 0}) -> []Vertex {
    reserve_vertices(ctx, len(ctx.vertices)+3);

    stats.num_triangles += 1;
    stats.num_indices += 3;

    texture_index : i32 = -1;
    
    if texture != nil {
        texture_index = bind_texture_and_flush_if_needed(ctx, texture.(jvk.Texture));
    }

    start_index := cast(u32)len(ctx.vertices);

    append_elems(&ctx.vertices,
        _make_vertex(ctx, transform_pos(front_transform, a) if len(transform_stack) > 0 else a, tint=(color), texture_index=texture_index, uv=uva),
        _make_vertex(ctx, transform_pos(front_transform, b) if len(transform_stack) > 0 else b, tint=(color), texture_index=texture_index, uv=uvb),
        _make_vertex(ctx, transform_pos(front_transform, c) if len(transform_stack) > 0 else c, tint=(color), texture_index=texture_index, uv=uvc),
    );

    append_elems(&ctx.indices,
        start_index + 0,
        start_index + 1,
        start_index + 2,
    );

    return vertices[len(vertices)-3:];
}
triangle :: proc {triangle_abc, triangle_isosceles};

circle :: proc(p : lin.Vector3, radius : f32, color := gfx.WHITE, using ctx := imm_context, texture : Maybe(jvk.Texture) = nil) -> []Vertex {
    return rectangle_by_bounds(p, {radius*2, radius*2}, ctx, color, texture, vertex_type = VERTEX_TYPE_CIRCLE);
}

line :: proc(p0, p1 : lin.Vector3, thickness :f32= 1, color := gfx.WHITE, using ctx := imm_context) -> []Vertex {
    dir := lin.normalize(p1 - p0);

    inv_view := lin.inverse(camera.view);

    cam_right := inv_view[2][0];
    cam_up := -inv_view[2][1];
    cam_forward := inv_view[2][2];

    camera_dir := lin.Vector3{cam_right, cam_up, cam_forward};
    
    perp_dir := lin.normalize(lin.cross(dir, camera_dir)) * (thickness / 2.0);
    
    return rectangle_by_aabb(
        p0 + perp_dir, // BL
        p0 - perp_dir, // TL
        p1 - perp_dir, // TR
        p1 + perp_dir, // BR
        color=color, ctx=ctx,
    );
}

text_fast :: proc(text : Rendered_Text, p : lin.Vector3, color := gfx.WHITE, background_color : Maybe(lin.Vector4)= nil, using ctx := imm_context, font := imm_context.default_font) -> (box : lin.Vector4) {
    rectangle(p, text.size, ctx, color, text.atlas_texture, text.uv_range, vertex_type=VERTEX_TYPE_TEXT);
    return {p.x, p.y, text.size.x, text.size.y};
}
text_slow :: proc(str : string, p : lin.Vector3, color := gfx.WHITE, background_color : Maybe(lin.Vector4)= nil, using ctx := imm_context, font := imm_context.default_font) -> (box : lin.Vector4) {
    text_size := gfxtext.measure(font, str);

    if background_color != nil {
        rectangle(p, text_size, color=background_color.(lin.Vector4));
    }

    half_text_size := text_size/2.0;
    pen : f32 = 0;
    line : f32 = 0;
    index_in_line := 0;
    last_glyph : rune = -1;
    for r in str {

        atlas := gfxtext.get_atlas_for_glyph(font, r);
        
        if r == '\n' {
            pen = 0;
            index_in_line = 0;
            line += 1;
            continue;
        } else if r == '\t' {
            space_glyph := gfxtext.get_glyph_info(font, ' ');
            num_spaces := gfxtext.TAB_STOP_SIZE - (index_in_line) % (gfxtext.TAB_STOP_SIZE);
            
            pen += space_glyph.advance * cast(f32)num_spaces;
            index_in_line += num_spaces;
            continue;
        }
        
        if last_glyph != -1 {
            pen += gfxtext.get_kerning_advance(font, last_glyph, r);
        }
        gfxtext.assure_glyph_rendered(font, r);
        last_glyph = r;
        
        glyph := gfxtext.get_glyph_info(font, r);
        
        uv := glyph.uv;
        width := glyph.width;
        height := glyph.height;
        
        pen_x := p.x + pen + glyph.xbearing - half_text_size.x;
        pen_y := p.y - font.ascent - cast(f32)glyph.yoffset - line * (font.ascent + font.line_gap - font.descent) + half_text_size.y;

        hs := lin.Vector2{cast(f32)width,cast(f32)height} / 2.0;

        rectangle_by_bounds({ pen_x, pen_y, 0 } - {-hs.x, hs.y, 0}, {f32(width), f32(height)}, ctx=ctx, color=color, texture=atlas.texture, uv_range=uv, vertex_type=VERTEX_TYPE_TEXT);
        
        pen += cast(f32)glyph.advance;

        index_in_line += 1;
    }

    return {p.x, p.y, text_size.x, text_size.y};
}

text :: proc {
    text_slow,
    text_fast,
}

begin :: proc(pipeline : ^jvk.Pipeline, using ctx := imm_context) {
    assert(active_pipeline == nil, "begin/end mismatch: imm.begin was called twice");
    clear(&vertices);
    clear(&indices);
    clear_transforms(ctx);

    active_pipeline = pipeline;
    next_texture_slot = 0;
    current_scissor_index = -1;
}
begin2d :: proc(using ctx := imm_context) {
    if active_target != nil {
        begin(pipeline_2d_offscreen, ctx);
    } else {
        begin(pipeline_2d, ctx);
    }
}
begin3d :: proc(using ctx := imm_context) {
    if active_target != nil {
        begin(pipeline_3d_offscreen, ctx);
    } else {
        begin(pipeline_3d, ctx);
    }
}
_rebegin :: proc(using ctx := imm_context) {
    clear(&vertices);
    clear(&indices);
    next_texture_slot = 0;
}
_internal_flush :: proc(using ctx : ^Imm_Context) {
    pipeline := ctx.active_pipeline;

    assert(len(vertices) * size_of(Vertex) <= current_vbo_size, "VBO management error");
    assert(len(indices) * size_of(u32) <= current_ibo_size, "IBO management error");

    vbo         := vbos[gfx.window_surface.frame_index];
    ibo         := ibos[gfx.window_surface.frame_index];
    camera_ubo  := camera_ubos[gfx.window_surface.frame_index];
    scissor_ubo := scissor_ubos[gfx.window_surface.frame_index];
    
    if len(vertices) > 0 {
        w, h := glfw.GetWindowSize(gfx.window);
        camera.viewport = {cast(f32)w, cast(f32)h};
        camera_copy := camera;
        camera_copy.view = lin.inverse(camera_copy.view);

        jvk.set_buffer_data(vbo, slice.as_ptr(vertices[:]), len(vertices) * size_of(Vertex));
        jvk.set_buffer_data(ibo, slice.as_ptr(indices[:]), len(indices) * size_of(u32));
        jvk.set_buffer_data(camera_ubo, &camera_copy, size_of(camera_copy));
        jvk.set_buffer_data(scissor_ubo, builtin.raw_data(scissor_boxes[:]), size_of(lin.Vector4) * len(scissor_boxes));

        has_camera_ubo, has_scissor_ubo, has_samplers : bool;

        for db, i in pipeline.program.program_layout.descriptor_bindings {
            if db.location == 0 && db.field.name == "samplers" && db.field.type.kind == .ARRAY && db.field.type.elem_type.kind == .SAMPLER2D {
                has_samplers = true;
            }

            if db.location == 1 && db.kind == .UNIFORM_BUFFER && db.field.type.std140_size >= size_of(Camera) {
                has_camera_ubo = true;
            }

            if db.location == 2 && db.kind == .UNIFORM_BUFFER && db.field.type.std140_size >= size_of(lin.Vector4) * MAX_SCISSOR_BOXES_PER_PIPELINE {
                has_scissor_ubo = true;
            }
        }

        if has_camera_ubo do jvk.bind_uniform_buffer(pipeline, camera_ubo, 1);
        if has_scissor_ubo do jvk.bind_uniform_buffer(pipeline, scissor_ubo, 2);
    
        if has_samplers do for slot in 0..<next_texture_slot {
            texture := texture_slots[slot]; 
            // #Speed: bind only if not already bound
            jvk.bind_texture(pipeline, texture, jvk.get_program_descriptor_binding(pipeline.program, "samplers"), cast(int)slot);
        }

        if active_target != nil {
            jvk.begin_draw(pipeline, active_target.(jvk.Render_Target));
        } else {
            jvk.begin_draw_surface(pipeline, gfx.window_surface);
        }
    
        //jvk.cmd_set_push_constant(pipeline, &camera_copy, 0, size_of(Camera));
        jvk.cmd_draw_indexed(pipeline, vbo, ibo, index_count=len(indices));

        jvk.end_draw(pipeline);
    }
    
    clear(&scissor_boxes);    
    current_scissor_index = -1;

    stats.num_draw_calls += 1;
}
flush :: proc(using ctx := imm_context) {
    assert(active_pipeline != nil, "begin/end mismatch: imm.end was called befrei imm.begin");
    _internal_flush(ctx);
    active_pipeline = nil;
    active_target = nil;
}

allocate_gpu_buffers :: proc(using ctx : ^Imm_Context, num_vertices : int) {
    // #Incomplete
    num_indices := (num_vertices / 4) * 6;

    if vbos != nil {
        for vbo in vbos {
            jvk.destroy_vertex_buffer(vbo);
        }
    } else {
        vbos = make([]^jvk.Vertex_Buffer, gfx.window_surface.number_of_frames);
    }
    if ibos != nil {
        for ibo in ibos {
            jvk.destroy_index_buffer(ibo);
        }
    } else {
        ibos = make([]^jvk.Index_Buffer, gfx.window_surface.number_of_frames);
    }

    

    for v,i in vbos {
        vbos[i] = jvk.make_vertex_buffer(make([]Vertex, num_vertices, allocator=context.temp_allocator), .RAM_SYNCED);
    }
    for _,i in vbos {
        ibos[i] = jvk.make_index_buffer(make([]u32, num_indices, allocator=context.temp_allocator), .RAM_SYNCED);
    }

    current_vbo_size = num_vertices * size_of(Vertex);
    current_ibo_size = num_indices  * size_of(u32);

    log.debugf("Resized imm vertex buffer to fit %i vertices and %i indices", num_vertices, num_indices);
}
reserve_vertices :: proc(using ctx : ^Imm_Context, num_vertices : int) {;
    if cap(vertices) >= num_vertices do return;

    num_vertices := num_vertices; 

    num_vertices = math.max(cap(vertices) * 2, num_vertices);

    num_indices := (num_vertices / 4) * 6;

    reserve(&vertices, num_vertices);
    reserve(&indices, num_indices);
    
    allocate_gpu_buffers(ctx, num_vertices);
}

make_context :: proc (hint_vertices := 1000) -> ^Imm_Context {
    
    using ctx := new(Imm_Context);

    ctx.max_textures_per_pipeline = min(MAX_TEXTURES_PER_PIPELINE, cast(int)jvk.get_target_device_context().graphics_device.props.limits.maxPerStageDescriptorSamplers);
    
    ok := false;
    default_font_family, ok = gfxtext.open_font_family(cast([^]byte)builtin.raw_data(data.BINARY_DATA_FONT_METROPOLIS), len(data.BINARY_DATA_FONT_METROPOLIS));
    assert(ok, "Failed loading default font");
    default_font = gfxtext.make_font_variation(default_font_family, DEFAULT_FONT_SIZE);

    pipeline_2d = jvk.make_pipeline(shaders.basic2d, gfx.window_surface.render_pass);
    pipeline_3d = jvk.make_pipeline(shaders.basic3d, gfx.window_surface.render_pass, enable_depth_test=true);

    // #Limitation #Incomplete
    // This limits us to only being able to render to render targets with f32 argb 4-channel textures.
    // Could make pipelines for each format we want to support but it feels like this
    // needs a more elegant solution.
    pipeline_2d_offscreen = jvk.make_pipeline(shaders.basic2d, gfx.window_surface.dc.default_offscreen_color_render_pass_srgb_f32);
    pipeline_3d_offscreen = jvk.make_pipeline(shaders.basic3d, gfx.window_surface.dc.default_offscreen_color_render_pass_srgb_f32, enable_depth_test=true);

    text_atlas_pass = jvk.make_render_pass(.R8_UNORM, .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL);
    text_atlas_pipeline = jvk.make_pipeline(shaders.text_atlas, text_atlas_pass);

    vertices = make([dynamic]Vertex);
    indices = make([dynamic]u32);
    transforms = make([dynamic]lin.Matrix4);
    transform_stack = make([dynamic]lin.Matrix4);
    scissor_boxes = make([dynamic]lin.Vector4);
    front_transform = lin.identity(lin.Matrix4);
    texture_slots = make_dynamic_array_len([dynamic]jvk.Texture, max_textures_per_pipeline);
    reserve_vertices(ctx, hint_vertices);

    camera_ubos = make([]^jvk.Uniform_Buffer, gfx.window_surface.number_of_frames);
    for _,i in camera_ubos {
        camera_ubos[i] = jvk.make_uniform_buffer(Camera, .RAM_SYNCED);
    }
    scissor_ubos = make([]^jvk.Uniform_Buffer, gfx.window_surface.number_of_frames);
    for _,i in scissor_ubos {
        Scissor_Ubo :: struct {
            scissors : [MAX_SCISSOR_BOXES_PER_PIPELINE]lin.Vector4,
        };
        scissor_ubos[i] = jvk.make_uniform_buffer(Scissor_Ubo, .RAM_SYNCED);
    }

    return ctx;
}

set_context :: proc(ctx : ^Imm_Context) {
    imm_context = ctx;
}

make_and_set_context :: proc(hint_vertices := 1000) {
    set_context(make_context(hint_vertices));
}

get_current_context :: proc() -> ^Imm_Context {
    return imm_context;
}

delete_context :: proc(using ctx : ^Imm_Context) {
    log.debug("imm context deletion");

    for vbo in vbos do jvk.destroy_vertex_buffer(vbo);
    for ibo in ibos do jvk.destroy_index_buffer(ibo);
    for ubo in camera_ubos do jvk.destroy_uniform_buffer(ubo);
    for ubo in scissor_ubos do jvk.destroy_uniform_buffer(ubo);

    delete(vbos);
    delete(ibos);
    delete(camera_ubos);
    delete(scissor_ubos);

    jvk.destroy_render_pass(text_atlas_pass);

    jvk.destroy_pipeline(pipeline_2d);
    jvk.destroy_pipeline(pipeline_2d_offscreen);
    jvk.destroy_pipeline(pipeline_3d);
    jvk.destroy_pipeline(pipeline_3d_offscreen);
    jvk.destroy_pipeline(text_atlas_pipeline);

    delete(vertices);
    delete(indices);
    delete(texture_slots);
    delete(transform_stack);
    delete(scissor_boxes);

    gfxtext.delete_font_variation(default_font);
    
    gfxtext.close_font_family(default_font_family);

    free(ctx);
}

delete_current_context :: proc() {
    delete_context(get_current_context());
}




init :: proc() {
    init_shaders();
}

shutdown :: proc() {
    log.debug("imm shutdown");
    destroy_shaders();
}