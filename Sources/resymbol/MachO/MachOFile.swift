import Foundation
import MachO

enum MachOLoadCommandKind: Equatable {
    case segment64
    case symbolTable
    case dynamicSymbolTable
    case dyldInfo
    case exportsTrie
    case chainedFixups
    case loadDylib
    case loadWeakDylib
    case reexportDylib
    case loadUpwardDylib
    case lazyLoadDylib
    case idDylib
    case rpath
    case uuid
    case main
    case buildVersion
    case versionMin
    case sourceVersion
    case encryptionInfo
    case functionStarts
    case dataInCode
    case twoLevelHints
    case other(UInt32)

    init(command: UInt32) {
        switch command {
        case UInt32(truncatingIfNeeded: LC_SEGMENT_64): self = .segment64
        case UInt32(truncatingIfNeeded: LC_SYMTAB): self = .symbolTable
        case UInt32(truncatingIfNeeded: LC_DYSYMTAB): self = .dynamicSymbolTable
        case UInt32(truncatingIfNeeded: LC_DYLD_INFO), UInt32(truncatingIfNeeded: LC_DYLD_INFO_ONLY): self = .dyldInfo
        case UInt32(truncatingIfNeeded: LC_DYLD_EXPORTS_TRIE): self = .exportsTrie
        case UInt32(truncatingIfNeeded: LC_DYLD_CHAINED_FIXUPS): self = .chainedFixups
        case UInt32(truncatingIfNeeded: LC_LOAD_DYLIB): self = .loadDylib
        case UInt32(truncatingIfNeeded: LC_LOAD_WEAK_DYLIB): self = .loadWeakDylib
        case UInt32(truncatingIfNeeded: LC_REEXPORT_DYLIB): self = .reexportDylib
        case UInt32(truncatingIfNeeded: LC_LOAD_UPWARD_DYLIB): self = .loadUpwardDylib
        case UInt32(truncatingIfNeeded: LC_LAZY_LOAD_DYLIB): self = .lazyLoadDylib
        case UInt32(truncatingIfNeeded: LC_ID_DYLIB): self = .idDylib
        case UInt32(truncatingIfNeeded: LC_RPATH): self = .rpath
        case UInt32(truncatingIfNeeded: LC_UUID): self = .uuid
        case UInt32(truncatingIfNeeded: LC_MAIN): self = .main
        case UInt32(truncatingIfNeeded: LC_BUILD_VERSION): self = .buildVersion
        case UInt32(truncatingIfNeeded: LC_VERSION_MIN_MACOSX), UInt32(truncatingIfNeeded: LC_VERSION_MIN_IPHONEOS), UInt32(truncatingIfNeeded: LC_VERSION_MIN_WATCHOS), UInt32(truncatingIfNeeded: LC_VERSION_MIN_TVOS): self = .versionMin
        case UInt32(truncatingIfNeeded: LC_SOURCE_VERSION): self = .sourceVersion
        case UInt32(truncatingIfNeeded: LC_ENCRYPTION_INFO), UInt32(truncatingIfNeeded: LC_ENCRYPTION_INFO_64): self = .encryptionInfo
        case UInt32(truncatingIfNeeded: LC_FUNCTION_STARTS): self = .functionStarts
        case UInt32(truncatingIfNeeded: LC_DATA_IN_CODE): self = .dataInCode
        case UInt32(truncatingIfNeeded: LC_TWOLEVEL_HINTS): self = .twoLevelHints
        default: self = .other(command)
        }
    }
}

