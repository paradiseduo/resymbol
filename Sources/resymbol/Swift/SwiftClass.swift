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
    let genericArgumentOffset: DataStruct
    let vtableOffset: DataStruct
    let vtableSize: DataStruct
    let methods: [SwiftMethod]
    let fieldOffsetVectorOffset: DataStruct
    
    static func SC(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftClass {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let superclassType = SwiftSuperClass.SSC(binary, offset: offset+16)
        let metadataNegativeSizeInWords = DataStruct.data(binary, offset: offset+20, length: 4)
        let metadataPositiveSizeInWords = DataStruct.data(binary, offset: offset+24, length: 4)
        let numImmediateMembers = DataStruct.data(binary, offset: offset+28, length: 4)
        let numFields = DataStruct.data(binary, offset: offset+32, length: 4)
        
        let address = offset.string16()
        var genericArgumentOffset = DataStruct(address: address, value: "00000000")
        var newOffset = offset+32
        if !type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasResilientSuperclass
        }) {
            newOffset += 4
            genericArgumentOffset = DataStruct.data(binary, offset: newOffset, length: 4)
        }

        var vtableOffset = DataStruct(address: address, value: "00000000")
        var vtableSize = DataStruct(address: address, value: "00000000")
        var methods = [SwiftMethod]()
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasVTable
        }) {
            newOffset += 4
            vtableOffset = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
            vtableSize = DataStruct.data(binary, offset: newOffset, length: 4)
            for _ in 0..<vtableSize.value.int16() {
                newOffset += 4
                methods.append(SwiftMethod.SM(binary, offset: &newOffset))
            }
        }
        
        var fieldOffsetVectorOffset = DataStruct(address: address, value: "00000000")
        if type.fieldDescriptor.fieldDescriptor.value.int16() != 0 {
            newOffset += 4
            fieldOffsetVectorOffset = DataStruct.data(binary, offset: newOffset, length: 4)
        }

        return SwiftClass(type: type, superclassType: superclassType, metadataNegativeSizeInWords: metadataNegativeSizeInWords, metadataPositiveSizeInWords: metadataPositiveSizeInWords, numImmediateMembers: numImmediateMembers, numFields: numFields, genericArgumentOffset: genericArgumentOffset, vtableOffset: vtableOffset, vtableSize: vtableSize, methods: methods, fieldOffsetVectorOffset: fieldOffsetVectorOffset)
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
