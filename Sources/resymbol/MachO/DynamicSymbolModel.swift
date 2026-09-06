import Foundation
import MachO

enum MachOSymbolKind: Equatable { case debugging, undefined, absolute, section, preboundUndefined, indirect, other(UInt8) }
enum MachOSymbolScope: Equatable { case local, externalDefined, undefined, other }

struct MachOSymbolRecord: Equatable {
    let index: Int
    let name: String
    let rawType: UInt8
    let sectionIndex: UInt8
    let descriptor: UInt16
    let value: UInt64
    /// For N_INDR records, n_value is a string-table offset rather than a VM
    /// address. Preserve the referenced name so a rebuilt string table can
    /// assign it a new offset.
    let indirectTargetName: String?
    let kind: MachOSymbolKind
    let scope: MachOSymbolScope
    let libraryOrdinal: Int
    var isExternal: Bool { rawType & UInt8(N_EXT) != 0 }
    var isPrivateExternal: Bool { rawType & UInt8(N_PEXT) != 0 }
    var isWeakReference: Bool { descriptor & UInt16(N_WEAK_REF) != 0 }
    var isWeakDefinition: Bool { descriptor & UInt16(N_WEAK_DEF) != 0 }
}

struct MachOIndirectSymbol: Equatable {
    let tableIndex: Int
    let rawValue: UInt32
    let symbolIndex: Int?
    let isLocal: Bool
    let isAbsolute: Bool
}

struct MachORelocation: Equatable {
    let address: Int32
    let symbolNumber: UInt32
    let isPCRelative: Bool
    let length: UInt8
    let isExternal: Bool
    let type: UInt8
    let isScattered: Bool
    let scatteredValue: UInt32?
}

struct MachODylibTableOfContentsEntry: Equatable { let symbolIndex: UInt32; let moduleIndex: UInt32 }
struct MachODylibReference: Equatable { let symbolIndex: UInt32; let flags: UInt8 }
struct MachODylibModule: Equatable {
    let name: String?
    let externalDefinedRange: Range<Int>
    let referenceRange: Range<Int>
    let localRange: Range<Int>
    let externalRelocationRange: Range<Int>
    let objcModuleInfoAddress: UInt64
    let objcModuleInfoSize: UInt32
}

struct MachODynamicSymbolTableModel {
    let symbols: [MachOSymbolRecord]
    let symbolsByAddress: [UInt64: [Int]]
    let symbolsByName: [String: [Int]]
    let localRange: Range<Int>
    let externalDefinedRange: Range<Int>
    let undefinedRange: Range<Int>
    let indirectSymbols: [MachOIndirectSymbol]
    let tableOfContents: [MachODylibTableOfContentsEntry]
    let modules: [MachODylibModule]
    let references: [MachODylibReference]
    let externalRelocations: [MachORelocation]
    let localRelocations: [MachORelocation]

    func symbols(at address: UInt64) -> [MachOSymbolRecord] { (symbolsByAddress[address] ?? []).map { symbols[$0] } }
    func symbols(named name: String) -> [MachOSymbolRecord] { (symbolsByName[name] ?? []).map { symbols[$0] } }
}

enum DynamicSymbolModelParser {
    static func parse(_ data: Data, machOFile: MachOFile) -> MachODynamicSymbolTableModel? {
        guard let symCommand = machOFile.firstCommand(ofKind: .symbolTable), case .symbolTable(let symtab) = symCommand.payload,
              let dynCommand = machOFile.firstCommand(ofKind: .dynamicSymbolTable), case .dynamicSymbolTable(let dynamic) = dynCommand.payload,
              let locals = range(dynamic.ilocalsym, dynamic.nlocalsym, symtab.nsyms),
              let extdefs = range(dynamic.iextdefsym, dynamic.nextdefsym, symtab.nsyms),
              let undefs = range(dynamic.iundefsym, dynamic.nundefsym, symtab.nsyms) else { return nil }
        var symbols = [MachOSymbolRecord](); symbols.reserveCapacity(Int(symtab.nsyms))
        var byAddress = [UInt64: [Int]](); var byName = [String: [Int]]()
        for index in 0..<Int(symtab.nsyms) {
            guard let record = symbol(data, symtab: symtab, index: index,
                                      scope: scope(index, locals: locals, extdefs: extdefs, undefs: undefs),
                                      swapped: machOFile.isByteSwapped) else { return nil }
            symbols.append(record)
            if record.value != 0 { byAddress[record.value, default: []].append(index) }
            if !record.name.isEmpty { byName[record.name, default: []].append(index) }
        }
        guard let indirect = indirectSymbols(data, command: dynamic, symbolCount: symbols.count, swapped: machOFile.isByteSwapped),
              let toc = tableOfContents(data, command: dynamic, swapped: machOFile.isByteSwapped),
              let modules = modules(data, command: dynamic, symtab: symtab, swapped: machOFile.isByteSwapped),
              let references = references(data, command: dynamic, swapped: machOFile.isByteSwapped),
              let extRelocs = relocations(data, offset: dynamic.extreloff, count: dynamic.nextrel, swapped: machOFile.isByteSwapped),
              let localRelocs = relocations(data, offset: dynamic.locreloff, count: dynamic.nlocrel, swapped: machOFile.isByteSwapped) else { return nil }
        return MachODynamicSymbolTableModel(symbols: symbols, symbolsByAddress: byAddress, symbolsByName: byName,
                                            localRange: locals, externalDefinedRange: extdefs, undefinedRange: undefs,
                                            indirectSymbols: indirect, tableOfContents: toc, modules: modules,
                                            references: references, externalRelocations: extRelocs, localRelocations: localRelocs)
    }

