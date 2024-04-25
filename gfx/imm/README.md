# (Imm)edate Mode Renderer

Batched 2D and/or simple 3D rendering with an immediate mode API.

Designed to make <b>simple drawing very simple</b>.

```CPP
//
// 2D batch
imm.set_default_2D_camera(...);
imm.begin2d();

// Z ignored in orthographic projection
imm.push_translation({ 300, 300, 0 });
imm.push_rotation_z(app.elapsed_seconds);

// Rectangle at origin 0, 0 (we're using translation matrix) with size {100, 100}
imm.rectangle({0, 0, 0}, {100, 100});

imm.pop_transforms(2);

// Render text with default font (or pass custom font to parameter 'font')
imm.text("Some text", { x, y, 0 });

imm.flush();

```

```CPP
//
// 3D batch
imm.set_default_3D_camera(...);
imm.begin3d();

imm.cube({0, 0, 0}, {1, 1, 1});

imm.flush();

```

```CPP
//
// Render to render target
target := jvk.make_render_target(...);

imm.set_render_target(target);

imm.begin2d();
/* ... render to target */
imm.flush();

imm.set_render_target(gfx.window);
/* ... render to window ... */

```

It even makes fast text rendering simple:
```CPP

// initialiation
atlas := imm.make_text_atlas(width, height);
rendered_text := imm.get_or_render_text(&atlas, "Some text");

// on draw
imm.begin2d();
imm.text(rendered_text, {x, y, 0})
imm.flush();

```
Most procedures come with a bunch of default arguments such as color or font. All shape procedures returns a slice pointing to the vertices it made which lets you fully customize things.
```CPP
verts := imm.cube(...);

verts[4].color = gfx.RED;
verts[6].pos = ...;
for vert, i in verts {
    /* ... do something on each vertex in the cube */
}
```

This renderer is best suited for 2D or very basic 3D stuff, specifically dynamic geometry updated each frame. It's used for the [immediate mode GUI](/gfx/imm/gui) and [console](/console) modules. It can theoretically draw as much geometry as you can fit in VRAM in one drawcall as the staging vbo and ibo dynamically resizes.