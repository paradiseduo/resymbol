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
        let superclassType = DataStruct.textSwiftData(binary, offset: offset+superclass.value.int16Subtraction(), isMangledName: false, isClassName: true)
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
    let fieldOffsetVectorOffset: DataStruct
    
    static func SC(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftClass {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let superclassType = SwiftSuperClass.SSC(binary, offset: offset+16)
        let metadataNegativeSizeInWords = DataStruct.data(binary, offset: offset+20, length: 4)
        let metadataPositiveSizeInWords = DataStruct.data(binary, offset: offset+24, length: 4)
        let numImmediateMembers = DataStruct.data(binary, offset: offset+28, length: 4)
        let numFields = DataStruct.data(binary, offset: offset+32, length: 4)
        let fieldOffsetVectorOffset = DataStruct.data(binary, offset: offset+36, length: 4)
        
        return SwiftClass(type: type, superclassType: superclassType, metadataNegativeSizeInWords: metadataNegativeSizeInWords, metadataPositiveSizeInWords: metadataPositiveSizeInWords, numImmediateMembers: numImmediateMembers, numFields: numFields, fieldOffsetVectorOffset: fieldOffsetVectorOffset)
    }
    
    func serialization() {
        var result = "\(type.flags.kind.description) \(type.name.swiftName.value)"
        if superclassType.superclassType.value != "00000000" {
            if superclassType.superclassType.value.starts(with: "0x") {
                result += ": \(fixMangledTypeName(superclassType.superclassType)) {\n"
            } else {
                result += ": \(superclassType.superclassType.value) {\n"
            }
        } else {
            result += " {\n"
        }
        for item in type.fieldDescriptor.fieldRecords {
            let front = item.flags.isVar ? "var" : "let"
            if item.mangledTypeName.swiftName.value.starts(with: "0x") {
                let fix = fixMangledTypeName(item.mangledTypeName.swiftName)
                if fix.count > 0 {
                    result += "    \(front) \(item.fieldName.swiftName.value): \(fix)\n"
                } else {
                    result += "    \(front) \(item.fieldName.swiftName.value)\n"
                }
            } else {
                if item.mangledTypeName.swiftName.value != "00000000" {
                    result += "    \(front) \(item.fieldName.swiftName.value): \(item.mangledTypeName.swiftName.value)\n"
                } else {
                    result += "    \(front) \(item.fieldName.swiftName.value)\n"
                }
            }
        }
        result += "}\n"
        print(result)
    }
}
