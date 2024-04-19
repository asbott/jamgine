package repro

import "core:math/linalg/glsl"
import "core:fmt";


inverse :: glsl.inverse;

main :: proc() {

    test1 : glsl.mat4;
    fmt.println(test1);
    test2 : glsl.mat4;
    fmt.println(test2);
    test1 = test2 * inverse(test1);
    fmt.println(test1);
    fmt.println(test2);
}