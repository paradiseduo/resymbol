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

struct GenericSign {
    let addMetadataInstantiationCache: DataStruct
    let addMetadataInstantiationPattern: DataStruct
    let genericParamCount: DataStruct
    let genericRequirementCount: DataStruct
    let genericKeyArgumentCount: DataStruct
    let genericExtraArgumentCount: DataStruct
    
    static func GS(_ binary: Data, offset: Int) -> GenericSign{
        let addMetadataInstantiationCache = DataStruct.data(binary, offset: offset, length: 4)
        let addMetadataInstantiationPattern = DataStruct.data(binary, offset: offset+4, length: 4)
        let genericParamCount = DataStruct.data(binary, offset: offset+8, length: 2)
        let genericRequirementCount = DataStruct.data(binary, offset: offset+10, length: 2)
        let genericKeyArgumentCount = DataStruct.data(binary, offset: offset+12, length: 2)
        let genericExtraArgumentCount = DataStruct.data(binary, offset: offset+14, length: 2)
        
        return GenericSign(addMetadataInstantiationCache: addMetadataInstantiationCache, addMetadataInstantiationPattern: addMetadataInstantiationPattern, genericParamCount: genericParamCount, genericRequirementCount: genericRequirementCount, genericKeyArgumentCount: genericKeyArgumentCount, genericExtraArgumentCount: genericExtraArgumentCount)
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
    let genericSign: GenericSign?
    let resilientSuperclass: DataStruct
    let metadataInitialization: DataStruct
    let vtableOffset: DataStruct
    let vtableSize: DataStruct
    let methods: [SwiftMethod]
    let overrideMethodNum: DataStruct
    let overrideTableList: [SwiftOverrideMethod]
    
    static func SC(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftClass {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let superclassType = SwiftSuperClass.SSC(binary, offset: offset+16)
        let metadataNegativeSizeInWords = DataStruct.data(binary, offset: offset+20, length: 4)
        let metadataPositiveSizeInWords = DataStruct.data(binary, offset: offset+24, length: 4)
        let numImmediateMembers = DataStruct.data(binary, offset: offset+28, length: 4)
        let numFields = DataStruct.data(binary, offset: offset+32, length: 4)
        let fieldOffsetVectorOffset = DataStruct.data(binary, offset: offset+32, length: 4)
        
        let address = offset.string16()
        var genericSign: GenericSign?
        var newOffset = offset+40
        // 如果是泛型，计算泛型签名字节数
        if type.flags.isGeneric {
            genericSign = GenericSign.GS(binary, offset: newOffset)
            let header = 16
            let paramCount = genericSign!.genericParamCount.value.int16()
            let requirementCount = genericSign!.genericRequirementCount.value.int16()
            let pandding = UInt(-paramCount&3)
            newOffset += header + paramCount + Int(pandding) + 3 * 4 * requirementCount
        }
        
        var resilientSuperclass = DataStruct(address: address, value: "00000000")
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasResilientSuperclass
        }) {
            resilientSuperclass = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
        }
        
        var metadataInitialization = DataStruct(address: address, value: "00000000")
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .MetadataInitialization
        }) {
            metadataInitialization = DataStruct.data(binary, offset: newOffset, length: 12)
            newOffset += 12
        }
        
        var vtableOffset = DataStruct(address: address, value: "00000000")
        var vtableSize = DataStruct(address: address, value: "00000000")
        var methods = [SwiftMethod]()
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasVTable
        }) {
            vtableOffset = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
            vtableSize = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
            for _ in 0..<vtableSize.value.int16() {
                methods.append(SwiftMethod.SM(binary, offset: &newOffset))
            }
        }
        
        var overrideMethodNum = DataStruct(address: address, value: "00000000")
        var overrideTableList = [SwiftOverrideMethod]()
        if type.flags.typeContextDescriptorFlags.contains(where: { t in
            return t == .Class_HasOverrideTable
        }) {
            overrideMethodNum = DataStruct.data(binary, offset: newOffset, length: 4)
            newOffset += 4
            for _ in 0..<overrideMethodNum.value.int16() {
                overrideTableList.append(SwiftOverrideMethod.SOM(binary, offset: &newOffset))
            }
        }

        return SwiftClass(type: type, superclassType: superclassType, metadataNegativeSizeInWords: metadataNegativeSizeInWords, metadataPositiveSizeInWords: metadataPositiveSizeInWords, numImmediateMembers: numImmediateMembers, numFields: numFields, fieldOffsetVectorOffset: fieldOffsetVectorOffset, genericSign: genericSign, resilientSuperclass: resilientSuperclass, metadataInitialization: metadataInitialization, vtableOffset: vtableOffset, vtableSize: vtableSize, methods: methods, overrideMethodNum: overrideMethodNum, overrideTableList: overrideTableList)
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
        if methods.count > 0 {
            result += "\n"
            for item in methods {
                result += "    func \(item.impl.implOffset.address)(){}\n"
            }
        }
        result += "}\n"
        print(result)
    }
}
