// Copyright 2015 The Shaderc Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package shaderc

import _c "core:c"

when ODIN_OS == .Windows 
{
  @(extra_linker_flags = "/NODEFAULTLIB:libcmt")
  foreign import libshaderc {
      "./libs/shaderc_combined.lib",
  }
}

@(default_calling_convention = "c")
@(link_prefix = "shaderc_")
foreign libshaderc {
  
    compiler_initialize :: proc() -> compilerT ---;
    compiler_release :: proc(unamed0 : compilerT) ---;

    compile_options_initialize :: proc() -> compileOptionsT ---;
    compile_options_clone :: proc(options : compileOptionsT) -> compileOptionsT ---;
    compile_options_release :: proc(options : compileOptionsT) ---;
    compile_options_add_macro_definition :: proc(options : compileOptionsT, name : cstring, nameLength : _c.size_t, value : cstring, valueLength : _c.size_t) ---;
    compile_options_set_source_language :: proc(options : compileOptionsT, lang : sourceLanguage) ---;
    compile_options_set_generate_debug_info :: proc(options : compileOptionsT) ---;
    compile_options_set_optimization_level :: proc(options : compileOptionsT, level : optimizationLevel) ---;
    compile_options_set_forced_version_profile :: proc(options : compileOptionsT, version : _c.int, profile : profile) ---;
    compile_options_set_include_callbacks :: proc(options : compileOptionsT, resolver : includeResolveFn, resultReleaser : includeResultReleaseFn, userData : rawptr) ---;
    compile_options_set_suppress_warnings :: proc(options : compileOptionsT) ---;
    compile_options_set_target_env :: proc(options : compileOptionsT, target : targetEnv, version : u32) ---;
    compile_options_set_target_spirv :: proc(options : compileOptionsT, version : spirvVersion) ---;
    compile_options_set_warnings_as_errors :: proc(options : compileOptionsT) ---;
    compile_options_set_limit :: proc(options : compileOptionsT, limit : limit, value : _c.int) ---;
    compile_options_set_auto_bind_uniforms :: proc(options : compileOptionsT, autoBind : bool) ---;
    compile_options_set_auto_combined_image_sampler :: proc(options : compileOptionsT, upgrade : bool) ---;
    compile_options_set_hlsl_io_mapping :: proc(options : compileOptionsT, hlslIomap : bool) ---;
    compile_options_set_hlsl_offsets :: proc(options : compileOptionsT, hlslOffsets : bool) ---;
    compile_options_set_binding_base :: proc(options : compileOptionsT, kind : uniformKind, base : u32) ---;
    compile_options_set_binding_base_for_stage :: proc(options : compileOptionsT, shaderKind : shaderKind, kind : uniformKind, base : u32) ---;
    compile_options_set_preserve_bindings :: proc(options : compileOptionsT, preserveBindings : bool) ---;
    compile_options_set_auto_map_locations :: proc(options : compileOptionsT, autoMap : bool) ---;
    compile_options_set_hlsl_register_set_and_binding_for_stage :: proc(options : compileOptionsT, shaderKind : shaderKind, reg : cstring, set : cstring, binding : cstring) ---;
    compile_options_set_hlsl_register_set_and_binding :: proc(options : compileOptionsT, reg : cstring, set : cstring, binding : cstring) ---;
    compile_options_set_hlsl_functionality1 :: proc(options : compileOptionsT, enable : bool) ---;
    compile_options_set_hlsl_16bit_types :: proc(options : compileOptionsT, enable : bool) ---;
    compile_options_set_invert_y :: proc(options : compileOptionsT, enable : bool) ---;
    compile_options_set_nan_clamp :: proc(options : compileOptionsT, enable : bool) ---;
    compile_into_spv :: proc(compiler : compilerT, sourceText : cstring, sourceTextSize : _c.size_t, shaderKind : shaderKind, inputFileName : cstring, entryPointName : cstring, additionalOptions : compileOptionsT) -> compilationResultT ---;
    compile_into_spv_assembly :: proc(compiler : compilerT, sourceText : cstring, sourceTextSize : _c.size_t, shaderKind : shaderKind, inputFileName : cstring, entryPointName : cstring, additionalOptions : compileOptionsT) -> compilationResultT ---;
    compile_into_preprocessed_text :: proc(compiler : compilerT, sourceText : cstring, sourceTextSize : _c.size_t, shaderKind : shaderKind, inputFileName : cstring, entryPointName : cstring, additionalOptions : compileOptionsT) -> compilationResultT ---;

    assemble_into_spv :: proc(compiler : compilerT, sourceAssembly : cstring, sourceAssemblySize : _c.size_t, additionalOptions : compileOptionsT) -> compilationResultT ---;

    result_release :: proc(result : compilationResultT) ---;
    result_get_length :: proc(result : compilationResultT) -> _c.size_t ---;
    result_get_num_warnings :: proc(result : compilationResultT) -> _c.size_t ---;
    result_get_num_errors :: proc(result : compilationResultT) -> _c.size_t ---;
    result_get_compilation_status :: proc(unamed0 : compilationResultT) -> compilationStatus ---;
    result_get_bytes :: proc(result : compilationResultT) -> [^]u8 ---;
    result_get_error_message :: proc(result : compilationResultT) -> cstring ---;

    get_spv_version :: proc(version : ^_c.uint, revision : ^_c.uint) ---;

    parse_version_profile :: proc(str : cstring, version : ^_c.int, profile : ^profile) -> bool ---;

}
