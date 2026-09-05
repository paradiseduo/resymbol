import Foundation
import MachO

enum DynamicSymbolTable {
    private static let indirectSymbolLocal: UInt32 = 0x8000_0000
    private static let indirectSymbolAbsolute: UInt32 = 0x4000_0000

    static func apply(_ data: Data, isByteSwapped: Bool) {
        guard data.count >= MemoryLayout<mach_header_64>.size else { return }
        var header = data.extract(mach_header_64.self)
        if isByteSwapped { swap_mach_header_64(&header, byteSwappedOrder) }
        var offset = MemoryLayout<mach_header_64>.size
        var symtab: symtab_command?
        var dysymtab: dysymtab_command?
        var sections = [section_64]()

        for _ in 0..<header.ncmds {
            guard offset <= data.count - MemoryLayout<load_command>.size else { return }
            var command = data.extract(load_command.self, offset: offset)
            if isByteSwapped { swap_load_command(&command, byteSwappedOrder) }
            let commandSize = Int(command.cmdsize)
            guard commandSize >= MemoryLayout<load_command>.size,
                  offset <= data.count - commandSize else { return }

            if command.cmd == LC_SYMTAB {
                var value = data.extract(symtab_command.self, offset: offset)
                if isByteSwapped { swap_symtab_command(&value, byteSwappedOrder) }
                symtab = value
            } else if command.cmd == LC_DYSYMTAB {
                var value = data.extract(dysymtab_command.self, offset: offset)
                if isByteSwapped { swap_dysymtab_command(&value, byteSwappedOrder) }
                dysymtab = value
            } else if command.cmd == LC_SEGMENT_64 {
                var segment = data.extract(segment_command_64.self, offset: offset)
                if isByteSwapped { swap_segment_command_64(&segment, byteSwappedOrder) }
                var sectionOffset = offset + MemoryLayout<segment_command_64>.size
                for _ in 0..<segment.nsects {
                    guard sectionOffset <= offset + commandSize - MemoryLayout<section_64>.size else { return }
                    var section = data.extract(section_64.self, offset: sectionOffset)
                    if isByteSwapped { swap_section_64(&section, 1, byteSwappedOrder) }
                    let type = section.flags & UInt32(SECTION_TYPE)
                    if type == UInt32(S_NON_LAZY_SYMBOL_POINTERS) ||
                        type == UInt32(S_LAZY_SYMBOL_POINTERS) ||
                        type == UInt32(S_SYMBOL_STUBS) {
                        sections.append(section)
                    }
                    sectionOffset += MemoryLayout<section_64>.size
                }
            }
            offset += commandSize
        }

        guard let symbols = symtab, let dynamic = dysymtab else { return }
        let indirectOffset = Int(dynamic.indirectsymoff)
        let indirectCount = Int(dynamic.nindirectsyms)
        guard indirectOffset >= 0, indirectCount >= 0,
              indirectCount <= (data.count - indirectOffset) / MemoryLayout<UInt32>.size else { return }

        for section in sections {
            let type = section.flags & UInt32(SECTION_TYPE)
            let stride: UInt64
            if type == UInt32(S_SYMBOL_STUBS) {
                stride = UInt64(section.reserved2)
            } else {
                stride = UInt64(MemoryLayout<UInt64>.size)
            }
            guard stride > 0 else { continue }
            let count = Int(section.size / stride)
            let first = Int(section.reserved1)
            guard first >= 0, count >= 0, first <= indirectCount,
                  count <= indirectCount - first else { continue }

            for index in 0..<count {
                guard let indirect: UInt32 = integer(data, at: indirectOffset + (first + index) * 4) else { break }
                let symbolIndex = isByteSwapped ? indirect.byteSwapped : indirect
                if symbolIndex & (indirectSymbolLocal | indirectSymbolAbsolute) != 0 ||
                    symbolIndex >= symbols.nsyms { continue }
                guard let name = symbolName(data, symtab: symbols, index: Int(symbolIndex), isByteSwapped: isByteSwapped) else { continue }
                var address = section.addr + UInt64(index) * stride
                if address > RVA { address -= RVA }
                MachOData.shared.dylbMap[String(address, radix: 16)] = name
            }
        }
    }

    private static func symbolName(_ data: Data, symtab: symtab_command, index: Int, isByteSwapped: Bool) -> String? {
        let entryOffset = Int(symtab.symoff) + index * MemoryLayout<nlist_64>.size
        guard entryOffset >= 0, entryOffset <= data.count - MemoryLayout<nlist_64>.size else { return nil }
        var entry = data.extract(nlist_64.self, offset: entryOffset)
        if isByteSwapped { swap_nlist_64(&entry, 1, byteSwappedOrder) }
        let stringOffset = Int(symtab.stroff) + Int(entry.n_un.n_strx)
        let stringEnd = Int(symtab.stroff) + Int(symtab.strsize)
        guard stringOffset >= Int(symtab.stroff), stringOffset < stringEnd, stringEnd <= data.count else { return nil }
        let end = data[stringOffset..<stringEnd].firstIndex(of: 0) ?? stringEnd
        return String(data: data[stringOffset..<end], encoding: .utf8)
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T? {
        guard offset >= 0, offset <= data.count - MemoryLayout<T>.size else { return nil }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<offset + MemoryLayout<T>.size)
        }
        return T(littleEndian: value)
    }
}
