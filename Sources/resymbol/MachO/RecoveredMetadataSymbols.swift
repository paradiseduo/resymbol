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

        var candidates = [RecoveredSymbolCandidate]()
        var seen = Set<String>()
        for section in file.sections where section.segmentName.hasPrefix("__DATA") &&
            (section.sectionName.contains("objc_classlist") ||
             section.sectionName.contains("objc_nlclslist")) {
            let count = Int(section.size / 8)
            for index in 0..<count {
                let slot = Int(section.fileOffset) + index * 8
                guard let raw: UInt64 = read(materialized, offset: slot),
                      let classOffset = resolve(raw, resolver: resolver),
                      let classAddress = resolver.vmAddress(forFileOffset: classOffset),
                      classOffset > 0 else { continue }
                let object = ObjcClass.OC(materialized, offset: classOffset)
                guard let classRO = object.classRO else { continue }
                let className = classRO.name.className.value
                guard usableName(className) else { continue }

                append(name: "_OBJC_CLASS_$_\(className)", address: classAddress,
                       seen: &seen, candidates: &candidates)
                appendIvars(classRO.ivars.instanceVariables, className: className,
                            resolver: resolver,
                            seen: &seen, candidates: &candidates)
                if let rawMeta: UInt64 = read(materialized, offset: classOffset),
                   let metaOffset = resolve(rawMeta, resolver: resolver),
                   let metaAddress = resolver.vmAddress(forFileOffset: metaOffset) {
                    append(name: "_OBJC_METACLASS_$_\(className)", address: metaAddress,
                           seen: &seen, candidates: &candidates)
                    let meta = ObjcClass.OC(materialized, offset: metaOffset)
                    appendMethods(meta.classRO?.baseMethod, className: className,
                                  isClass: true, data: materialized, resolver: resolver,
                                  seen: &seen, candidates: &candidates)
                }
                appendMethods(classRO.baseMethod, className: className, isClass: false,
                              data: materialized, resolver: resolver,
                              seen: &seen, candidates: &candidates)
            }
        }

        // Categories are kept in separate pointer lists.  The old
        // class-dump scanner visits them after classes and names methods with
        // the host class plus category (for example -[UIView (Logging) foo]).
        // Keep that ordering and only emit a category when its host class is
        // proven by the class pointer or a recorded dyld bind.
        for section in file.sections where section.segmentName.hasPrefix("__DATA") &&
            (section.sectionName.contains("objc_catlist") ||
             section.sectionName.contains("objc_nlcatlist")) {
            let count = Int(section.size / 8)
            for index in 0..<count {
                let slot = Int(section.fileOffset) + index * 8
                guard let raw: UInt64 = read(materialized, offset: slot),
                      let categoryOffset = resolve(raw, resolver: resolver),
                      categoryOffset > 0, categoryOffset <= materialized.count - 16,
                      let categoryName = cString(materialized, pointer: rawPointer(materialized,
                                                                                     offset: categoryOffset),
                                                  resolver: resolver),
                      usableName(categoryName),
                      let hostName = categoryHostName(materialized, categoryOffset: categoryOffset,
                                                      resolver: resolver),
                      usableName(hostName) else { continue }
                let category = ObjcCategory.OCCG(materialized, offset: categoryOffset)
                appendCategoryMethods(category.instanceMethods, hostName: hostName,
                                      categoryName: categoryName, isClass: false,
                                      data: materialized, resolver: resolver,
                                      seen: &seen, candidates: &candidates)
                appendCategoryMethods(category.classMethods, hostName: hostName,
                                      categoryName: categoryName, isClass: true,
                                      data: materialized, resolver: resolver,
                                      seen: &seen, candidates: &candidates)
            }
        }
        return candidates.sorted {
            $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address
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
