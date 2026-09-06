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

struct MachOBoundSymbol {
    let name: String
    let libraryOrdinal: Int
    let libraryName: String?
}

class MachOData {
    static let shared = MachOData()
    private let serialQueue = DispatchQueue(label: "MachOData.Binary.Queue", attributes: .concurrent)
    private var _binary = Data()
    private var _originalBinary = Data()
    private var _dynamicSymbolTable: MachODynamicSymbolTableModel?
    private var _swiftMethodIndex = [String: [String]]()

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

    var originalBinary: Data {
        get { serialQueue.sync { _originalBinary } }
        set { serialQueue.sync(flags: .barrier) { _originalBinary = newValue } }
    }

    var dynamicSymbolTable: MachODynamicSymbolTableModel? {
        get { serialQueue.sync { _dynamicSymbolTable } }
        set { serialQueue.sync(flags: .barrier) { _dynamicSymbolTable = newValue } }
    }

    var swiftTypeRefRange: Range<Int>?
    var swiftReflectionStringRange: Range<Int>?

    /// Clears all state before starting a new independent Mach-O parse.
    func reset() {
        binary = Data()
        originalBinary = Data()
        swiftTypeRefRange = nil
        swiftReflectionStringRange = nil
        dynamicSymbolTable = nil
        serialQueue.sync(flags: .barrier) { _swiftMethodIndex.removeAll(keepingCapacity: false) }
        objcClasses.removeAllSync(); swiftSuperclasses.removeAllSync(); dylbMap.removeAllSync(); boundSymbols.removeAllSync(); undefinedSymbols.removeAllSync(); objcProtocols.removeAllSync()
        swiftProtocols.removeAllSync(); stringTable.removeAllSync(); symbolTable.removeAllSync(); accessorTypes.removeAllSync()
        ProtocolWitnessIndex.shared.reset()
        mangledNameMap.removeAllSync(); nominalOffsetMap.removeAllSync()
        swiftClasses.removeAllSync(); swiftStruct.removeAllSync(); swiftEnum.removeAllSync()
        swiftAssocty.removeAllSync(); swiftBuiltin.removeAllSync(); swiftCapture.removeAllSync()
        swiftProtocolConformances.removeAllSync()
        segments.removeAll()
        machOFile = nil
    }

    var segments = [MachOSegmentInfo]()
    var machOFile: MachOFile?

    func fileOffset(forVMAddress address: UInt64) -> Int? {
        segments.first { $0.containsVMAddress(address) }?.fileOffset(forVMAddress: address)
    }

    func addressResolver() -> MachOAddressResolver? {
        guard let machOFile else { return nil }
        return MachOAddressResolver(file: machOFile, data: binary)
    }

    func symbols(at address: UInt64) -> [MachOSymbolRecord] {
        dynamicSymbolTable?.symbols(at: address) ?? []
    }

    func symbols(named name: String) -> [MachOSymbolRecord] {
        dynamicSymbolTable?.symbols(named: name) ?? []
    }

    /// Build a compact owner -> source member index from defined Swift symbols.
    /// Only member declarations are retained; raw symbol names and metadata
    /// entries are discarded to keep memory bounded on large binaries.
    func buildSwiftMethodIndex() {
        guard let symbols = dynamicSymbolTable?.symbols else { return }
        var index = [String: Set<String>]()
        var shortOwners = [String: Set<String>]()
        for symbol in symbols where symbol.scope != .undefined {
            let raw = symbol.name
            guard raw.hasPrefix("_$s") || raw.hasPrefix("$s") else { continue }
            guard let demangled = swift_demangle(raw),
                  let member = Self.swiftMemberDeclaration(from: demangled) else { continue }
            index[member.owner, default: []].insert(member.declaration)
            if let short = member.owner.split(separator: ".").last.map(String.init) {
                shortOwners[short, default: []].insert(member.owner)
            }
        }
        for (short, owners) in shortOwners where owners.count == 1 {
            if let owner = owners.first, let declarations = index[owner] {
                index[short, default: []].formUnion(declarations)
            }
        }
        serialQueue.sync(flags: .barrier) {
            _swiftMethodIndex = index.mapValues { $0.sorted() }
        }
    }

    func swiftMethodNames(owner: String) -> [String] {
        serialQueue.sync {
            if let exact = _swiftMethodIndex[owner] { return exact }
            let matches = _swiftMethodIndex.filter { key, _ in key.hasSuffix(".\(owner)") }
            guard matches.count == 1 else { return [] }
            return matches.first?.value ?? []
        }
    }

