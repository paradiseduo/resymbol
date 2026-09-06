import Foundation

enum RecoveredSymbolSource: String, CaseIterable, Hashable {
    case symbolTable = "nlist"
    case exportTrie = "export-trie"
    case objectiveCMetadata = "objc-metadata"
    case externalJSON = "external-json"
}

enum RecoveredSymbolConfidence: Int, Comparable {
    case heuristic = 0
    case inferred = 1
    case exact = 2

    static func < (lhs: RecoveredSymbolConfidence, rhs: RecoveredSymbolConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct RecoveredSymbolCandidate: Equatable {
    let address: UInt64
    let name: String
    let sources: Set<RecoveredSymbolSource>
    let confidence: RecoveredSymbolConfidence
    let isExternal: Bool
}

extension RecoveredSymbolCandidate {
    /// Parse the legacy restore-symbol JSON shape: an array of
    /// {"name": "...", "address": "0x..."} records. Invalid records are
    /// ignored so one stale entry cannot invalidate an otherwise useful file.
    static func externalJSON(_ data: Data) -> [RecoveredSymbolCandidate] {
        guard let objects = try? JSONSerialization.jsonObject(with: data),
              let records = objects as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var result = [RecoveredSymbolCandidate]()
        for record in records {
            guard let name = record["name"] as? String, !name.isEmpty,
                  name.utf8.count < 4096,
                  let address = parseExternalAddress(record["address"]) else { continue }
            let key = "\(address)|\(name)"
            guard seen.insert(key).inserted else { continue }
            result.append(RecoveredSymbolCandidate(address: address, name: name,
                                                   sources: [.externalJSON],
                                                   confidence: .exact, isExternal: true))
        }
        return result.sorted {
            $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address
        }
    }

    private static func parseExternalAddress(_ value: Any?) -> UInt64? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
            return UInt64(digits, radix: 16) ?? UInt64(trimmed)
        }
        if let number = value as? NSNumber, number.doubleValue >= 0,
           number.doubleValue.rounded() == number.doubleValue {
            return UInt64(exactly: number.uint64Value)
        }
        return nil
    }
}

/// One nlist_64 record in a rebuilt symbol table. Keeping this as a typed
/// model avoids writing bytes before all offset/range decisions are validated.
struct RecoveredNListEntry: Equatable {
    let originalIndex: Int?
    let name: String
    let stringOffset: UInt32
    let type: UInt8
    let sectionIndex: UInt8
    let descriptor: UInt16
    let value: UInt64
    let isNew: Bool
}

struct RecoveredSymbolWriteLayout {
    let entries: [RecoveredNListEntry]
    let stringTable: Data
    let localRange: Range<Int>
    let externalDefinedRange: Range<Int>
    let undefinedRange: Range<Int>
    /// New string-table offsets for each dylib_module_64 module name.
    let moduleNameOffsets: [UInt32]
    /// Indirect-symbol, TOC, module and relocation indexes refer to nlist
    /// indexes. Any insertion therefore requires a DYSYMTAB rewrite.
    let requiresDynamicSymbolTableRewrite: Bool

