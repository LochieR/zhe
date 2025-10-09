#include "ShaderLibrary.h"

#include <string>
#include <iostream>

namespace bridge {

#define HANDLE_ERROR(slangResult, libraryResultPtr, returnStatement) { if (SLANG_FAILED(slangResult)) { if (libraryResultPtr) { *(ShaderLibraryResult*)libraryResultPtr = (ShaderLibraryResult)slangResult; } returnStatement; } }
#define PRINT_DIAGNOSTICS(diagnostics, returnStatement) { if (diagnostics) { std::string diag((const char*)diagnostics->getBufferPointer(), diagnostics->getBufferSize()); std::cout << "slang error: " << diag << std::endl; diagnostics = nullptr; returnStatement; } }

    ModuleReference* ShaderLibrary::loadModule(const char* moduleName, ShaderLibraryResult* result)
    {
        Slang::ComPtr<slang::IBlob> diagnostics;
        m_LoadedModules.emplace_back();
        ModuleReference& reference = m_LoadedModules.back();
        reference.Name = moduleName;
        reference.Module = m_Session->loadModule(moduleName, diagnostics.writeRef());

        PRINT_DIAGNOSTICS(diagnostics, m_LoadedModules.pop_back(); if (result) *result = ShaderLibraryResult::Fail; return nullptr);

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

        m_LoadedEntryPoints[index].emplace_back();
        EntryPointReference& entryPointReference = m_LoadedEntryPoints[index].back();
        entryPointReference.Name = entryPointName;

        for (uint32_t i = 0; i < moduleReference->Module->getDefinedEntryPointCount(); i++)
        {
            Slang::ComPtr<slang::IEntryPoint> entry;
            SlangResult slangResult = moduleReference->Module->getDefinedEntryPoint(i, entry.writeRef());
            HANDLE_ERROR(slangResult, result, return nullptr);

            if (std::string(entry->getLayout()->getEntryPointByIndex(0)->getName()) == std::string(entryPointName))
            {
                entryPointReference.EntryPointIndex = i;
                entryPointReference.EntryPoint = entry;
            }
        }

        if (result)
            *result = ShaderLibraryResult::Ok;

        Slang::ComPtr<slang::IBlob> diagnostics = nullptr;

        slang::IComponentType* components[] = { moduleReference->Module.get(), entryPointReference.EntryPoint.get() };
        SlangResult slangResult = m_Session->createCompositeComponentType(components, 2, entryPointReference.Program.writeRef(), diagnostics.writeRef());

        PRINT_DIAGNOSTICS(diagnostics, {});
        HANDLE_ERROR(slangResult, result, m_LoadedEntryPoints[index].pop_back(); return nullptr);

        slangResult = entryPointReference.Program->link(entryPointReference.LinkedProgram.writeRef(), diagnostics.writeRef());

        PRINT_DIAGNOSTICS(diagnostics, {});
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

        PRINT_DIAGNOSTICS(diagnostics, {});
        HANDLE_ERROR(slangResult, result, return nullptr);

        *size = kernelBlob->getBufferSize();
        uint8_t* code = reinterpret_cast<uint8_t*>(allocator->Allocate(*size, allocator->UserData));
        std::memcpy(code, kernelBlob->getBufferPointer(), *size);

        kernelBlob = nullptr;

        return code;
    }

