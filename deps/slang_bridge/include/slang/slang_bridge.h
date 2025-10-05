#pragma once

#include <stdint.h>

#ifdef __cplusplus
#define EXPORT extern "C"
#else
#define EXPORT
#endif

typedef struct ShaderLibrary ShaderLibrary;
typedef struct ModuleReference ModuleReference;
typedef struct EntryPointReference EntryPointReference;

typedef int32_t ShaderLibraryResult;
typedef uint32_t ShaderCompileTarget;
typedef uint32_t FloatingPointMode;
typedef uint32_t LineDirectiveMode;
typedef uint32_t MatrixLayoutMode;

typedef struct ShaderTarget
{
    ShaderCompileTarget CompileTarget;
    const char* ProfileName;
    FloatingPointMode FloatingPointMode;
    LineDirectiveMode LineDirectiveMode;
    uint8_t ForceGLSLScalarBufferLayout;
    // todo: compiler options
} ShaderTarget;

typedef struct PreprocessorMacroInfo
{
    const char* Name;
    const char* Value;
} PreprocessorMacroInfo;

typedef struct ShaderLibraryInfo
{
    const char* const* SearchPaths;
    size_t SearchPathsCount;

    ShaderTarget const* Targets;
    size_t TargetCount;

    MatrixLayoutMode DefaultMatrixLayoutMode;

    PreprocessorMacroInfo const* PreprocessorMacros;
    size_t PreprocessorMacroCount;

    // todo: filesystem

    uint8_t AllowGLSLSyntax;

    // todo: compiler options

    uint8_t SkipSpirVValidation;
} ShaderLibraryInfo;

typedef struct AllocatorInfo
{
    void* (*Allocate)(size_t size, void* userData);
    void (*Free)(void* memory, size_t size, void* userData);
    void* UserData;
} AllocatorInfo;

EXPORT ShaderLibrary* ShaderLibrary_init(const ShaderLibraryInfo* libraryInfo, ShaderLibraryResult* result);
EXPORT void ShaderLibrary_deinit(ShaderLibrary* library);
EXPORT ModuleReference* ShaderLibrary_loadModule(ShaderLibrary* library, const char* moduleName, ShaderLibraryResult* result);
EXPORT EntryPointReference* ShaderLibrary_loadEntryPoint(ShaderLibrary* library, ModuleReference* moduleReference, const char* entryPointName, ShaderLibraryResult* result);
EXPORT uint8_t* ShaderLibrary_createEntryPointCode(ShaderLibrary* library, ModuleReference* moduleReference, EntryPointReference* entryPointReference, ShaderLibraryResult* result, size_t* size, const AllocatorInfo* allocator);
