import Foundation
import MachO

enum MachOLoadCommandKind: Equatable {
    case segment64
    case symbolTable
    case dynamicSymbolTable
    case dyldInfo
    case exportsTrie
    case chainedFixups
    case other(UInt32)

    init(command: UInt32) {
        switch command {
        case UInt32(truncatingIfNeeded: LC_SEGMENT_64): self = .segment64
        case UInt32(truncatingIfNeeded: LC_SYMTAB): self = .symbolTable
        case UInt32(truncatingIfNeeded: LC_DYSYMTAB): self = .dynamicSymbolTable
        case UInt32(truncatingIfNeeded: LC_DYLD_INFO), UInt32(truncatingIfNeeded: LC_DYLD_INFO_ONLY): self = .dyldInfo
        case UInt32(truncatingIfNeeded: LC_DYLD_EXPORTS_TRIE): self = .exportsTrie
        case UInt32(truncatingIfNeeded: LC_DYLD_CHAINED_FIXUPS): self = .chainedFixups
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
    case none
}

struct MachOLoadCommand {
    let command: UInt32
    let kind: MachOLoadCommandKind
    let fileOffset: Int
    let commandSize: Int
    let range: Range<Int>
    let payload: MachOLoadCommandPayload
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
        for _ in 0..<header.ncmds {
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
            }
            loadCommands.append(MachOLoadCommand(command: command.cmd,
                                                  kind: MachOLoadCommandKind(command: command.cmd),
                                                  fileOffset: cursor,
                                                  commandSize: commandSize,
                                                  range: cursor..<(cursor + commandSize),
                                                  payload: payload))
            cursor += commandSize
        }
        return MachOFile(header: header, isByteSwapped: swapped,
                         segments: segments, loadCommands: loadCommands)
    }
}
