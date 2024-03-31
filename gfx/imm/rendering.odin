package imm

import jvk "jamgine:gfx/justvk"
import "jamgine:glsl_inspect"
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

// In vulkan this is a lot higher (on my device ~1000000), but that is simply
// too much and will use way to much VRAM in a single shader just to store the
// samplers that could potentially be used.
MAX_TEXTURES_PER_PIPELINE :: 32

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

DATA_INDEX_TRANSFORM_INDEX :: 0
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

}
Clear_Request :: struct {
    aspect : vk.ImageAspectFlags,
    color : lin.Vector4,
}
Imm_Context :: struct {

    // One buffer per window frame so they can be stored in ram and reflected on gpu without screen flickering
    vbos                  : []^jvk.Vertex_Buffer,
    ibos                  : []^jvk.Index_Buffer,

    current_vbo_size      : int,
    current_ibo_size      : int,

    pipeline_2d           : ^jvk.Pipeline,
    pipeline_2d_offscreen : ^jvk.Pipeline,

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
    front_transform       : lin.Matrix4,
    next_transform_index  : int,
    next_texture_slot     : i32,

    camera : Camera,

    stats           :  Stats,

    target_fbo      : c.uint,

    default_font_family : ^gfxtext.Font_Family,
    default_font : ^gfxtext.Font_Variation,
}


imm_context : ^Imm_Context;


transform_pos_vec3 :: proc(transform : lin.Matrix4, pos : lin.Vector3) -> lin.Vector3{
    return (transform * lin.Vector4{pos.x, pos.y, pos.z, 1.0}).xyz;
}
transform_pos :: proc{transform_pos_vec3}

_make_vertex :: proc(using ctx : ^Imm_Context, pos : lin.Vector3, tint := gfx.WHITE, uv := lin.Vector2{0, 0}, texture_index : i32 = -1, transform_index : i32 = -1, vertex_type :i32= VERTEX_TYPE_REGULAR) -> Vertex{
    assert(active_pipeline != nil, "begin/flush mismatch; please call imm.begin() before drawing");
    v : Vertex;
    v.pos = pos;
    v.tint = tint;
    v.uv = uv;
    v.data_indices[DATA_INDEX_TRANSFORM_INDEX] = transform_index;
    v.data_indices[DATA_INDEX_VERTEX_TYPE] = vertex_type;
    v.data_indices[DATA_INDEX_TEXTURE_INDEX] = texture_index;
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

set_default_2D_camera :: proc(width, height : f32, using ctx := imm_context) {
    set_projection_ortho(0, width, 0, height);
    camera.view = lin.identity(lin.Matrix4) * lin.translate({0, 0, 1});
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

    if cast(u32)next_texture_slot >= MAX_TEXTURES_PER_PIPELINE {
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

    jvk.cmd_clear(active_pipeline, clear_color=color);
    jvk.end_draw(active_pipeline);
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
    stats.num_vertices += 4;
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
    stats.num_vertices += 3;
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
    return rectangle_by_bounds(p, {radius, radius}, ctx, color, texture, vertex_type = VERTEX_TYPE_CIRCLE);
}

line :: proc(p0, p1 : lin.Vector3, thickness :f32= 1, color := gfx.WHITE, using ctx := imm_context) -> []Vertex {
    dir := lin.normalize(p1 - p0);

    camera_dir_x := -camera.view[2][0];
    camera_dir_y := -camera.view[2][1];
    camera_dir_z := -camera.view[2][2];

    camera_dir := lin.Vector3{camera_dir_x, camera_dir_y, camera_dir_z};
    
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
}
begin2d :: proc(using ctx := imm_context) {
    if active_target != nil {
        begin(pipeline_2d_offscreen, ctx);
    } else {
        begin(pipeline_2d, ctx);
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

    vbo := vbos[gfx.window_surface.frame_index];
    ibo := ibos[gfx.window_surface.frame_index];

    if len(vertices) >= 0 { 
        jvk.set_buffer_data(vbo, slice.as_ptr(vertices[:]), len(vertices) * size_of(Vertex));
        jvk.set_buffer_data(ibo, slice.as_ptr(indices[:]), len(indices) * size_of(u32));
    
        for slot in 0..<next_texture_slot {
            texture := texture_slots[slot]; 
            // #Speed: bind only if not already bound
            jvk.bind_texture(pipeline, texture, jvk.get_program_descriptor_binding(pipeline.program, "samplers"), cast(int)slot);
        }
    }
    

    if active_target != nil {
        jvk.begin_draw(pipeline, active_target.(jvk.Render_Target));
    } else {
        jvk.begin_draw_surface(pipeline, gfx.window_surface);
    }

    if len(vertices) >= 0 {
    
        w, h := glfw.GetWindowSize(gfx.window);
        camera.viewport = {cast(f32)w, cast(f32)h};
        camera_copy := camera;
        camera_copy.view = lin.inverse(camera_copy.view);
        jvk.cmd_set_push_constant(pipeline, &camera_copy, 0, size_of(Camera));
        jvk.cmd_draw_indexed(pipeline, vbo, ibo, index_count=len(indices));
    }
    
    jvk.end_draw(pipeline);
    
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

    ok := false;
    default_font_family, ok = gfxtext.open_font_family(cast([^]byte)builtin.raw_data(data.BINARY_DATA_FONT_METROPOLIS), len(data.BINARY_DATA_FONT_METROPOLIS));
    assert(ok, "Failed loading default font");
    default_font = gfxtext.make_font_variation(default_font_family, 18);

    pipeline_2d = jvk.make_pipeline(shaders.basic2d, gfx.window_surface.render_pass);

    // #Limitation #Incomplete
    // This limits us to only being able to render to render targets with f32 argb 4-channel textures.
    // Could make pipelines for each format we want to support but it feels like this
    // needs a more elegant solution.
    pipeline_2d_offscreen = jvk.make_pipeline(shaders.basic2d, gfx.window_surface.dc.default_offscreen_color_render_pass_srgb_f32);

    text_atlas_pass = jvk.make_render_pass(.R8_UNORM, .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL);
    text_atlas_pipeline = jvk.make_pipeline(shaders.text_atlas, text_atlas_pass);

    vertices = make([dynamic]Vertex);
    indices = make([dynamic]u32);
    transforms = make([dynamic]lin.Matrix4);
    transform_stack = make([dynamic]lin.Matrix4);
    front_transform = lin.identity(lin.Matrix4);
    texture_slots = make_dynamic_array_len([dynamic]jvk.Texture, MAX_TEXTURES_PER_PIPELINE);
    reserve_vertices(ctx, hint_vertices);

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

    jvk.destroy_render_pass(text_atlas_pass);

    jvk.destroy_pipeline(pipeline_2d);
    jvk.destroy_pipeline(pipeline_2d_offscreen);
    jvk.destroy_pipeline(text_atlas_pipeline);

    delete(vertices);
    delete(indices);
    delete(texture_slots);
    delete(transform_stack);

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