enum MachOLoadCommandPayload {
    case segment64(MachOSegment)
    case symbolTable(symtab_command)
    case dynamicSymbolTable(dysymtab_command)
    case dyldInfo(dyld_info_command)
    case linkeditData(linkedit_data_command)
    case dylib(MachODylib)
    case rpath(MachORPath)
    case uuid(MachOUUID)
    case main(MachOEntryPoint)
    case buildVersion(MachOBuildVersion)
    case versionMin(MachOVersionMin)
    case sourceVersion(MachOSourceVersion)
    case encryptionInfo(MachOEncryptionInfo)
    case functionStarts(MachOFunctionStarts)
    case dataInCode(MachODataInCode)
    case twoLevelHints(MachOTwoLevelHints)
    case none
}

struct MachODylib {
    let command: MachOLoadCommandKind
    let commandIndex: Int
    let ordinal: Int?
    let name: String
    let timestamp: UInt32
    let currentVersion: UInt32
    let compatibilityVersion: UInt32
    let useFlags: UInt32?
}

struct MachORPath { let path: String }
struct MachOUUID { let bytes: [UInt8] }
struct MachOEntryPoint { let entryoff: UInt64; let stacksize: UInt64 }
struct MachOBuildToolVersion { let tool: UInt32; let version: UInt32 }
struct MachOBuildVersion {
    let platform: UInt32
    let minimumOS: UInt32
    let sdk: UInt32
    let tools: [MachOBuildToolVersion]
}
struct MachOVersionMin { let command: UInt32; let version: UInt32; let sdk: UInt32 }
struct MachOSourceVersion { let version: UInt64 }
struct MachOEncryptionInfo {
    let cryptoff: UInt32
    let cryptsize: UInt32
    let cryptid: UInt32
    let isEncrypted: Bool
}
struct MachOLinkeditDataRange: Equatable {
    let offset: UInt32
    let size: UInt32
    var fileRange: Range<Int> { Int(offset)..<(Int(offset) + Int(size)) }
}
struct MachOFunctionStarts {
    let data: MachOLinkeditDataRange
    let offsets: [UInt64]
    let addresses: [UInt64]
}
struct MachODataInCodeEntry: Equatable {
    let offset: UInt32
    let length: UInt16
    let kind: UInt16
}
struct MachODataInCode {
    let data: MachOLinkeditDataRange
    let entries: [MachODataInCodeEntry]
}
struct MachOTwoLevelHint: Equatable {
    let subImage: UInt8
    let tocIndex: UInt32
}
struct MachOTwoLevelHints {
    let data: MachOLinkeditDataRange
    let hints: [MachOTwoLevelHint]
}

struct MachOLoadCommand {
    let command: UInt32
    let kind: MachOLoadCommandKind
    let fileOffset: Int
    let commandSize: Int
    let range: Range<Int>
    let payload: MachOLoadCommandPayload

    var linkeditDataRange: MachOLinkeditDataRange? {
        switch payload {
        case .linkeditData(let value):
            return MachOLinkeditDataRange(offset: value.dataoff, size: value.datasize)
        case .functionStarts(let value): return value.data
        case .dataInCode(let value): return value.data
        case .twoLevelHints(let value): return value.data
        default: return nil
        }
    }
}

struct MachOSectionInfo {
    let segmentName: String
    let sectionName: String
    let address: UInt64
    let size: UInt64
    let fileOffset: UInt32
    let alignment: UInt32
    let relocationOffset: UInt32
    let relocationCount: UInt32
    let flags: UInt32
    let reserved1: UInt32
    let reserved2: UInt32
    let reserved3: UInt32
}

struct MachOSegment {
    let name: String
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
    let maxProtection: vm_prot_t
    let initialProtection: vm_prot_t
    let flags: UInt32
    let sections: [MachOSectionInfo]

    func containsVMAddress(_ address: UInt64) -> Bool {
        address >= vmaddr && address - vmaddr < vmsize
    }

    func fileOffset(forVMAddress address: UInt64) -> Int? {
        guard containsVMAddress(address), address - vmaddr < filesize else { return nil }
        let result = fileoff + address - vmaddr
        return result <= UInt64(Int.max) ? Int(result) : nil
    }
}

