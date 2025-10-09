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
        uint32_t EntryPointIndex;
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

    struct VertexInputBindingData
    {
        uint32_t Binding;
        uint8_t InputRate;
        uint32_t Stride;
    };

    enum class VertexInputFormat : int32_t
    {
        // from Vulkan

        R8_SInt = 14,
        R16_SInt = 75,
        R32_SInt = 99,
        R64_SInt = 111,

        R8_UInt = 13,
        R16_UInt = 74,
        R32_UInt = 98,
        R64_UInt = 110,

        R16_SFloat = 76,
        R32_SFloat = 100,
        R64_SFloat = 112,

        R8G8_SInt = 21,
        R16G16_SInt = 82,
        R32G32_SInt = 102,
        R64G64_SInt = 114,

        R8G8_UInt = 20,
        R16G16_UInt = 81,
        R32G32_UInt = 101,
        R64G64_UInt = 113,

        R16G16_SFloat = 83,
        R32G32_SFloat = 103,
        R64G64_SFloat = 115,

        R8G8B8_SInt = 28,
        R16G16B16_SInt = 89,
        R32G32B32_SInt = 105,
        R64G64B64_SInt = 117,

        R8G8B8_UInt = 27,
        R16G16B16_UInt = 88,
        R32G32B32_UInt = 104,
        R64G64B64_UInt = 116,

        R16G16B16_SFloat = 90,
        R32G32B32_SFloat = 106,
        R64G64B64_SFloat = 118,

        R8G8B8A8_SInt = 42,
        R16G16B16A16_SInt = 96,
        R32G32B32A32_SInt = 108,
        R64G64B64A64_SInt = 120,

        R8G8B8A8_UInt = 41,
        R16G16B16A16_UInt = 95,
        R32G32B32A32_UInt = 107,
        R64G64B64A64_UInt = 119,

        R16G16B16A16_SFloat = 97,
        R32G32B32A32_SFloat = 109,
        R64G64B64A64_SFloat = 121,
    };

    struct VertexInputAttributeData
    {
        uint32_t Binding;
        uint32_t Location;
        uint32_t Offset;
        VertexInputFormat Format;
    };

    enum class ShaderResourceType : uint32_t
    {
        TextureResource = 0,
        SamplerState
    };

    class ShaderLibrary
    {
    public:
        ShaderLibrary() = default;
        ~ShaderLibrary() = default;

        ModuleReference* loadModule(const char* moduleName, ShaderLibraryResult* result);
        EntryPointReference* loadEntryPoint(ModuleReference* moduleReference, const char* entryPointName, ShaderLibraryResult* result);

        uint8_t* createEntryPointCode(ModuleReference* moduleReference, EntryPointReference* entryPointReference, ShaderLibraryResult* result, size_t* size, const AllocatorInfo* allocator);

        void reflectVertexInputLayout(EntryPointReference* entryPoint, const AllocatorInfo* allocator, ShaderLibraryResult* result, const char* perVertexStructName, const char* perInstanceStructName, VertexInputBindingData** bindingData, size_t* bindingDataCount, VertexInputAttributeData** attributeData, size_t* attributeDataCount);

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
