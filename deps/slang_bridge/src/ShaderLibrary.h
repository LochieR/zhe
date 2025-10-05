#pragma once

#include <slang.h>
#include <slang-com-ptr.h>

#include <vector>
#include <string>
#include <cstdint>
#include <unordered_map>

namespace bridge {

    enum class ShaderLibraryResult : int32_t
    {
        Ok = 0,
        Fail = -2147467259,
        NotImplemented = -2147467263,
        NoInterface = -2147467262,
        Abort = -2147467260,
        InvalidHandle = -2147024890,
        InvalidArg = -2147024809,
        OutOfMemory = -2147024882,
        BufferTooSmall = -2113929215,
        Uninitialized = -2113929214,
        Pending = -2113929213,
        CannotOpen = -2113929212,
        NotFound = -2113929211,
        InternalFail = -2113929210,
        NotAvailable = -2113929209,
        TimeOut = -2113929208
    };

    enum class ShaderCompileTarget : uint32_t
    {
        Unkown,
        None,
        Glsl,
        Hlsl = 5,
        SpirV,
        SpirVASM,
        Dxbc,
        DxbcAsm,
        DxIl,
        DXIlAsm,
        C,
        Cpp,
        HostExe,
        ShaderSharedLibrary,
        ShaderHostCallable,
        CudaSource,
        Ptx,
        ObjectCode,
        HostCpp,
        HostHostCallable,
        CppPytorchBinding,
        Metal,
        MetalLib,
        MetalLibAsm,
        HostSharedLibrary,
        Wgsl,
        WgslSpirvAsm,
        WgslSpirv,
        HostVM,
    };

    enum class FloatingPointMode : uint32_t
    {
        Default,
        Fast,
        Precise
    };

    enum class LineDirectiveMode : uint32_t
    {
        Default,
        None,
        Standard,
        Glsl,
        SourceMap,
    };

    struct ShaderTarget
    {
        ShaderCompileTarget CompileTarget;
        const char* ProfileName;
        FloatingPointMode FloatingPointMode;
        LineDirectiveMode LineDirectiveMode;
        uint8_t ForceGLSLScalarBufferLayout;
        // todo: compiler options
    };

    enum class MatrixLayoutMode : uint32_t
    {
        Unknown,
        RowMajor,
        ColumnMajor
    };

    struct PreprocessorMacroInfo
    {
        const char* Name;
        const char* Value;
    };

    struct ShaderLibraryInfo
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
    };

    struct ModuleReference
    {
        const char* Name;
        Slang::ComPtr<slang::IModule> Module;
    };

    struct EntryPointReference
    {
        const char* Name;
        Slang::ComPtr<slang::IEntryPoint> EntryPoint;
        Slang::ComPtr<slang::IComponentType> Program;
        Slang::ComPtr<slang::IComponentType> LinkedProgram;
    };

    struct AllocatorInfo
    {
        void* (*Allocate)(size_t size, void* userData);
        void (*Free)(void* memory, size_t size, void* userData);
        void* UserData;
    };

    class ShaderLibrary
    {
    public:
        ShaderLibrary() = default;
        ~ShaderLibrary() = default;

        ModuleReference* loadModule(const char* moduleName, ShaderLibraryResult* result);
        EntryPointReference* loadEntryPoint(ModuleReference* moduleReference, const char* entryPointName, ShaderLibraryResult* result);

        uint8_t* createEntryPointCode(ModuleReference* moduleReference, EntryPointReference* entryPointReference, ShaderLibraryResult* result, size_t* size, const AllocatorInfo* allocator);

        static ShaderLibrary* init(const ShaderLibraryInfo* libraryInfo, ShaderLibraryResult* result);
        static void deinit(ShaderLibrary* library);
    private:
        inline static Slang::ComPtr<slang::IGlobalSession> s_GlobalSession = nullptr;
    private:
        Slang::ComPtr<slang::ISession> m_Session;

        std::vector<ModuleReference> m_LoadedModules;
        std::vector<std::vector<EntryPointReference>> m_LoadedEntryPoints;
    };

}
