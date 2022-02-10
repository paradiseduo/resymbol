//
//  File.swift
//  
//
//  Created by admin on 2022/1/29.
//

import Foundation

struct AssociatedTypeRecord {
    let name: SwiftName
    let substitutedTypeName: SwiftName
    
    static func AT(_ binary: Data, offset: inout Int) -> AssociatedTypeRecord {
        let name = SwiftName.SN(binary, offset: offset, isClassName: false)
        offset += 4
        let substitutedTypeName = SwiftName.SN(binary, offset: offset, isClassName: false)
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
        let conformingTypeName = SwiftName.SN(binary, offset: offset, isClassName: false)
        offset += 4
        let protocolTypeName = SwiftName.SN(binary, offset: offset, isClassName: true)
        offset += 4
        let numAssociatedTypes = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let associatedTypeRecordSize = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        var associatedTypeRecords = [AssociatedTypeRecord]()
        for _ in 0..<numAssociatedTypes.value.int16() {
            associatedTypeRecords.append(AssociatedTypeRecord.AT(binary, offset: &offset))
        }
        return SwiftAssocty(conformingTypeName: conformingTypeName, protocolTypeName: protocolTypeName, numAssociatedTypes: numAssociatedTypes, associatedTypeRecordSize: associatedTypeRecordSize, associatedTypeRecords: associatedTypeRecords)
    }
}
