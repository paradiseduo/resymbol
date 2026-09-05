import Foundation

enum ExportTrie {
    struct Export {
        let name: String
        let flags: UInt64
        let address: UInt64?
        let resolver: UInt64?
        let reexportOrdinal: UInt64?
        let importedName: String?
    }

    private static let reexportFlag: UInt64 = 0x08
    private static let stubAndResolverFlag: UInt64 = 0x10

    static func parse(_ data: Data, offset: Int, size: Int) -> [Export] {
        guard offset >= 0, size >= 0, offset <= data.count,
              size <= data.count - offset else { return [] }
        let end = offset + size
        var exports = [Export]()
        var stack: [(node: Int, prefix: String)] = [(offset, "")]
        var visited = Set<NodeKey>()

        while let current = stack.popLast() {
            let key = NodeKey(offset: current.node, prefix: current.prefix)
            guard current.node >= offset, current.node < end, visited.insert(key).inserted else { continue }
            var cursor = current.node
            guard let terminalSize = readULEB(data, cursor: &cursor, end: end),
                  terminalSize <= UInt64(end - cursor) else { continue }
            let terminalEnd = cursor + Int(terminalSize)

            if terminalSize != 0, let flags = readULEB(data, cursor: &cursor, end: terminalEnd) {
                if flags & reexportFlag != 0 {
                    guard let ordinal = readULEB(data, cursor: &cursor, end: terminalEnd),
                          let imported = readCString(data, cursor: &cursor, end: terminalEnd) else { continue }
                    exports.append(Export(name: current.prefix, flags: flags, address: nil,
                                          resolver: nil, reexportOrdinal: ordinal,
                                          importedName: imported.isEmpty ? current.prefix : imported))
                } else if let address = readULEB(data, cursor: &cursor, end: terminalEnd) {
                    var resolver: UInt64?
                    if flags & stubAndResolverFlag != 0 {
                        resolver = readULEB(data, cursor: &cursor, end: terminalEnd)
                    }
                    exports.append(Export(name: current.prefix, flags: flags, address: address,
                                          resolver: resolver, reexportOrdinal: nil, importedName: nil))
                }
            }

            cursor = terminalEnd
            guard cursor < end else { continue }
            let childCount = Int(data[cursor])
            cursor += 1
            for _ in 0..<childCount {
                guard let edge = readCString(data, cursor: &cursor, end: end),
                      let childOffset = readULEB(data, cursor: &cursor, end: end),
                      childOffset < UInt64(size) else { break }
                stack.append((offset + Int(childOffset), current.prefix + edge))
            }
        }
        return exports
    }

    static func apply(_ data: Data, commandOffset: Int) {
        guard let dataOffset: UInt32 = integer(data, at: commandOffset + 8),
              let dataSize: UInt32 = integer(data, at: commandOffset + 12) else { return }
        for item in parse(data, offset: Int(dataOffset), size: Int(dataSize)) {
            if let address = item.address {
                MachOData.shared.dylbMap[String(address, radix: 16)] = item.name
            }
            if let resolver = item.resolver {
                MachOData.shared.dylbMap[String(resolver, radix: 16)] = item.name
            }
        }
    }

    private struct NodeKey: Hashable { let offset: Int; let prefix: String }

    private static func readULEB(_ data: Data, cursor: inout Int, end: Int) -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while cursor < end, shift < 64 {
            let byte = data[cursor]
            cursor += 1
            let payload = UInt64(byte & 0x7f)
            guard shift < 64, payload <= (UInt64.max >> shift) else { return nil }
            result |= payload << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private static func readCString(_ data: Data, cursor: inout Int, end: Int) -> String? {
        guard cursor >= 0, cursor < end else { return nil }
        let start = cursor
        while cursor < end, data[cursor] != 0 { cursor += 1 }
        guard cursor < end else { return nil }
        defer { cursor += 1 }
        return String(data: data[start..<cursor], encoding: .utf8)
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