    void ShaderLibrary::reflectVertexInputLayout(EntryPointReference* entryPoint, const AllocatorInfo* allocator, ShaderLibraryResult* result, const char* perVertexStructName, const char* perInstanceStructName, VertexInputBindingData** bindingData, size_t* bindingDataCount, VertexInputAttributeData** attributeData, size_t* attributeDataCount)
    {
        if (perVertexStructName == nullptr && perInstanceStructName == nullptr)
            return;

        Slang::ComPtr<slang::IBlob> diagnostics;
        PRINT_DIAGNOSTICS(diagnostics, {});

        size_t bindingCount = 0;
        if (perVertexStructName)
            bindingCount++;
        if (perInstanceStructName)
            bindingCount++;

        VertexInputBindingData* inputBindingDatas = reinterpret_cast<VertexInputBindingData*>(allocator->Allocate(bindingCount * sizeof(VertexInputBindingData), allocator->UserData));
        std::vector<VertexInputAttributeData> attributes;

        uint32_t lastLocation = 0;

        auto getFormat = [](slang::TypeReflection::ScalarType scalarType, uint32_t componentCount) -> VertexInputFormat
        {
            switch (scalarType)
            {
            case slang::TypeReflection::ScalarType::Float16:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R16_SFloat;
                    case 2: return VertexInputFormat::R16G16_SFloat;
                    case 3: return VertexInputFormat::R16G16B16_SFloat;
                    case 4: return VertexInputFormat::R16G16B16A16_SFloat;
                }
                break;
            }
            case slang::TypeReflection::ScalarType::Float32:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R32_SFloat;
                    case 2: return VertexInputFormat::R32G32_SFloat;
                    case 3: return VertexInputFormat::R32G32B32_SFloat;
                    case 4: return VertexInputFormat::R32G32B32A32_SFloat;
                }
                break;
            }
            case slang::TypeReflection::ScalarType::Float64:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R64_SFloat;
                    case 2: return VertexInputFormat::R64G64_SFloat;
                    case 3: return VertexInputFormat::R64G64B64_SFloat;
                    case 4: return VertexInputFormat::R64G64B64A64_SFloat;
                }
                break;
            }
            case slang::TypeReflection::Int8:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R8_SInt;
                    case 2: return VertexInputFormat::R8G8_SInt;
                    case 3: return VertexInputFormat::R8G8B8_SInt;
                    case 4: return VertexInputFormat::R8G8B8A8_SInt;
                }
                break;
            }
            case slang::TypeReflection::Int16:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R16_SInt;
                    case 2: return VertexInputFormat::R16G16_SInt;
                    case 3: return VertexInputFormat::R16G16B16_SInt;
                    case 4: return VertexInputFormat::R16G16B16A16_SInt;
                }
                break;
            }
            case slang::TypeReflection::Int32:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R32_SInt;
                    case 2: return VertexInputFormat::R32G32_SInt;
                    case 3: return VertexInputFormat::R32G32B32_SInt;
                    case 4: return VertexInputFormat::R32G32B32A32_SInt;
                }
                break;
            }
            case slang::TypeReflection::Int64:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R64_SInt;
                    case 2: return VertexInputFormat::R64G64_SInt;
                    case 3: return VertexInputFormat::R64G64B64_SInt;
                    case 4: return VertexInputFormat::R64G64B64A64_SInt;
                }
                break;
            }
            case slang::TypeReflection::UInt8:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R8_UInt;
                    case 2: return VertexInputFormat::R8G8_UInt;
                    case 3: return VertexInputFormat::R8G8B8_UInt;
                    case 4: return VertexInputFormat::R8G8B8A8_UInt;
                }
                break;
            }
            case slang::TypeReflection::UInt16:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R16_UInt;
                    case 2: return VertexInputFormat::R16G16_UInt;
                    case 3: return VertexInputFormat::R16G16B16_UInt;
                    case 4: return VertexInputFormat::R16G16B16A16_UInt;
                }
                break;
            }
            case slang::TypeReflection::UInt32:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R32_UInt;
                    case 2: return VertexInputFormat::R32G32_UInt;
                    case 3: return VertexInputFormat::R32G32B32_UInt;
                    case 4: return VertexInputFormat::R32G32B32A32_UInt;
                }
                break;
            }
            case slang::TypeReflection::UInt64:
            {
                switch (componentCount)
                {
                    case 1: return VertexInputFormat::R64_UInt;
                    case 2: return VertexInputFormat::R64G64_UInt;
                    case 3: return VertexInputFormat::R64G64B64_UInt;
                    case 4: return VertexInputFormat::R64G64B64A64_UInt;
                }
                break;
            }
            default:
                return VertexInputFormat::R8_SInt;
            }
        };

        slang::ProgramLayout* programLayout = entryPoint->LinkedProgram->getLayout();

        slang::EntryPointReflection* entryPointReflection = nullptr;
        for (uint32_t i = 0; i < programLayout->getEntryPointCount(); i++)
        {
            slang::EntryPointReflection* tempEntryPoint = programLayout->getEntryPointByIndex(i);
            if (tempEntryPoint->getStage() == SLANG_STAGE_VERTEX)
            {
                entryPointReflection = tempEntryPoint;
                break;
            }
        }

        auto processInputStruct = [&](slang::TypeLayoutReflection* structLayout, uint32_t binding, uint32_t inputRate)
        {
            if (!structLayout)
            {
                *result = ShaderLibraryResult::Fail;
                return;
            }

            uint32_t fieldCount = structLayout->getFieldCount();
            uint32_t offset = 0;
            uint32_t locationsUsed = 0;

            for (uint32_t i = 0; i < fieldCount; i++)
            {
                slang::VariableLayoutReflection* fieldLayout = structLayout->getFieldByIndex(i);
                slang::VariableReflection* field = fieldLayout->getVariable();
                slang::TypeLayoutReflection* fieldTypeLayout = fieldLayout->getTypeLayout();
                slang::TypeReflection* fieldType = field->getType();

                if (!fieldTypeLayout || !fieldType)
                    continue;

                const char* semanticName = fieldLayout->getSemanticName();
                uint32_t semanticIndex = fieldLayout->getSemanticIndex();

                VertexInputAttributeData attribute;
                attribute.Binding = binding;
                attribute.Location = lastLocation + i;
                attribute.Offset = offset;

                switch (fieldType->getKind())
                {
                    case slang::TypeReflection::Kind::Scalar:
                    case slang::TypeReflection::Kind::Vector:
                        offset += fieldTypeLayout->getSize();
                        attribute.Format = getFormat(fieldType->getScalarType(), fieldType->getElementCount());
                        locationsUsed++;
                        break;
                    case slang::TypeReflection::Kind::Matrix:
                    {
                        uint32_t columns = fieldType->getColumnCount();
                        uint32_t rows = fieldType->getRowCount();
                        size_t columnSize = fieldTypeLayout->getElementTypeLayout()->getSize();

                        for (uint32_t j = 0; j < columns; j++)
                        {
                            VertexInputAttributeData matAttr{};
                            matAttr.Binding = binding;
                            matAttr.Location = lastLocation + i + j;
                            matAttr.Offset = offset + j * columnSize;
                            matAttr.Format = getFormat(fieldType->getScalarType(), rows);

                            attributes.push_back(matAttr);

                            locationsUsed++;
                        }

                        offset += fieldTypeLayout->getSize();
                        continue;
                    }
                    default:
                        std::cout << "ShaderLibrary: unsupported type in vertex input" << std::endl;
                        continue;
                }

                attributes.push_back(attribute);
            }

            VertexInputBindingData& bindingData = inputBindingDatas[binding];
            bindingData.Binding = binding;
            bindingData.Stride = offset;
            bindingData.InputRate = inputRate;

            lastLocation += locationsUsed;
        };

        slang::VariableLayoutReflection* entryPointScope = entryPointReflection->getVarLayout();
        slang::TypeLayoutReflection* typeLayout = entryPointScope->getTypeLayout();

        uint32_t paramCount = typeLayout->getFieldCount();
        for (uint32_t param = 0; param < paramCount; param++)
        {
            slang::VariableLayoutReflection* paramLayout = typeLayout->getFieldByIndex(param);

            slang::TypeLayoutReflection* paramTypeLayout = paramLayout->getTypeLayout();
            const char* name = paramTypeLayout->getName();

            if (name && perVertexStructName && std::string(name) == std::string(perVertexStructName))
                processInputStruct(paramTypeLayout, 0, 0);
            else if (name && perInstanceStructName && std::string(name) == std::string(perInstanceStructName))
                processInputStruct(paramTypeLayout, perVertexStructName ? 1 : 0, 1);
        }

        VertexInputAttributeData* attributesPtr = reinterpret_cast<VertexInputAttributeData*>(
            allocator->Allocate(sizeof(VertexInputAttributeData) * attributes.size(), allocator->UserData)
        );

        std::memcpy(attributesPtr, attributes.data(), sizeof(VertexInputAttributeData) * attributes.size());

        *bindingData = inputBindingDatas;
        *bindingDataCount = bindingCount;
        *attributeData = attributesPtr;
        *attributeDataCount = attributes.size();
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
