package imm

import "vendor:glfw"
import jvk "jamgine:gfx/justvk"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:builtin"
import "jamgine:gfx"



shaders : struct {
    basic2d : jvk.Shader_Program,
    text_atlas : jvk.Shader_Program,

    are_loaded  : bool,
}

make_shader :: proc(vert_src : string, frag_src : string) -> (program: jvk.Shader_Program, ok: bool) {
    constants := []jvk.Shader_Constant {
        {name="MAX_SAMPLERS", value=MAX_TEXTURES_PER_PIPELINE},
    }
    return jvk.make_shader_program_from_sources(vert_src, frag_src, constants=constants);
}

init_shaders :: proc() {
    ok : bool;
    shaders.basic2d, ok = make_shader(vert_src_basic2d, frag_src_basic2d);
    if ok do shaders.text_atlas, ok = make_shader(vert_src_text_atlas, frag_src_text_atlas);

    if !ok {
        panic("Failed initializing a default shader in gfx");
    }

    log.debug("Loaded shaders");

    shaders.are_loaded = true;
}
destroy_shaders :: proc() {
    shaders.are_loaded = false;

    jvk.destroy_shader_program(shaders.basic2d);
    jvk.destroy_shader_program(shaders.text_atlas);
}

vert_src_basic2d :: `#version 450
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

    void main()
    {
        gl_Position = u_Proj * u_View * vec4(a_Pos, 1.0);

        v_Color = a_Color;
        v_UV = a_UV;
        v_TextureIndex = int(a_DataIndices[1]);
        v_Type = int(a_DataIndices[2]);

    }
`;

frag_src_basic2d :: `#version 450
    layout (location = 0) out vec4 result;
    
    layout (location = 0) flat in int v_TextureIndex;
    layout (location = 1) flat in int v_Type;
    layout (location = 2) in vec4 v_Color;
    layout (location = 3) in vec2 v_UV;

    layout (binding = 0) uniform sampler2D samplers[MAX_SAMPLERS];

    void main()
    {
        if (v_Type == 0) { // Regular 2D 
            result = v_Color;
    
            if (v_TextureIndex >= 0) {
                result *= texture(samplers[v_TextureIndex], v_UV);
            }
        } else if (v_Type == 1) { // Text
            float text_sample = texture(samplers[v_TextureIndex], v_UV).r;
            result = vec4(1.0, 1.0, 1.0, text_sample) * v_Color;
        } else if (v_Type == 2) { // Circle
            float distance = length(v_UV - vec2(0.5, 0.5));
            if (distance > 0.5 ) {
                discard;
            }
            result = v_Color;
            if (v_TextureIndex >= 0) {
                result *= texture(samplers[v_TextureIndex], v_UV);
            }
        } else { // Invalid type
            result = vec4(1.0, 0.0, 0.0, 1.0);
        }
    }
`;




vert_src_text_atlas :: `#version 450
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
    layout (location = 2) out vec4 v_Color;
    layout (location = 3) out vec2 v_UV;

    void main()
    {
        gl_Position = u_Proj * u_View * vec4(a_Pos, 1.0);

        v_Color = a_Color;
        v_UV = a_UV;
        v_TextureIndex = int(a_DataIndices[1]);
    }
`;

frag_src_text_atlas :: `#version 450
    layout (location = 0) out float alpha_channel;
    
    layout (location = 0) flat in int v_TextureIndex;
    layout (location = 2) in vec4 v_Color;
    layout (location = 3) in vec2 v_UV;

    layout (binding = 0) uniform sampler2D samplers[MAX_SAMPLERS];

    void main()
    {
        float text_sample = texture(samplers[v_TextureIndex], v_UV).r;
        alpha_channel = text_sample;
    }
`;
