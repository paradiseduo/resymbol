//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftStruct {
    let type: SwiftType
    let numFields: DataStruct
    let fieldOffsetVectorOffset: DataStruct
    
    static func SS(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftStruct {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let numFields = DataStruct.data(binary, offset: offset+16, length: 4)
        let fieldOffsetVectorOffset = DataStruct.data(binary, offset: offset+20, length: 4)
        
        return SwiftStruct(type: type, numFields: numFields, fieldOffsetVectorOffset: fieldOffsetVectorOffset)
    }
}
