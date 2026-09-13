import Foundation

/// Extracts symbol candidates from Objective-C runtime metadata without
/// printing or retaining the parsed class graph. This is the Swift equivalent
/// of restore-symbol2's RSSymbolCollector/RSScanMethodVisitor path.
enum RecoveredMetadataSymbolScanner {
    static func objectiveCCandidates(data: Data, file: MachOFile) -> [RecoveredSymbolCandidate] {
        guard !file.sections.isEmpty else { return [] }
        let resolver = MachOAddressResolver(file: file, data: data)
        // ObjcClass/Methods are the existing, bounds-checked metadata models.
        // Configure the shared compatibility context for their pointer fields;
        // no parser output or global symbol index is produced here.
        MachOData.shared.reset()
        MachOData.shared.binary = data
        MachOData.shared.originalBinary = data
        MachOData.shared.machOFile = file
        MachOData.shared.segments = file.segments.map {
            MachOSegmentInfo(vmaddr: $0.vmaddr, vmsize: $0.vmsize,
                             fileoff: $0.fileoff, filesize: $0.filesize)
        }
        defer { MachOData.shared.reset() }

        // Materialization records external bind names in MachOData, so it must
        // happen after the compatibility context is installed and before the
        // metadata models consume the rewritten pointer slots.
        let materialized: Data
        if let command = file.firstCommand(ofKind: .chainedFixups) {
            materialized = ChainedFixups.apply(to: data, command: command, resolver: resolver)
        } else {
            materialized = data
        }
        MachOData.shared.binary = materialized

        // The compatibility models above are intentionally retained for the
        // legacy Section pipeline.  Recovery, however, only needs a small
        // subset of the runtime records.  Reading those records directly
        // avoids constructing thousands of short-lived DataStruct/Methods
        // values for every class in a large image.
        var lightweightReader = LightweightObjCReader(data: materialized, file: file,
                                                       resolver: resolver)
        return lightweightReader.collect()

    }

    private struct LightweightObjCReader {
        let data: Data
        let file: MachOFile
        let resolver: MachOAddressResolver
        var pointerCache = [UInt64: Int?]()
        var stringCache = [Int: String?]()
        var seen = Set<String>()
        var candidates = [RecoveredSymbolCandidate]()

        mutating func collect() -> [RecoveredSymbolCandidate] {
            for section in file.sections where section.segmentName.hasPrefix("__DATA") &&
                (section.sectionName.contains("objc_classlist") || section.sectionName.contains("objc_nlclslist")) {
                let count = Int(section.size / 8)
                for index in 0..<count {
                    guard let slot = checkedOffset(section.fileOffset, adding: index * 8),
                          let raw = read64(slot), let classOffset = pointer(raw),
                          classOffset > 0, classOffset <= data.count - 64,
                          let classAddress = resolver.vmAddress(forFileOffset: classOffset),
                          let classInfo = classRecord(classOffset) else { continue }
                    append(name: "_OBJC_CLASS_$_\(classInfo.name)", address: classAddress)
                    appendIvars(classInfo.ivarList, className: classInfo.name)
                    if let isa = read64(classOffset), let metaOffset = pointer(isa),
                       metaOffset > 0, metaOffset <= data.count - 64,
                       let metaAddress = resolver.vmAddress(forFileOffset: metaOffset) {
                        append(name: "_OBJC_METACLASS_$_\(classInfo.name)", address: metaAddress)
                        if let meta = classRecord(metaOffset) { appendMethods(meta.methodList, className: classInfo.name, isClass: true) }
                    }
                    appendMethods(classInfo.methodList, className: classInfo.name, isClass: false)
                }
            }
            for section in file.sections where section.segmentName.hasPrefix("__DATA") &&
                (section.sectionName.contains("objc_catlist") || section.sectionName.contains("objc_nlcatlist")) {
                let count = Int(section.size / 8)
                for index in 0..<count {
                    guard let slot = checkedOffset(section.fileOffset, adding: index * 8),
                          let raw = read64(slot), let categoryOffset = pointer(raw),
                          categoryOffset > 0, categoryOffset <= data.count - 56,
                          let categoryName = string(pointer(read64(categoryOffset)), demangle: false),
                          usableName(categoryName), let hostName = categoryHostName(categoryOffset),
                          usableName(hostName) else { continue }
                    appendCategoryMethods(listPointer: read64(categoryOffset + 16), hostName: hostName, categoryName: categoryName, isClass: false)
                    appendCategoryMethods(listPointer: read64(categoryOffset + 24), hostName: hostName, categoryName: categoryName, isClass: true)
                }
            }
            return candidates.sorted { $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address }
        }

        func checkedOffset(_ base: UInt32, adding: Int) -> Int? {
            let value = Int(base) + adding
            return value >= 0 && value <= data.count ? value : nil
        }

