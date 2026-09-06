import Foundation
import MachO

struct MachOArchitecture {
    let cpuType: Int32
    let cpuSubtype: Int32
    let offset: UInt64
    let size: UInt64
    let align: UInt32
    let name: String
    // A Data slice shares the original storage; materialize only the selected
    // architecture before handing it to the thin Mach-O parser.
    let data: Data.SubSequence
}

enum MachOFat {
    static func isFat(_ data: Data) -> Bool {
        guard data.count >= MemoryLayout<UInt32>.size else { return false }
        let magic = data.extract(UInt32.self)
        return magic == FAT_MAGIC || magic == FAT_CIGAM ||
            magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64
    }

    static func architectures(in data: Data) -> [MachOArchitecture]? {
        guard data.count >= MemoryLayout<fat_header>.size else { return nil }
        let magic = data.extract(UInt32.self)
        let is64 = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64
        let swapped = magic == FAT_CIGAM || magic == FAT_CIGAM_64
        guard isFat(data) else { return nil }
        var header = data.extract(fat_header.self)
        if swapped { swap_fat_header(&header, byteSwappedOrder) }
        let count = UInt64(header.nfat_arch)
        let entrySize = UInt64(is64 ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size)
        let tableSize = count.multipliedReportingOverflow(by: entrySize)
        guard !tableSize.overflow,
              UInt64(MemoryLayout<fat_header>.size) + tableSize.partialValue <= UInt64(data.count) else { return nil }

        var result = [MachOArchitecture]()
        result.reserveCapacity(Int(min(count, 1024)))
        for index in 0..<count {
            let entryOffset = MemoryLayout<fat_header>.size + Int(index * entrySize)
            let cpuType: Int32
            let cpuSubtype: Int32
            let offset: UInt64
            let size: UInt64
            let align: UInt32
            if is64 {
                var arch = data.extract(fat_arch_64.self, offset: entryOffset)
                if swapped { swap_fat_arch_64(&arch, 1, byteSwappedOrder) }
                cpuType = arch.cputype
                cpuSubtype = arch.cpusubtype
                offset = arch.offset
                size = arch.size
                align = arch.align
            } else {
                var arch = data.extract(fat_arch.self, offset: entryOffset)
                if swapped { swap_fat_arch(&arch, 1, byteSwappedOrder) }
                cpuType = arch.cputype
                cpuSubtype = arch.cpusubtype
                offset = UInt64(arch.offset)
                size = UInt64(arch.size)
                align = arch.align
            }
            guard offset <= UInt64(data.count), size <= UInt64(data.count) - offset,
                  offset <= UInt64(Int.max), size <= UInt64(Int.max) else { return nil }
            let start = Int(offset)
            let end = start + Int(size)
            guard end >= start else { return nil }
            let slice = data[start..<end]
            result.append(MachOArchitecture(cpuType: cpuType, cpuSubtype: cpuSubtype,
                                             offset: offset, size: size, align: align,
                                             name: architectureName(cpuType: cpuType, subtype: cpuSubtype),
                                             data: slice))
        }
        return result
    }

    static func select(_ architectures: [MachOArchitecture], name: String?) -> MachOArchitecture? {
        if let name {
            let normalized = name.lowercased()
            return architectures.first { architecture in
                architecture.name.lowercased() == normalized ||
                    (normalized == "arm64" && architecture.cpuType == CPU_TYPE_ARM64) ||
                    (normalized == "arm64e" && architecture.cpuSubtype == CPU_SUBTYPE_ARM64E)
            }
        }
        return architectures.first { $0.cpuType == CPU_TYPE_ARM64 } ?? architectures.first
    }

    private static func architectureName(cpuType: Int32, subtype: Int32) -> String {
        switch cpuType {
        case CPU_TYPE_ARM64:
            return subtype == CPU_SUBTYPE_ARM64E ? "arm64e" : "arm64"
        case CPU_TYPE_X86_64:
            return "x86_64"
        case CPU_TYPE_ARM:
            return "armv7"
        case CPU_TYPE_I386:
            return "i386"
        default:
            return "cpu\(cpuType)"
        }
    }
}
