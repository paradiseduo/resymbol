//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftSuperClass {
    let superclass: DataStruct
    let superclassType: DataStruct
    
    static func SSC(_ binary: Data, offset: Int) -> SwiftSuperClass {
        let superclass = DataStruct.data(binary, offset: offset, length: 4)
        let superclassOffset = MachOData.shared.resolveRelativePointer(base: offset, raw: superclass.value)
            ?? binary.count
        let superclassType = DataStruct.textSwiftData(binary, offset: superclassOffset, isMangledName: false, isClassName: true)
        return SwiftSuperClass(superclass: superclass, superclassType: superclassType)
    }
}

struct GenericSign {
    let addMetadataInstantiationCache: DataStruct
    let addMetadataInstantiationPattern: DataStruct
    let genericParamCount: DataStruct
    let genericRequirementCount: DataStruct
    let genericKeyArgumentCount: DataStruct
    let genericExtraArgumentCount: DataStruct
    let signature: SwiftGenericSignature
    
    static func GS(_ binary: Data, offset: Int) -> GenericSign{
        let addMetadataInstantiationCache = DataStruct.data(binary, offset: offset, length: 4)
        let addMetadataInstantiationPattern = DataStruct.data(binary, offset: offset+4, length: 4)
        let genericParamCount = DataStruct.data(binary, offset: offset+8, length: 2)
        let genericRequirementCount = DataStruct.data(binary, offset: offset+10, length: 2)
        let genericKeyArgumentCount = DataStruct.data(binary, offset: offset+12, length: 2)
        let genericExtraArgumentCount = DataStruct.data(binary, offset: offset+14, length: 2)
        
        let signature = SwiftGenericSignature.parse(binary, offset: offset)
            ?? SwiftGenericSignature(parameterCount: Int(UInt32(genericParamCount.value, radix: 16) ?? 0),
                                     requirementCount: Int(UInt32(genericRequirementCount.value, radix: 16) ?? 0),
                                     requirements: [])
        return GenericSign(addMetadataInstantiationCache: addMetadataInstantiationCache, addMetadataInstantiationPattern: addMetadataInstantiationPattern, genericParamCount: genericParamCount, genericRequirementCount: genericRequirementCount, genericKeyArgumentCount: genericKeyArgumentCount, genericExtraArgumentCount: genericExtraArgumentCount, signature: signature)
    }
}

struct SwiftClass {
    let type: SwiftType
    let superclassType: SwiftSuperClass
    let metadataNegativeSizeInWords: DataStruct
    let metadataPositiveSizeInWords: DataStruct
    let numImmediateMembers: DataStruct
    let numFields: DataStruct
    let fieldOffsetVectorOffset: DataStruct
    let genericSign: GenericSign?
    let resilientSuperclass: DataStruct
    let resilientSuperclassType: DataStruct
    let metadataInitialization: DataStruct
    let vtableOffset: DataStruct
    let vtableSize: DataStruct
    let methods: [SwiftMethod]
    let overrideMethodNum: DataStruct
    let overrideTableList: [SwiftOverrideMethod]
    