struct MachOFile {
    let header: mach_header_64
    let isByteSwapped: Bool
    let segments: [MachOSegment]
    let loadCommands: [MachOLoadCommand]

    var sections: [MachOSectionInfo] { segments.flatMap(\.sections) }
    var dylibs: [MachODylib] {
        loadCommands.compactMap {
            guard case .dylib(let dylib) = $0.payload else { return nil }
            return dylib
        }
    }
    var linkedDylibs: [MachODylib] { dylibs.filter { $0.ordinal != nil } }
    var rpaths: [String] {
        loadCommands.compactMap { if case .rpath(let value) = $0.payload { return value.path }; return nil }
    }
    var uuid: [UInt8]? {
        loadCommands.compactMap { if case .uuid(let value) = $0.payload { return value.bytes }; return nil }.first
    }
    var entryPoint: MachOEntryPoint? {
        loadCommands.compactMap { if case .main(let value) = $0.payload { return value }; return nil }.first
    }
    var encryptionInfo: MachOEncryptionInfo? {
        loadCommands.compactMap { if case .encryptionInfo(let value) = $0.payload { return value }; return nil }.first
    }
    var isEncrypted: Bool { encryptionInfo?.isEncrypted == true }
    var functionStarts: MachOFunctionStarts? {
        loadCommands.compactMap { if case .functionStarts(let value) = $0.payload { return value }; return nil }.first
    }
    var dataInCode: MachODataInCode? {
        loadCommands.compactMap { if case .dataInCode(let value) = $0.payload { return value }; return nil }.first
    }
    var twoLevelHints: MachOTwoLevelHints? {
        loadCommands.compactMap { if case .twoLevelHints(let value) = $0.payload { return value }; return nil }.first
    }
    var preferredLoadAddress: UInt64 {
        if let text = segment(named: "__TEXT") { return text.vmaddr }
        return segments.filter { $0.filesize > 0 }.map(\.vmaddr).min() ?? 0
    }

    func segment(named name: String) -> MachOSegment? { segments.first { $0.name == name } }
    func segment(containingVMAddress address: UInt64) -> MachOSegment? { segments.first { $0.containsVMAddress(address) } }
    func section(segment: String? = nil, named name: String) -> MachOSectionInfo? {
        sections.first { $0.sectionName == name && (segment == nil || $0.segmentName == segment) }
    }
    func fileOffset(forVMAddress address: UInt64) -> Int? {
        segment(containingVMAddress: address)?.fileOffset(forVMAddress: address)
    }
    func commands(ofKind kind: MachOLoadCommandKind) -> [MachOLoadCommand] {
        loadCommands.filter { $0.kind == kind }
    }
    func firstCommand(ofKind kind: MachOLoadCommandKind) -> MachOLoadCommand? {
        loadCommands.first { $0.kind == kind }
    }

