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
    
    static func SE(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftEnum {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let numPayloadCasesAndPayloadSizeOffset = DataStruct.data(binary, offset: offset+16, length: 4)
        let numEmptyCases = DataStruct.data(binary, offset: offset+20, length: 4)
        
        return SwiftEnum(type: type, numPayloadCasesAndPayloadSizeOffset: numPayloadCasesAndPayloadSizeOffset, numEmptyCases: numEmptyCases)
    }
    
    func serialization() async {
        var result = "\(type.flags.kind.description) \(type.name.swiftName.value) {\n"
        for item in type.fieldDescriptor.fieldRecords {
            if item.mangledTypeName.swiftName.value.starts(with: "0x") {
                let fix = await fixMangledTypeName(item.mangledTypeName.swiftName)
                if fix.count > 0 {
                    result += "    case \(item.fieldName.swiftName.value): \(fix)\n"
                } else {
                    result += "    case \(item.fieldName.swiftName.value)\n"
                }
            } else {
                if item.mangledTypeName.swiftName.value != "00000000" {
                    result += "    case \(item.fieldName.swiftName.value): \(item.mangledTypeName.swiftName.value)\n"
                } else {
                    result += "    case \(item.fieldName.swiftName.value)\n"
                }
            }
        }
        result += "}\n"
        print(result)
    }
}
