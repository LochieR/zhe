#include "slang/slang_bridge.h"

#include "ShaderLibrary.h"

ShaderLibrary* ShaderLibrary_init(const ShaderLibraryInfo* libraryInfo, ShaderLibraryResult* result)
{
    return reinterpret_cast<ShaderLibrary*>(
        bridge::ShaderLibrary::init(
            reinterpret_cast<const bridge::ShaderLibraryInfo*>(libraryInfo),
            reinterpret_cast<bridge::ShaderLibraryResult*>(result)
        )
    );
}

void ShaderLibrary_deinit(ShaderLibrary* library)
{
    bridge::ShaderLibrary::deinit(reinterpret_cast<bridge::ShaderLibrary*>(library));
}

ModuleReference* ShaderLibrary_loadModule(ShaderLibrary* library, const char* moduleName, ShaderLibraryResult* result)
{
    return reinterpret_cast<ModuleReference*>(
            reinterpret_cast<bridge::ShaderLibrary*>(library)->loadModule(
            moduleName,
            reinterpret_cast<bridge::ShaderLibraryResult*>(result)
        )
    );
}

EntryPointReference* ShaderLibrary_loadEntryPoint(ShaderLibrary* library, ModuleReference* moduleReference, const char* entryPointName, ShaderLibraryResult* result)
{
    return reinterpret_cast<EntryPointReference*>(
        reinterpret_cast<bridge::ShaderLibrary*>(library)->loadEntryPoint(
            reinterpret_cast<bridge::ModuleReference*>(moduleReference),
            entryPointName,
            reinterpret_cast<bridge::ShaderLibraryResult*>(result)
        )    
    );
}

uint8_t* ShaderLibrary_createEntryPointCode(ShaderLibrary* library, ModuleReference* moduleReference, EntryPointReference* entryPointReference, ShaderLibraryResult* result, size_t* size, const AllocatorInfo* allocator)
{
    return reinterpret_cast<bridge::ShaderLibrary*>(library)->createEntryPointCode(
        reinterpret_cast<bridge::ModuleReference*>(moduleReference),
        reinterpret_cast<bridge::EntryPointReference*>(entryPointReference),
        reinterpret_cast<bridge::ShaderLibraryResult*>(result),
        size,
        reinterpret_cast<const bridge::AllocatorInfo*>(allocator)
    );
}