    static func parse(_ data: Data) -> MachOFile? {
        guard data.count >= MemoryLayout<mach_header_64>.size else { return nil }
        var header = data.extract(mach_header_64.self)
        guard header.magic == MH_MAGIC_64 || header.magic == MH_CIGAM_64 else { return nil }
        let swapped = header.magic == MH_CIGAM_64
        if swapped { swap_mach_header_64(&header, byteSwappedOrder) }
        var cursor = MemoryLayout<mach_header_64>.size
        var segments = [MachOSegment]()
        var loadCommands = [MachOLoadCommand]()
        var nextDylibOrdinal = 1
        for commandIndex in 0..<Int(header.ncmds) {
            guard cursor <= data.count - MemoryLayout<load_command>.size else { return nil }
            var command = data.extract(load_command.self, offset: cursor)
            if swapped { swap_load_command(&command, byteSwappedOrder) }
            let commandSize = Int(command.cmdsize)
            guard commandSize >= MemoryLayout<load_command>.size, cursor <= data.count - commandSize else { return nil }
            var payload: MachOLoadCommandPayload = .none
            if command.cmd == LC_SEGMENT_64 {
                guard commandSize >= MemoryLayout<segment_command_64>.size else { return nil }
                var raw = data.extract(segment_command_64.self, offset: cursor)
                if swapped { swap_segment_command_64(&raw, byteSwappedOrder) }
                let sectionBytes = Int(raw.nsects) * MemoryLayout<section_64>.size
                guard sectionBytes <= commandSize - MemoryLayout<segment_command_64>.size else { return nil }
                var sectionCursor = cursor + MemoryLayout<segment_command_64>.size
                var sections = [MachOSectionInfo]()
                for _ in 0..<raw.nsects {
                    var section = data.extract(section_64.self, offset: sectionCursor)
                    if swapped { swap_section_64(&section, 1, byteSwappedOrder) }
                    sections.append(MachOSectionInfo(segmentName: String(rawCChar: section.segname), sectionName: String(rawCChar: section.sectname), address: section.addr, size: section.size, fileOffset: section.offset, alignment: section.align, relocationOffset: section.reloff, relocationCount: section.nreloc, flags: section.flags, reserved1: section.reserved1, reserved2: section.reserved2, reserved3: section.reserved3))
                    sectionCursor += MemoryLayout<section_64>.size
                }
                let segment = MachOSegment(name: String(rawCChar: raw.segname), vmaddr: raw.vmaddr, vmsize: raw.vmsize, fileoff: raw.fileoff, filesize: raw.filesize, maxProtection: raw.maxprot, initialProtection: raw.initprot, flags: raw.flags, sections: sections)
                segments.append(segment)
                payload = .segment64(segment)
            } else if command.cmd == LC_SYMTAB {
                guard commandSize >= MemoryLayout<symtab_command>.size else { return nil }
                var value = data.extract(symtab_command.self, offset: cursor)
                if swapped { swap_symtab_command(&value, byteSwappedOrder) }
                payload = .symbolTable(value)
            } else if command.cmd == LC_DYSYMTAB {
                guard commandSize >= MemoryLayout<dysymtab_command>.size else { return nil }
                var value = data.extract(dysymtab_command.self, offset: cursor)
                if swapped { swap_dysymtab_command(&value, byteSwappedOrder) }
                payload = .dynamicSymbolTable(value)
            } else if command.cmd == LC_DYLD_INFO || command.cmd == LC_DYLD_INFO_ONLY {
                guard commandSize >= MemoryLayout<dyld_info_command>.size else { return nil }
                var value = data.extract(dyld_info_command.self, offset: cursor)
                if swapped { swap_dyld_info_command(&value, byteSwappedOrder) }
                payload = .dyldInfo(value)
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_FUNCTION_STARTS) ||
                command.cmd == UInt32(truncatingIfNeeded: LC_DATA_IN_CODE) {
                guard commandSize >= MemoryLayout<linkedit_data_command>.size else { return nil }
                var value = data.extract(linkedit_data_command.self, offset: cursor)
                if swapped {
                    value.cmd = value.cmd.byteSwapped; value.cmdsize = value.cmdsize.byteSwapped
                    value.dataoff = value.dataoff.byteSwapped; value.datasize = value.datasize.byteSwapped
                }
                let range = MachOLinkeditDataRange(offset: value.dataoff, size: value.datasize)
                guard rangeIsValid(range, dataCount: data.count) else { return nil }
                if command.cmd == UInt32(truncatingIfNeeded: LC_FUNCTION_STARTS) {
                    guard let offsets = decodeFunctionStarts(data, range: range) else { return nil }
                    let base = segments.first(where: { $0.name == "__TEXT" })?.vmaddr ?? 0
                    var addresses = [UInt64](); addresses.reserveCapacity(offsets.count)
                    for offset in offsets {
                        let (address, overflow) = base.addingReportingOverflow(offset)
                        guard !overflow else { return nil }
                        addresses.append(address)
                    }
                    payload = .functionStarts(MachOFunctionStarts(data: range, offsets: offsets,
                                                                   addresses: addresses))
                } else {
                    guard range.size % UInt32(MemoryLayout<data_in_code_entry>.size) == 0 else { return nil }
                    var entries = [MachODataInCodeEntry]()
                    for index in 0..<Int(range.size) / MemoryLayout<data_in_code_entry>.size {
                        var entry = data.extract(data_in_code_entry.self, offset: Int(range.offset) + index * MemoryLayout<data_in_code_entry>.size)
                        if swapped { entry.offset = entry.offset.byteSwapped; entry.length = entry.length.byteSwapped; entry.kind = entry.kind.byteSwapped }
                        guard UInt64(entry.offset) <= UInt64(data.count),
                              UInt64(entry.length) <= UInt64(data.count) - UInt64(entry.offset) else { return nil }
                        entries.append(MachODataInCodeEntry(offset: entry.offset, length: entry.length, kind: entry.kind))
                    }
                    payload = .dataInCode(MachODataInCode(data: range, entries: entries))
                }
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_TWOLEVEL_HINTS) {
                guard commandSize >= MemoryLayout<twolevel_hints_command>.size else { return nil }
                var value = data.extract(twolevel_hints_command.self, offset: cursor)
                if swapped { swap_twolevel_hints_command(&value, byteSwappedOrder) }
                let hintBytes = value.nhints.multipliedReportingOverflow(by: 4)
                let range = MachOLinkeditDataRange(offset: value.offset, size: hintBytes.partialValue)
                guard !hintBytes.overflow,
                      rangeIsValid(range, dataCount: data.count) else { return nil }
                var hints = [MachOTwoLevelHint](); hints.reserveCapacity(Int(value.nhints))
                for index in 0..<Int(value.nhints) {
                    guard let raw: UInt32 = readInteger(data, offset: Int(range.offset) + index * 4, swapped: swapped) else { return nil }
                    hints.append(MachOTwoLevelHint(subImage: UInt8(raw & 0xff), tocIndex: raw >> 8))
                }
                payload = .twoLevelHints(MachOTwoLevelHints(data: range, hints: hints))
            } else if command.cmd == LC_DYLD_EXPORTS_TRIE || command.cmd == LC_DYLD_CHAINED_FIXUPS {
                guard commandSize >= MemoryLayout<linkedit_data_command>.size else { return nil }
                var value = data.extract(linkedit_data_command.self, offset: cursor)
                if swapped {
                    value.cmd = value.cmd.byteSwapped
                    value.cmdsize = value.cmdsize.byteSwapped
                    value.dataoff = value.dataoff.byteSwapped
                    value.datasize = value.datasize.byteSwapped
                }
                payload = .linkeditData(value)
            } else if isDylibCommand(command.cmd) {
                guard commandSize >= MemoryLayout<dylib_command>.size else { return nil }
                var value = data.extract(dylib_command.self, offset: cursor)
                if swapped { swap_dylib_command(&value, byteSwappedOrder) }
                let nameOffset = Int(value.dylib.name.offset)
                let commandEnd = cursor + commandSize
                let nameStart = cursor + nameOffset
                guard nameOffset >= MemoryLayout<dylib_command>.size,
                      nameStart >= cursor, nameStart < commandEnd,
                      let nameEnd = data[nameStart..<commandEnd].firstIndex(of: 0),
                      let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else { return nil }
                let kind = MachOLoadCommandKind(command: command.cmd)
                let ordinal: Int?
                if kind == .idDylib {
                    ordinal = nil
                } else {
                    ordinal = nextDylibOrdinal
                    nextDylibOrdinal += 1
                }
                let dylibUseMarker: UInt32 = 0x1a74_1800
                let isDylibUse = value.dylib.timestamp == dylibUseMarker && commandSize >= 28
                var rawUseFlags: UInt32 = 0
                if isDylibUse {
                    rawUseFlags = data.extract(UInt32.self, offset: cursor + 24)
                    if swapped { rawUseFlags = rawUseFlags.byteSwapped }
                }
                let useFlags: UInt32? = isDylibUse ? rawUseFlags : nil
                payload = .dylib(MachODylib(command: kind, commandIndex: commandIndex,
                                             ordinal: ordinal, name: name,
                                             timestamp: isDylibUse ? 0 : value.dylib.timestamp,
                                             currentVersion: value.dylib.current_version,
                                             compatibilityVersion: value.dylib.compatibility_version,
                                             useFlags: useFlags))
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_RPATH) {
                guard commandSize >= MemoryLayout<rpath_command>.size else { return nil }
                var value = data.extract(rpath_command.self, offset: cursor)
                if swapped { swap_rpath_command(&value, byteSwappedOrder) }
                guard let path = commandString(data, commandOffset: cursor, commandSize: commandSize,
                                               offset: Int(value.path.offset)) else { return nil }
                payload = .rpath(MachORPath(path: path))
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_UUID) {
                guard commandSize >= MemoryLayout<uuid_command>.size else { return nil }
                payload = .uuid(MachOUUID(bytes: Array(data[(cursor + 8)..<(cursor + 24)])))
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_MAIN) {
                guard commandSize >= MemoryLayout<entry_point_command>.size else { return nil }
                var value = data.extract(entry_point_command.self, offset: cursor)
                if swapped { swap_entry_point_command(&value, byteSwappedOrder) }
                payload = .main(MachOEntryPoint(entryoff: value.entryoff, stacksize: value.stacksize))
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_BUILD_VERSION) {
                guard commandSize >= MemoryLayout<build_version_command>.size else { return nil }
                var value = data.extract(build_version_command.self, offset: cursor)
                if swapped { swap_build_version_command(&value, byteSwappedOrder) }
                let toolBytes = UInt64(value.ntools) * UInt64(MemoryLayout<build_tool_version>.size)
                guard toolBytes <= UInt64(commandSize - MemoryLayout<build_version_command>.size) else { return nil }
                var tools = [MachOBuildToolVersion]()
                for index in 0..<Int(value.ntools) {
                    var tool = data.extract(build_tool_version.self, offset: cursor + MemoryLayout<build_version_command>.size + index * MemoryLayout<build_tool_version>.size)
                    if swapped { swap_build_tool_version(&tool, 1, byteSwappedOrder) }
                    tools.append(MachOBuildToolVersion(tool: tool.tool, version: tool.version))
                }
                payload = .buildVersion(MachOBuildVersion(platform: value.platform, minimumOS: value.minos, sdk: value.sdk, tools: tools))
            } else if isVersionMinCommand(command.cmd) {
                guard commandSize >= MemoryLayout<version_min_command>.size else { return nil }
                var value = data.extract(version_min_command.self, offset: cursor)
                if swapped { swap_version_min_command(&value, byteSwappedOrder) }
                payload = .versionMin(MachOVersionMin(command: command.cmd, version: value.version, sdk: value.sdk))
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_SOURCE_VERSION) {
                guard commandSize >= MemoryLayout<source_version_command>.size else { return nil }
                var value = data.extract(source_version_command.self, offset: cursor)
                if swapped { swap_source_version_command(&value, byteSwappedOrder) }
                payload = .sourceVersion(MachOSourceVersion(version: value.version))
            } else if command.cmd == UInt32(truncatingIfNeeded: LC_ENCRYPTION_INFO) || command.cmd == UInt32(truncatingIfNeeded: LC_ENCRYPTION_INFO_64) {
                let minimumSize = command.cmd == UInt32(truncatingIfNeeded: LC_ENCRYPTION_INFO_64)
                    ? MemoryLayout<encryption_info_command_64>.size
                    : MemoryLayout<encryption_info_command>.size
                guard commandSize >= minimumSize else { return nil }
                var value = data.extract(encryption_info_command.self, offset: cursor)
                if swapped {
                    if command.cmd == UInt32(truncatingIfNeeded: LC_ENCRYPTION_INFO_64) {
                        var value64 = data.extract(encryption_info_command_64.self, offset: cursor)
                        swap_encryption_command_64(&value64, byteSwappedOrder)
                        value.cryptoff = value64.cryptoff
                        value.cryptsize = value64.cryptsize
                        value.cryptid = value64.cryptid
                    } else {
                        swap_encryption_command(&value, byteSwappedOrder)
                    }
                }
                guard UInt64(value.cryptoff) <= UInt64(data.count), UInt64(value.cryptsize) <= UInt64(data.count) - UInt64(value.cryptoff) else { return nil }
                payload = .encryptionInfo(MachOEncryptionInfo(cryptoff: value.cryptoff, cryptsize: value.cryptsize, cryptid: value.cryptid, isEncrypted: value.cryptid != 0))
            }
            guard validatePayload(payload, in: data) else { return nil }
            loadCommands.append(MachOLoadCommand(command: command.cmd,
                                                  kind: MachOLoadCommandKind(command: command.cmd),
                                                  fileOffset: cursor,
                                                  commandSize: commandSize,
                                                  range: cursor..<(cursor + commandSize),
                                                  payload: payload))
            cursor += commandSize
        }
        let file = MachOFile(header: header, isByteSwapped: swapped,
                             segments: segments, loadCommands: loadCommands)
        guard file.hasValidDynamicSymbolRanges else { return nil }
        return file
    }

