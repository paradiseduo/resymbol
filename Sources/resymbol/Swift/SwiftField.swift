//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

enum FieldDescriptorKindType: Int {
    case Struct
    case Class
    case Enum
    // Fixed-size multi-payload enums have a special descriptor format that encodes spare bits.
    case MultiPayloadEnum
    // A Swift opaque protocol. There are no fields, just a record for the type itself.
    case kProtocol
    // A Swift class-bound protocol.
    case ClassProtocol
    // An Objective-C protocol, which may be imported or defined in Swift.
    case ObjCProtocol
    // An Objective-C class, which may be imported or defined in Swift.
    // In the former case, field type metadata is not emitted, and must be obtained from the Objective-C runtime.
    case ObjCClass
    
    case Unknown
}

struct FieldDescriptorKind {
    let kind: DataStruct
    let kindType: FieldDescriptorKindType
    
    static func FDK(_ binary: Data, offset: Int) -> FieldDescriptorKind {
        let kind = DataStruct.data(binary, offset: offset, length: 2)
        let kindType = FieldDescriptorKindType(rawValue: kind.value.int16()) ?? .Unknown
        return FieldDescriptorKind(kind: kind, kindType: kindType)
    }
}

struct FieldRecordFlags {
    let flags: DataStruct
    /// Is this an indirect enum case?
    let isIndirectCase: Bool
    /// Is this a mutable `var` property?
    let isVar: Bool
    
    static func FRF(_ binary: Data, offset: Int) -> FieldRecordFlags {
        let flags = DataStruct.data(binary, offset: offset, length: 4)
        let isIndirectCase = (flags.value.int16() & 0x1) == 0x1
        let isVar = (flags.value.int16() & 0x2) == 0x2
        return FieldRecordFlags(flags: flags, isIndirectCase: isIndirectCase, isVar: isVar)
    }
}

struct FieldRecord {
    let flags: FieldRecordFlags
    let mangledTypeName: SwiftName
    let fieldName: SwiftName
    
    static func FR(_ binary: Data, offset: Int) -> FieldRecord {
        let flags = FieldRecordFlags.FRF(binary, offset: offset)
        let mangledTypeName = SwiftName.SN(binary, offset: offset+4, isMangledName: true, isClassName: false)
        let fieldName = SwiftName.SN(binary, offset: offset+8, isMangledName: false, isClassName: false)
        return FieldRecord(flags: flags, mangledTypeName: mangledTypeName, fieldName: fieldName)
    }
}

struct FieldDescriptor {
    let fieldDescriptor: DataStruct
    let mangledTypeName: SwiftName
    let superclass: DataStruct
    let kind: FieldDescriptorKind
    let fieldRecordSize: DataStruct
    let numFields: DataStruct
    let fieldRecords: [FieldRecord]
    
    static func FD(_ binary: Data, offset: Int) -> FieldDescriptor {
        let fieldDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        
        let newOffset = fieldDescriptor.address.int16()+fieldDescriptor.value.int16()
        
        let mangledTypeName = SwiftName.SN(binary, offset: newOffset, isMangledName: false, isClassName: false)
        let superclass = DataStruct.data(binary, offset: newOffset+4, length: 4)
        let kind = FieldDescriptorKind.FDK(binary, offset: newOffset+8)
        let fieldRecordSize = DataStruct.data(binary, offset: newOffset+10, length: 2)
        let numFields = DataStruct.data(binary, offset: newOffset+12, length: 4)
        var fieldRecords = [FieldRecord]()
        
        if fieldRecordSize.value.int16() != 0 {
            var fieldStart = newOffset+16
            for _ in 0..<numFields.value.int16() {
                fieldRecords.append(FieldRecord.FR(binary, offset: fieldStart))
                fieldStart += fieldRecordSize.value.int16()
            }
        }
        
        return FieldDescriptor(fieldDescriptor: fieldDescriptor, mangledTypeName: mangledTypeName, superclass: superclass, kind: kind, fieldRecordSize: fieldRecordSize, numFields: numFields, fieldRecords: fieldRecords)
    }
}
