//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/13.
//

import Foundation

enum SwiftTypeEnum: Int, CustomStringConvertible {
    /// This context descriptor represents a module.
    case Module = 0
    
    /// This context descriptor represents an extension.
    case Extension = 1
    
    /// This context descriptor represents an anonymous possibly-generic context
    /// such as a function body.
    case Anonymous = 2
    
    /// This context descriptor represents a protocol context.
    case SwiftProtocol = 3
    
    /// This context descriptor represents an opaque type alias.
    case OpaqueType = 4
    
    /// First kind that represents a type of any sort.
    //case Type_First = 16
    
    /// This context descriptor represents a class.
    case Class = 16 // Type_First
    
    /// This context descriptor represents a struct.
    case Struct = 17 // Type_First + 1
    
    /// This context descriptor represents an enum.
    case Enum = 18 // Type_First + 2
    
    /// Last kind that represents a type of any sort.
    case Type_Last = 31
    
    case Unknow = 0xFF // It's not in swift source, this value only used for dump
    
    var description: String {
        switch self {
        case .Module: return "module"
        case .Extension: return "extension"
        case .Anonymous: return "anonymous"
        case .SwiftProtocol: return "protocol"
        case .OpaqueType: return "OpaqueType"
        case .Class: return "class"
        case .Struct: return "struct"
        case .Enum: return "enum"
        case .Type_Last: return "Type_Last"
        case .Unknow: return "unknow"
        }
    }
}

struct SwiftFlags {
    let flags: DataStruct
    let kind: SwiftTypeEnum
    let isGeneric: Bool
    let isUnique: Bool
    let version: UInt8
    let kindSpecificFlags: UInt16
    
    static func SF(_ binary: Data, offset: Int) -> SwiftFlags {
        let flags = DataStruct.data(binary, offset: offset, length: 4)
        let value = flags.value.int16()
        let kind = SwiftTypeEnum(rawValue: value & 0x1F) ?? SwiftTypeEnum.Unknow
        let isGeneric = ((value & 0x80) != 0)
        let isUnique = ((value & 0x40) != 0)
        let version = UInt8((value >> 8) & 0xFF)
        let kindSpecificFlags = UInt16((value >> 16) & 0xFFFF)
        
        return SwiftFlags(flags: flags, kind: kind, isGeneric: isGeneric, isUnique: isUnique, version: version, kindSpecificFlags: kindSpecificFlags)
    }
}