    func dylib(forOrdinal ordinal: Int) -> MachODylib? {
        guard ordinal > 0 else { return nil }
        return linkedDylibs.first { $0.ordinal == ordinal }
    }

    private static func isDylibCommand(_ command: UInt32) -> Bool {
        let commands: [UInt32] = [UInt32(truncatingIfNeeded: LC_LOAD_DYLIB),
                                   UInt32(truncatingIfNeeded: LC_LOAD_WEAK_DYLIB),
                                   UInt32(truncatingIfNeeded: LC_REEXPORT_DYLIB),
                                   UInt32(truncatingIfNeeded: LC_LOAD_UPWARD_DYLIB),
                                   UInt32(truncatingIfNeeded: LC_LAZY_LOAD_DYLIB),
                                   UInt32(truncatingIfNeeded: LC_ID_DYLIB)]
        return commands.contains(command)
    }

    private static func isVersionMinCommand(_ command: UInt32) -> Bool {
        [UInt32(truncatingIfNeeded: LC_VERSION_MIN_MACOSX), UInt32(truncatingIfNeeded: LC_VERSION_MIN_IPHONEOS), UInt32(truncatingIfNeeded: LC_VERSION_MIN_WATCHOS), UInt32(truncatingIfNeeded: LC_VERSION_MIN_TVOS)].contains(command)
    }

