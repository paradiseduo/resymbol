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
    
    static func SMI(_ binary: Data, offset: Int) -> SwiftMethodImpl {
        let impl = DataStruct.data(binary, offset: offset, length: 4)
        let implOffset = DataStruct.data(binary, offset: offset+impl.value.int16Subtraction(), length: 4)
        
        return SwiftMethodImpl(impl: impl, implOffset: implOffset)
    }
}

struct SwiftMethod {
    let flags: DataStruct
    let impl: SwiftMethodImpl
    
    static func SM(_ binary: Data, offset: inout Int) -> SwiftMethod {
        let flags = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let impl = SwiftMethodImpl.SMI(binary, offset: offset)
        return SwiftMethod(flags: flags, impl: impl)
    }
}
