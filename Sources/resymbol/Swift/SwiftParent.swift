//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftParent {
    let parent: DataStruct
    let swiftParent: DataStruct
    
    static func SP(_ binary: Data, offset: Int) -> SwiftParent {
        let parent = DataStruct.data(binary, offset: offset, length: 4)
        let parentOffset = MachOData.shared.resolveRelativePointer(base: offset, raw: parent.value)
            ?? (offset + parent.value.int16Subtraction())
        let swiftParent = DataStruct.textSwiftData(binary, offset: parentOffset, isMangledName: false, isClassName: true)
        return SwiftParent(parent: parent, swiftParent: swiftParent)
    }
}
