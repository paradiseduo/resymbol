//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/13.
//

import Foundation

struct SwiftFlags {
    let flags: DataStruct
    let kind: SwiftTypeEnum
    let isGeneric: Bool
    let isUnique: Bool
    let version: UInt8
    let kindSpecificFlags: UInt16
    let typeContextDescriptorFlags: [SwiftTypeContextDescriptorFlag]
    
    static func SF(_ binary: Data, offset: Int) -> SwiftFlags {
        let flags = DataStruct.data(binary, offset: offset, length: 4)
        let value = flags.value.int16()
        let kind = SwiftTypeEnum(rawValue: value & 0x1F) ?? SwiftTypeEnum.Unknow
        let isGeneric = ((value & 0x80) != 0)
        let isUnique = ((value & 0x40) != 0)
        let version = UInt8((value >> 8) & 0xFF)
        let kindSpecificFlags = UInt16((value >> 16) & 0xFFFF)
        let typeContextDescriptorFlags = SwiftTypeContextDescriptorFlag.STCDF(value: kindSpecificFlags)
        
        return SwiftFlags(flags: flags, kind: kind, isGeneric: isGeneric, isUnique: isUnique, version: version, kindSpecificFlags: kindSpecificFlags, typeContextDescriptorFlags: typeContextDescriptorFlags)
    }
}
