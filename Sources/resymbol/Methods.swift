//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct Method {
    let name: DataStruct
    let types: DataStruct
    let implementation: DataStruct
    
    static func methods(_ binary: Data, startOffset: Int, count: Int) -> [Method] {
        var result = [Method]()
        var offSet = startOffset
        for _ in 0..<count {
            let mtName = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            let mtTypes = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            let mtImplementation = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            result.append(Method(name: mtName, types: mtTypes, implementation: mtImplementation))
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
