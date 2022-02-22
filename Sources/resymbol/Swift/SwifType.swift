//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/26.
//

import Foundation

struct SwiftType {
    let flags: SwiftFlags
    let parent: SwiftParent
    let name: SwiftName
    let accessFunction: DataStruct
    let fieldDescriptor: FieldDescriptor
    
    static func ST(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftType {
        let parent = SwiftParent.SP(binary, offset: offset)
        let name = SwiftName.SN(binary, offset: offset+4, isMangledName: false, isClassName: true)
        let accessFunction = DataStruct.data(binary, offset: offset+8, length: 4)
        let fieldDescriptor = FieldDescriptor.FD(binary, offset: offset+12)
        
        return SwiftType(flags: flags, parent: parent, name: name, accessFunction: accessFunction, fieldDescriptor: fieldDescriptor)
    }
}
