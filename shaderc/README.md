shaderc-odin
==========

odin bindings for the [shaderc][shaderc] library.


Documentation
-------------

shaderc provides the compiler interface to compile GLSL/HLSL
source code into SPIR-V binary modules or assembly code. It can also assemble
SPIR-V assembly into binary module. 
Example
-------

Compile a shader into SPIR-V binary module and assembly text:

```rust

package main

import "shared:shaderc"

main :: proc(){
    compiler := shaderc.compiler_initialize()
    source :cstring= "#version 310 es\n void main() {}"
    result := shaderc.compile_into_spv(compiler,source,len(source),.FragmentShader,"shader.frag","main",nil)
    if (shaderc.result_get_compilation_status(result) != shaderc.compilationStatus.Success) {
        panic(string(shaderc.result_get_error_message(result)))
    }

    
   lenn := shaderc.result_get_length(result)
   bytes := (shaderc.result_get_bytes(result))
   shadercode := transmute([]u8)bytes[:lenn]
   //shadercode you want to put into vulkan and whatnot
}
```

Setup
-----

shaderc-odin needs the C++ [shaderc library](https://github.com/google/shaderc).
It's shipped inside the [Vulkan SDK](https://www.lunarg.com/vulkan-sdk/).
You may be able to install it directly on some Linux distro's using the package
manager. The C++ shaderc project provides [artifacts
downloads](https://github.com/google/shaderc#downloads).

use shaderc library `shaderc_combined` by putting it in libs folder, on windows it should be `shaderc_combined.lib` on linux `shaderc_combined.a`

Contributions
-------------

This project is licensed under the [MIT](LICENSE) license. Please see
[CONTRIBUTING](CONTRIBUTING.md) before contributing.

### Authors

This project is initialized and mainly developed by Matthew Goodman
([@antiagainst][me]).

[shaderc]: https://github.com/google/shaderc
[me]: https://github.com/juxta-tad