        func read32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        func read64(_ offset: Int) -> UInt64? {
            guard offset >= 0, offset <= data.count - 8 else { return nil }
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(data[offset + i]) << UInt64(i * 8) }
            return value
        }

        mutating func pointer(_ raw: UInt64?) -> Int? {
            guard let raw, raw != 0 else { return nil }
            if let cached = pointerCache[raw] { return cached }
            let result = resolver.resolveAbsolutePointer(raw, format: .arm64eAuthenticated) ?? resolver.resolveAbsolutePointer(raw)
            pointerCache[raw] = result
            return result
        }

        mutating func resolveRelative(_ field: Int, _ raw: UInt32) -> Int? {
            resolver.resolveRelativePointer(fieldOffset: field, raw: raw)
        }

        struct ClassInfo { let name: String; let methodList: Int?; let ivarList: Int? }

        mutating func classRecord(_ offset: Int) -> ClassInfo? {
            guard let classData = read64(offset + 32) else { return nil }
            let swift = classData & 1 != 0
            guard let roOffset = pointer(classData & ~UInt64(7)), roOffset > 0,
                  roOffset <= data.count - 72,
                  let namePointer = read64(roOffset + 24),
                  let name = string(pointer(namePointer), demangle: swift), usableName(name) else { return nil }
            return ClassInfo(name: name, methodList: pointer(read64(roOffset + 32)), ivarList: pointer(read64(roOffset + 48)))
        }

        mutating func string(_ offset: Int?, demangle: Bool) -> String? {
            guard let offset, offset >= 0, offset < data.count else { return nil }
            if let cached = stringCache[offset] { return cached }
            var end = offset
            while end < data.count && data[end] != 0 && end - offset < 4096 { end += 1 }
            guard end > offset, let raw = String(data: data[offset..<end], encoding: .utf8), !raw.isEmpty else {
                stringCache[offset] = nil; return nil
            }
            let value = demangle ? (swift_demangle(raw) ?? raw) : raw
            stringCache[offset] = value
            return value
        }

        mutating func appendIvars(_ list: Int?, className: String) {
            guard let list, let stride = read32(list), let countRaw = read32(list + 4), stride >= 32 else { return }
            let count = min(Int(countRaw), max(0, (data.count - min(data.count, list + 8)) / Int(stride)))
            for i in 0..<count {
                let offset = list + 8 + i * Int(stride)
                guard let storage = pointer(read64(offset)), let name = string(pointer(read64(offset + 8)), demangle: false),
                      usableName(name), let address = resolver.vmAddress(forFileOffset: storage),
                      file.sections.contains(where: { $0.sectionName == "__objc_ivar" && storage >= Int($0.fileOffset) && UInt64(storage - Int($0.fileOffset)) < $0.size }) else { continue }
                append(name: "_OBJC_IVAR_$_\(className).\(name)", address: address)
            }
        }

        mutating func appendMethods(_ list: Int?, className: String, isClass: Bool) {
            guard let list else { return }
            appendMethodList(list, className: className, categoryName: nil, isClass: isClass)
        }

        mutating func appendCategoryMethods(listPointer: UInt64?, hostName: String, categoryName: String, isClass: Bool) {
            guard let listPointer, let list = pointer(listPointer) else { return }
            appendMethodList(list, className: hostName, categoryName: categoryName, isClass: isClass)
        }

        mutating func appendMethodList(_ list: Int, className: String, categoryName: String?, isClass: Bool) {
            guard let header = read32(list), let countRaw = read32(list + 4) else { return }
            let relative = header & 0x8000_0000 != 0, direct = header & 0x4000_0000 != 0
            let stride = relative ? 12 : 24
            let count = min(Int(countRaw), max(0, (data.count - min(data.count, list + 8)) / stride))
            for i in 0..<count {
                let entry = list + 8 + i * stride
                let selectorOffset: Int?
                let implementation: Int?
                if relative {
                    guard let nameRaw = read32(entry), let nameTarget = resolveRelative(entry, nameRaw) else { continue }
                    selectorOffset = direct ? nameTarget : pointer(read64(nameTarget))
                    guard let impRaw = read32(entry + 8), let impTarget = resolveRelative(entry + 8, impRaw) else { continue }
                    implementation = impTarget
                } else {
                    selectorOffset = pointer(read64(entry))
                    implementation = pointer(read64(entry + 16))
                }
                guard let selector = string(selectorOffset, demangle: false), usableName(selector),
                      let implementation, let address = resolver.vmAddress(forFileOffset: implementation), isExecutableAddress(address) else { continue }
                let prefix = isClass ? "+" : "-"
                let owner = categoryName.map { "\(className)(\($0))" } ?? className
                append(name: "\(prefix)[\(owner) \(selector)]", address: address)
            }
        }

