import Foundation

enum ChainedFixups {
    private struct Import {
        let name: String
        let libraryOrdinal: Int
    }

    static func apply(to input: Data, command: MachOLoadCommand, resolver: MachOAddressResolver) -> Data {
        guard case .linkeditData(let payload) = command.payload else { return input }
        var output = input
        let base = Int(payload.dataoff), limit = base + Int(payload.datasize)
        guard limit <= input.count, let version: UInt32 = input.integer(at: base), version == 0,
              let startsOffset: UInt32 = input.integer(at: base + 4),
              let importsOffset: UInt32 = input.integer(at: base + 8),
              let symbolsOffset: UInt32 = input.integer(at: base + 12),
              let importsCount: UInt32 = input.integer(at: base + 16),
              let importsFormat: UInt32 = input.integer(at: base + 20),
              let symbolsFormat: UInt32 = input.integer(at: base + 24) else { return input }
        let imports = symbolsFormat == 0
            ? readImports(input, base: base + Int(importsOffset), count: Int(importsCount),
                          format: importsFormat, symbols: base + Int(symbolsOffset), limit: limit)
            : []
        let starts = base + Int(startsOffset)
        guard let segmentCount: UInt32 = input.integer(at: starts), starts + 4 + Int(segmentCount) * 4 <= limit else { return input }
        for index in 0..<Int(segmentCount) {
            guard let relative: UInt32 = input.integer(at: starts + 4 + index * 4), relative != 0 else { continue }
            let info = starts + Int(relative)
            guard let size: UInt32 = input.integer(at: info), let pageSize: UInt16 = input.integer(at: info + 4), pageSize != 0, let format: UInt16 = input.integer(at: info + 6), let segmentOffset: UInt64 = input.integer(at: info + 8), let pageCount: UInt16 = input.integer(at: info + 20), info + Int(size) <= limit, info + 22 + Int(pageCount) * 2 <= limit else { continue }
            for page in 0..<Int(pageCount) {
                guard let start: UInt16 = input.integer(at: info + 22 + page * 2), start != 0xffff else { continue }
                let process: (UInt16) -> Void = { chainStart in
                    let pageOffset = UInt64(page) * UInt64(pageSize) + UInt64(chainStart)
                    guard let location = resolver.chainedFixupLocation(segmentOffset: segmentOffset, pageOffset: pageOffset) else { return }
                    walk(&output, original: input, fileOffset: location.fileOffset, vmAddress: location.vmAddress, format: format, resolver: resolver, imports: imports)
                }
                if start & 0x8000 == 0 { process(start) }
                else {
                    var overflow = Int(start & 0x7fff)
                    while info + 24 + overflow * 2 <= info + Int(size), let item: UInt16 = input.integer(at: info + 22 + overflow * 2) {
                        process(item & 0x7fff); overflow += 1
                        if item & 0x8000 != 0 { break }
                    }
                }
            }
        }
        return output
    }

    private static func walk(_ output: inout Data, original: Data, fileOffset: Int, vmAddress: UInt64, format: UInt16, resolver: MachOAddressResolver, imports: [Import]) {
        var file = fileOffset, vm = vmAddress, remaining = original.count / 4 + 1
        while remaining > 0, original.count >= 8, file >= 0, file <= original.count - 8, let raw: UInt64 = original.integer(at: file) {
            let value = decode(raw, format: format, resolver: resolver)
            if let ordinal = value.ordinal, ordinal < imports.count,
               let imageOffset = resolver.imageOffset(forVMAddress: vm) {
                let chainedImport = imports[ordinal]
                MachOData.shared.recordBoundSymbol(key: String(imageOffset, radix: 16),
                                                   name: chainedImport.name,
                                                   libraryOrdinal: chainedImport.libraryOrdinal)
            } else if let target = value.target {
                output.replaceSubrange(file..<(file + 8), with: target.bytes)
            }
            guard value.next != 0 else { break }
            let delta = value.next * value.stride
            let (nextFile, fileOverflow) = file.addingReportingOverflow(delta)
            let (nextVM, vmOverflow) = vm.addingReportingOverflow(UInt64(delta))
            guard !fileOverflow, !vmOverflow else { break }
            file = nextFile; vm = nextVM; remaining -= 1
        }
    }

    static func decode(_ raw: UInt64, format: UInt16,
                       resolver: MachOAddressResolver) -> (target: UInt64?, ordinal: Int?, next: Int, stride: Int) {
        switch format {
        case 1, 7, 9, 10, 12:
            let next = Int((raw >> 51) & 0x7ff)
            let stride = (format == 7 || format == 10) ? 4 : 8
            let ordinalMask: UInt64 = format == 12 ? 0x00ff_ffff : 0xffff
            if raw & (1 << 62) != 0 { return (nil, Int(raw & ordinalMask), next, stride) }
            if raw & (1 << 63) != 0 {
                return (resolver.chainedRebaseTarget(raw & 0xffff_ffff, domain: .imageRelative),
                        nil, next, stride)
            }
            let target = raw & 0x0000_07ff_ffff_ffff
            let high8 = UInt8((raw >> 43) & 0xff)
            if format == 7 || format == 9 || format == 12 {
                return (resolver.chainedRebaseTarget(target, high8: high8, domain: .imageRelative),
                        nil, next, stride)
            }
            return (resolver.chainedRebaseTarget(target, high8: high8, domain: .absoluteVM),
                    nil, next, stride)
        case 2, 6:
            let next = Int((raw >> 51) & 0xfff)
            if raw & (1 << 63) != 0 { return (nil, Int(raw & 0x00ff_ffff), next, 4) }
            let target = raw & 0x0000_000f_ffff_ffff
            let high8 = UInt8((raw >> 36) & 0xff)
            let domain: MachOAddressDomain = format == 6 ? .imageRelative : .absoluteVM
            return (resolver.chainedRebaseTarget(target, high8: high8, domain: domain), nil, next, 4)
        default: return (nil, nil, 0, 4)
        }
    }

    private static func readImports(_ data: Data, base: Int, count: Int, format: UInt32, symbols: Int, limit: Int) -> [Import] {
        let stride = format == 1 ? 4 : (format == 2 ? 8 : 16)
        guard (1...3).contains(format), base + count * stride <= limit else { return [] }
        return (0..<count).map { index in
            let nameOffset: UInt32
            let libraryOrdinal: Int
            if format == 3, let value: UInt64 = data.integer(at: base + index * stride) {
                nameOffset = UInt32(value >> 32)
                libraryOrdinal = Int(Int16(bitPattern: UInt16(value & 0xffff)))
            } else if let value: UInt32 = data.integer(at: base + index * stride) {
                nameOffset = value >> 9
                libraryOrdinal = Int(Int8(bitPattern: UInt8(value & 0xff)))
            } else {
                return Import(name: "", libraryOrdinal: 0)
            }
            return Import(name: data.cString(at: symbols + Int(nameOffset), limit: limit) ?? "",
                          libraryOrdinal: libraryOrdinal)
        }
    }
}

private extension Data {
    func integer<T: FixedWidthInteger>(at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<offset + MemoryLayout<T>.size) }
        return T(littleEndian: value)
    }
    func cString(at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < Swift.min(limit, count) else { return nil }
        let end = self[offset..<Swift.min(limit, count)].firstIndex(of: 0) ?? Swift.min(limit, count)
        return String(data: self[offset..<end], encoding: .utf8)
    }
}
private extension UInt64 { var bytes: [UInt8] { var value = littleEndian; return Swift.withUnsafeBytes(of: &value) { Array($0) } } }
