//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/2/13.
//

import Foundation

struct SwiftBuiltinTypeFlag {
    let alignmentAndFlags: DataStruct
    let alignment: Int
    let isBitwiseTakable: Bool
    
    static func SBTF(_ binary: Data, offset: Int) -> SwiftBuiltinTypeFlag {
        let alignmentAndFlags = DataStruct.data(binary, offset: offset, length: 4)
        let v = alignmentAndFlags.value.int16()
        let alignment = Int(v & 0xffff)
        let isBitwiseTakable = ((v >> 16)&1 != 0)
        
        return SwiftBuiltinTypeFlag(alignmentAndFlags: alignmentAndFlags, alignment: alignment, isBitwiseTakable: isBitwiseTakable)
    }
}


struct SwiftBuiltin {
    let typeName: SwiftName
    let size: DataStruct
    let alignmentAndFlags: SwiftBuiltinTypeFlag
    let stride: DataStruct
    let numExtraInhabitants: DataStruct
    
    static func SB(_ binary: Data, offset: inout Int) -> SwiftBuiltin {
        let typeName = SwiftName.SN(binary, offset: offset, isClassName: false)
        offset += 4
        let size = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let alignmentAndFlags = SwiftBuiltinTypeFlag.SBTF(binary, offset: offset)
        offset += 4
        let stride = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let numExtraInhabitants = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        return SwiftBuiltin(typeName: typeName, size: size, alignmentAndFlags: alignmentAndFlags, stride: stride, numExtraInhabitants: numExtraInhabitants)
    }
    
    func serialization() async {
        print("builtin \(await fixMangledTypeName(typeName.swiftName)) {\n\t\(alignmentAndFlags.alignment)\n\t\(alignmentAndFlags.isBitwiseTakable)\n\t\(stride.value.int16())\n\t\(numExtraInhabitants.value.int16())\n}\n")
    }
}
