#include "ShaderLibrary.h"

#include <iostream>

namespace bridge {

#define HANDLE_ERROR(slangResult, libraryResultPtr, returnStatement) { if (SLANG_FAILED(slangResult)) { if (libraryResultPtr) { *libraryResultPtr = (ShaderLibraryResult)slangResult; } returnStatement; } }

    ModuleReference* ShaderLibrary::loadModule(const char* moduleName, ShaderLibraryResult* result)
    {
        Slang::ComPtr<slang::IBlob> diagnostics;
        ModuleReference& reference = m_LoadedModules.emplace_back();
        reference.Name = moduleName;
        reference.Module = m_Session->loadModule(moduleName, diagnostics.writeRef());

        if (diagnostics)
        {
            std::string diag((const char*)diagnostics->getBufferPointer(), diagnostics->getBufferSize());
            std::cout << "slang error:" << diag << std::endl;
            diagnostics = nullptr;

            m_LoadedModules.pop_back();

            if (result)
                *result = ShaderLibraryResult::Fail;
            return nullptr;
        }

        m_LoadedEntryPoints.push_back({});

        if (result)
            *result = ShaderLibraryResult::Ok;

        return &reference;
    }

    EntryPointReference* ShaderLibrary::loadEntryPoint(ModuleReference* moduleReference, const char* entryPointName, ShaderLibraryResult* result)
    {
        size_t index = 0;
        for (const ModuleReference& moduleRef : m_LoadedModules)
        {
            if (std::string(moduleRef.Name) == std::string(moduleReference->Name))
                break;

            index++;
        }

        EntryPointReference& entryPointReference = m_LoadedEntryPoints[index].emplace_back();
        entryPointReference.Name = entryPointName;

        SlangResult slangResult = moduleReference->Module->findEntryPointByName(entryPointName, entryPointReference.EntryPoint.writeRef());
        HANDLE_ERROR(slangResult, result, m_LoadedEntryPoints[index].pop_back(); return nullptr);

        if (result)
            *result = ShaderLibraryResult::Ok;

        Slang::ComPtr<slang::IBlob> diagnostics = nullptr;

        slang::IComponentType* components[] = { moduleReference->Module.get(), entryPointReference.EntryPoint.get() };
        slangResult = m_Session->createCompositeComponentType(components, 2, entryPointReference.Program.writeRef(), diagnostics.writeRef());

        if (diagnostics)
        {
            std::string diag((const char*)diagnostics->getBufferPointer(), diagnostics->getBufferSize());
            std::cout << "slang error: " << diag << std::endl;
        }

        HANDLE_ERROR(slangResult, result, m_LoadedEntryPoints[index].pop_back(); return nullptr);

        slangResult = entryPointReference.Program->link(entryPointReference.LinkedProgram.writeRef(), diagnostics.writeRef());
        if (diagnostics)
        {
            std::string diag((const char*)diagnostics->getBufferPointer(), diagnostics->getBufferSize());
            std::cout << "slang error: " << diag << std::endl;
        }

        HANDLE_ERROR(slangResult, result, m_LoadedEntryPoints[index].pop_back(); return nullptr);

        return &entryPointReference;
    }

    uint8_t* ShaderLibrary::createEntryPointCode(ModuleReference* moduleReference, EntryPointReference* entryPointReference, ShaderLibraryResult* result, size_t* size, const AllocatorInfo* allocator)
    {
        Slang::ComPtr<slang::IBlob> kernelBlob;
        Slang::ComPtr<slang::IBlob> diagnostics;

        SlangResult slangResult = entryPointReference->LinkedProgram->getEntryPointCode(
            0, 0,
            kernelBlob.writeRef(),
            diagnostics.writeRef()
        );

        if (diagnostics)
        {
            std::string diag((const char*)diagnostics->getBufferPointer(), diagnostics->getBufferSize());
            std::cout << "slang error: " << diag << std::endl;
        }

        HANDLE_ERROR(slangResult, result, return nullptr);

        *size = kernelBlob->getBufferSize();
        uint8_t* code = reinterpret_cast<uint8_t*>(allocator->Allocate(*size, allocator->UserData));
        std::memcpy(code, kernelBlob->getBufferPointer(), *size);

        kernelBlob = nullptr;

        return code;
    }

    ShaderLibrary* ShaderLibrary::init(const ShaderLibraryInfo* libraryInfo, ShaderLibraryResult* result)
    {
        ShaderLibrary* library = new ShaderLibrary;

        if (!s_GlobalSession)
        {
            SlangResult slangResult = slang_createGlobalSession(SLANG_API_VERSION, s_GlobalSession.writeRef());
            HANDLE_ERROR(slangResult, result, delete library; return nullptr);
            
            if (result)
                *result = ShaderLibraryResult::Ok;
        }

        slang::SessionDesc sessionDesc{};
        sessionDesc.targets = new slang::TargetDesc[libraryInfo->TargetCount];
        sessionDesc.targetCount = static_cast<SlangInt>(libraryInfo->TargetCount);
        sessionDesc.defaultMatrixLayoutMode = (SlangMatrixLayoutMode)libraryInfo->DefaultMatrixLayoutMode;
        sessionDesc.searchPaths = libraryInfo->SearchPaths;
        sessionDesc.searchPathCount = static_cast<SlangInt>(libraryInfo->SearchPathsCount);
        sessionDesc.preprocessorMacros = reinterpret_cast<slang::PreprocessorMacroDesc const*>(libraryInfo->PreprocessorMacros);
        sessionDesc.preprocessorMacroCount = static_cast<SlangInt>(libraryInfo->PreprocessorMacroCount);
        sessionDesc.allowGLSLSyntax = libraryInfo->AllowGLSLSyntax == 0 ? false : true;
        sessionDesc.skipSPIRVValidation = libraryInfo->SkipSpirVValidation == 0 ? false : true;

        for (size_t i = 0; i < libraryInfo->TargetCount; i++)
        {
            slang::TargetDesc target{};
            target.format = (SlangCompileTarget)libraryInfo->Targets[i].CompileTarget;
            target.profile = s_GlobalSession->findProfile(libraryInfo->Targets[i].ProfileName);
            target.floatingPointMode = (SlangFloatingPointMode)libraryInfo->Targets[i].FloatingPointMode;
            target.lineDirectiveMode = (SlangLineDirectiveMode)libraryInfo->Targets[i].LineDirectiveMode;
            target.forceGLSLScalarBufferLayout = libraryInfo->Targets[i].ForceGLSLScalarBufferLayout == 0 ? false : true;

            std::memcpy(const_cast<slang::TargetDesc*>(&sessionDesc.targets[i]), &target, sizeof(slang::TargetDesc));
        }

        SlangResult slangResult = s_GlobalSession->createSession(sessionDesc, library->m_Session.writeRef());
        delete[] sessionDesc.targets;
        HANDLE_ERROR(slangResult, result, delete library; return nullptr);
        
        if (result)
            *result = ShaderLibraryResult::Ok;

        return library;
    }

    void ShaderLibrary::deinit(ShaderLibrary* library)
    {
        library->m_Session = nullptr;

        delete library;
    }

}
