//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation


struct SwiftName {
    let name: DataStruct
    let swiftName: DataStruct
    
    static func SN(_ binary: Data, offset: Int, isMangledName: Bool, isClassName: Bool) -> SwiftName {
        let name = DataStruct.data(binary, offset: offset, length: 4)
        let nameOffset = MachOData.shared.resolveRelativePointer(base: offset, raw: name.value)
            ?? (offset + name.value.int16Subtraction())
        let swiftName = DataStruct.textSwiftData(binary, offset: nameOffset, isMangledName: isMangledName, isClassName: isClassName)
        return SwiftName(name: name, swiftName: swiftName)
    }
}