    static func swiftMemberDeclaration(from demangled: String) -> (owner: String, declaration: String)? {
        let lower = demangled.lowercased()
        let excluded = ["getter ", "setter ", "modify ", "read ", "materializeforset",
                        "metadata", "witness", "outlined", "default argument", "property wrapper"]
        guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
        guard let open = demangled.firstIndex(of: "(") else { return nil }
        let prefix = String(demangled[..<open])
        guard let dot = prefix.lastIndex(of: ".") else { return nil }
        var owner = String(prefix[..<dot])
        var rawMember = String(prefix[prefix.index(after: dot)...])
        guard !owner.isEmpty, !rawMember.isEmpty else { return nil }
        if owner.hasPrefix("static ") { owner = String(owner.dropFirst(7)) }
        if owner.hasPrefix("class ") { owner = String(owner.dropFirst(6)) }
        guard !owner.contains(" "), owner.split(separator: ".").allSatisfy({ part in
            guard let first = part.first else { return false }
            return first.isLetter || first == "_"
        }) else { return nil }
        if rawMember == "__allocating_init" || rawMember == "__deallocating_deinit" {
            rawMember = rawMember.contains("init") ? "init" : "deinit"
        }
        if let generic = owner.firstIndex(of: "<") { owner = String(owner[..<generic]) }
        guard let argumentEnd = matchingParenthesis(in: demangled, opening: open) else { return nil }
        let arguments = String(demangled[open...argumentEnd])
        let tailStart = demangled.index(after: argumentEnd)
        let suffix = String(demangled[tailStart...]).trimmingCharacters(in: .whitespaces)
        let arrow = suffix.range(of: "->")
        let effects = arrow.map { String(suffix[..<$0.lowerBound]).trimmingCharacters(in: .whitespaces) } ?? suffix
        let returnType = arrow.map { String(suffix[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
        let isSubscript = rawMember == "subscript"
        let isOperator = rawMember.contains(" ") || rawMember == "+" || rawMember == "-" || rawMember == "*" || rawMember == "/"
        var declaration = isSubscript ? "subscript\(arguments)" : "func \(rawMember)\(arguments)"
        if rawMember == "init" { declaration = "init\(arguments)" }
        if isOperator, rawMember.contains(" infix") {
            declaration = "func \(rawMember.replacingOccurrences(of: " infix", with: ""))\(arguments)"
        }
        if prefix.contains("static ") || prefix.contains("class ") { declaration = "static \(declaration)" }
        if effects.split(separator: " ").contains("async") { declaration += " async" }
        if effects.split(separator: " ").contains("throws") { declaration += " throws" }
        if effects.split(separator: " ").contains("rethrows") { declaration += " rethrows" }
        if rawMember != "init", !returnType.isEmpty, returnType != "()" {
            declaration += " -> \(returnType)"
        }
        return (owner, "\(declaration) {}")
    }

    private static func matchingParenthesis(in value: String, opening: String.Index) -> String.Index? {
        var depth = 0
        var index = opening
        while index < value.endIndex {
            switch value[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = value.index(after: index)
        }
        return nil
    }

    /// Resolve a Swift vtable implementation through every address domain
    /// available to the parsed Mach-O. Stripped binaries legitimately return
    /// nil here; a vtable slot by itself does not contain its source method
    /// name.
    func swiftMethodName(fileOffset: Int) -> String? {
        guard fileOffset >= 0, let resolver = addressResolver(),
              let vmAddress = resolver.vmAddress(forFileOffset: fileOffset) else { return nil }
        let candidates = [vmAddress,
                          resolver.imageOffset(forVMAddress: vmAddress) ?? 0,
                          UInt64(fileOffset)]
        for address in candidates where address != 0 {
            for symbol in symbols(at: address) {
                if let demangled = swift_demangle(symbol.name), !demangled.isEmpty {
                    return demangled
                }
            }
            let keys = [String(format: "%016llx", address),
                        String(format: "%08llx", address),
                        String(format: "00000001%08llx", address)]
            for key in keys {
                if let symbol = symbolTable[key],
                   let demangled = symbol.name(demangle: true), !demangled.isEmpty {
                    return demangled
                }
            }
        }
        return nil
    }

    /// Return a source-shaped declaration for a vtable implementation when a
    /// defined Swift symbol proves both the address and its owner. The owner
    /// check matters for thunks and folded functions that can share an
    /// implementation address with another nominal type.
    func swiftMethodDeclaration(fileOffset: Int, owner: String) -> String? {
        guard fileOffset >= 0, let resolver = addressResolver(),
              let vmAddress = resolver.vmAddress(forFileOffset: fileOffset) else { return nil }
        let addresses = [vmAddress,
                         resolver.imageOffset(forVMAddress: vmAddress) ?? 0,
                         UInt64(fileOffset)].filter { $0 != 0 }
        var rawNames = [String]()
        for address in addresses {
            rawNames.append(contentsOf: symbols(at: address).map(\.name))
            let keys = [String(format: "%016llx", address),
                        String(format: "%08llx", address),
                        String(format: "00000001%08llx", address)]
            rawNames.append(contentsOf: keys.compactMap { symbolTable[$0]?.name() })
        }
        let normalizedOwner = owner.split(separator: "<", maxSplits: 1).first.map(String.init) ?? owner
        for raw in rawNames where raw.hasPrefix("_$s") || raw.hasPrefix("$s") {
            guard let demangled = swift_demangle(raw),
                  let member = Self.swiftMemberDeclaration(from: demangled) else { continue }
            let memberOwner = member.owner.split(separator: "<", maxSplits: 1).first.map(String.init) ?? member.owner
            let ownerMatches = memberOwner == normalizedOwner ||
                (!normalizedOwner.contains(".") && memberOwner.hasSuffix(".\(normalizedOwner)")) ||
                (!memberOwner.contains(".") && normalizedOwner.hasSuffix(".\(memberOwner)"))
            guard ownerMatches else { continue }
            return member.declaration
        }
        return nil
    }

    var functionStarts: MachOFunctionStarts? { machOFile?.functionStarts }
    var dataInCode: MachODataInCode? { machOFile?.dataInCode }
    var twoLevelHints: MachOTwoLevelHints? { machOFile?.twoLevelHints }

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

    /// Resolve an absolute ObjC pointer, retaining compatibility with legacy
    /// file-offset encoded metadata when no VM mapping exists.
    func resolvePointerWithLegacyFallback(_ value: String) -> Int? {
        resolvePointer(value) ?? Int(value, radix: 16).flatMap { $0 >= 0 ? $0 : nil }
    }

    func resolveRelativePointer(base: Int, raw: String) -> Int? {
        guard let bits = UInt32(raw, radix: 16) else { return nil }
        if let resolver = addressResolver(),
           let target = resolver.resolveRelativePointer(fieldOffset: base, raw: bits) {
            return target
        }
        let delta = Int(Int32(bitPattern: bits))
        let (target, overflow) = base.addingReportingOverflow(delta)
        guard !overflow, target >= 0, target < binary.count else { return nil }
        return target
    }

    func recordBoundSymbol(key: String, name: String, libraryOrdinal: Int) {
        dylbMap[key] = name
        boundSymbols[key] = makeBoundSymbol(name: name, libraryOrdinal: libraryOrdinal)
    }

    func recordUndefinedSymbol(name: String, libraryOrdinal: Int) {
        undefinedSymbols[name] = makeBoundSymbol(name: name, libraryOrdinal: libraryOrdinal)
    }

    private func makeBoundSymbol(name: String, libraryOrdinal: Int) -> MachOBoundSymbol {
        MachOBoundSymbol(
            name: name,
            libraryOrdinal: libraryOrdinal,
            libraryName: machOFile?.dylib(forOrdinal: libraryOrdinal)?.name
        )
    }
    
    var objcClasses = SyncDictionary<Int, String>("ObjcClassesDicSyncQueue")
    /// Runtime class metadata can preserve a Swift superclass binding even
    /// when the Swift context descriptor is stripped or malformed.
    var swiftSuperclasses = SyncDictionary<String, String>("SwiftSuperclassDicSyncQueue")
    var dylbMap = SyncDictionary<String, String>("DyldDicSyncQueue")
    var boundSymbols = SyncDictionary<String, MachOBoundSymbol>("BoundSymbolsDicSyncQueue")
    var undefinedSymbols = SyncDictionary<String, MachOBoundSymbol>("UndefinedSymbolsDicSyncQueue")
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
    var swiftProtocolConformances = SyncArray<SwiftProtocolConformance>("SwiftProtocolConformanceArraySyncQueue")
    
    private init() {}
}
