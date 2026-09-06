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
    
    static func className(_ binary: Data, startOffset: Int, isSwiftClass: Bool) -> ClassName {
        let name = DataStruct.data(binary, offset: startOffset, length: 8)
        let classNameOffset = MachOData.shared.resolvePointerWithLegacyFallback(name.value) ?? -1
        let className = DataStruct.textData(binary, offset: classNameOffset, demangle: isSwiftClass)
        return ClassName(name: name, className: className)
    }
}
