//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct InstanceVariableName {
    let name: DataStruct
    let instanceVariableName: DataStruct
    
    static func instanceVariableName(_ binary: Data, offset: Int) -> InstanceVariableName {
        let name = DataStruct.data(binary, offset: offset, length: 8)
        let instanceVariableName = DataStruct.textData(binary, offset: name.value.int16Replace())
        return InstanceVariableName(name: name, instanceVariableName: instanceVariableName)
    }
}

struct InstanceVariableTypes {
    let types: DataStruct
    let instanceVariableTypes: DataStruct
    
    static func instanceVariableTypes(_ binary: Data, offset: Int) -> InstanceVariableTypes {
        let types = DataStruct.data(binary, offset: offset, length: 8)
        let instanceVariableTypes = DataStruct.textData(binary, offset: types.value.int16Replace())
        return InstanceVariableTypes(types: types, instanceVariableTypes: instanceVariableTypes)
    }
}

struct InstanceVariable {
    let offset: DataStruct
    let name: InstanceVariableName
    let types: InstanceVariableTypes
    let alignment: DataStruct
    let alignSizement: DataStruct
    
    static func instances(_ binary: Data, startOffset: Int, count: Int) -> [InstanceVariable] {
        var result = [InstanceVariable]()
        var offSet = startOffset
        for _ in 0..<count {
            let ioffset = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            let iName = InstanceVariableName.instanceVariableName(binary, offset: offSet)
            offSet += 8
            let iType = InstanceVariableTypes.instanceVariableTypes(binary, offset: offSet)
            offSet += 8
            let iAli = DataStruct.data(binary, offset: offSet, length: 4)
            offSet += 4
            let iAliSize = DataStruct.data(binary, offset: offSet, length: 4)
            offSet += 4
            result.append(InstanceVariable(offset: ioffset, name: iName, types: iType, alignment: iAli, alignSizement: iAliSize))
        }
        return result
    }
    
    func serialization() -> String {
        return "\t\(primitiveType(types.instanceVariableTypes.value)) \(name.instanceVariableName.value);"
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
