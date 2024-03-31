package shaderc
import _c "core:c"

H_ :: 1;
ENV_H_ :: 1;
STATUS_H_ :: 1;

compilerT :: ^compiler;
compileOptionsT :: ^compileOptions;
includeResolveFn :: #type proc(userData : rawptr, requestedSource : cstring, type : _c.int, requestingSource : cstring, includeDepth : _c.size_t) -> ^includeResult;
includeResultReleaseFn :: #type proc(userData : rawptr, includeResult : ^includeResult);
compilationResultT :: ^compilationResult;

sourceLanguage :: enum i32 {
    Glsl,
    Hlsl,
};

shaderKind :: enum i32 {
    VertexShader,
    FragmentShader,
    ComputeShader,
    GeometryShader,
    TessControlShader,
    TessEvaluationShader,
    GlslVertexShader = 0,
    GlslFragmentShader = 1,
    GlslComputeShader = 2,
    GlslGeometryShader = 3,
    GlslTessControlShader = 4,
    GlslTessEvaluationShader = 5,
    GlslInferFromSource,
    GlslDefaultVertexShader,
    GlslDefaultFragmentShader,
    GlslDefaultComputeShader,
    GlslDefaultGeometryShader,
    GlslDefaultTessControlShader,
    GlslDefaultTessEvaluationShader,
    SpirvAssembly,
    RaygenShader,
    AnyhitShader,
    ClosesthitShader,
    MissShader,
    IntersectionShader,
    CallableShader,
    GlslRaygenShader = 14,
    GlslAnyhitShader = 15,
    GlslClosesthitShader = 16,
    GlslMissShader = 17,
    GlslIntersectionShader = 18,
    GlslCallableShader = 19,
    GlslDefaultRaygenShader,
    GlslDefaultAnyhitShader,
    GlslDefaultClosesthitShader,
    GlslDefaultMissShader,
    GlslDefaultIntersectionShader,
    GlslDefaultCallableShader,
    TaskShader,
    MeshShader,
    GlslTaskShader = 26,
    GlslMeshShader = 27,
    GlslDefaultTaskShader,
    GlslDefaultMeshShader,
};

profile :: enum i32 {
    None,
    Core,
    Compatibility,
    Es,
};

optimizationLevel :: enum i32 {
    Zero,
    Size,
    Performance,
};

