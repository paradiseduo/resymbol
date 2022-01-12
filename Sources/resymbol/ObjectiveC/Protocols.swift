//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct Protocol {
    let pointer: DataStruct
    
    static func protocols(_ binary: Data, startOffset: Int, count: Int) -> [Protocol] {
        var result = [Protocol]()
        var offSet = startOffset
        for _ in 0..<count {
            let pointer = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            result.append(Protocol(pointer: pointer))
        }
        return result
    }
}

struct Protocols {
    let baseProtocol: DataStruct
    let count: DataStruct?
    let protocols: [Protocol]?
    
    static func protocols(_ binary: Data, startOffset: Int) -> Protocols {
        let baseProtocol = DataStruct.data(binary, offset: startOffset, length: 8)
        let offSetIV = baseProtocol.value.int16Replace()
        if offSetIV > 0 {
            let count = DataStruct.data(binary, offset: offSetIV, length: 8)
            let protocols = Protocol.protocols(binary, startOffset: offSetIV+8, count: count.value.int16())
            return Protocols(baseProtocol: baseProtocol, count: count, protocols: protocols)
        } else {
            return Protocols(baseProtocol: baseProtocol, count: nil, protocols: nil)
        }
    }
    
    func serialization() -> String {
        var protocolString = ""
        if let pros = protocols {
            protocolString += "<"
            for item in pros {
                if let p = MachOData.shared.objcProtocols.get(item.pointer.value.int16Replace()) as? String {
                    protocolString += p + ", "
                }
            }
            protocolString = protocolString.rtrim(", ") + ">"
        }
        return protocolString
    }
}
