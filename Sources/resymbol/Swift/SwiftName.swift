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
    
    static func SN(_ binary: Data, offset: inout Int) -> SwiftName {
        let name = DataStruct.swiftData(binary, offset: &offset)
        let swiftName = DataStruct.textData(binary, offset: name.address.int16()+name.value.int16Subtraction(), isClassName: false)
        return SwiftName(name: name, swiftName: swiftName)
    }
}