    static func SC(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftClass {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let superclassType = SwiftSuperClass.SSC(binary, offset: offset+16)
        let metadataNegativeSizeInWords = DataStruct.data(binary, offset: offset+20, length: 4)
        let metadataPositiveSizeInWords = DataStruct.data(binary, offset: offset+24, length: 4)
        let numImmediateMembers = DataStruct.data(binary, offset: offset+28, length: 4)
        let numFields = DataStruct.data(binary, offset: offset+32, length: 4)
        // Class context descriptors store `numFields` followed by the
        // relative offset of the field-offset vector. These are distinct
        // 32-bit fields; reading both at +32 made every class report its
        // field count as the vector offset and shifted subsequent metadata
        // interpretation.
        let fieldOffsetVectorOffset = DataStruct.data(binary, offset: offset+36, length: 4)
        
        let address = offset.string16()
        var genericSign: GenericSign?
        var newOffset = offset+40
        // 如果是泛型，计算泛型签名字节数
        if type.flags.isGeneric {
            genericSign = GenericSign.GS(binary, offset: newOffset)
            let header = 16
            // Descriptor counts are unsigned byte/word fields. Older code
            // decoded them through a signed hexadecimal helper; malformed
            // Release metadata could therefore produce a negative count and
            // trap while converting the alignment value to UInt.
            let paramCount = max(0, min(1024, genericSign!.signature.parameterCount))
            let requirementCount = max(0, min(4096, genericSign!.signature.requirementCount))
            let padding = (4 - (paramCount & 3)) & 3
            let requirementBytes = requirementCount.multipliedReportingOverflow(by: 12)
            if !requirementBytes.overflow {
                let cursorAdvance = header.addingReportingOverflow(paramCount)
                let withPadding = cursorAdvance.partialValue.addingReportingOverflow(padding)
                let withRequirements = withPadding.partialValue.addingReportingOverflow(requirementBytes.partialValue)
                if !cursorAdvance.overflow && !withPadding.overflow && !withRequirements.overflow {
                    newOffset += withRequirements.partialValue
                }
            }
        }
        
        var resilientSuperclass = DataStruct(address: address, value: None)
        var resilientSuperclassType = DataStruct(address: address, value: None)
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasResilientSuperclass
        }) {
            resilientSuperclass = DataStruct.data(binary, offset: newOffset, length: 4)
            let resilientOffset = MachOData.shared.resolveRelativePointer(base: newOffset,
                                                                            raw: resilientSuperclass.value)
                ?? binary.count
            resilientSuperclassType = DataStruct.textSwiftData(binary, offset: resilientOffset,
                                                                 isMangledName: false,
                                                                 isClassName: true)
            newOffset += 4
        }
        
