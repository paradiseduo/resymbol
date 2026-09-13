//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftStruct {
    let type: SwiftType
    let numFields: DataStruct
    let fieldOffsetVectorOffset: DataStruct
    let genericSignature: SwiftGenericSignature?
    
    static func SS(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftStruct {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let numFields = DataStruct.data(binary, offset: offset+16, length: 4)
        let fieldOffsetVectorOffset = DataStruct.data(binary, offset: offset+20, length: 4)
        let genericSignature = flags.isGeneric ? SwiftGenericSignature.parse(binary, offset: offset + 24) : nil
        return SwiftStruct(type: type, numFields: numFields, fieldOffsetVectorOffset: fieldOffsetVectorOffset, genericSignature: genericSignature)
    }
    
    func serialization() {
        guard type.hasUsableName else { return }
        let qualifiedName = type.qualifiedName
        var result = "\(type.flags.kind.description) \(qualifiedName)"
        let genericNames = genericSignature?.parameterNames() ?? []
        var resolvedFieldTypes = [String: String]()
        var unresolvedFieldTypes = Set<String>()
        if let genericSignature {
            result += genericSignature.declaration()
        }
        result += " {\n"
        for item in type.fieldDescriptor.fieldRecords {
            let property = SwiftStoredProperty.from(item)
            let front = property.declaration
            let fieldName = property.name
            guard isUsableSwiftMemberName(fieldName) else { continue }
            let qualifiedAccessorKey = "\(qualifiedName)|\(fieldName)"
            let accessorName = fieldName.hasPrefix("_") ? String(fieldName.dropFirst()) : fieldName
            let accessorType = MachOData.shared.accessorTypes.firstNonEmpty(for: [
                qualifiedAccessorKey, "\(qualifiedName)|\(accessorName)", fieldName, accessorName
            ])
            let cacheKey = item.mangledTypeName.swiftName.value + "|" + (accessorType ?? "")
            let fieldType: String?
            if let cached = resolvedFieldTypes[cacheKey] {
                fieldType = cached
            } else if unresolvedFieldTypes.contains(cacheKey) {
                fieldType = nil
            } else {
                let resolved = resolvedSwiftFieldType(item, accessorType: accessorType,
                                                       genericNames: genericNames,
                                                       owner: qualifiedName, fieldName: fieldName)
                if let resolved { resolvedFieldTypes[cacheKey] = resolved }
                else { unresolvedFieldTypes.insert(cacheKey) }
                fieldType = resolved
            }
            if let fieldType {
                let normalizedFieldType = normalizeRecoveredSwiftType(fieldType)
                let fieldType = normalizedFieldType.isEmpty ? fieldType : normalizedFieldType
                if let wrapper = recoveredPropertyWrapper(item, fieldType: fieldType,
                                                          accessorType: accessorType) {
                    result += "    \(wrapper)\n"
                } else {
                    result += "    \(front) \(fieldName): \(fieldType)\n"
                }
            } else {
                result += "    \(front) \(fieldName)\n"
            }
        }
        let methods = MachOData.shared.swiftMethodNames(owner: qualifiedName)
        if !methods.isEmpty {
            result += "\n"
            for method in methods {
                result += "    \(normalizeGenericPlaceholders(method, names: genericNames))\n"
            }
        }
        result += "}\n"
        SerializationOutput.emit(result, kind: .swiftStruct, name: qualifiedName)
    }
}
