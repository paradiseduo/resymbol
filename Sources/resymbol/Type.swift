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
            print("Please run 'lipo \(machoPath) -thin armv7 -output \(machoPath)_armv7' first")
            handle(.x86_fat, false)
            break
        case FAT_CIGAM_64, FAT_MAGIC_64:
            print("Please run 'lipo \(machoPath) -thin armv64 -output \(machoPath)_arm64' first")
            handle(.x64_fat, false)
            break
        case MH_MAGIC, MH_CIGAM:
            handle(.x86, header.magic == MH_CIGAM)
            break
        case MH_MAGIC_64, MH_CIGAM_64:
            handle(.x64, header.magic == MH_CIGAM_64)
            break
        default:
            print("Unkonw machO header")
            handle(.none, false)
            break
        }
    }
}

enum CDBindType: Int32 {
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