    /// Serialize the planned records as contiguous Mach-O nlist_64 entries.
    /// The caller decides where to place this data in a new output file.
    func serializedNListData(byteSwapped: Bool = false) -> Data {
        var result = Data()
        result.reserveCapacity(entries.count * 16)
        for entry in entries {
            append(UInt32(entry.stringOffset), to: &result, byteSwapped: byteSwapped)
            result.append(entry.type)
            result.append(entry.sectionIndex)
            append(entry.descriptor, to: &result, byteSwapped: byteSwapped)
            append(entry.value, to: &result, byteSwapped: byteSwapped)
        }
        return result
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data,
                                              byteSwapped: Bool) {
        var encoded = byteSwapped ? value.byteSwapped : value
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

struct RecoveredSymbolPatchPlan: Equatable {
    let symbolTableCommandOffset: Int
    let dynamicSymbolTableCommandOffset: Int?
    let symbolTableFileOffset: Int
    let stringTableFileOffset: Int
    let symbolCount: Int
    let stringTableSize: Int
    let outputSize: Int
    let requiresDynamicSymbolTableRewrite: Bool

    static func make(data: Data, file: MachOFile,
                     layout: RecoveredSymbolWriteLayout) -> RecoveredSymbolPatchPlan? {
        guard let symtab = file.firstCommand(ofKind: .symbolTable),
              let dynamic = file.firstCommand(ofKind: .dynamicSymbolTable),
              layout.entries.count <= Int(UInt32.max),
              layout.stringTable.count <= Int(UInt32.max) else { return nil }
        let aligned = data.count.addingReportingOverflow(7)
        guard !aligned.overflow else { return nil }
        let alignedSymbols = aligned.partialValue & ~7
        let stringOffset = alignedSymbols.addingReportingOverflow(layout.serializedNListData(
            byteSwapped: file.isByteSwapped).count)
        guard !stringOffset.overflow else { return nil }
        let outputSize = stringOffset.partialValue.addingReportingOverflow(layout.stringTable.count)
        guard !outputSize.overflow else { return nil }
        guard alignedSymbols <= Int(UInt32.max),
              stringOffset.partialValue <= Int(UInt32.max) else { return nil }
        return RecoveredSymbolPatchPlan(
            symbolTableCommandOffset: symtab.fileOffset,
            dynamicSymbolTableCommandOffset: dynamic.fileOffset,
            symbolTableFileOffset: alignedSymbols,
            stringTableFileOffset: stringOffset.partialValue,
            symbolCount: layout.entries.count,
            stringTableSize: layout.stringTable.count,
            outputSize: outputSize.partialValue,
            requiresDynamicSymbolTableRewrite: layout.requiresDynamicSymbolTableRewrite)
    }
}

enum RecoveredSymbolWriterError: Error {
    case missingCommands
    case unsupportedDynamicIndexLayout
    case invalidLayout
    case validationFailed
}

enum RecoveredSymbolWriter {
    /// Materialize a new Mach-O copy with the rebuilt nlist/string tables.
    /// The source file is never modified. Dynamic-table indexes are rewritten
    /// only when every referenced symbol maps unambiguously.
    static func materialize(data: Data, file: MachOFile,
                            dynamicSymbols: MachODynamicSymbolTableModel?,
                            layout: RecoveredSymbolWriteLayout) throws -> Data {
        guard let symtab = file.firstCommand(ofKind: .symbolTable),
              symtab.payload.symbolTableValue != nil,
              let dynamicSymbols,
              let dynamicCommand = file.firstCommand(ofKind: .dynamicSymbolTable),
              let patch = RecoveredSymbolPatchPlan.make(data: data, file: file, layout: layout) else {
            throw RecoveredSymbolWriterError.missingCommands
        }
        let nlistData = layout.serializedNListData(byteSwapped: file.isByteSwapped)
        guard nlistData.count == layout.entries.count * 16,
              patch.outputSize >= patch.stringTableFileOffset + layout.stringTable.count else {
            throw RecoveredSymbolWriterError.invalidLayout
        }
        guard patch.outputSize >= data.count else {
            throw RecoveredSymbolWriterError.invalidLayout
        }
        var output = data
        output.reserveCapacity(patch.outputSize)
        if output.count < patch.outputSize {
            output.append(contentsOf: repeatElement(UInt8(0),
                                                     count: patch.outputSize - output.count))
        }
        output.replaceSubrange(patch.symbolTableFileOffset..<(patch.symbolTableFileOffset + nlistData.count),
                               with: nlistData)
        output.replaceSubrange(patch.stringTableFileOffset..<(patch.stringTableFileOffset + layout.stringTable.count),
                               with: layout.stringTable)
        try patchUInt32(&output, at: symtab.fileOffset + 8, value: UInt32(patch.symbolTableFileOffset), swapped: file.isByteSwapped)
        try patchUInt32(&output, at: symtab.fileOffset + 12, value: UInt32(patch.symbolCount), swapped: file.isByteSwapped)
        try patchUInt32(&output, at: symtab.fileOffset + 16, value: UInt32(patch.stringTableFileOffset), swapped: file.isByteSwapped)
        try patchUInt32(&output, at: symtab.fileOffset + 20, value: UInt32(patch.stringTableSize), swapped: file.isByteSwapped)
        try patchDynamicIndexes(&output, command: dynamicCommand, symbols: dynamicSymbols,
                                file: file, layout: layout, swapped: file.isByteSwapped)
        try patchLinkeditSegment(&output, file: file)
        try validate(output, expected: layout)
        return output
    }

    private static func patchDynamicIndexes(_ data: inout Data, command: MachOLoadCommand,
                                            symbols: MachODynamicSymbolTableModel,
                                            file: MachOFile,
                                            layout: RecoveredSymbolWriteLayout,
                                            swapped: Bool) throws {
        var map = [Int: Int]()
        for (newIndex, entry) in layout.entries.enumerated() {
            if let original = entry.originalIndex {
                guard map[original] == nil else { throw RecoveredSymbolWriterError.invalidLayout }
                map[original] = newIndex
            }
        }
        guard map.count == symbols.symbols.count else { throw RecoveredSymbolWriterError.invalidLayout }
        guard case .dynamicSymbolTable(let dynamic) = command.payload,
              symbols.indirectSymbols.count == Int(dynamic.nindirectsyms),
              symbols.tableOfContents.count == Int(dynamic.ntoc),
              symbols.modules.count == Int(dynamic.nmodtab),
              symbols.references.count == Int(dynamic.nextrefsyms),
              layout.moduleNameOffsets.count == symbols.modules.count else {
            throw RecoveredSymbolWriterError.invalidLayout
        }

        try patchUInt32(&data, at: command.fileOffset + 8,
                        value: checkedUInt32(layout.localRange.lowerBound), swapped: swapped)
        try patchUInt32(&data, at: command.fileOffset + 12,
                        value: checkedUInt32(layout.localRange.count), swapped: swapped)
        try patchUInt32(&data, at: command.fileOffset + 16,
                        value: checkedUInt32(layout.externalDefinedRange.lowerBound), swapped: swapped)
        try patchUInt32(&data, at: command.fileOffset + 20,
                        value: checkedUInt32(layout.externalDefinedRange.count), swapped: swapped)
        try patchUInt32(&data, at: command.fileOffset + 24,
                        value: checkedUInt32(layout.undefinedRange.lowerBound), swapped: swapped)
        try patchUInt32(&data, at: command.fileOffset + 28,
                        value: checkedUInt32(layout.undefinedRange.count), swapped: swapped)

        for item in symbols.indirectSymbols {
            guard item.tableIndex >= 0 else { throw RecoveredSymbolWriterError.invalidLayout }
            var raw = item.rawValue
            if !item.isLocal && !item.isAbsolute {
                guard let old = item.symbolIndex, let new = map[old] else {
                    throw RecoveredSymbolWriterError.unsupportedDynamicIndexLayout
                }
                raw = try checkedUInt32(new)
            }
            try patchUInt32(&data, at: Int(dynamic.indirectsymoff) + item.tableIndex * 4,
                            value: raw, swapped: swapped)
        }

        for (index, item) in symbols.tableOfContents.enumerated() {
            guard let mapped = map[Int(item.symbolIndex)] else {
                throw RecoveredSymbolWriterError.unsupportedDynamicIndexLayout
            }
            try patchUInt32(&data, at: Int(dynamic.tocoff) + index * 8,
                            value: checkedUInt32(mapped), swapped: swapped)
        }

        let moduleStride = MemoryLayout<dylib_module_64>.size
        for (index, module) in symbols.modules.enumerated() {
            let offset = Int(dynamic.modtaboff) + index * moduleStride
            try patchUInt32(&data, at: offset, value: layout.moduleNameOffsets[index], swapped: swapped)
            if !module.externalDefinedRange.isEmpty {
                let range = try remappedContiguousRange(module.externalDefinedRange, using: map)
                try patchUInt32(&data, at: offset + 4, value: checkedUInt32(range.lowerBound), swapped: swapped)
                try patchUInt32(&data, at: offset + 8, value: checkedUInt32(range.count), swapped: swapped)
            }
            if !module.localRange.isEmpty {
                let range = try remappedContiguousRange(module.localRange, using: map)
                try patchUInt32(&data, at: offset + 20, value: checkedUInt32(range.lowerBound), swapped: swapped)
                try patchUInt32(&data, at: offset + 24, value: checkedUInt32(range.count), swapped: swapped)
            }
        }

        for (index, reference) in symbols.references.enumerated() {
            guard let mapped = map[Int(reference.symbolIndex)], mapped < 0x0100_0000 else {
                throw RecoveredSymbolWriterError.unsupportedDynamicIndexLayout
            }
            let raw = UInt32(reference.flags) << 24 | UInt32(mapped)
            try patchUInt32(&data, at: Int(dynamic.extrefsymoff) + index * 4,
                            value: raw, swapped: swapped)
        }

        var relocationOffsets = Set<Int>()
        addRelocationOffsets(&relocationOffsets, start: dynamic.extreloff, count: dynamic.nextrel)
        addRelocationOffsets(&relocationOffsets, start: dynamic.locreloff, count: dynamic.nlocrel)
        for section in file.sections {
            addRelocationOffsets(&relocationOffsets, start: section.relocationOffset,
                                 count: section.relocationCount)
        }
        for offset in relocationOffsets.sorted() {
            try patchExternalRelocation(&data, at: offset, map: map, swapped: swapped)
        }
    }

    private static func patchLinkeditSegment(_ data: inout Data, file: MachOFile) throws {
        guard let command = file.commands(ofKind: .segment64).first(where: {
            if case .segment64(let segment) = $0.payload { return segment.name == "__LINKEDIT" }
            return false
        }), case .segment64(let segment) = command.payload,
              segment.fileoff <= UInt64(data.count) else {
            throw RecoveredSymbolWriterError.missingCommands
        }
        let fileSize = UInt64(data.count) - segment.fileoff
        let pageSize: UInt64 = 0x4000
        let rounded = fileSize.addingReportingOverflow(pageSize - 1)
        guard !rounded.overflow else { throw RecoveredSymbolWriterError.invalidLayout }
        let requiredVMSize = rounded.partialValue & ~(pageSize - 1)
        try patchUInt64(&data, at: command.fileOffset + 32,
                        value: max(segment.vmsize, requiredVMSize), swapped: file.isByteSwapped)
        try patchUInt64(&data, at: command.fileOffset + 48,
                        value: fileSize, swapped: file.isByteSwapped)
    }

    private static func validate(_ data: Data, expected layout: RecoveredSymbolWriteLayout) throws {
        guard let file = MachOFile.parse(data),
              let parsed = DynamicSymbolModelParser.parse(data, machOFile: file),
              parsed.symbols.count == layout.entries.count,
              parsed.localRange == layout.localRange,
              parsed.externalDefinedRange == layout.externalDefinedRange,
              parsed.undefinedRange == layout.undefinedRange else {
            throw RecoveredSymbolWriterError.validationFailed
        }
        for (record, entry) in zip(parsed.symbols, layout.entries) {
            guard record.name == entry.name, record.rawType == entry.type,
                  record.sectionIndex == entry.sectionIndex,
                  record.descriptor == entry.descriptor, record.value == entry.value else {
                throw RecoveredSymbolWriterError.validationFailed
            }
        }
    }

    private static func addRelocationOffsets(_ offsets: inout Set<Int>, start: UInt32, count: UInt32) {
        for index in 0..<Int(count) { offsets.insert(Int(start) + index * 8) }
    }

    private static func patchExternalRelocation(_ data: inout Data, at offset: Int,
                                                map: [Int: Int], swapped: Bool) throws {
        let address = try readUInt32(data, at: offset, swapped: swapped)
        guard address & 0x8000_0000 == 0 else { return }
        let info = try readUInt32(data, at: offset + 4, swapped: swapped)
        guard info & 0x0800_0000 != 0 else { return }
        let old = Int(info & 0x00ff_ffff)
        guard let mapped = map[old], mapped < 0x0100_0000 else {
            throw RecoveredSymbolWriterError.unsupportedDynamicIndexLayout
        }
        try patchUInt32(&data, at: offset + 4,
                        value: info & 0xff00_0000 | UInt32(mapped), swapped: swapped)
    }

    private static func remappedContiguousRange(_ range: Range<Int>,
                                                using map: [Int: Int]) throws -> Range<Int> {
        guard let firstOld = range.first, let first = map[firstOld] else {
            throw RecoveredSymbolWriterError.unsupportedDynamicIndexLayout
        }
        for (distance, old) in range.enumerated() where map[old] != first + distance {
            throw RecoveredSymbolWriterError.unsupportedDynamicIndexLayout
        }
        return first..<(first + range.count)
    }

    private static func checkedUInt32(_ value: Int) throws -> UInt32 {
        guard value >= 0, value <= Int(UInt32.max) else {
            throw RecoveredSymbolWriterError.invalidLayout
        }
        return UInt32(value)
    }

    private static func readUInt32(_ data: Data, at offset: Int, swapped: Bool) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw RecoveredSymbolWriterError.invalidLayout
        }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<(offset + 4))
        }
        return swapped ? value.byteSwapped : value
    }

    private static func patchUInt32(_ data: inout Data, at offset: Int,
                                    value: UInt32, swapped: Bool) throws {
        guard offset >= 0, offset <= data.count - 4 else {
            throw RecoveredSymbolWriterError.invalidLayout
        }
        var encoded = swapped ? value.byteSwapped : value
        withUnsafeBytes(of: &encoded) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private static func patchUInt64(_ data: inout Data, at offset: Int,
                                    value: UInt64, swapped: Bool) throws {
        guard offset >= 0, offset <= data.count - 8 else {
            throw RecoveredSymbolWriterError.invalidLayout
        }
        var encoded = swapped ? value.byteSwapped : value
        withUnsafeBytes(of: &encoded) { data.replaceSubrange(offset..<(offset + 8), with: $0) }
    }
}

