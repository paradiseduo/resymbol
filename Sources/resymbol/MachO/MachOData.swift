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
    private let serialQueue = DispatchQueue(label: "MachOData.Binary.Queue", attributes: .concurrent)
    private var _binary = Data()

    var binary: Data {
        get {
            return serialQueue.sync {
                return _binary
            }
        }
        set {
            serialQueue.async(flags: .barrier) {
                self._binary = newValue
            }
        }
    }
    
    var objcClasses = SyncDictionary<Int, String>("ObjcClassesDicSyncQueue")
    var dylbMap = SyncDictionary<String, String>("DyldDicSyncQueue")
    var objcProtocols = SyncDictionary<Int, String>("ObjcProtocolDicSyncQueue")
    var swiftProtocols = SyncDictionary<Int, String>("SwiftProtocolslDicSyncQueue")
    var stringTable = SyncDictionary<String, String>("StringTableDicSyncQueue")
    var symbolTable = SyncDictionary<String, Nlist>("SymbolTableDicSyncQueue")
    var mangledNameMap = SyncDictionary<String, String>("MangledNameMapDicSyncQueue")
    var nominalOffsetMap = SyncDictionary<Int, String>("NominalOffsetMapDicSyncQueue")
    
    var swiftClasses = SyncArray<SwiftClass>("SwiftClassesArraySyncQueue")
    var swiftStruct = SyncArray<SwiftStruct>("SwiftStructArraySyncQueue")
    var swiftEnum = SyncArray<SwiftEnum>("SwiftEnumArraySyncQueue")
    var swiftAssocty = SyncArray<SwiftAssocty>("SwiftAssoctyArraySyncQueue")
    var swiftBuiltin = SyncArray<SwiftBuiltin>("SwiftBuiltinArraySyncQueue")
    var swiftCapture = SyncArray<SwiftCapture>("SwiftCaptureArraySyncQueue")
    
    private init() {}
}

