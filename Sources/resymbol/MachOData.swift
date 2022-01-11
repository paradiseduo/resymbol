//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/30.
//

import Foundation

let RVA: UInt64 = 0x100000000

class MachOData {
    static let shared = MachOData()
    var objcClasses = ObjcClassesDic()
    var dylbMap = DyldDic()
    var objcProtocols = ObjcProtocolDic()
    
    private init() {}
}

