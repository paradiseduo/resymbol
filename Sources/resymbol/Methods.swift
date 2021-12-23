//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct MethodName {
    let name: DataStruct
    let methodName: DataStruct
    
    static func methodName(_ binary: Data, offset: Int) -> MethodName {
        let name = DataStruct.data(binary, offset: offset, length: 8)
        let methodName = DataStruct.textData(binary, offset: name.value.int16Replace(), length: 128)
        return MethodName(name: name, methodName: methodName)
    }
}

struct MethodTypes {
    let types: DataStruct
    let methodTypes: DataStruct
    
    static func methodTypes(_ binary: Data, offset: Int) -> MethodTypes {
        let types = DataStruct.data(binary, offset: offset, length: 8)
        let methodTypes = DataStruct.textData(binary, offset: types.value.int16Replace(), length: 128)
        return MethodTypes(types: types, methodTypes: methodTypes)
    }
}

struct Method {
    let name: MethodName
    let types: MethodTypes
    let implementation: DataStruct
    
    static func methods(_ binary: Data, startOffset: Int, count: Int) -> [Method] {
        var result = [Method]()
        var offSet = startOffset
        for _ in 0..<count {
            let name = MethodName.methodName(binary, offset: offSet)
            offSet += 8
            let types = MethodTypes.methodTypes(binary, offset: offSet)
            offSet += 8
            let implementation = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            result.append(Method(name: name, types: types, implementation: implementation))
        }
        return result
    }
}

struct Methods {
    let baseMethod: DataStruct
    let elementSize: DataStruct?
    let elementCount: DataStruct?
    let methods: [Method]?
    
    static func methods(_ binary: Data, startOffset: Int) -> Methods {
        let baseMethod = DataStruct.data(binary, offset: startOffset, length: 8)
        let offSetMD = baseMethod.value.int16Replace()
        if offSetMD > 0 {
            let elementSize = DataStruct.data(binary, offset: offSetMD, length: 4)
            let elementCount = DataStruct.data(binary, offset: offSetMD+4, length: 4)
            let methods = Method.methods(binary, startOffset: offSetMD+8, count: elementCount.value.int16())
            return Methods(baseMethod: baseMethod, elementSize: elementSize, elementCount: elementCount, methods: methods)
        } else {
            return Methods(baseMethod: baseMethod, elementSize: nil, elementCount: nil, methods: nil)
        }
    }
}