private extension MachOLoadCommandPayload {
    var symbolTableValue: symtab_command? {
        if case .symbolTable(let value) = self { return value }
        return nil
    }
}

enum RecoveredSymbolInventory {
    private struct Key: Hashable {
        let address: UInt64
        let name: String
    }

    static func build(data: Data, file: MachOFile,
                      dynamicSymbols: MachODynamicSymbolTableModel?,
                      includeMetadata: Bool = false,
                      externalCandidates: [RecoveredSymbolCandidate] = []) -> [RecoveredSymbolCandidate] {
        var candidates = [Key: RecoveredSymbolCandidate]()

        if let dynamicSymbols {
            for symbol in dynamicSymbols.symbols
                where symbol.value != 0 && !symbol.name.isEmpty && symbol.kind != .indirect {
                merge(RecoveredSymbolCandidate(address: symbol.value,
                                               name: symbol.name,
                                               sources: [.symbolTable],
                                               confidence: .exact,
                                               isExternal: symbol.isExternal),
                      into: &candidates)
            }
        }

        if let command = file.firstCommand(ofKind: .exportsTrie),
           case .linkeditData(let payload) = command.payload {
            for item in ExportTrie.parse(data, offset: Int(payload.dataoff), size: Int(payload.datasize)) {
                guard let imageAddress = item.address, !item.name.isEmpty else { continue }
                let address = file.preferredLoadAddress.addingReportingOverflow(imageAddress)
                guard !address.overflow else { continue }
                merge(RecoveredSymbolCandidate(address: address.partialValue,
                                               name: item.name,
                                               sources: [.exportTrie],
                                               confidence: .exact,
                                               isExternal: true),
                      into: &candidates)
            }
        }

        if includeMetadata {
            for candidate in RecoveredMetadataSymbolScanner.objectiveCCandidates(data: data, file: file) {
                merge(candidate, into: &candidates)
            }
        }

        for candidate in externalCandidates {
            merge(candidate, into: &candidates)
        }

        return candidates.values.sorted {
            if $0.address != $1.address { return $0.address < $1.address }
            return $0.name < $1.name
        }
    }

