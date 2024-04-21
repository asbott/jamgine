# Jamgine
My personal sandbox/portfolio.

I cannot offer you a fancy paper or fancy numbers in my CV, but I can offer  you quality software in a jungle of terrible software getting worse by each passing day.

This project is meant to showcase the real fruits of my efforts and competence in software. 

Everything is made from scratch with one temporary external dependency being shaderc.

Except for shaderc binaries, there are some unimplemented unix functions needed to compile on unix systems (osext/linux).

Vulkan backend is tested with a RTX 3060 Laptop GPU as well as 11th gen intel i5 integrated graphics.

I can be reached at charlie.malmqvist1@gmail.com.

## Build & Run
If you want to run this project you would need to be on a x64 Windows system because I'm using precompiled binaries for shaderc. The plan is to replace shaderc with my own GLSL compiler, making this project entirely self-contained.

Everything is written with odin lang, a modern take on C-like low-level programming. If you want to compile and run any of the code it's quite simple to install odin and get started ([odin-lang.org](https://odin-lang.org)).

To build and run the project:<br>
`odin run "path/to/project" collection:jamgine="path/to/jamgine/repo"`<br>
To run with debug information, including vulkan layers, just append `-debug` to the command.
By default odin compiles with minimal optimization. For an optimized build simply append `-o:aggressive` or `-o:speed`. If you only want to build the project without running, it's the same deal but replace `odin run` with `odin build`.

You can tell the engine to prioritize targetting some type of GPU over another with the following command-line arguments:
```
-prefer-integrated
-prefer-discrete
-prefer-virtual
-prefer-cpu

-force-integrated
-force-discrete
-force_virtual
-force-cpu
```
`prefer` simply boosts the "score" for the respective GPU type in the GPU selection algorithm while `force` guarantees to select a GPU of that type if possible.

## Points of interest
Note: Some implementation pages contain more information and showcases.
### GPU Accelerated Particle emitter

(GIF might take a while to load)

![](/repo/emitters_spawn_area.gif)
![](/repo/emitter_v1_smoke.gif)

- Implementation: https://github.com/asbott/jamgine/tree/main/gfx/particles
- Test project: https://github.com/asbott/jamgine/tree/main/projects/emitters_test

### Immediate Mode GUI
Also seen in the particle emitter showcase.
```
igui.begin_window("My Window");

igui.label("Hey there", color=gfx.GREEN);

@(static)
f32_value : f32;
igui.f32_drag("Float value: ", &f32_value);

if igui.button("Unset") {
    f32_value = 0;
}

igui.end_window();
``` 
![](/repo/simple_example.gif)

- Implementation: https://github.com/asbott/jamgine/tree/main/gfx/imm/gui
- Test project: https://github.com/asbott/jamgine/tree/main/projects/imm_gui_test

### Developer console
![](/repo/console_intro.gif)

- Implementation: https://github.com/asbott/jamgine/tree/main/console
- Test project: Active in most projects

## Technical points of interest
- [Vulkan Backend](/gfx/justvk)
- GLSL [Lexer](/gfx/justvk/glsl_lexer.odin), [Parser](/gfx/justvk/glsl_parser.odin) and [Introspection](/gfx/justvk/glsl_inspect.odin)