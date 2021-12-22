//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct InstanceVariable {
    let offset: DataStruct
    let name: DataStruct
    let types: DataStruct
    let alignment: DataStruct
    let alignSizement: DataStruct
    
    static func instances(_ binary: Data, startOffset: Int, count: Int) -> [InstanceVariable] {
        var result = [InstanceVariable]()
        var offSet = startOffset
        for _ in 0..<count {
            let ioffset = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            let iName = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            let iType = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            let iAli = DataStruct.data(binary, offset: offSet, length: 4)
            offSet += 4
            let iAliSize = DataStruct.data(binary, offset: offSet, length: 4)
            offSet += 4
            result.append(InstanceVariable(offset: ioffset, name: iName, types: iType, alignment: iAli, alignSizement: iAliSize))
        }
        return result
    }
}

struct InstanceVariables {
    let ivars: DataStruct
    let elementSize: DataStruct?
    let elementCount: DataStruct?
    let instanceVariables: [InstanceVariable]?
    
    static func instances(_ binary: Data, startOffset: Int) -> InstanceVariables {
        let ivars = DataStruct.data(binary, offset: startOffset, length: 8)
        let offSetIV = ivars.value.int16Replace()
        if offSetIV > 0 {
            let elementSize = DataStruct.data(binary, offset: offSetIV, length: 4)
            let elementCount = DataStruct.data(binary, offset: offSetIV+4, length: 4)
            let instanceVariables = InstanceVariable.instances(binary, startOffset: offSetIV+8, count: elementCount.value.int16())
            return InstanceVariables(ivars: ivars, elementSize: elementSize, elementCount: elementCount, instanceVariables: instanceVariables)
        } else {
            return InstanceVariables(ivars: ivars, elementSize: nil, elementCount: nil, instanceVariables: nil)
        }
    }
}
