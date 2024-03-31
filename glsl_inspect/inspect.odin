package glsl_inspect

import "core:fmt"
import "core:strconv"
import vk "vendor:vulkan"
import "core:mem"
import "core:log"
import "core:strings"

main_ :: proc()  {

    context.logger = log.create_console_logger();

    vert_src := `
#version 450

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 fragColor;

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    float meow;
    mat4 view;
    float test;
    mat4 proj;
    int parse_test[27];
} ubo;
layout(binding = 1) uniform int parse_test_4[128];

int parse_test_2[24];
const int parse_test_3[24];

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * vec4(inPosition, 0.0, 1.0);
    fragColor = inColor;
}
    `;

    //fmt.println(inspect_glsl(vert_src));
}