    struct Plan {
        let candidates: [RecoveredSymbolCandidate]
        let existingCount: Int
        let newCount: Int
        let estimatedStringBytes: Int

        var exportOnlyCount: Int {
            candidates.reduce(into: 0) { count, candidate in
                if candidate.sources == [.exportTrie] { count += 1 }
            }
        }
    }

    static func plan(data: Data, file: MachOFile,
                     dynamicSymbols: MachODynamicSymbolTableModel?,
                     externalCandidates: [RecoveredSymbolCandidate] = []) -> Plan {
        let candidates = build(data: data, file: file, dynamicSymbols: dynamicSymbols,
                               includeMetadata: true, externalCandidates: externalCandidates)
        let existing = Set((dynamicSymbols?.symbols ?? []).filter { $0.value != 0 }.map {
            Key(address: $0.value, name: $0.name)
        })
        var existingCount = 0
        var newCount = 0
        var strings = 0
        for candidate in candidates {
            if existing.contains(Key(address: candidate.address, name: candidate.name)) {
                existingCount += 1
            } else {
                newCount += 1
                strings += candidate.name.utf8.count + 1
            }
        }
        return Plan(candidates: candidates,
                    existingCount: existingCount,
                    newCount: newCount,
                    estimatedStringBytes: strings)
    }

