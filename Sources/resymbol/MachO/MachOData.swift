//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/30.
//

import Foundation

let RVA: UInt64 = 0x100000000

struct MachOSegmentInfo {
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64

    func containsVMAddress(_ address: UInt64) -> Bool {
        address >= vmaddr && address - vmaddr < vmsize
    }

    func fileOffset(forVMAddress address: UInt64) -> Int? {
        guard containsVMAddress(address), address - vmaddr < filesize else { return nil }
        let offset = fileoff + (address - vmaddr)
        return offset <= UInt64(Int.max) ? Int(offset) : nil
    }
}

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
            serialQueue.sync(flags: .barrier) {
                self._binary = newValue
            }
        }
    }

    var swiftTypeRefRange: Range<Int>?
    var swiftReflectionStringRange: Range<Int>?

    /// Clears all state before starting a new independent Mach-O parse.
    func reset() {
        binary = Data()
        swiftTypeRefRange = nil
        swiftReflectionStringRange = nil
        objcClasses.removeAllSync(); dylbMap.removeAllSync(); objcProtocols.removeAllSync()
        swiftProtocols.removeAllSync(); stringTable.removeAllSync(); symbolTable.removeAllSync(); accessorTypes.removeAllSync()
        ProtocolWitnessIndex.shared.reset()
        mangledNameMap.removeAllSync(); nominalOffsetMap.removeAllSync()
        swiftClasses.removeAllSync(); swiftStruct.removeAllSync(); swiftEnum.removeAllSync()
        swiftAssocty.removeAllSync(); swiftBuiltin.removeAllSync(); swiftCapture.removeAllSync()
        segments.removeAll()
        machOFile = nil
    }

    var segments = [MachOSegmentInfo]()
    var machOFile: MachOFile?

    func fileOffset(forVMAddress address: UInt64) -> Int? {
        segments.first { $0.containsVMAddress(address) }?.fileOffset(forVMAddress: address)
    }

    /// Resolve a pointer stored in a Mach-O data section. Chained-fixup
    /// materialization may already have converted it to a file-relative value,
    /// so retain that as a fallback for existing parsers.
    func resolvePointer(_ raw: UInt64) -> Int? {
        if let offset = fileOffset(forVMAddress: raw) { return offset }
        let masked = raw & 0x0000_FFFF_FFFF_FFFF
        if let offset = fileOffset(forVMAddress: masked) { return offset }
        guard masked <= UInt64(Int.max) else { return nil }
        let offset = Int(masked)
        return offset >= 0 && offset < binary.count ? offset : nil
    }

    func resolvePointer(_ value: String) -> Int? {
        resolvePointer(UInt64(value, radix: 16) ?? 0)
    }

    func resolveRelativePointer(base: Int, raw: String) -> Int? {
        guard let bits = UInt32(raw, radix: 16) else { return nil }
        let delta = Int(Int32(bitPattern: bits))
        let target = base + delta
        return target >= 0 && target < binary.count ? target : nil
    }
    
    var objcClasses = SyncDictionary<Int, String>("ObjcClassesDicSyncQueue")
    var dylbMap = SyncDictionary<String, String>("DyldDicSyncQueue")
    var objcProtocols = SyncDictionary<Int, String>("ObjcProtocolDicSyncQueue")
    var swiftProtocols = SyncDictionary<Int, String>("SwiftProtocolslDicSyncQueue")
    var stringTable = SyncDictionary<String, String>("StringTableDicSyncQueue")
    var symbolTable = SyncDictionary<String, Nlist>("SymbolTableDicSyncQueue")
    var accessorTypes = SyncDictionary<String, String>("SwiftAccessorTypesSyncQueue")
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
