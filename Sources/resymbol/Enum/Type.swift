//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/9/10.
//

import Foundation
import ArgumentParser

enum BitType {
    case x86
    case x64
    case x86_fat
    case x64_fat
    case none
    
    static func checkType(machoPath: String, header: fat_header, handle: (BitType, Bool)->()) {
        switch header.magic {
        case FAT_CIGAM, FAT_MAGIC:
            ConsoleIO.writeMessage("Please run 'lipo \(machoPath) -thin armv7 -output \(machoPath)_armv7' first", .error)
            handle(.x86_fat, false)
            break
        case FAT_CIGAM_64, FAT_MAGIC_64:
            ConsoleIO.writeMessage("Please run 'lipo \(machoPath) -thin armv64 -output \(machoPath)_arm64' first", .error)
            handle(.x64_fat, false)
            break
        case MH_MAGIC, MH_CIGAM:
            handle(.x86, header.magic == MH_CIGAM)
            break
        case MH_MAGIC_64, MH_CIGAM_64:
            handle(.x64, header.magic == MH_CIGAM_64)
            break
        default:
            ConsoleIO.writeMessage("Unkonw machO header", .error)
            handle(.none, false)
            break
        }
    }
}

enum BindType: Int32 {
    case REBASE_TYPE_POINTER = 1
    case REBASE_TYPE_TEXT_ABSOLUTE32 = 2
    case REBASE_TYPE_TEXT_PCREL32 = 3
    
    static func description(_ raw: Int32) -> String {
        switch raw {
        case REBASE_TYPE_POINTER.rawValue:
            return "Pointer"
        case REBASE_TYPE_TEXT_ABSOLUTE32.rawValue:
            return "Absolute 32"
        case REBASE_TYPE_TEXT_PCREL32.rawValue:
            return "PC rel 32"
        default:
            return "Unknown"
        }
    }
}

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

enum SwiftTypeContextDescriptorFlag: UInt16 {
    // All of these values are bit offsets or widths.
    // Generic flags build upwards from 0.
    // Type-specific flags build downwards from 15.

    /// Whether there's something unusual about how the metadata is
    /// initialized.
    ///
    /// Meaningful for all type-descriptor kinds.
    case MetadataInitialization = 0
//    case MetadataInitialization_width = 2
    
    /// Set if the type has extended import information.
    ///
    /// If true, a sequence of strings follow the null terminator in the
    /// descriptor, terminated by an empty string (i.e. by two null
    /// terminators in a row).  See TypeImportInfo for the details of
    /// these strings and the order in which they appear.
    ///
    /// Meaningful for all type-descriptor kinds.
    case HasImportInfo = 2
    
    /// Set if the type descriptor has a pointer to a list of canonical
    /// prespecializations.
    case HasCanonicalMetadataPrespecializations = 3
    
    // Type-specific flags:

    /// Set if the class is an actor.
    ///
    /// Only meaningful for class descriptors.
    case Class_IsActor = 7
    
    /// Set if the class is a default actor class.  Note that this is
    /// based on the best knowledge available to the class; actor
    /// classes with resilient superclassess might be default actors
    /// without knowing it.
    ///
    /// Only meaningful for class descriptors.
    case Class_IsDefaultActor = 8
    
    /// The kind of reference that this class makes to its resilient superclass
    /// descriptor.  A TypeReferenceKind.
    ///
    /// Only meaningful for class descriptors.
    case Class_ResilientSuperclassReferenceKind = 9
//    case Class_ResilientSuperclassReferenceKind_width = 3
    
    /// Whether the immediate class members in this metadata are allocated
    /// at negative offsets.  For now, we don't use this.
    case Class_AreImmediateMembersNegative = 12

    /// Set if the context descriptor is for a class with resilient ancestry.
    ///
    /// Only meaningful for class descriptors.
    case Class_HasResilientSuperclass = 13

    /// Set if the context descriptor includes metadata for dynamically
    /// installing method overrides at metadata instantiation time.
    case Class_HasOverrideTable = 14

    /// Set if the context descriptor includes metadata for dynamically
    /// constructing a class's vtables at metadata instantiation time.
    ///
    /// Only meaningful for class descriptors.
    case Class_HasVTable = 15
    
    static func STCDF(value: UInt16) -> [SwiftTypeContextDescriptorFlag] {
        var flags = [SwiftTypeContextDescriptorFlag]()
        let er = String(value, radix: 2)
        for (i, item) in er.reversed().enumerated() {
            if item == "1" {
                switch i {
                case 0:
                    flags.append(SwiftTypeContextDescriptorFlag.MetadataInitialization)
                case 2:
                    flags.append(SwiftTypeContextDescriptorFlag.HasImportInfo)
                case 3:
                    flags.append(SwiftTypeContextDescriptorFlag.HasCanonicalMetadataPrespecializations)
                case 7:
                    flags.append(SwiftTypeContextDescriptorFlag.Class_IsActor)
                case 8:
                    flags.append(SwiftTypeContextDescriptorFlag.Class_IsDefaultActor)
                case 9:
                    flags.append(SwiftTypeContextDescriptorFlag.Class_ResilientSuperclassReferenceKind)
                case 12:
                    flags.append(SwiftTypeContextDescriptorFlag.Class_AreImmediateMembersNegative)
                case 13:
                    flags.append(SwiftTypeContextDescriptorFlag.Class_HasResilientSuperclass)
                case 14:
                    flags.append(SwiftTypeContextDescriptorFlag.Class_HasOverrideTable)
                case 15:
                    flags.append(SwiftTypeContextDescriptorFlag.Class_HasVTable)
                default:
                    continue
                }
            }
        }
        return flags
    }
}


enum SwiftMethodKind: Int {
    case Method = 0
    case Init = 1
    case Getter = 2
    case Setter = 3
    case Modify = 4
    case Read = 5
    
    static func getKind(value: Int) -> SwiftMethodKind {
        switch (value & SwiftMethodType.Kind.rawValue) {
        case SwiftMethodKind.Method.rawValue:
            return SwiftMethodKind.Method
        case SwiftMethodKind.Init.rawValue:
            return SwiftMethodKind.Init
        case SwiftMethodKind.Getter.rawValue:
            return SwiftMethodKind.Getter
        case SwiftMethodKind.Setter.rawValue:
            return SwiftMethodKind.Setter
        case SwiftMethodKind.Modify.rawValue:
            return SwiftMethodKind.Modify
        case SwiftMethodKind.Read.rawValue:
            return SwiftMethodKind.Read
        default:
            return SwiftMethodKind.Method
        }
    }
}

enum SwiftMethodType: Int {
    case Kind = 0x0F
    case Instance = 0x10
    case Dynamic = 0x20
    case ExtraDiscriminator = 0xFFFF0000
    
    static func getType(value: Int) -> SwiftMethodType {
        if value & SwiftMethodType.Instance.rawValue == SwiftMethodType.Instance.rawValue {
            return SwiftMethodType.Instance
        }
        if value & SwiftMethodType.Dynamic.rawValue == SwiftMethodType.Dynamic.rawValue {
            return SwiftMethodType.Dynamic
        }
        if value & SwiftMethodType.ExtraDiscriminator.rawValue == SwiftMethodType.ExtraDiscriminator.rawValue {
            return SwiftMethodType.ExtraDiscriminator
        }
        return SwiftMethodType.Kind
    }
}
