//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct Property {
    let name: DataStruct
    let attributes: DataStruct
    
    static func properties(_ binary: Data, startOffset: Int, count: Int) -> [Property] {
        var result = [Property]()
        var offSet = startOffset
        for _ in 0..<count {
            let name = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            let attributes = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            result.append(Property(name: name, attributes: attributes))
        }
        return result
    }
}

struct Properties {
    let baseProperties: DataStruct
    let elementSize: DataStruct?
    let elementCount: DataStruct?
    let properties: [Property]?
    
    static func properties(_ binary: Data, startOffset: Int) -> Properties {
        let baseProperties = DataStruct.data(binary, offset: startOffset, length: 8)
        let offSetIV = baseProperties.value.int16Replace()
        if offSetIV > 0 {
            let elementSize = DataStruct.data(binary, offset: offSetIV, length: 4)
            let elementCount = DataStruct.data(binary, offset: offSetIV+4, length: 4)
            let properties = Property.properties(binary, startOffset: offSetIV+8, count: elementCount.value.int16())
            return Properties(baseProperties: baseProperties, elementSize: elementSize, elementCount: elementCount, properties: properties)
        } else {
            return Properties(baseProperties: baseProperties, elementSize: nil, elementCount: nil, properties: nil)
        }
    }
}
