package text

import stb "vendor:stb/truetype"
import "core:os"
import "core:builtin"
import "core:mem"
import "core:math"
import "core:log"
import jvk "jamgine:gfx/justvk"
import "core:fmt"
import "core:slice"

import "jamgine:gfx"
import "jamgine:lin"

ATLAS_RANGE :: 128
TAB_STOP_SIZE :: 4;

Font_Family :: struct {
    data : []byte,
    info : stb.fontinfo
}
Glyph :: struct {
    codepoint : rune,
    rendered : bool,

    xoffset, yoffset, width, height, xindex, yindex : int,

    xbearing, advance : f32,    

    uv : lin.Vector4,
}
Font_Atlas :: struct {
    texture : jvk.Texture,
    start, end : u32, // u32 codepoints
    loaded : bool,

    glyphs : [ATLAS_RANGE]Glyph,
}
Font_Variation :: struct {
    family : ^Font_Family,

    font_size : f32,
    atlas_width, atlas_height, atlas_rows, atlas_cols : i32,
    ascent, descent, line_gap : f32,

    atlases : map[int]Font_Atlas,
}

measure :: proc(font : ^Font_Variation, text : string) -> (sz : lin.Vector2) {
    last_glyph : rune = -1;
    curx :f32= 0.0;
    index_in_line := 0;
    sz.y = (font.ascent + font.line_gap - font.descent);
    for r in text {

        atlas := get_atlas_for_glyph(font, r);

        if r == '\n' {
            curx = 0;
            index_in_line = 0;
            sz.y += (font.ascent + font.line_gap - font.descent);

            if last_glyph != -1 {
                curx += get_glyph_info(font, last_glyph).advance - cast(f32)get_glyph_info(font, last_glyph).width;
                if curx > sz.x do sz.x = curx;
            }
            continue;
        } else if r == '\t' {
            space_glyph := get_glyph_info(font, ' ');
            num_spaces := TAB_STOP_SIZE - (index_in_line) % (TAB_STOP_SIZE);
            
            curx += space_glyph.advance * cast(f32)num_spaces;
            index_in_line += num_spaces;
            if curx > sz.x do sz.x = curx;
            continue;
        }

        if last_glyph != -1 {
            curx += get_kerning_advance(font, last_glyph, r);
        }
        last_glyph = r;
        
        glyph := get_glyph_info(font, r);
        
        width := glyph.width;
        height := glyph.height;
        
        curx += cast(f32)glyph.advance;
        if curx > sz.x do sz.x = curx;

        index_in_line += 1;
    }

    if last_glyph != -1 {
        curx += get_glyph_info(font, last_glyph).advance - cast(f32)get_glyph_info(font, last_glyph).width;
        if curx > sz.x do sz.x = curx;
    }

    return sz;
}

atlas_index_for_codepoint :: proc(c : rune) -> int {
    return (cast(int)c) / ATLAS_RANGE;
} 

get_atlas_for_glyph :: proc(font : ^Font_Variation, g : rune) -> ^Font_Atlas {
    return &font.atlases[atlas_index_for_codepoint(g)];
}

get_glyph_info :: proc (font : ^Font_Variation, g : rune) -> Glyph {
    assure_glyph_rendered(font, g);
    atlas := get_atlas_for_glyph(font, g);
    return atlas.glyphs[g % ATLAS_RANGE];
}

measure_text_width :: proc(font : ^Font_Variation, str : string) -> f32 {
    w : f32 = 0;
    for r in str {
        w += get_glyph_info(font, r).advance;
    }

    return w;
}

get_kerning_advance :: proc(using font : ^Font_Variation, ch0, ch1 : rune) -> f32 {
    scale := stb.ScaleForPixelHeight(&family.info, font_size);

    full_advance := stb.GetCodepointKernAdvance(&family.info, ch0, ch1);

    return f32(full_advance) * scale;
}

open_font_family_from_file :: proc(path : string) -> (family: ^Font_Family, ok: bool) {
    family = new (Font_Family);
    defer if !ok do free(family);
    
    family.data = os.read_entire_file(path) or_return;
    
    stb.InitFont(&family.info, builtin.raw_data(family.data), stb.GetFontOffsetForIndex(builtin.raw_data(family.data), 0)) or_return;
    
    log.debug("Opened font from ", path);

    return family, true;
}
open_font_family_from_memory :: proc(data : [^]byte, len : int) -> (family: ^Font_Family, ok: bool) {
    family = new (Font_Family);
    defer if !ok do free(family);
    
    family.data = slice.clone(mem.byte_slice(data, len));
    
    stb.InitFont(&family.info, builtin.raw_data(family.data), stb.GetFontOffsetForIndex(builtin.raw_data(family.data), 0)) or_return;

    log.debug("Opened font from memory");

    return family, true;
}

open_font_family :: proc {  open_font_family_from_file, open_font_family_from_memory }

close_font_family :: proc(family : ^Font_Family) {
    delete(family.data);
}

