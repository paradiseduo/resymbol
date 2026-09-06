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
        let offSetIV = MachOData.shared.resolvePointerWithLegacyFallback(baseProtocol.value) ?? -1
        if offSetIV > 0 {
            let count = DataStruct.data(binary, offset: offSetIV, length: 8)
            let recordCount = boundedObjCRecordCount(count.value,
                                                     startOffset: offSetIV + 8,
                                                     stride: 8,
                                                     dataCount: binary.count)
            let protocols = Protocol.protocols(binary, startOffset: offSetIV+8, count: recordCount)
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
                let pointerOffset = MachOData.shared.resolvePointerWithLegacyFallback(item.pointer.value) ?? -1
                if let p = MachOData.shared.objcProtocols[pointerOffset] {
                    protocolString += p + ", "
                }
            }
            protocolString = protocolString.rtrim(", ") + ">"
        }
        return protocolString
    }
}
