import Foundation

enum ChainedFixups {
    struct Segment { let vmaddr: UInt64; let fileoff: UInt64 }

    static func apply(to input: Data, commandOffset: Int, segments: [Segment]) -> Data {
        var output = input
        guard let dataoff: UInt32 = input.integer(at: commandOffset + 8), let datasize: UInt32 = input.integer(at: commandOffset + 12) else { return input }
        let base = Int(dataoff), limit = base + Int(datasize)
        guard limit <= input.count, let startsOffset: UInt32 = input.integer(at: base + 4), let importsOffset: UInt32 = input.integer(at: base + 8), let symbolsOffset: UInt32 = input.integer(at: base + 12), let importsCount: UInt32 = input.integer(at: base + 16), let importsFormat: UInt32 = input.integer(at: base + 20) else { return input }
        let imports = readImports(input, base: base + Int(importsOffset), count: Int(importsCount), format: importsFormat, symbols: base + Int(symbolsOffset), limit: limit)
        let starts = base + Int(startsOffset)
        guard let segmentCount: UInt32 = input.integer(at: starts), starts + 4 + Int(segmentCount) * 4 <= limit else { return input }
        let imageBase = segments.first?.vmaddr ?? RVA
        for index in 0..<min(Int(segmentCount), segments.count) {
            guard let relative: UInt32 = input.integer(at: starts + 4 + index * 4), relative != 0 else { continue }
            let info = starts + Int(relative)
            guard let size: UInt32 = input.integer(at: info), let pageSize: UInt16 = input.integer(at: info + 4), let format: UInt16 = input.integer(at: info + 6), let pageCount: UInt16 = input.integer(at: info + 20), info + Int(size) <= limit, info + 22 + Int(pageCount) * 2 <= limit else { continue }
            for page in 0..<Int(pageCount) {
                guard let start: UInt16 = input.integer(at: info + 22 + page * 2), start != 0xffff else { continue }
                let process: (UInt16) -> Void = { chainStart in
                    walk(&output, original: input, fileOffset: segments[index].fileoff + UInt64(page) * UInt64(pageSize) + UInt64(chainStart), vmOffset: segments[index].vmaddr - imageBase + UInt64(page) * UInt64(pageSize) + UInt64(chainStart), format: format, imageBase: imageBase, imports: imports)
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

    private static func walk(_ output: inout Data, original: Data, fileOffset: UInt64, vmOffset: UInt64, format: UInt16, imageBase: UInt64, imports: [String]) {
        var file = fileOffset, vm = vmOffset, remaining = original.count / 4 + 1
        while remaining > 0, file <= UInt64(original.count - 8), let raw: UInt64 = original.integer(at: Int(file)) {
            let value = decode(raw, format: format, imageBase: imageBase)
            if let ordinal = value.ordinal, ordinal < imports.count { MachOData.shared.dylbMap[String(vm, radix: 16)] = imports[ordinal] }
            else if let target = value.target { output.replaceSubrange(Int(file)..<Int(file + 8), with: target.bytes) }
            guard value.next != 0 else { break }
            let delta = UInt64(value.next * value.stride); file += delta; vm += delta; remaining -= 1
        }
    }

    static func decode(_ raw: UInt64, format: UInt16, imageBase: UInt64) -> (target: UInt64?, ordinal: Int?, next: Int, stride: Int) {
        switch format {
        case 1, 7, 9, 10, 12:
            let next = Int((raw >> 51) & 0x7ff), stride = (format == 7 || format == 10) ? 4 : 8
            if raw >> 62 & 1 != 0 { return (nil, Int(raw & (format == 12 ? 0x00ff_ffff : 0xffff)), next, stride) }
            let offset = raw >> 63 != 0 ? raw & 0xffff_ffff : raw & 0x0000_07ff_ffff_ffff
            return ((format == 1 || format == 10 ? 0 : imageBase) &+ offset, nil, next, stride)
        case 2, 6:
            let next = Int((raw >> 51) & 0xfff)
            if raw >> 63 != 0 { return (nil, Int(raw & 0x00ff_ffff), next, 4) }
            let target = (raw & 0x0000_000f_ffff_ffff) | ((raw << 13) & 0xff00_0000_0000_0000)
            return ((format == 6 ? imageBase : 0) &+ target, nil, next, 4)
        default: return (nil, nil, 0, 4)
        }
    }

    private static func readImports(_ data: Data, base: Int, count: Int, format: UInt32, symbols: Int, limit: Int) -> [String] {
        let stride = format == 1 ? 4 : (format == 2 ? 8 : 16)
        guard (1...3).contains(format), base + count * stride <= limit else { return [] }
        return (0..<count).map { index in
            let nameOffset: UInt32
            if format == 3, let value: UInt64 = data.integer(at: base + index * stride) { nameOffset = UInt32(value >> 32) }
            else if let value: UInt32 = data.integer(at: base + index * stride) { nameOffset = value >> 9 }
            else { return "" }
            return data.cString(at: symbols + Int(nameOffset), limit: limit) ?? ""
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
