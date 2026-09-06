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
        var result = "\(type.flags.kind.description) \(type.qualifiedName)"
        let genericNames = genericSignature?.parameterNames(owner: type.name.swiftName.value,
                                                            fields: type.fieldDescriptor.fieldRecords) ?? []
        if let genericSignature {
            result += genericSignature.declaration(owner: type.name.swiftName.value,
                                                   fields: type.fieldDescriptor.fieldRecords)
        }
        result += " {\n"
        for item in type.fieldDescriptor.fieldRecords {
            let property = SwiftStoredProperty.from(item)
            let front = property.declaration
            let fieldName = property.name
            guard isUsableSwiftMemberName(fieldName) else { continue }
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
                    result += "    \(front) \(fieldName): \(fieldType)\n"
                }
            } else {
                result += "    \(front) \(fieldName)\n"
            }
        }
        let methods = MachOData.shared.swiftMethodNames(owner: type.qualifiedName)
        if !methods.isEmpty {
            result += "\n"
            for method in methods {
                result += "    \(normalizeGenericPlaceholders(method, names: genericNames))\n"
            }
        }
        result += "}\n"
        ConsoleIO.writeMessage(result)
    }
}
