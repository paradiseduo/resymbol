//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/2/24.
//

import Foundation

struct SwiftMethodImpl {
    let impl: DataStruct
    let implOffset: DataStruct
    
    static func SMI(_ binary: Data, offset: inout Int) -> SwiftMethodImpl {
        let impl = DataStruct.data(binary, offset: offset, length: 4)
        let implOffset = DataStruct.data(binary, offset: (offset+impl.value.int16Subtraction()).alignment(), length: 4)
        offset += 4
        return SwiftMethodImpl(impl: impl, implOffset: implOffset)
    }
}

struct SwiftMethodFlags {
    let flag: DataStruct
    let kind: SwiftMethodKind
    let type: SwiftMethodType

    static func SMF(_ binary: Data, offset: inout Int) -> SwiftMethodFlags {
        let flag = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let flagV = flag.value.int16()
        let kind = SwiftMethodKind.getKind(value: flagV)
        let type = SwiftMethodType.getType(value: flagV)
        return SwiftMethodFlags(flag: flag, kind: kind, type: type)
    }
}

struct SwiftMethod {
    let flag: SwiftMethodFlags
    let impl: SwiftMethodImpl
    
    static func SM(_ binary: Data, offset: inout Int) -> SwiftMethod {
        let flag = SwiftMethodFlags.SMF(binary, offset: &offset)
        let impl = SwiftMethodImpl.SMI(binary, offset: &offset)
        return SwiftMethod(flag: flag, impl: impl)
    }
}

struct OverrideMethod {
    let overrideOffset: DataStruct
    let overrideMethod: SwiftMethod
    
    static func OM(_ binary: Data, offset: inout Int) -> OverrideMethod {
        let overrideOffset = DataStruct.data(binary, offset: offset, length: 4)
        var newOffset = (offset+overrideOffset.value.int16Subtraction()).alignment()
        offset += 4
        let overrideMethod = SwiftMethod.SM(binary, offset: &newOffset)
        return OverrideMethod(overrideOffset: overrideOffset, overrideMethod: overrideMethod)
    }
}

struct SwiftOverrideMethod {
    let overrideClass: DataStruct
    let overrideMethod: OverrideMethod
    let method: SwiftMethodImpl
    
    static func SOM(_ binary: Data, offset: inout Int) -> SwiftOverrideMethod {
        let overrideClass = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let overrideMethod = OverrideMethod.OM(binary, offset: &offset)
        let method = SwiftMethodImpl.SMI(binary, offset: &offset)
        return SwiftOverrideMethod(overrideClass: overrideClass, overrideMethod: overrideMethod, method: method)
    }
}
