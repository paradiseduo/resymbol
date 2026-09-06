import Foundation
import MachO

enum DynamicSymbolTable {
    static func apply(_ data: Data, machOFile: MachOFile) {
        guard let model = DynamicSymbolModelParser.parse(data, machOFile: machOFile) else { return }
        MachOData.shared.dynamicSymbolTable = model
        for item in model.symbols where item.scope == .undefined {
            MachOData.shared.recordUndefinedSymbol(name: item.name, libraryOrdinal: item.libraryOrdinal)
        }
        let sections = machOFile.sections.filter {
            let type = $0.flags & UInt32(SECTION_TYPE)
            return type == UInt32(S_NON_LAZY_SYMBOL_POINTERS) || type == UInt32(S_LAZY_SYMBOL_POINTERS) || type == UInt32(S_SYMBOL_STUBS)
        }
        for section in sections {
            let type = section.flags & UInt32(SECTION_TYPE)
            let stride = type == UInt32(S_SYMBOL_STUBS) ? UInt64(section.reserved2) : UInt64(MemoryLayout<UInt64>.size)
            guard stride > 0 else { continue }
            let count = Int(section.size / stride)
            let first = Int(section.reserved1)
            guard first >= 0, count >= 0, first <= model.indirectSymbols.count,
                  count <= model.indirectSymbols.count - first else { continue }
            for index in 0..<count {
                guard let symbolIndex = model.indirectSymbols[first + index].symbolIndex,
                      symbolIndex < model.symbols.count else { continue }
                let symbol = model.symbols[symbolIndex]
                var address = section.address + UInt64(index) * stride
                if address >= machOFile.preferredLoadAddress { address -= machOFile.preferredLoadAddress }
                MachOData.shared.recordBoundSymbol(key: String(address, radix: 16),
                                                   name: symbol.name,
                                                   libraryOrdinal: symbol.libraryOrdinal)
            }
        }
    }
}