    private static func scope(_ index: Int, locals: Range<Int>, extdefs: Range<Int>, undefs: Range<Int>) -> MachOSymbolScope {
        if locals.contains(index) { return .local }; if extdefs.contains(index) { return .externalDefined }; if undefs.contains(index) { return .undefined }; return .other
    }
    private static func range(_ start: UInt32, _ count: UInt32, _ limit: UInt32) -> Range<Int>? {
        guard start <= limit, count <= limit - start else { return nil }; return Int(start)..<Int(start + count)
    }
    private static func symbol(_ data: Data, symtab: symtab_command, index: Int, scope: MachOSymbolScope, swapped: Bool) -> MachOSymbolRecord? {
        let offset = Int(symtab.symoff) + index * MemoryLayout<nlist_64>.size
        guard let strx: UInt32 = integer(data, offset: offset, swapped: swapped), let rawType: UInt8 = integer(data, offset: offset + 4, swapped: false),
              let section: UInt8 = integer(data, offset: offset + 5, swapped: false), let desc: UInt16 = integer(data, offset: offset + 6, swapped: swapped),
              let value: UInt64 = integer(data, offset: offset + 8, swapped: swapped), let name = string(data, symtab: symtab, index: strx, swapped: swapped) else { return nil }
        let type = rawType & UInt8(N_TYPE)
        let kind: MachOSymbolKind = rawType & UInt8(N_STAB) != 0 ? .debugging : type == UInt8(N_UNDF) ? .undefined : type == UInt8(N_ABS) ? .absolute : type == UInt8(N_SECT) ? .section : type == UInt8(N_PBUD) ? .preboundUndefined : type == UInt8(N_INDR) ? .indirect : .other(type)
        let indirectTargetName = kind == .indirect
            ? string(data, symtab: symtab, index: UInt32(truncatingIfNeeded: value), swapped: swapped)
            : nil
        if kind == .indirect && (value > UInt64(UInt32.max) || indirectTargetName == nil) { return nil }
        return MachOSymbolRecord(index: index, name: name, rawType: rawType, sectionIndex: section,
                                 descriptor: desc, value: value,
                                 indirectTargetName: indirectTargetName, kind: kind, scope: scope,
                                 libraryOrdinal: Int((desc >> 8) & 0xff))
    }
    private static func string(_ data: Data, symtab: symtab_command, index: UInt32, swapped: Bool) -> String? {
        let start = UInt64(symtab.stroff) + UInt64(index); let end = UInt64(symtab.stroff) + UInt64(symtab.strsize)
        guard UInt64(index) < UInt64(symtab.strsize), start <= UInt64(Int.max), end <= UInt64(data.count) else { return nil }
        let s = Int(start), e = Int(end), terminator = data[s..<e].firstIndex(of: 0) ?? e
        return String(data: data[s..<terminator], encoding: .utf8)
    }
    private static func indirectSymbols(_ data: Data, command: dysymtab_command, symbolCount: Int, swapped: Bool) -> [MachOIndirectSymbol]? {
        var result = [MachOIndirectSymbol](); result.reserveCapacity(Int(command.nindirectsyms))
        for index in 0..<Int(command.nindirectsyms) { guard let raw: UInt32 = integer(data, offset: Int(command.indirectsymoff) + index * 4, swapped: swapped) else { return nil }; let local = raw & 0x8000_0000 != 0; let absolute = raw & 0x4000_0000 != 0; result.append(MachOIndirectSymbol(tableIndex: index, rawValue: raw, symbolIndex: !local && !absolute && raw < UInt32(symbolCount) ? Int(raw) : nil, isLocal: local, isAbsolute: absolute)) }
        return result
    }
    private static func tableOfContents(_ data: Data, command: dysymtab_command, swapped: Bool) -> [MachODylibTableOfContentsEntry]? {
        var result = [MachODylibTableOfContentsEntry](); result.reserveCapacity(Int(command.ntoc)); for index in 0..<Int(command.ntoc) { let offset = Int(command.tocoff) + index * 8; guard let symbol: UInt32 = integer(data, offset: offset, swapped: swapped), let module: UInt32 = integer(data, offset: offset + 4, swapped: swapped) else { return nil }; result.append(MachODylibTableOfContentsEntry(symbolIndex: symbol, moduleIndex: module)) }; return result
    }
    private static func modules(_ data: Data, command: dysymtab_command, symtab: symtab_command, swapped: Bool) -> [MachODylibModule]? {
        var result = [MachODylibModule](); result.reserveCapacity(Int(command.nmodtab)); let stride = MemoryLayout<dylib_module_64>.size
        for index in 0..<Int(command.nmodtab) { let o = Int(command.modtaboff) + index * stride; guard let nameIndex: UInt32 = integer(data, offset: o, swapped: swapped), let iext: UInt32 = integer(data, offset: o + 4, swapped: swapped), let next: UInt32 = integer(data, offset: o + 8, swapped: swapped), let iref: UInt32 = integer(data, offset: o + 12, swapped: swapped), let nref: UInt32 = integer(data, offset: o + 16, swapped: swapped), let ilocal: UInt32 = integer(data, offset: o + 20, swapped: swapped), let nlocal: UInt32 = integer(data, offset: o + 24, swapped: swapped), let iextrel: UInt32 = integer(data, offset: o + 28, swapped: swapped), let nextrel: UInt32 = integer(data, offset: o + 32, swapped: swapped), let infoSize: UInt32 = integer(data, offset: o + 44, swapped: swapped), let infoAddress: UInt64 = integer(data, offset: o + 48, swapped: swapped), let ext = range(iext, next, symtab.nsyms), let refs = range(iref, nref, command.nextrefsyms), let locals = range(ilocal, nlocal, symtab.nsyms), let relocs = range(iextrel, nextrel, command.nextrel), let moduleName = string(data, symtab: symtab, index: nameIndex, swapped: swapped) else { return nil }; result.append(MachODylibModule(name: moduleName.isEmpty ? nil : moduleName, externalDefinedRange: ext, referenceRange: refs, localRange: locals, externalRelocationRange: relocs, objcModuleInfoAddress: infoAddress, objcModuleInfoSize: infoSize)) }
        return result
    }
    private static func references(_ data: Data, command: dysymtab_command, swapped: Bool) -> [MachODylibReference]? { var result = [MachODylibReference](); for index in 0..<Int(command.nextrefsyms) { guard let raw: UInt32 = integer(data, offset: Int(command.extrefsymoff) + index * 4, swapped: swapped) else { return nil }; result.append(MachODylibReference(symbolIndex: raw & 0x00ff_ffff, flags: UInt8(raw >> 24))) }; return result }
    private static func relocations(_ data: Data, offset: UInt32, count: UInt32, swapped: Bool) -> [MachORelocation]? { var result = [MachORelocation](); for index in 0..<Int(count) { let o = Int(offset) + index * 8; guard let address: UInt32 = integer(data, offset: o, swapped: swapped), let info: UInt32 = integer(data, offset: o + 4, swapped: swapped) else { return nil }; let scattered = address & 0x8000_0000 != 0; result.append(MachORelocation(address: Int32(bitPattern: scattered ? address & 0x00ff_ffff : address), symbolNumber: scattered ? 0 : info & 0x00ff_ffff, isPCRelative: scattered ? address & 0x4000_0000 != 0 : info & 0x0100_0000 != 0, length: UInt8((scattered ? address >> 28 : info >> 25) & 3), isExternal: !scattered && info & 0x0800_0000 != 0, type: UInt8((scattered ? address >> 24 : info >> 28) & 0xf), isScattered: scattered, scatteredValue: scattered ? info : nil)) }; return result }
    private static func integer<T: FixedWidthInteger>(_ data: Data, offset: Int, swapped: Bool) -> T? { guard offset >= 0, offset <= data.count - MemoryLayout<T>.size else { return nil }; var value: T = 0; _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<offset + MemoryLayout<T>.size) }; return swapped ? value.byteSwapped : value }
}
