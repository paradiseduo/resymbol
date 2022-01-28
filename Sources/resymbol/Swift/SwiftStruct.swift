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
    
    static func SS(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftStruct {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let numFields = DataStruct.data(binary, offset: offset+16, length: 4)
        let fieldOffsetVectorOffset = DataStruct.data(binary, offset: offset+20, length: 4)
        
        return SwiftStruct(type: type, numFields: numFields, fieldOffsetVectorOffset: fieldOffsetVectorOffset)
    }
    
    func serialization() {
        var result = "\(type.flags.kind.description) \(type.name.swiftName.value) {\n"
        for item in type.fieldDescriptor.fieldRecords {
            if item.mangledTypeName.swiftName.value.starts(with: "0x") {
                result += "    let \(item.fieldName.swiftName.value): \(item.fixMangledTypeName())\n"
            } else {
                result += "    let \(item.fieldName.swiftName.value): \(item.mangledTypeName.swiftName.value)\n"
            }
        }
        result += "}\n"
        print(result)
    }
}
