//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct ClassName {
    let name: DataStruct
    let className: DataStruct
    
    static func className(_ binary: Data, startOffset: Int, isSwiftClass: Bool = false) -> ClassName {
        let name = DataStruct.data(binary, offset: startOffset, length: 8)
        let className = DataStruct.textData(binary, offset: name.value.int16Replace(), demangle: isSwiftClass)
        return ClassName(name: name, className: className)
    }
}