    private static func commandString(_ data: Data, commandOffset: Int, commandSize: Int, offset: Int) -> String? {
        guard offset >= 8, offset < commandSize else { return nil }
        let start = commandOffset + offset
        let end = commandOffset + commandSize
        guard let terminator = data[start..<end].firstIndex(of: 0),
              let string = String(data: data[start..<terminator], encoding: .utf8) else { return nil }
        return string
    }

    private static func rangeIsValid(_ range: MachOLinkeditDataRange, dataCount: Int) -> Bool {
        UInt64(range.offset) <= UInt64(dataCount) && UInt64(range.size) <= UInt64(dataCount) - UInt64(range.offset)
    }

    private static func decodeFunctionStarts(_ data: Data, range: MachOLinkeditDataRange) -> [UInt64]? {
        let start = Int(range.offset), end = start + Int(range.size)
        var cursor = start, current: UInt64 = 0, offsets = [UInt64]()
        if cursor == end { return offsets }
        while cursor < end {
            var value: UInt64 = 0, shift = 0
            var terminated = false
            while cursor < end, shift < 64 {
                let byte = data[cursor]; cursor += 1
                value |= UInt64(byte & 0x7f) << UInt64(shift)
                if byte & 0x80 == 0 { terminated = true; break }
                shift += 7
            }
            guard terminated else { return nil }
            if value == 0 { return offsets }
            let (next, overflow) = current.addingReportingOverflow(value)
            guard !overflow else { return nil }
            current = next; offsets.append(current)
        }
        return nil
    }