        mutating func categoryHostName(_ offset: Int) -> String? {
            guard let raw = read64(offset + 8), raw != 0, let classOffset = pointer(raw),
                  classOffset > 0, let info = classRecord(classOffset) else {
                guard let fieldVM = resolver.vmAddress(forFileOffset: offset + 8), let imageOffset = resolver.imageOffset(forVMAddress: fieldVM) else { return nil }
                let key = String(imageOffset, radix: 16)
                let bound = MachOData.shared.boundSymbols[key]?.name ?? MachOData.shared.dylbMap[key]
                for prefix in ["_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"] where bound?.hasPrefix(prefix) == true { return String(bound!.dropFirst(prefix.count)) }
                return nil
            }
            return info.name
        }

        func isExecutableAddress(_ address: UInt64) -> Bool {
            file.sections.contains { $0.segmentName == "__TEXT" && address >= $0.address && address - $0.address < $0.size && ($0.sectionName == "__text" || $0.sectionName.contains("stub")) }
        }

        mutating func append(name: String, address: UInt64) {
            let key = "\(address)|\(name)"
            guard seen.insert(key).inserted else { return }
            candidates.append(RecoveredSymbolCandidate(address: address, name: name, sources: [.objectiveCMetadata], confidence: .exact, isExternal: true))
        }
    }

    /// ObjC ivar symbols point at the ivar offset-storage slot in the
    /// metadata record, not at an instance's runtime address. That slot is
    /// present in the file and therefore provides exact symbol evidence.
    private static func appendIvars(_ ivars: [InstanceVariable]?, className: String,
                                    resolver: MachOAddressResolver,
                                    seen: inout Set<String>,
                                    candidates: inout [RecoveredSymbolCandidate]) {
        guard let ivars else { return }
        for ivar in ivars {
            let name = ivar.name.instanceVariableName.value
            guard usableName(name), let raw = UInt64(ivar.offset.value, radix: 16), raw != 0,
                  let targetOffset = resolve(raw, resolver: resolver),
                  targetOffset > 0,
                  resolver.file.sections.contains(where: {
                      $0.sectionName == "__objc_ivar" &&
                      UInt64(targetOffset) >= UInt64($0.fileOffset) &&
                      UInt64(targetOffset) - UInt64($0.fileOffset) < $0.size
                  }),
                  let address = resolver.vmAddress(forFileOffset: targetOffset) else { continue }
            append(name: "_OBJC_IVAR_$_\(className).\(name)", address: address,
                   seen: &seen, candidates: &candidates)
        }
    }

    private static func appendMethods(_ methods: Methods?, className: String, isClass: Bool,
                                      data: Data, resolver: MachOAddressResolver,
                                      seen: inout Set<String>,
                                      candidates: inout [RecoveredSymbolCandidate]) {
        guard let methods, let values = methods.methods else { return }
        let header = methods.elementSize.flatMap { UInt32($0.value, radix: 16) } ?? 0
        let relative = header & 0x8000_0000 != 0
        let directSelectors = header & 0x4000_0000 != 0
        for method in values {
            let selector = selectorName(method, relative: relative, directSelectors: directSelectors,
                                        data: data, resolver: resolver)
            guard usableName(selector), let address = implementationAddress(
                method.implementation, relative: relative, data: data, resolver: resolver),
                  isExecutableAddress(address, resolver: resolver) else { continue }
            let prefix = isClass ? "+" : "-"
            append(name: "\(prefix)[\(className) \(selector)]", address: address,
                   seen: &seen, candidates: &candidates)
        }
    }

    private static func implementationAddress(_ implementation: DataStruct, relative: Bool,
                                              data: Data, resolver: MachOAddressResolver) -> UInt64? {
        guard let raw = UInt64(implementation.value, radix: 16), raw != 0 else { return nil }
        if relative, let field = Int(implementation.address, radix: 16),
           let target = resolver.resolveRelativePointer(fieldOffset: field,
                                                         raw: UInt32(truncatingIfNeeded: raw)) {
            return resolver.vmAddress(forFileOffset: target)
        }
        guard let offset = resolver.resolveAbsolutePointer(raw, format: .arm64eAuthenticated) else {
            return nil
        }
        return resolver.vmAddress(forFileOffset: offset)
    }

    private static func isExecutableAddress(_ address: UInt64,
                                            resolver: MachOAddressResolver) -> Bool {
        resolver.file.sections.contains { section in
            guard section.segmentName == "__TEXT", address >= section.address,
                  address - section.address < section.size else { return false }
            return section.sectionName == "__text" || section.sectionName.contains("stub")
        }
    }

    private static func appendCategoryMethods(_ methods: Methods, hostName: String,
                                              categoryName: String, isClass: Bool,
                                              data: Data, resolver: MachOAddressResolver,
                                              seen: inout Set<String>,
                                              candidates: inout [RecoveredSymbolCandidate]) {
        guard let values = methods.methods else { return }
        let header = methods.elementSize.flatMap { UInt32($0.value, radix: 16) } ?? 0
        let relative = header & 0x8000_0000 != 0
        let directSelectors = header & 0x4000_0000 != 0
        for method in values {
            let selector = selectorName(method, relative: relative, directSelectors: directSelectors,
                                        data: data, resolver: resolver)
            guard usableName(selector), let address = implementationAddress(
                method.implementation, relative: relative, data: data, resolver: resolver),
                  isExecutableAddress(address, resolver: resolver) else { continue }
            let prefix = isClass ? "+" : "-"
            append(name: "\(prefix)[\(hostName)(\(categoryName)) \(selector)]",
                   address: address, seen: &seen, candidates: &candidates)
        }
    }

    /// DataStruct.textData intentionally has a small display bound. Symbol
    /// recovery must not inherit that bound because ObjC selectors in large
    /// production images can exceed 256 bytes.
    private static func selectorName(_ method: Method, relative: Bool,
                                     directSelectors: Bool, data: Data,
                                     resolver: MachOAddressResolver) -> String {
        let raw = UInt64(method.name.name.value, radix: 16) ?? 0
        let offset: Int?
        if relative {
            guard let field = Int(method.name.name.address, radix: 16),
                  let relativeTarget = resolver.resolveRelativePointer(
                    fieldOffset: field, raw: UInt32(truncatingIfNeeded: raw)) else {
                return method.name.methodName.value
            }
            if directSelectors {
                offset = relativeTarget
            } else if let indirect: UInt64 = read(data, offset: relativeTarget) {
                offset = resolve(indirect, resolver: resolver)
            } else {
                offset = nil
            }
        } else {
            offset = resolve(raw, resolver: resolver)
        }
        guard let offset, offset >= 0, offset < data.count else {
            return method.name.methodName.value
        }
        let end = data[offset..<data.count].firstIndex(of: 0) ?? data.count
        return String(data: data[offset..<end], encoding: .utf8) ?? method.name.methodName.value
    }

    private static func categoryHostName(_ data: Data, categoryOffset: Int,
                                         resolver: MachOAddressResolver) -> String? {
        guard let raw: UInt64 = read(data, offset: categoryOffset + 8), raw != 0 else { return nil }
        if let classOffset = resolve(raw, resolver: resolver), classOffset > 0,
           classOffset <= data.count - 64 {
            let object = ObjcClass.OC(data, offset: classOffset)
            let name = object.classRO?.name.className.value
            if let name, usableName(name) { return name }
        }

        // External hosts are commonly represented by a bind slot rather than
        // a class object in the file.  ChainedFixups/Dyld record the imported
        // symbol at the slot's image-relative address.
        guard let fieldVM = resolver.vmAddress(forFileOffset: categoryOffset + 8),
              let imageOffset = resolver.imageOffset(forVMAddress: fieldVM) else { return nil }
        let key = String(imageOffset, radix: 16)
        let bound = MachOData.shared.boundSymbols[key]?.name ?? MachOData.shared.dylbMap[key]
        guard let bound else { return nil }
        let prefixes = ["_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"]
        for prefix in prefixes where bound.hasPrefix(prefix) {
            let value = String(bound.dropFirst(prefix.count))
            return usableName(value) ? value : nil
        }
        return nil
    }

    private static func rawPointer(_ data: Data, offset: Int) -> UInt64 {
        read(data, offset: offset) ?? 0
    }

    private static func cString(_ data: Data, pointer: UInt64, resolver: MachOAddressResolver) -> String? {
        guard let offset = resolve(pointer, resolver: resolver), offset >= 0, offset < data.count else { return nil }
        let end = data[offset..<data.count].firstIndex(of: 0) ?? data.count
        return String(data: data[offset..<end], encoding: .utf8)
    }

    private static func append(name: String, address: UInt64, seen: inout Set<String>,
                               candidates: inout [RecoveredSymbolCandidate]) {
        let key = "\(address)|\(name)"
        guard seen.insert(key).inserted else { return }
        candidates.append(RecoveredSymbolCandidate(address: address, name: name,
                                                   sources: [.objectiveCMetadata],
                                                   confidence: .exact, isExternal: true))
    }

    private static func usableName(_ value: String) -> Bool {
        !value.isEmpty && value != None && !value.contains("MISSING_TYPE") &&
            value.utf8.count < 4096
    }

    private static func resolve(_ raw: UInt64, resolver: MachOAddressResolver) -> Int? {
        resolver.resolveAbsolutePointer(raw, format: .arm64eAuthenticated) ??
            resolver.resolveAbsolutePointer(raw)
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T? {
        guard offset >= 0, offset <= data.count - MemoryLayout<T>.size else { return nil }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return value
    }
}