make_font_variation :: proc(family : ^Font_Family, font_size : f32) -> ^Font_Variation {
    assert(font_size > 1);
    total_width := font_size * ATLAS_RANGE;

    nrows := cast(int)math.ceil_f32(total_width / cast(f32)gfx.env.max_texture_size);
    height := cast(int)math.ceil(cast(f32)nrows * font_size);
    width := cast(int)math.ceil(min(total_width, cast(f32)gfx.env.max_texture_size));
    ncols := cast(int)math.ceil_f32(cast(f32)width / font_size);
    
    scale := stb.ScaleForPixelHeight(&family.info, font_size);
    x, y, ascent, descent, line_gap : i32;
    stb.GetFontVMetrics(&family.info, &ascent, &descent, &line_gap);

    upscaled_font_size := cast(i32)(font_size / scale);
    ratio := upscaled_font_size / (ascent - descent);

    f := new(Font_Variation);
    f.font_size = font_size;
    f.atlases = make(map[int]Font_Atlas);
    f.family = family;
    f.atlas_width  = cast(i32)width;
    f.atlas_height = cast(i32)(f32(ascent)-f32(descent)) + 1; // Sometimes we get a bitmap with a height thats atlas_height + 1 !??!?!??!?!? #Hack
    f.atlas_rows   = cast(i32)nrows;
    f.atlas_cols   = cast(i32)ncols;
    f.ascent       = cast(f32)ascent * scale;
    f.descent      = cast(f32)descent * scale;
    f.line_gap     = cast(f32)line_gap * scale;


    log.debug("Made a font variation of size", font_size);

    return f;
}
delete_font_variation :: proc(using f : ^Font_Variation) {

    for i, atlas in atlases {
        jvk.destroy_texture(atlas.texture);
    }

    delete(f.atlases);
    free(f);
}

assure_glyph_rendered :: proc(using font : ^Font_Variation, g : rune, loc := #caller_location) {

    atlas_index := atlas_index_for_codepoint(g);
    if atlas_index not_in font.atlases || !font.atlases[atlas_index].loaded {
        // #Hack
        // Logging to game console will recurse
        context.logger = log.create_console_logger();        
        defer log.destroy_console_logger(context.logger);
        
        font.atlases[atlas_index] = {};
        atlas := &font.atlases[atlas_index];
        atlas.loaded = true;

        sampler := jvk.DEFAULT_SAMPLER_SETTINGS;
        sampler.min_filter = .NEAREST;
        sampler.mag_filter = .NEAREST;
        atlas.texture = jvk.make_texture(cast(int)atlas_width, cast(int)atlas_height, nil, .SR, {.SAMPLE, .WRITE}, sampler);
        atlas.start = cast(u32)(atlas_index * ATLAS_RANGE);
        atlas.end   = cast(u32)(atlas.start + ATLAS_RANGE);
    }

    atlas := &font.atlases[atlas_index];

    local_glyph_index :i32 = cast(i32)g % ATLAS_RANGE;
    glyph := &atlas.glyphs[local_glyph_index];
    

    if !glyph.rendered {
        
        glyph.codepoint = g;

        log.debugf("Rendering glyph '%r' codepoint %i", glyph.codepoint, cast(int)glyph.codepoint);

        scale := stb.ScaleForPixelHeight(&family.info, font_size);
        glyph_index := stb.FindGlyphIndex(&family.info, g);
        
        adv_width, left_bearing : i32;
        stb.GetGlyphHMetrics(&family.info, glyph_index, &adv_width, &left_bearing);
        
        w, h, xoffset, yoffset : i32;
        bitmap := stb.GetGlyphBitmap(
            &family.info, 
            scale, 
            scale, 
            glyph_index, 
            &w, 
            &h, 
            &xoffset, 
            &yoffset,
        );

        xindex := local_glyph_index % atlas_cols;
        yindex := local_glyph_index / atlas_cols;

        // #Hack #Bug
        // For some reason GetGlyphBitmap sometimes returns a bitmap height thats
        // font pixel height + 1, even though we pass the scale.
        if h > atlas_height {
            log.warnf("stb GetGlyphBitmap return a bitmap height of %i for glyph %c (%i), but font atlas height is %i (scale: %f). Clamped to %i.", h, g, cast(int)g, atlas_height, scale, atlas_height);
            h = cast(i32)atlas_height;
        }
        
        xpos := cast(int)math.round(cast(f32)xindex * font_size);
        ypos := cast(int)math.round(cast(f32)yindex * font_size);
        
        if bitmap != nil && g != 0 {
            jvk.write_texture(atlas.texture, bitmap, cast(int)xpos, cast(int)ypos, cast(int)w, cast(int)h);
            stb.FreeBitmap(bitmap, nil);
        }
        
        glyph.xindex = cast(int)xindex;
        glyph.yindex = cast(int)yindex;
        glyph.width = cast(int)w;
        glyph.height = cast(int)h;
        glyph.advance = cast(f32)adv_width * scale;
        glyph.xoffset = cast(int)xoffset;
        glyph.yoffset = cast(int)yoffset;
        glyph.xbearing = cast(f32)left_bearing * scale;
        
        glyph.uv = {
            f32(xpos) / f32(atlas_width), 
            (f32(ypos) + f32(h)) / f32(atlas_height),
            (f32(xpos) + f32(w)) / f32(atlas_width), 
            (f32(ypos)) / f32(atlas_height),
        };
        
        glyph.rendered = true;
    }

}

