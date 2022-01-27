//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftEnum {
    let type: SwiftType
    let numPayloadCasesAndPayloadSizeOffset: DataStruct
    let numEmptyCases: DataStruct
    
    static func SE(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftEnum {
        let type = SwiftType.ST(binary, offset: offset, flags: flags)
        let numPayloadCasesAndPayloadSizeOffset = DataStruct.data(binary, offset: offset+16, length: 4)
        let numEmptyCases = DataStruct.data(binary, offset: offset+20, length: 4)
        
        return SwiftEnum(type: type, numPayloadCasesAndPayloadSizeOffset: numPayloadCasesAndPayloadSizeOffset, numEmptyCases: numEmptyCases)
    }
}
