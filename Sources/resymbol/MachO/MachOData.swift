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
    var binary = Data()
    
    var objcClasses = SyncDictionary("ObjcClassesDicSyncQueue")
    var dylbMap = SyncDictionary("DyldDicSyncQueue")
    var objcProtocols = SyncDictionary("ObjcProtocolDicSyncQueue")
    var swiftProtocols = SyncDictionary("SwiftProtocolslDicSyncQueue")
    var stringTable = SyncDictionary("StringTableDicSyncQueue")
    var symbolTable = SyncDictionary("SymbolTableDicSyncQueue")
    var mangledNameMap = SyncDictionary("MangledNameMapDicSyncQueue")
    var swiftClasses = SyncArray<SwiftClass>("SwiftClassesArraySyncQueue")
    var nominalOffsetMap = SyncDictionary("NominalOffsetMapDicSyncQueue")
    
    private init() {}
}