    /// Build a validated in-memory layout for the symbol-table writer.
    /// Existing records retain their raw ABI metadata; only proven export and
    /// runtime-metadata candidates are synthesized. No file bytes are changed
    /// by this method.
    static func writeLayout(data: Data, file: MachOFile,
                            dynamicSymbols: MachODynamicSymbolTableModel?,
                            externalCandidates: [RecoveredSymbolCandidate] = []) -> RecoveredSymbolWriteLayout? {
        guard let dynamicSymbols else { return nil }
        var newCandidates = newExportCandidates(data: data, file: file,
                                                dynamicSymbols: dynamicSymbols)
        let existing = { (candidate: RecoveredSymbolCandidate) -> Bool in
            (dynamicSymbols.symbolsByName[candidate.name] ?? []).contains {
                dynamicSymbols.symbols[$0].value == candidate.address
            }
        }
        var metadataKeys = Set(newCandidates.map { Key(address: $0.address, name: $0.name) })
        for candidate in RecoveredMetadataSymbolScanner.objectiveCCandidates(data: data, file: file)
            where !existing(candidate) && metadataKeys.insert(Key(address: candidate.address,
                                                                    name: candidate.name)).inserted {
            newCandidates.append(candidate)
        }
        for candidate in externalCandidates
            where !existing(candidate) && metadataKeys.insert(Key(address: candidate.address,
                                                                    name: candidate.name)).inserted {
            newCandidates.append(candidate)
        }
        newCandidates.sort {
            $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address
        }

        var locals = [RecoveredNListEntry]()
        var external = [RecoveredNListEntry]()
        var undefined = [RecoveredNListEntry]()
        var strings = Data([0])
        var stringOffsets = [String: UInt32](minimumCapacity: dynamicSymbols.symbols.count)

        func offset(for name: String) -> UInt32? {
            if name.isEmpty { return 0 }
            if let value = stringOffsets[name] { return value }
            guard strings.count <= Int(UInt32.max),
                  name.utf8.count < Int(UInt32.max) - strings.count else { return nil }
            let value = UInt32(strings.count)
            strings.append(contentsOf: name.utf8)
            strings.append(0)
            stringOffsets[name] = value
            return value
        }

        for symbol in dynamicSymbols.symbols {
            let value: UInt64
            if symbol.kind == .indirect, let target = symbol.indirectTargetName {
                guard let targetOffset = offset(for: target) else { return nil }
                value = UInt64(targetOffset)
            } else {
                value = symbol.value
            }
            guard let nameOffset = offset(for: symbol.name) else { return nil }
            let entry = RecoveredNListEntry(originalIndex: symbol.index,
                                            name: symbol.name,
                                            stringOffset: nameOffset,
                                            type: symbol.rawType,
                                            sectionIndex: symbol.sectionIndex,
                                            descriptor: symbol.descriptor,
                                            value: value,
                                            isNew: false)
            switch symbol.scope {
            case .local: locals.append(entry)
            case .undefined: undefined.append(entry)
            default: external.append(entry)
            }
        }

        for candidate in newCandidates {
            let section = file.sections.firstIndex { section in
                candidate.address >= section.address && candidate.address - section.address < section.size
            }
            let sectionIndex = section.flatMap { $0 < Int(UInt8.max) ? UInt8($0 + 1) : nil }
            guard let nameOffset = offset(for: candidate.name) else { return nil }
            // restore-symbol2 emitted runtime ObjC discoveries as private
            // externals. Keep that ABI visibility while leaving exports and
            // user-supplied symbols externally visible.
            let visibility = candidate.sources.contains(.objectiveCMetadata) &&
                !candidate.sources.contains(.exportTrie) &&
                !candidate.sources.contains(.externalJSON) ? UInt8(N_PEXT) : UInt8(N_EXT)
            let entry = RecoveredNListEntry(originalIndex: nil,
                                            name: candidate.name,
                                            stringOffset: nameOffset,
                                            type: UInt8(sectionIndex == nil ? N_ABS : N_SECT) | visibility,
                                            sectionIndex: sectionIndex ?? 0,
                                            descriptor: 0,
                                            value: candidate.address,
                                            isNew: true)
            external.append(entry)
        }

        let localRange = 0..<locals.count
        let externalStart = locals.count
        let externalRange = externalStart..<(externalStart + external.count)
        let undefinedStart = externalRange.upperBound
        let undefinedRange = undefinedStart..<(undefinedStart + undefined.count)
        var moduleNameOffsets = [UInt32]()
        moduleNameOffsets.reserveCapacity(dynamicSymbols.modules.count)
        for module in dynamicSymbols.modules {
            guard let nameOffset = offset(for: module.name ?? "") else { return nil }
            moduleNameOffsets.append(nameOffset)
        }
        return RecoveredSymbolWriteLayout(entries: locals + external + undefined,
                                          stringTable: strings,
                                          localRange: localRange,
                                          externalDefinedRange: externalRange,
                                          undefinedRange: undefinedRange,
                                          moduleNameOffsets: moduleNameOffsets,
                                          requiresDynamicSymbolTableRewrite: !newCandidates.isEmpty)
    }

