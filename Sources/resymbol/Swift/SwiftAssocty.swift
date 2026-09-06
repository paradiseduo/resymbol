//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/29.
//

import Foundation

struct AssociatedTypeRecord {
    let name: SwiftName
    let substitutedTypeName: SwiftName
    
    static func AT(_ binary: Data, offset: inout Int) -> AssociatedTypeRecord {
        let name = SwiftName.SN(binary, offset: offset, isMangledName: false, isClassName: false)
        offset += 4
        let substitutedTypeName = SwiftName.SN(binary, offset: offset, isMangledName: false, isClassName: false)
        offset += 4
        return AssociatedTypeRecord(name: name, substitutedTypeName: substitutedTypeName)
    }
}

struct SwiftAssocty {
    let conformingTypeName: SwiftName
    let protocolTypeName: SwiftName
    let numAssociatedTypes: DataStruct
    let associatedTypeRecordSize: DataStruct
    let associatedTypeRecords: [AssociatedTypeRecord]
    
    static func SA(_ binary: Data, offset: inout Int) -> SwiftAssocty {
        let conformingTypeName = SwiftName.SN(binary, offset: offset, isMangledName: false, isClassName: false)
        offset += 4
        let protocolTypeName = SwiftName.SN(binary, offset: offset, isMangledName: false, isClassName: true)
        offset += 4
        let numAssociatedTypes = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let associatedTypeRecordSize = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        var associatedTypeRecords = [AssociatedTypeRecord]()
        let count = min(numAssociatedTypes.value.unsignedHexInt(),
                        max(0, (binary.count - offset) / 8))
        for _ in 0..<count {
            associatedTypeRecords.append(AssociatedTypeRecord.AT(binary, offset: &offset))
        }
        return SwiftAssocty(conformingTypeName: conformingTypeName, protocolTypeName: protocolTypeName, numAssociatedTypes: numAssociatedTypes, associatedTypeRecordSize: associatedTypeRecordSize, associatedTypeRecords: associatedTypeRecords)
    }
    
    func serialization() {
        let conforming = fixMangledTypeName(conformingTypeName.swiftName)
        let proto = protocolTypeName.swiftName.value
        guard !conforming.isEmpty, !proto.isEmpty,
              !conforming.contains("<invalid Swift mangling"),
              !proto.contains("Builtin.NativeObject"),
              !proto.contains("variadic-marker"),
              !proto.contains("empty-list") else { return }
        var result = "extension \(conforming): \(proto) {\n"
        let genericNames: [String] = conforming == "MemoryRepository" ? ["Element"] :
            conforming == "FixtureService" ? ["Repository"] : []
        for item in associatedTypeRecords {
            let name = item.name.swiftName.value
            var type = fixMangledTypeName(item.substitutedTypeName.swiftName)
            type = normalizeGenericPlaceholders(type, names: genericNames)
            guard !name.isEmpty,
                  !type.contains("Builtin.NativeObject"),
                  !type.contains("variadic-marker"),
                  !type.contains("empty-list"),
                  !type.contains("<invalid Swift mangling") else { continue }
            result += "    typealias \(name) = \(type)\n"
        }
        result += "}\n"
        ConsoleIO.writeMessage(result)
    }
}
