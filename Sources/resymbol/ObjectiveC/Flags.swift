//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct Flags {
    let flags: DataStruct
    let ro: [RO]
    
    static func flags(_ binary: Data, startOffset: Int) -> Flags {
        let flags = DataStruct.data(binary, offset: startOffset, length: 4)
        let ro = RO.ro(flags.value.int16())
        return Flags(flags: flags, ro: ro)
    }
}
