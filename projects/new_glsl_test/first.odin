package new_glsl_test

import "core:fmt"
import "core:log"
import "core:c/libc"

import jvk "jamgine:gfx/justvk"
import "jamgine:osext"

vert_src :: `#version 450

    layout (location = 0) in vec3 a_Pos;
    layout (location = 1) in vec4 a_Color;
    layout (location = 2) in vec2 a_UV;
    layout (location = 3) in vec3 a_Normal;
    layout (location = 4) in ivec4 a_DataIndices;

    layout (push_constant) uniform Camera {
        mat4 u_Proj;
        mat4 u_View;
        vec2 u_Viewport;
    };
    
    layout (location = 0) flat out int v_TextureIndex;
    layout (location = 1) flat out int v_Type;
    layout (location = 2) out vec4 v_Color;
    layout (location = 3) out vec2 v_UV;
    layout (location = 4) out Vertex_Output {
        vec3 some_data;
        vec2 some_more_data;
    }v_Output;

    layout (std140, binding = 0) uniform Transform {
        mat4 model;
    };
    layout (binding = 1) uniform sampler2D some_texture;
    layout (binding = 2) uniform sampler2D many_textures[99];
    layout (binding = 3) uniform Bazinga {
        int a;
        int b;
    } BAZINGAS[99];
    layout (std430, binding = 4) buffer Mega_Buffer {
        int oooweee[];
    } dink_donk;
    layout (binding = 5) uniform float yes[];

    void main()
    {
        gl_Position = u_Proj * u_View * vec4(a_Pos, 1.0);

        v_Color = a_Color;
        v_UV = a_UV;
        v_TextureIndex = int(a_DataIndices[1]);
        v_Type = int(a_DataIndices[2]);

    }
`

main :: proc() {
    context.logger = log.create_console_logger();

    info, err := jvk.inspect_glsl(vert_src, .VERTEX);

    if err.kind != .NONE {
        panic(fmt.tprintf("Inspection error %s: %s", err.kind, err.str));
    }

    log_stuff :: proc(collection : $T) {
        for thing in collection {
            fmt.printf("\t%s : %s  [%s, location %i]\n", thing.field.name, thing.field.type.name, thing.kind, thing.location);
        }
    }
    fmt.println("Descriptor bindings:");
    log_stuff(info.layout.descriptor_bindings);
    fmt.println("Inputs:");
    log_stuff(info.layout.inputs);
    fmt.println("Outputs:");
    log_stuff(info.layout.outputs);
    if info.layout.push_constant != nil do fmt.println("Push Constant: ", info.layout.push_constant.(jvk.Glsl_Field).name, ":", info.layout.push_constant.(jvk.Glsl_Field).type.name);
}