        var metadataInitialization = DataStruct(address: address, value: None)
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .MetadataInitialization
        }) {
            metadataInitialization = DataStruct.data(binary, offset: newOffset, length: 12)
            newOffset += 12
        }
        
        var vtableOffset = DataStruct(address: address, value: None)
        var vtableSize = DataStruct(address: address, value: None)
        var methods = [SwiftMethod]()
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasVTable
        }) {
            vtableOffset = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
            vtableSize = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
            for _ in 0..<min(vtableSize.value.unsignedHexInt(), max(0, (binary.count - newOffset) / 4)) {
                methods.append(SwiftMethod.SM(binary, offset: &newOffset))
            }
        }
        
        var overrideMethodNum = DataStruct(address: address, value: None)
        var overrideTableList = [SwiftOverrideMethod]()
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasOverrideTable
        }) {
            overrideMethodNum = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
            for _ in 0..<min(overrideMethodNum.value.unsignedHexInt(), max(0, (binary.count - newOffset) / 8)) {
                overrideTableList.append(SwiftOverrideMethod.SOM(binary, offset: &newOffset))
            }
        }

        return SwiftClass(type: type, superclassType: superclassType,
                          metadataNegativeSizeInWords: metadataNegativeSizeInWords,
                          metadataPositiveSizeInWords: metadataPositiveSizeInWords,
                          numImmediateMembers: numImmediateMembers, numFields: numFields,
                          fieldOffsetVectorOffset: fieldOffsetVectorOffset,
                          genericSign: genericSign, resilientSuperclass: resilientSuperclass,
                          resilientSuperclassType: resilientSuperclassType,
                          metadataInitialization: metadataInitialization,
                          vtableOffset: vtableOffset, vtableSize: vtableSize,
                          methods: methods, overrideMethodNum: overrideMethodNum,
                          overrideTableList: overrideTableList)
    }
    
    func serialization() {
        guard type.hasUsableName else { return }
        var result = "\(type.flags.kind.description) \(type.qualifiedName)"
        let genericNames = genericSign?.signature.parameterNames(owner: type.name.swiftName.value,
                                                                 fields: type.fieldDescriptor.fieldRecords) ?? []
        if let genericSign {
            result += genericSign.signature.declaration(owner: type.name.swiftName.value,
                                                         fields: type.fieldDescriptor.fieldRecords)
        }
        let runtimeSuperclass = MachOData.shared.swiftSuperclasses[type.qualifiedName]
            ?? MachOData.shared.swiftSuperclasses[type.name.swiftName.value]
        let descriptorCandidates = [superclassType.superclassType, resilientSuperclassType]
        var superclassText: String?
        for candidate in descriptorCandidates where candidate.value != None {
            if candidate.value.hasPrefix("0x") {
                let fixed = fixMangledTypeName(candidate)
                if !fixed.isEmpty && !fixed.hasPrefix("0x") {
                    superclassText = fixed
                    break
                }
            } else {
                // The superclass name is already a Swift-mangled string (e.g.
                // "So6UIViewC"). Demangle it so the output reads ": UIView"
                // instead of the raw mangled form.
                let demangled = getTypeFromMangledName(candidate.value)
                if !demangled.isEmpty && !demangled.hasPrefix("0x") {
                    superclassText = demangled
                    break
                }
            }
        }
        if superclassText == nil { superclassText = runtimeSuperclass }
        if let superclassText, !superclassText.isEmpty {
            result += ": \(superclassText) {\n"
        } else {
            result += " {\n"
        }
        for item in type.fieldDescriptor.fieldRecords {
            let property = SwiftStoredProperty.from(item)
            let front = property.declaration
            let fieldName = property.name
            guard isUsableSwiftMemberName(fieldName) else { continue }
            let declaration = property.declaration
            let qualifiedAccessorKey = "\(type.qualifiedName)|\(fieldName)"
            let accessorName = fieldName.hasPrefix("_") ? String(fieldName.dropFirst()) : fieldName
            let accessorType = [MachOData.shared.accessorTypes[qualifiedAccessorKey],
                                MachOData.shared.accessorTypes["\(type.qualifiedName)|\(accessorName)"],
                                MachOData.shared.accessorTypes[fieldName],
                                MachOData.shared.accessorTypes[accessorName]]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            if let fieldType = resolvedSwiftFieldType(item, accessorType: accessorType,
                                                      genericNames: genericNames) {
                if let wrapper = recoveredPropertyWrapper(item, fieldType: fieldType,
                                                          accessorType: accessorType) {
                    result += "    \(wrapper)\n"
                } else {
                    result += "    \(declaration) \(fieldName): \(fieldType)\n"
                }
            } else {
                result += "    \(front) \(fieldName)\n"
            }
        }
        if methods.count > 0 {
            result += "\n"
            var emittedMethods = Set<String>()
            for item in methods {
                let addr = item.impl.implOffset.address
                if item.impl.implOffset.value != None {
                    if let fileOffset = Int(addr, radix: 16),
                       let source = MachOData.shared.swiftMethodDeclaration(
                           fileOffset: fileOffset, owner: type.qualifiedName) {
                        let declaration = normalizeGenericPlaceholders(source, names: genericNames)
                        if emittedMethods.insert(declaration).inserted { result += "    \(declaration)\n" }
                    } else {
                        let declaration = "func \(addr)(){}"
                        if emittedMethods.insert(declaration).inserted { result += "    \(declaration)\n" }
                    }
                }
            }
            for method in MachOData.shared.swiftMethodNames(owner: type.qualifiedName) {
                let normalized = normalizeGenericPlaceholders(method, names: genericNames)
                if emittedMethods.insert(normalized).inserted { result += "    \(normalized)\n" }
            }
        } else {
            let indexed = MachOData.shared.swiftMethodNames(owner: type.qualifiedName)
            if !indexed.isEmpty {
                result += "\n"
                for method in indexed {
                    result += "    \(normalizeGenericPlaceholders(method, names: genericNames))\n"
                }
            }
        }
        result += "}\n"
        ConsoleIO.writeMessage(result)
    }
}
