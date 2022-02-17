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
    
    var objcClasses = SyncDictionary<Int, String>()
    var dylbMap = SyncDictionary<String, String>()
    var objcProtocols = SyncDictionary<Int, String>()
    var swiftProtocols = SyncDictionary<Int, String>()
    var stringTable = SyncDictionary<String, String>()
    var symbolTable = SyncDictionary<String, String>()
    var mangledNameMap = SyncDictionary<String, String>()
    var nominalOffsetMap = SyncDictionary<Int, String>()
    
    var swiftClasses = SyncArray<SwiftClass>()
    var swiftStruct = SyncArray<SwiftStruct>()
    var swiftEnum = SyncArray<SwiftEnum>()
    var swiftAssocty = SyncArray<SwiftAssocty>()
    var swiftBuiltin = SyncArray<SwiftBuiltin>()
    var swiftCapture = SyncArray<SwiftCapture>()
    
    var symtab: symtab_command?
    var dylib: dyld_info_command?
    var vmAddress = [UInt64]()
    var categorySections = [section_64]()
    var classSections = [section_64]()
    var swiftProtoSection: section_64?
    var swiftTypeSection: section_64?
    var objc_protolist: section_64?
    var swift5_protos: section_64?
    var swift5_ref: section_64?
    var assocty: section_64?
    var builtin: section_64?
    var capture: section_64?
    
    private init() {}
}

