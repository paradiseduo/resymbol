//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct FieldRecord {
    let flags: SwiftFlags
    let mangledTypeName: SwiftName
    let fieldName: SwiftName
    
    static func FR(_ binary: Data, offset: Int) -> FieldRecord {
        let flags = SwiftFlags.SF(binary, offset: offset)
        let mangledTypeName = SwiftName.SN(binary, offset: offset+4, isClassName: false)
        let fieldName = SwiftName.SN(binary, offset: offset+8, isClassName: false)
        return FieldRecord(flags: flags, mangledTypeName: mangledTypeName, fieldName: fieldName)
    }
}

struct FieldDescriptor {
    let fieldDescriptor: DataStruct
    let mangledTypeName: SwiftName
    let superclass: DataStruct
    let kind: DataStruct
    let fieldRecordSize: DataStruct
    let numFields: DataStruct
    let fieldRecords: [FieldRecord]
    
    static func FD(_ binary: Data, offset: Int) -> FieldDescriptor {
        let fieldDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        
        let newOffset = fieldDescriptor.address.int16()+fieldDescriptor.value.int16()
        
        let mangledTypeName = SwiftName.SN(binary, offset: newOffset, isClassName: false)
        let superclass = DataStruct.data(binary, offset: newOffset+4, length: 4)
        let kind = DataStruct.data(binary, offset: newOffset+8, length: 2)
        let fieldRecordSize = DataStruct.data(binary, offset: newOffset+10, length: 2)
        let numFields = DataStruct.data(binary, offset: newOffset+12, length: 4)
        var fieldRecords = [FieldRecord]()
        
        if numFields.value.int16() < 128 {
            var fieldStart = newOffset+16
            for _ in 0..<numFields.value.int16() {
                fieldRecords.append(FieldRecord.FR(binary, offset: fieldStart))
                fieldStart += 12
            }
        }
        
        return FieldDescriptor(fieldDescriptor: fieldDescriptor, mangledTypeName: mangledTypeName, superclass: superclass, kind: kind, fieldRecordSize: fieldRecordSize, numFields: numFields, fieldRecords: fieldRecords)
    }
}
