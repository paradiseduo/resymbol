//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct PropertyName {
    let name: DataStruct
    let propertyName: DataStruct
    
    static func propertyName(_ binary: Data, offset: Int) -> PropertyName {
        let name = DataStruct.data(binary, offset: offset, length: 8)
        let propertyName = DataStruct.textData(binary, offset: name.value.int16Replace(), length: 128)
        return PropertyName(name: name, propertyName: propertyName)
    }
}

struct PropertyAttributes {
    let attributes: DataStruct
    let propertyAttributes: DataStruct
    
    static func propertyName(_ binary: Data, offset: Int) -> PropertyAttributes {
        let attributes = DataStruct.data(binary, offset: offset, length: 8)
        let propertyAttributes = DataStruct.textData(binary, offset: attributes.value.int16Replace(), length: 128)
        return PropertyAttributes(attributes: attributes, propertyAttributes: propertyAttributes)
    }
}

struct Property {
    let name: PropertyName
    let attributes: PropertyAttributes
    
    static func properties(_ binary: Data, startOffset: Int, count: Int) -> [Property] {
        var result = [Property]()
        var offSet = startOffset
        for _ in 0..<count {
            let name = PropertyName.propertyName(binary, offset: offSet)
            offSet += 8
            let attributes = PropertyAttributes.propertyName(binary, offset: offSet)
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
