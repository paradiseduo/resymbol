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
    
    var objcClasses = SyncDictionary<Int, String>("ObjcClassesDicSyncQueue")
    var dylbMap = SyncDictionary<String, String>("DyldDicSyncQueue")
    var objcProtocols = SyncDictionary<Int, String>("ObjcProtocolDicSyncQueue")
    var swiftProtocols = SyncDictionary<Int, String>("SwiftProtocolslDicSyncQueue")
    var stringTable = SyncDictionary<String, String>("StringTableDicSyncQueue")
    var symbolTable = SyncDictionary<String, String>("SymbolTableDicSyncQueue")
    var mangledNameMap = SyncDictionary<String, String>("MangledNameMapDicSyncQueue")
    var swiftClasses = SyncArray<SwiftClass>("SwiftClassesArraySyncQueue")
    var nominalOffsetMap = SyncDictionary<Int, String>("NominalOffsetMapDicSyncQueue")
    
    var categorySections = [section_64]()
    var classSections = [section_64]()
    var protocolSection: section_64?
    var swiftProtoSection: section_64?
    var swiftTypeSection: section_64?
    
    private init() {}
}