limit :: enum i32 {
    MaxLights,
    MaxClipPlanes,
    MaxTextureUnits,
    MaxTextureCoords,
    MaxVertexAttribs,
    MaxVertexUniformComponents,
    MaxVaryingFloats,
    MaxVertexTextureImageUnits,
    MaxCombinedTextureImageUnits,
    MaxTextureImageUnits,
    MaxFragmentUniformComponents,
    MaxDrawBuffers,
    MaxVertexUniformVectors,
    MaxVaryingVectors,
    MaxFragmentUniformVectors,
    MaxVertexOutputVectors,
    MaxFragmentInputVectors,
    MinProgramTexelOffset,
    MaxProgramTexelOffset,
    MaxClipDistances,
    MaxComputeWorkGroupCountX,
    MaxComputeWorkGroupCountY,
    MaxComputeWorkGroupCountZ,
    MaxComputeWorkGroupSizeX,
    MaxComputeWorkGroupSizeY,
    MaxComputeWorkGroupSizeZ,
    MaxComputeUniformComponents,
    MaxComputeTextureImageUnits,
    MaxComputeImageUniforms,
    MaxComputeAtomicCounters,
    MaxComputeAtomicCounterBuffers,
    MaxVaryingComponents,
    MaxVertexOutputComponents,
    MaxGeometryInputComponents,
    MaxGeometryOutputComponents,
    MaxFragmentInputComponents,
    MaxImageUnits,
    MaxCombinedImageUnitsAndFragmentOutputs,
    MaxCombinedShaderOutputResources,
    MaxImageSamples,
    MaxVertexImageUniforms,
    MaxTessControlImageUniforms,
    MaxTessEvaluationImageUniforms,
    MaxGeometryImageUniforms,
    MaxFragmentImageUniforms,
    MaxCombinedImageUniforms,
    MaxGeometryTextureImageUnits,
    MaxGeometryOutputVertices,
    MaxGeometryTotalOutputComponents,
    MaxGeometryUniformComponents,
    MaxGeometryVaryingComponents,
    MaxTessControlInputComponents,
    MaxTessControlOutputComponents,
    MaxTessControlTextureImageUnits,
    MaxTessControlUniformComponents,
    MaxTessControlTotalOutputComponents,
    MaxTessEvaluationInputComponents,
    MaxTessEvaluationOutputComponents,
    MaxTessEvaluationTextureImageUnits,
    MaxTessEvaluationUniformComponents,
    MaxTessPatchComponents,
    MaxPatchVertices,
    MaxTessGenLevel,
    MaxViewports,
    MaxVertexAtomicCounters,
    MaxTessControlAtomicCounters,
    MaxTessEvaluationAtomicCounters,
    MaxGeometryAtomicCounters,
    MaxFragmentAtomicCounters,
    MaxCombinedAtomicCounters,
    MaxAtomicCounterBindings,
    MaxVertexAtomicCounterBuffers,
    MaxTessControlAtomicCounterBuffers,
    MaxTessEvaluationAtomicCounterBuffers,
    MaxGeometryAtomicCounterBuffers,
    MaxFragmentAtomicCounterBuffers,
    MaxCombinedAtomicCounterBuffers,
    MaxAtomicCounterBufferSize,
    MaxTransformFeedbackBuffers,
    MaxTransformFeedbackInterleavedComponents,
    MaxCullDistances,
    MaxCombinedClipAndCullDistances,
    MaxSamples,
    MaxMeshOutputVerticesNv,
    MaxMeshOutputPrimitivesNv,
    MaxMeshWorkGroupSizeX_nv,
    MaxMeshWorkGroupSizeY_nv,
    MaxMeshWorkGroupSizeZ_nv,
    MaxTaskWorkGroupSizeX_nv,
    MaxTaskWorkGroupSizeY_nv,
    MaxTaskWorkGroupSizeZ_nv,
    MaxMeshViewCountNv,
    MaxMeshOutputVerticesExt,
    MaxMeshOutputPrimitivesExt,
    MaxMeshWorkGroupSizeX_ext,
    MaxMeshWorkGroupSizeY_ext,
    MaxMeshWorkGroupSizeZ_ext,
    MaxTaskWorkGroupSizeX_ext,
    MaxTaskWorkGroupSizeY_ext,
    MaxTaskWorkGroupSizeZ_ext,
    MaxMeshViewCountExt,
    MaxDualSourceDrawBuffersExt,
};

uniformKind :: enum i32 {
    Image,
    Sampler,
    Texture,
    Buffer,
    StorageBuffer,
    UnorderedAccessView,
};

includeType :: enum i32 {
    Relative,
    Standard,
};

targetEnv :: enum i32 {
    Vulkan,
    Opengl,
    OpenglCompat,
    Webgpu,
    Default = 0,
};

envVersion :: enum i32 {
    Vulkan1_0 =  1 << 22,
    Vulkan1_1 = (1 << 22) | (1 << 12),
    Vulkan1_2 = (1 << 22) | (2 << 12),
    Vulkan1_3 = (1 << 22) | (3 << 12),
    Opengl4_5 = 450,
    Webgpu,
};

spirvVersion :: enum i32 {
};

compilationStatus :: enum i32 {
    Success = 0,
    InvalidStage = 1,
    CompilationError = 2,
    InternalError = 3,
    NullResultObject = 4,
    InvalidAssembly = 5,
    ValidationError = 6,
    TransformationError = 7,
    ConfigurationError = 8,
};

compiler :: struct {};

compileOptions :: struct {};

includeResult :: struct {
    sourceName : cstring,
    sourceNameLength : _c.size_t,
    content : cstring,
    contentLength : _c.size_t,
    userData : rawptr,
};

compilationResult :: struct {};