    private static func newExportCandidates(data: Data, file: MachOFile,
                                            dynamicSymbols: MachODynamicSymbolTableModel)
        -> [RecoveredSymbolCandidate] {
        guard let command = file.firstCommand(ofKind: .exportsTrie),
              case .linkeditData(let payload) = command.payload else { return [] }
        var seen = Set<Key>()
        var result = [RecoveredSymbolCandidate]()
        ExportTrie.forEachExport(data, offset: Int(payload.dataoff), size: Int(payload.datasize)) { item in
            guard let imageAddress = item.address, !item.name.isEmpty else { return }
            let address = file.preferredLoadAddress.addingReportingOverflow(imageAddress)
            guard !address.overflow, address.partialValue != 0 else { return }
            let key = Key(address: address.partialValue, name: item.name)
            let alreadyPresent = (dynamicSymbols.symbolsByName[item.name] ?? []).contains {
                dynamicSymbols.symbols[$0].value == address.partialValue
            }
            guard !alreadyPresent, seen.insert(key).inserted else { return }
            result.append(RecoveredSymbolCandidate(address: address.partialValue,
                                                   name: item.name,
                                                   sources: [.exportTrie],
                                                   confidence: .exact,
                                                   isExternal: true))
        }
        return result.sorted {
            $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address
        }
    }

    private static func merge(_ candidate: RecoveredSymbolCandidate,
                              into candidates: inout [Key: RecoveredSymbolCandidate]) {
        let key = Key(address: candidate.address, name: candidate.name)
        guard let existing = candidates[key] else {
            candidates[key] = candidate
            return
        }
        candidates[key] = RecoveredSymbolCandidate(
            address: existing.address,
            name: existing.name,
            sources: existing.sources.union(candidate.sources),
            confidence: max(existing.confidence, candidate.confidence),
            isExternal: existing.isExternal || candidate.isExternal)
    }
}
