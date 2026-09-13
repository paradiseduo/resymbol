//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftEnum {
    let type: SwiftType
    let numPayloadCasesAndPayloadSizeOffset: DataStruct
    let numEmptyCases: DataStruct
    let genericSignature: SwiftGenericSignature?

    /// The low 24 bits encode payload case count; the high byte is the
    /// payload-size offset. Empty case count is a separate 32-bit field.
    var declaredCaseCount: Int? {
        Self.decodeCaseCount(payload: numPayloadCasesAndPayloadSizeOffset.value,
                             empty: numEmptyCases.value)
    }

    static func decodeCaseCount(payload: String, empty: String) -> Int? {
        guard let raw = UInt32(payload, radix: 16),
              let empty = UInt32(empty, radix: 16) else { return nil }
        let payload = Int(raw & 0x00ff_ffff)
        let emptyCount = Int(empty)
        let total = payload + emptyCount
        guard total > 0, total < 100_000 else { return nil }
        return total
    }
    
    static func SE(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftEnum {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let numPayloadCasesAndPayloadSizeOffset = DataStruct.data(binary, offset: offset+16, length: 4)
        let numEmptyCases = DataStruct.data(binary, offset: offset+20, length: 4)
        
        let genericSignature = flags.isGeneric ? SwiftGenericSignature.parse(binary, offset: offset + 24) : nil
        return SwiftEnum(type: type, numPayloadCasesAndPayloadSizeOffset: numPayloadCasesAndPayloadSizeOffset, numEmptyCases: numEmptyCases, genericSignature: genericSignature)
    }
    
    func serialization() {
        guard type.hasUsableName else { return }
        var result = "\(type.flags.kind.description) \(type.qualifiedName)"
        let genericNames = genericSignature?.parameterNames() ?? []
        var resolvedFieldTypes = [String: String]()
        var unresolvedFieldTypes = Set<String>()
        if let genericSignature {
            result += genericSignature.declaration()
        }
        result += " {\n"
        let records: ArraySlice<FieldRecord>
        if let declaredCaseCount, declaredCaseCount <= type.fieldDescriptor.fieldRecords.count {
            records = type.fieldDescriptor.fieldRecords.prefix(declaredCaseCount)
        } else {
            records = type.fieldDescriptor.fieldRecords[...]
        }
        for item in records {
            let name = item.fieldName.swiftName.value
            guard isUsableSwiftMemberName(name) else { continue }
            let indirect = item.flags.isIndirectCase ? "indirect " : ""
            let cacheKey = item.mangledTypeName.swiftName.value
            let fieldType: String?
            if let cached = resolvedFieldTypes[cacheKey] {
                fieldType = cached
            } else if unresolvedFieldTypes.contains(cacheKey) {
                fieldType = nil
            } else {
                let resolved = resolvedSwiftFieldType(item, genericNames: genericNames,
                                                      owner: type.qualifiedName, fieldName: name)
                if let resolved { resolvedFieldTypes[cacheKey] = resolved }
                else { unresolvedFieldTypes.insert(cacheKey) }
                fieldType = resolved
            }
            if let type = fieldType {
                let normalizedType = normalizeRecoveredSwiftType(type)
                let type = normalizedType.isEmpty ? type : normalizedType
                // Associated values are function-like in Swift source. Keep
                // an already-tupled payload intact instead of producing
                // invalid `case name: Type` declarations.
                let payload: String
                if type.hasPrefix("(") && type.hasSuffix(")") {
                    payload = type
                } else {
                    payload = "(\(type))"
                }
                result += "    \(indirect)case \(name)\(payload)\n"
            } else {
                result += "    \(indirect)case \(name)\n"
            }
        }
        result += "}\n"
        SerializationOutput.emit(result, kind: .swiftEnum, name: type.qualifiedName)
    }
}
