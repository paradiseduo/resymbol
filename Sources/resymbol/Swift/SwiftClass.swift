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
        let superclassType = DataStruct.textSwiftData(binary, offset: offset+superclass.value.int16Subtraction(), isClassName: true)
        return SwiftSuperClass(superclass: superclass, superclassType: superclassType)
    }
}

struct SwiftClass {
    let type: SwiftType
    let superclassType: SwiftSuperClass
    let metadataNegativeSizeInWords: DataStruct
    let metadataPositiveSizeInWords: DataStruct
    let numImmediateMembers: DataStruct
    let numFields: DataStruct
    
    static func SC(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftClass {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let superclassType = SwiftSuperClass.SSC(binary, offset: offset+16)
        let metadataNegativeSizeInWords = DataStruct.data(binary, offset: offset+20, length: 4)
        let metadataPositiveSizeInWords = DataStruct.data(binary, offset: offset+24, length: 4)
        let numImmediateMembers = DataStruct.data(binary, offset: offset+28, length: 4)
        let numFields = DataStruct.data(binary, offset: offset+32, length: 4)
        
        return SwiftClass(type: type, superclassType: superclassType, metadataNegativeSizeInWords: metadataNegativeSizeInWords, metadataPositiveSizeInWords: metadataPositiveSizeInWords, numImmediateMembers: numImmediateMembers, numFields: numFields)
    }
    
    func serialization() {
        var result = "class \(type.name.swiftName.value)"
        if superclassType.superclassType.value != "00000000" {
            if superclassType.superclassType.value.starts(with: "0x"), let s = MachOData.shared.mangledNameMap[superclassType.superclassType.value] {
                result += ": \(s) {\n"
            } else {
                result += ": \(superclassType.superclassType.value) {\n"
            }
        } else {
            result += " {\n"
        }
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
