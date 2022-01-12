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
    
    static func SP(_ binary: Data, offset: inout Int) -> SwiftParent {
        let parent = DataStruct.swiftData(binary, offset: &offset)
        let offSet = parent.address.int16()+parent.value.int16Subtraction()
        let swiftParent = DataStruct.textData(binary, offset: offSet, isClassName: false)
        print("youshaoduo", offSet)
        return SwiftParent(parent: parent, swiftParent: swiftParent)
    }
}