    private static func readInteger<T: FixedWidthInteger>(_ data: Data, offset: Int, swapped: Bool) -> T? {
        guard offset >= 0, offset <= data.count - MemoryLayout<T>.size else { return nil }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size)) }
        return swapped ? value.byteSwapped : value
    }

    private var hasValidDynamicSymbolRanges: Bool {
        guard let symbolCommand = firstCommand(ofKind: .symbolTable),
              case .symbolTable(let symbols) = symbolCommand.payload,
              let dynamicCommand = firstCommand(ofKind: .dynamicSymbolTable),
              case .dynamicSymbolTable(let dynamic) = dynamicCommand.payload else { return true }
        func valid(_ start: UInt32, _ count: UInt32) -> Bool {
            start <= symbols.nsyms && count <= symbols.nsyms - start
        }
        return valid(dynamic.ilocalsym, dynamic.nlocalsym) &&
            valid(dynamic.iextdefsym, dynamic.nextdefsym) &&
            valid(dynamic.iundefsym, dynamic.nundefsym)
    }

    private static func validatePayload(_ payload: MachOLoadCommandPayload, in data: Data) -> Bool {
        func valid(_ offset: UInt64, _ size: UInt64) -> Bool {
            if size == 0 { return true }
            return offset <= UInt64(data.count) && size <= UInt64(data.count) - offset
        }
        switch payload {
        case .symbolTable(let value):
            let entries = UInt64(value.nsyms) * UInt64(MemoryLayout<nlist_64>.size)
            return valid(UInt64(value.symoff), entries) && valid(UInt64(value.stroff), UInt64(value.strsize))
        case .dynamicSymbolTable(let value):
            return valid(UInt64(value.tocoff), UInt64(value.ntoc) * UInt64(MemoryLayout<dylib_table_of_contents>.size)) &&
                valid(UInt64(value.modtaboff), UInt64(value.nmodtab) * UInt64(MemoryLayout<dylib_module_64>.size)) &&
                valid(UInt64(value.extrefsymoff), UInt64(value.nextrefsyms) * UInt64(MemoryLayout<dylib_reference>.size)) &&
                valid(UInt64(value.indirectsymoff), UInt64(value.nindirectsyms) * UInt64(MemoryLayout<UInt32>.size)) &&
                valid(UInt64(value.extreloff), UInt64(value.nextrel) * UInt64(MemoryLayout<relocation_info>.size)) &&
                valid(UInt64(value.locreloff), UInt64(value.nlocrel) * UInt64(MemoryLayout<relocation_info>.size))
        case .dyldInfo(let value):
            return valid(UInt64(value.rebase_off), UInt64(value.rebase_size)) &&
                valid(UInt64(value.bind_off), UInt64(value.bind_size)) &&
                valid(UInt64(value.weak_bind_off), UInt64(value.weak_bind_size)) &&
                valid(UInt64(value.lazy_bind_off), UInt64(value.lazy_bind_size)) &&
                valid(UInt64(value.export_off), UInt64(value.export_size))
        case .linkeditData(let value):
            return valid(UInt64(value.dataoff), UInt64(value.datasize))
        default:
            return true
        }
    }
}
