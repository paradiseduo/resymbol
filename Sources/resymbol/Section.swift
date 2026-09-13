//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/9/10.
//

import Foundation
import MachO

let byteSwappedOrder = NXByteOrder(rawValue: 0)

let queueWait = DispatchQueue(label: "com.Wait", qos: .userInteractive, attributes: [], autoreleaseFrequency: .inherit, target: nil)

// 先进行dyld绑定和protocol的dump
let dyldGroup = DispatchGroup()
let queueDyld = DispatchQueue(label: "com.Dyld", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueStringTable = DispatchQueue(label: "com.String.Table", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSwiftRef = DispatchQueue(label: "com.Swift.Ref", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueProtocol = DispatchQueue(label: "com.Protocol", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSwiftProtocols = DispatchQueue(label: "com.Swift.Protocols", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)

// 再进行class的dump，因为superclass依赖dyld的绑定结果和protocol
let symbolGroup = DispatchGroup()
let queueSymbol = DispatchQueue(label: "com.Symbol", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueClass = DispatchQueue(label: "com.Class", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSwiftProtocol = DispatchQueue(label: "com.Swift.Protocol", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target:nil)
let queueSwiftAssocty = DispatchQueue(label: "com.Swift.Assocty", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSwiftBuiltin = DispatchQueue(label: "com.Swift.Builtin", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)

// 再进行category的dump，因为category依赖于class list和dyld
let categoryGroup = DispatchGroup()
let queueCategory = DispatchQueue(label: "com.Category", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSwiftCapture = DispatchQueue(label: "com.Swift.Capture", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSwiftTypes = DispatchQueue(label: "com.Swift.Types", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)

let printGroup = DispatchGroup()
let queuePrint = DispatchQueue(label: "com.Print.Class", qos: .userInteractive, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)

let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)

struct Section {

    private struct SectionRange {
        let offset: UInt32
        let size: UInt64
        let address: UInt64

        init(_ section: section_64) { offset = section.offset; size = section.size; address = section.addr }
        init(_ section: MachOSectionInfo) { offset = section.fileOffset; size = section.size; address = section.address }
    }

    private static let parseCoordinator = DispatchQueue(label: "com.resymbol.parse-coordinator", qos: .userInitiated)

    static func readSection(_ input: Data, type: BitType, isByteSwapped: Bool,
                            symbol: Bool = false, mode: ResymbolParseMode = .both,
                            progress: ProgressDisplay? = nil,
                            handle: @escaping (Bool) -> Void) {
        parseCoordinator.async {
            let completion = DispatchSemaphore(value: 0)
            MachOData.shared.reset()
            MachOData.shared.binary = input
            MachOData.shared.originalBinary = input
            readSectionImpl(input, type: type, isByteSwapped: isByteSwapped,
                            symbol: symbol, mode: mode, progress: progress) { result in
                handle(result)
                completion.signal()
            }
            completion.wait()
        }
    }

    private static func readSectionImpl(_ input: Data, type:BitType, isByteSwapped: Bool,
                                        symbol: Bool, mode: ResymbolParseMode,
                                        progress: ProgressDisplay?,
                                        handle: @escaping (Bool)->()) {
        var binary = input
        progress?.beginPhase("validating Mach-O", base: 0.02, span: 0.08)
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            ConsoleIO.writeMessage("Only Support x64", .error)
            handle(false)
            return
        }
        
        // Chained pointers must be materialized before any section is parsed. Some
        // protocol handlers run while the load-command table is being scanned.
        // Parse the validated command model once. Chained fixups may rewrite
        // pointer bytes, but never change load-command locations or section
        // geometry, so the same model remains valid for the patched data.
        guard let machOFile = MachOFile.parse(binary) else {
            ConsoleIO.writeMessage("Invalid 64-bit Mach-O structure", .error)
            handle(false)
            return
        }
        progress?.completePhase()
        if let encryption = machOFile.encryptionInfo, encryption.isEncrypted {
            ConsoleIO.writeMessage("Mach-O contains encrypted data (cryptid \(encryption.cryptid)); metadata parsing is unavailable", .error)
            handle(false)
            return
        }
        MachOData.shared.machOFile = machOFile
        if let command = machOFile.firstCommand(ofKind: .chainedFixups) {
            binary = ChainedFixups.apply(to: binary, command: command,
                                         resolver: MachOAddressResolver(file: machOFile, data: binary))
        }
        // All later metadata readers, including symbolic typeref fixups, must
        // observe the materialized chained pointers. Keep the pristine input
        // in `originalBinary` for callers that need byte-for-byte data.
        MachOData.shared.binary = binary
        let resolver = MachOAddressResolver(file: machOFile, data: binary)
        MachOData.shared.segments = machOFile.segments.map {
            MachOSegmentInfo(vmaddr: $0.vmaddr, vmsize: $0.vmsize,
                             fileoff: $0.fileoff, filesize: $0.filesize)
        }
        let parseObjectiveC = mode.includesObjectiveC
        let parseSwift = mode.includesSwift
        var categorySections = [SectionRange]()
        var classSections = [SectionRange]()
        var swiftProtoSection: SectionRange?
        var swiftProtocolsSection: SectionRange?
        var swiftTypeSection: SectionRange?
        var assocty: SectionRange?
        var builtin: SectionRange?
        var capture: SectionRange?
        var symtab: symtab_command!
        var needSymbol = symbol || parseSwift

        for section in machOFile.sections {
            let range = SectionRange(section)
            if (parseObjectiveC || parseSwift) && section.segmentName.hasPrefix("__DATA") {
                if section.sectionName.contains("objc_classlist") || section.sectionName.contains("objc_nlclslist") {
                    classSections.append(range)
                } else if parseObjectiveC && (section.sectionName.contains("objc_catlist") || section.sectionName.contains("objc_nlcatlist")) {
                    categorySections.append(range)
                } else if parseObjectiveC && section.sectionName.contains("objc_protolist") {
                    handle__objc_protolist(binary, section: range)
                }
            } else if parseSwift && section.segmentName.hasPrefix("__TEXT") {
                switch section.sectionName {
                case "__swift5_proto": swiftProtoSection = range
                case let name where name.contains("__swift5_protos"):
                    swiftProtocolsSection = range
                    needSymbol = true
                case let name where name.contains("__swift5_types"): swiftTypeSection = range
                case let name where name.contains("__swift5_typeref"):
                    MachOData.shared.swiftTypeRefRange = Int(range.offset)..<(Int(range.offset) + Int(range.size))
                    handle__swift5_ref(binary, section: range)
                case let name where name.contains("__swift5_reflstr"):
                    MachOData.shared.swiftReflectionStringRange = Int(range.offset)..<(Int(range.offset) + Int(range.size))
                    handle__swift5_ref(binary, section: range)
                case let name where name.contains("__swift5_assocty"): assocty = range
                case let name where name.contains("__swift5_builtin"): builtin = range
                case let name where name.contains("__swift5_capture"): capture = range; needSymbol = true
                default: break
                }
            }
        }
        progress?.beginPhase("indexing metadata", completed: 1, total: 1, base: 0.10, span: 0.12)
        progress?.completePhase()
        
        var header = binary.extract(mach_header_64.self)
        if isByteSwapped { swap_mach_header_64(&header, byteSwappedOrder) }
        var vmAddress = [UInt64]()
        for command in machOFile.loadCommands {
            let offset_machO = command.fileOffset
            if command.kind == .segment64 {
                if case .segment64(let segment) = command.payload {
                    vmAddress.append(segment.vmaddr)
                    if segment.name.isEmpty { needSymbol = true }
                }
            } else if command.kind == .dyldInfo {
                bindingDylb(binary, offSet: offset_machO, isByteSwapped: isByteSwapped, vmAddress: vmAddress)
            } else if command.kind == .symbolTable {
                // Typed MachOFile scan already validated and decoded this command.
                if let command = machOFile.firstCommand(ofKind: .symbolTable),
                   case .symbolTable(let value) = command.payload { symtab = value }
            } else if command.kind == .dynamicSymbolTable {
                // Parsed after the command scan so LC_SYMTAB and every relevant
                // section are available regardless of load-command ordering.
            } else if command.kind == .exportsTrie {
                if let command = machOFile.firstCommand(ofKind: .exportsTrie) {
                    ExportTrie.apply(binary, command: command)
                }
            } else if command.kind == .chainedFixups {
                // Applied in the preliminary pass above.
            }
        }
        if needSymbol, symtab != nil {
            handle_string_table(binary, symtab: symtab)
        }
        progress?.beginPhase("resolving dyld and symbols", base: 0.22, span: 0.13)
        DynamicSymbolTable.apply(binary, machOFile: machOFile)
        MachOData.shared.buildSwiftMethodIndex()
        dyldGroup.wait()
        progress?.completePhase()
        dyldGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: queueWait) {
            if needSymbol, symtab != nil {
                handle_symbol_table(binary, symtab: symtab)
            }
            if parseObjectiveC || parseSwift {
                let total = max(1, classSections.reduce(0) { $0 + Int($1.size / 8) } +
                    categorySections.reduce(0) { $0 + Int($1.size / 8) })
                progress?.beginPhase("parsing Objective-C metadata", total: total,
                                     base: 0.35, span: 0.25)
                for section in classSections {
                    handle__objc_classlist(binary, section: section, emit: parseObjectiveC,
                                           progress: progress)
                }
            }
            if parseSwift {
                let total = max(1, (swiftProtoSection.map { Int($0.size / 4) } ?? 0) +
                    (swiftProtocolsSection.map { Int($0.size / 4) } ?? 0))
                progress?.beginPhase("parsing Swift protocols", total: total,
                                     base: 0.60, span: 0.15)
                if let section = swiftProtoSection {
                    handle__swift5_proto(binary, section: section, resolver: resolver, progress: progress)
                }
                if let section = assocty {
                    handle__swift5_assocty(binary, section: section)
                }
                if let section = builtin {
                    handle__swift5_builtin(binary, section: section)
                }
                if swiftProtoSection == nil { progress?.completePhase() }
            }
            symbolGroup.wait()
            symbolGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: queueWait) {
                if parseSwift {
                    MachOData.shared.buildSwiftProtocolConformanceIndex()
                }
                if parseSwift, let section = swiftTypeSection {
                    let total = max(1, Int(section.size / 4))
                    progress?.beginPhase("parsing Swift types", total: total,
                                         base: 0.75, span: 0.17)
                    if let protocols = swiftProtocolsSection {
                        handle__swift5_protos(binary, section: protocols, resolver: resolver, progress: progress)
                    }
                    handle__swift5_types(binary, section: section, resolver: resolver, progress: progress)
                }
                if parseObjectiveC {
                    for section in categorySections {
                        handle__objc_catlist(binary, section: section, progress: progress)
                    }
                }
                if parseSwift, let section = capture {
                    handle__swift5_capture(binary, section: section, progress: progress)
                }
                categoryGroup.wait()
                categoryGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: queueWait) {
                    progress?.beginPhase("writing declarations", base: 0.92, span: 0.07)
                    if parseSwift {
                        SerializationOutput.beginStdoutBatch()
                        printSwiftType()
                        SerializationOutput.endStdoutBatch()
                    }
                    printGroup.wait()
                    printGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: DispatchQueue.main) {
                        handle(true)
                        progress?.completePhase()
                    }
                }
            }
        }
    }
    
    static func printSwiftType() {
        let profileStart = DispatchTime.now().uptimeNanoseconds
        let classStart = DispatchTime.now().uptimeNanoseconds
        let classes = MachOData.shared.swiftClasses.sorted {
            if $0.type.name.swiftName.value != $1.type.name.swiftName.value {
                return $0.type.name.swiftName.value < $1.type.name.swiftName.value
            }
            let lhsSuperclass = $0.superclassType.superclassType.value
            let rhsSuperclass = $1.superclassType.superclassType.value
            let lhsUseful = !lhsSuperclass.isEmpty && lhsSuperclass != None
            let rhsUseful = !rhsSuperclass.isEmpty && rhsSuperclass != None
            if lhsUseful != rhsUseful { return lhsUseful }
            return $0.type.name.name.address < $1.type.name.name.address
        }
        var emitted = Set<String>()
        for item in classes {
            // Serialization writes to stdout. Keep this final stage
            // synchronous so output order is stable across runs; parsing
            // itself remains concurrent.
            let key = item.type.name.swiftName.value
            guard item.type.hasUsableName, emitted.insert(key).inserted else { continue }
            item.serialization()
        }
        PerformanceProfile.report("swift-class-serialization", start: classStart,
                                  count: classes.count)
        let structStart = DispatchTime.now().uptimeNanoseconds
        
        let structs = MachOData.shared.swiftStruct.sorted {
            if $0.type.name.swiftName.value != $1.type.name.swiftName.value {
                return $0.type.name.swiftName.value < $1.type.name.swiftName.value
            }
            if $0.type.fieldDescriptor.fieldRecords.count != $1.type.fieldDescriptor.fieldRecords.count {
                return $0.type.fieldDescriptor.fieldRecords.count > $1.type.fieldDescriptor.fieldRecords.count
            }
            return $0.type.name.name.address < $1.type.name.name.address
        }
        emitted.removeAll()
        for item in structs {
            let key = item.type.name.swiftName.value
            guard item.type.hasUsableName, emitted.insert(key).inserted else { continue }
            item.serialization()
        }
        PerformanceProfile.report("swift-struct-serialization", start: structStart,
                                  count: structs.count)
        let enumStart = DispatchTime.now().uptimeNanoseconds
        
        let enums = MachOData.shared.swiftEnum.sorted {
            if $0.type.name.swiftName.value != $1.type.name.swiftName.value {
                return $0.type.name.swiftName.value < $1.type.name.swiftName.value
            }
            if $0.type.fieldDescriptor.fieldRecords.count != $1.type.fieldDescriptor.fieldRecords.count {
                return $0.type.fieldDescriptor.fieldRecords.count > $1.type.fieldDescriptor.fieldRecords.count
            }
            return $0.type.name.name.address < $1.type.name.name.address
        }
        emitted.removeAll()
        for item in enums {
            let key = item.type.name.swiftName.value
            guard item.type.hasUsableName, emitted.insert(key).inserted else { continue }
            item.serialization()
        }
        PerformanceProfile.report("swift-enum-serialization", start: enumStart,
                                  count: enums.count)
        var associatedKeys = Set<String>()
        for i in 0..<MachOData.shared.swiftAssocty.count {
            guard let item = MachOData.shared.swiftAssocty[i] else { continue }
            let key = "\(item.conformingTypeName.swiftName.value)|\(item.protocolTypeName.swiftName.value)"
            guard associatedKeys.insert(key).inserted else { continue }
            item.serialization()
        }
        for i in 0..<MachOData.shared.swiftBuiltin.count {
            guard let item = MachOData.shared.swiftBuiltin[i] else { continue }
            guard emitted.insert(item.typeName.swiftName.value).inserted else { continue }
            item.serialization()
        }
        emitted.removeAll()
        for i in 0..<MachOData.shared.swiftCapture.count {
            guard let item = MachOData.shared.swiftCapture[i] else { continue }
            guard emitted.insert(String(item.descriptorAddress, radix: 16)).inserted else { continue }
            item.serialization()
        }
        PerformanceProfile.report("swift-declaration-serialization", start: profileStart,
                                  count: emitted.count)
    }

    
    static func dumpSymbol(_ binary: Data, type: BitType, isByteSwapped: Bool, handle: @escaping (Bool) -> Void) {
        parseCoordinator.async {
            let completion = DispatchSemaphore(value: 0)
            MachOData.shared.reset()
            MachOData.shared.binary = binary
            dumpSymbolImpl(binary, type: type, isByteSwapped: isByteSwapped) { result in
                handle(result)
                completion.signal()
            }
            completion.wait()
        }
    }

    private static func dumpSymbolImpl(_ binary: Data, type:BitType, isByteSwapped: Bool, handle: @escaping (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            ConsoleIO.writeMessage("Only Support x64", .error)
            handle(false)
            return
        }
        
        guard let file = MachOFile.parse(binary) else {
            ConsoleIO.writeMessage("Invalid 64-bit Mach-O structure", .error)
            handle(false)
            return
        }
        guard let command = file.firstCommand(ofKind: .symbolTable),
              case .symbolTable(let symtab) = command.payload else {
            ConsoleIO.writeMessage("Mach-O does not contain an LC_SYMTAB command", .error)
            handle(false)
            return
        }
        handle_string_table(binary, symtab: symtab)
        dyldGroup.wait()
        dyldGroup.notify(queue: queueSymbol) {
            handle_symbol_table(binary, symtab: symtab, dumpSymbol: true)
            symbolGroup.wait()
            symbolGroup.notify(queue: DispatchQueue.main) {
                handle(true)
            }
        }
    }
    
    private static func bindingDylb(_ binary: Data, offSet: Int, isByteSwapped: Bool, vmAddress: [UInt64]) {
        var dylib = binary.extract(dyld_info_command.self, offset: offSet)
        if isByteSwapped {
            swap_dyld_info_command(&dylib, byteSwappedOrder)
        }
        Dyld.binding(binary, vmAddress: vmAddress, start: Int(dylib.bind_off), end: Int(dylib.bind_off+dylib.bind_size))
        Dyld.binding(binary, vmAddress: vmAddress, start: Int(dylib.weak_bind_off), end: Int(dylib.weak_bind_off+dylib.weak_bind_size))
        Dyld.binding(binary, vmAddress: vmAddress, start: Int(dylib.lazy_bind_off), end: Int(dylib.lazy_bind_off+dylib.lazy_bind_size), isLazy: true)
    }
}


extension Section {
    private static func handle__objc_classlist(_ binary: Data, section: SectionRange,
                                               emit: Bool = true,
                                               progress: ProgressDisplay? = nil) {
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>3
        for i in 0..<count {
            symbolGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueClass, group: symbolGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                let rawPointer = UInt64(sub.rawValueBig(), radix: 16) ?? 0
                if let offsetS = MachOData.shared.resolvePointer(rawPointer), offsetS > 0 {
                    var oc = ObjcClass.OC(binary, offset: offsetS)
                    
                    let isa = DataStruct.data(binary, offset: offsetS, length: 8)
                    let rawMetaClass = UInt64(isa.value, radix: 16) ?? 0
                    if let metaClassOffset = MachOData.shared.resolvePointer(rawMetaClass) {
                        oc.classMethods = ObjcClass.OC(binary, offset: metaClassOffset).classRO?.baseMethod
                    }
                    if let c = oc.classRO {
                        MachOData.shared.objcClasses[oc.isa.address.int16()] = c.name.className.value
                        MachOData.shared.objcClassMetadataNames.setIfUnambiguous(c.name.className.value,
                                                                                  forKey: offsetS)
                        let classDataPointer = (UInt64(oc.classData.value, radix: 16) ?? 0) & ~UInt64(0x7)
                        if let classROOffset = MachOData.shared.resolvePointer(classDataPointer),
                           classROOffset > 0 {
                            MachOData.shared.objcClassMetadataNames.setIfUnambiguous(c.name.className.value,
                                                                                      forKey: classROOffset)
                        }
                        if classDataPointer <= UInt64(Int.max) {
                            let rawOffset = Int(classDataPointer)
                            if rawOffset < binary.count {
                                MachOData.shared.objcClassMetadataNames.setIfUnambiguous(c.name.className.value,
                                                                                          forKey: rawOffset)
                            }
                        }
                        let lowOffset = classDataPointer & 0x0000_0000_FFFF_FFFF
                        if lowOffset < UInt64(binary.count) {
                            MachOData.shared.objcClassMetadataNames.setIfUnambiguous(c.name.className.value,
                                                                                      forKey: Int(lowOffset))
                        }
                        // Swift/ObjC hybrid class metadata stores the Swift
                        // context descriptor in a later metadata slot rather
                        // than in the conventional classData field. Index
                        // every aligned pointer in the object header so a
                        // stripped Swift typeref can still resolve by the
                        // runtime class identity.
                        for slot in stride(from: 0, to: 128, by: 8) {
                            let raw = UInt64(DataStruct.data(binary, offset: offsetS + slot,
                                                              length: 8).value, radix: 16) ?? 0
                            if let target = MachOData.shared.resolvePointer(raw), target > 0 {
                                MachOData.shared.objcClassMetadataNames.setIfUnambiguous(c.name.className.value,
                                                                                          forKey: target)
                            }
                        }
                        recordSwiftFieldTypeHints(c, owner: c.name.className.value)
                        let boundSuperclass = fixSymbolName(
                            MachOData.shared.dylbMap[oc.superClass.address.ltrim("0")])
                        let runtimeSuperclass: String? = {
                            if let boundSuperclass, !boundSuperclass.isEmpty { return boundSuperclass }
                            guard let superclassOffset = MachOData.shared.resolvePointerWithLegacyFallback(
                                oc.superClass.value), superclassOffset > 0 else { return nil }
                            let superclassObject = ObjcClass.OC(binary, offset: superclassOffset)
                            let name = superclassObject.classRO?.name.className.value ?? ""
                            return name.isEmpty || name == None ? nil : name
                        }()
                        // Swift classes exposed through ObjC often have a
                        // module-qualified runtime name even when the class
                        // data bit is not preserved in a stripped image.
                        let looksSwift = oc.isSwiftClass || c.name.className.value.contains(".")
                        if looksSwift, let superclass = runtimeSuperclass,
                           !superclass.isEmpty {
                            let sourceSuperclass = superclass.split(separator: ".").last.map(String.init) ?? superclass
                            MachOData.shared.swiftSuperclasses.setIfUnambiguous(
                                sourceSuperclass, forKey: c.name.className.value)
                            if let shortName = c.name.className.value.split(separator: ".").last {
                                MachOData.shared.swiftSuperclasses.setIfUnambiguous(
                                    sourceSuperclass, forKey: String(shortName))
                            }
                        }
                    }
                    if emit { oc.serialization() }
                }
                progress?.advance()
                symbolGroup.leave()
            }
        }
    }

    /// Objective-C metadata retains ABI encodings for Swift classes exported
    /// through Objective-C interoperability. Use only unambiguous scalar and named struct
    /// encodings as a Swift field fallback; object encodings lose
    /// optionality and generic arguments and are intentionally left unresolved.
    private static func recordSwiftFieldTypeHints(_ classRO: ObjcClassRO, owner: String) {
        guard owner.contains(".") || owner.first?.isUppercase == true else { return }
        func hint(_ encoding: String) -> String? {
            let value = encoding.trimmingCharacters(in: .whitespacesAndNewlines)
            // Swift classes exposed through Objective-C metadata retain an
            // object encoding such as `@"_TtC..."` even when the Swift field
            // typeref's symbolic relative pointer was stripped. Demangle that
            // runtime name as evidence for the field type; do not infer names
            // from the property or owner.
            if value.hasPrefix("@\""), let quote = value.dropFirst(2).firstIndex(of: "\"") {
                let runtimeName = String(value[value.index(value.startIndex, offsetBy: 2)..<quote])
                if runtimeName.hasPrefix("_Tt"),
                   let demangled = swift_demangle(runtimeName),
                   !demangled.isEmpty {
                    return demangled.split(separator: ".").last.map(String.init) ?? demangled
                }
            }
            switch value {
            case "B": return "Bool"
            case "c": return "Int8"
            case "C": return "UInt8"
            case "s": return "Int16"
            case "S": return "UInt16"
            case "i": return "Int32"
            case "I": return "UInt32"
            case "q": return "Int64"
            case "Q": return "UInt64"
            case "f": return "Float"
            case "d": return "Double"
            default:
                guard value.hasPrefix("{") else { return nil }
                let name = String(value.dropFirst()).split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                guard let first = name.first, first.isLetter || first == "_",
                      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                    return nil
                }
                return name
            }
        }
        if let ivars = classRO.ivars.instanceVariables {
            for ivar in ivars {
                let name = ivar.name.instanceVariableName.value
                if let type = hint(ivar.types.instanceVariableTypes.value) {
                    MachOData.shared.recordSwiftFieldTypeHint(owner: owner, field: name, type: type)
                }
            }
        }
        if let properties = classRO.baseProperties.properties {
            for property in properties {
                let name = property.name.propertyName.value
                let attrs = property.attributes.propertyAttributes.value
                guard let typeToken = attrs.split(separator: ",").first(where: { $0.first == "T" }) else { continue }
                let encoding = String(typeToken.dropFirst())
                if let type = hint(encoding) {
                    MachOData.shared.recordSwiftFieldTypeHint(owner: owner, field: name, type: type)
                }
            }
        }
    }
    
    private static func handle__objc_catlist(_ binary: Data, section: SectionRange,
                                             progress: ProgressDisplay? = nil) {
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>3
        for i in 0..<count {
            categoryGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueCategory, group: categoryGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                let rawPointer = UInt64(sub.rawValueBig(), radix: 16) ?? 0
                if let offsetS = MachOData.shared.resolvePointer(rawPointer), offsetS > 0 {
                    ObjcCategory.OCCG(binary, offset: offsetS).serialization()
                }
                progress?.advance()
                categoryGroup.leave()
            }
        }
    }
    
    private static func handle__objc_protolist(_ binary: Data, section: SectionRange) {
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>3
        for i in 0..<count {
            dyldGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueProtocol, group: dyldGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                let rawPointer = UInt64(sub.rawValueBig(), radix: 16) ?? 0
                if let offsetS = MachOData.shared.resolvePointer(rawPointer), offsetS > 0 {
                    guard MachOData.shared.objcProtocols[offsetS] == nil else {
                        dyldGroup.leave()
                        return
                    }
                    let pr = ObjcProtocol.OCPT(binary, offset: offsetS)
                    MachOData.shared.objcProtocols[offsetS] = pr.name.className.value
                    pr.serialization()
                }
                dyldGroup.leave()
            }
        }
    }
}


extension Section {
    private static func handle__swift5_protos(_ binary: Data, section: SectionRange,
                                               resolver: MachOAddressResolver,
                                               progress: ProgressDisplay? = nil) {
        let profileStart = DispatchTime.now().uptimeNanoseconds
        defer { PerformanceProfile.report("swift-protocol-descriptors", start: profileStart,
                                          count: Int(section.size / 4)) }
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>2
        for i in 0..<count {
            let location = i<<2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            let base = Int(section.offset) + location
            guard let offsetS = resolver.resolveAlignedRelativePointer(
                fieldOffset: base, rawHex: sub.rawValueBig()), offsetS > 0 else { continue }
            if offsetS > 0 {
                let p = ProtocolDescriptor.PD(binary, offset: offsetS,
                                              addressResolver: resolver.vmAddress(forFileOffset:),
                                              resolver: resolver)
                p.serialization()
                MachOData.shared.swiftProtocols[offsetS] = p.name.swiftName.value
                progress?.advance()
            }
        }
    }
    
    private static func handle__swift5_proto(_ binary: Data, section: SectionRange,
                                             resolver: MachOAddressResolver,
                                             progress: ProgressDisplay? = nil) {
        let profileStart = DispatchTime.now().uptimeNanoseconds
        defer { PerformanceProfile.report("swift-conformance-dispatch", start: profileStart,
                                          count: Int(section.size / 4)) }
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>2
        for i in 0..<count {
            symbolGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSwiftProtocol, group: symbolGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            let entryBase = Int(section.offset) + location
                if let offsetS = resolver.resolveAlignedRelativePointer(
                    fieldOffset: entryBase, rawHex: sub.rawValueBig()), offsetS > 0 {
                    let p = SwiftProtocol.SP(binary, offset: offsetS)
                    if let conformance = SwiftProtocolConformance.parse(binary, offset: offsetS,
                                                                          resolver: resolver) {
                        MachOData.shared.swiftProtocolConformances.append(conformance)
                    }
                    var nominalName = ""
                    let nominalFlags = UInt32(p.nominalTypeDescriptor.nominalTypeDescriptor.value,
                                              radix: 16) ?? 0
                    switch Int(nominalFlags & 0x3) {
                    case 0:
                        nominalName = MachOData.shared.nominalOffsetMap[p.nominalTypeDescriptor.nominalTypeDescriptor.address.int16()] ?? ""
                        if nominalName.isEmpty {
                            MachOData.shared.nominalOffsetMap.setDeterministically(
                                p.nominalTypeDescriptor.nominalTypeName.value,
                                forKey: p.nominalTypeDescriptor.nominalTypeDescriptor.address.int16())
                        }
                        break
                    case 1:
                        nominalName = p.nominalTypeDescriptor.nominalTypeName.value
                        break
                    case 2:
                        nominalName = p.nominalTypeDescriptor.nominalTypeName.value
                        break
                    case 3:
                        break
                    default:
                        break
                    }
                }
                progress?.advance()
                symbolGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_types(_ binary: Data, section: SectionRange,
                                             resolver: MachOAddressResolver,
                                             progress: ProgressDisplay? = nil) {
        let profileStart = DispatchTime.now().uptimeNanoseconds
        defer { PerformanceProfile.report("swift-type-dispatch", start: profileStart,
                                          count: Int(section.size / 4)) }
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>2

        // Seed every nominal descriptor before concurrent workers parse full
        // class/struct/enum bodies. Superclass and field demangling can refer
        // to a sibling descriptor; populating this index first removes the
        // scheduler-dependent lookup that previously changed large dumps.
        for i in 0..<count {
            let location = i << 2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            let entryBase = Int(section.offset) + location
            guard let offsetS = resolver.resolveAlignedRelativePointer(
                fieldOffset: entryBase, rawHex: sub.rawValueBig()), offsetS > 0 else { continue }
            let flags = SwiftFlags.SF(binary, offset: offsetS)
            switch flags.kind {
            case .Class, .Enum, .Struct:
                // The seed pass only needs the nominal name. Constructing a
                // full SwiftType here parses its field descriptor (and every
                // field record) a second time before the real type pass.
                // Keep this pass deliberately shallow; the full descriptor
                // remains parsed once below in the established order.
                let typeName = SwiftName.SN(binary, offset: offsetS + 8,
                                             isMangledName: false, isClassName: true)
                MachOData.shared.nominalOffsetMap.setDeterministically(
                    typeName.swiftName.value, forKey: offsetS)
            default:
                continue
            }
        }
        for i in 0..<count {
            categoryGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSwiftTypes, group: categoryGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
                let entryBase = Int(section.offset) + location
                if let offsetS = resolver.resolveAlignedRelativePointer(
                    fieldOffset: entryBase, rawHex: sub.rawValueBig()), offsetS > 0 {
                    let flags = SwiftFlags.SF(binary, offset: offsetS)
                    switch flags.kind {
                    case .Class:
                        let c = SwiftClass.SC(binary, offset: offsetS+4, flags: flags)
                        MachOData.shared.swiftClasses.append(c)
                        MachOData.shared.nominalOffsetMap.setDeterministically(c.type.name.swiftName.value,
                                                                                forKey: offsetS)
                        MachOData.shared.mangledNameMap.setIfUnambiguous(
                            c.type.name.swiftName.value,
                            forKey: c.type.fieldDescriptor.mangledTypeName.swiftName.value)
                    case .Enum:
                        let e = SwiftEnum.SE(binary, offset: offsetS+4, flags: flags)
                        MachOData.shared.swiftEnum.append(e)
                        MachOData.shared.nominalOffsetMap.setDeterministically(e.type.name.swiftName.value,
                                                                                forKey: offsetS)
                        MachOData.shared.mangledNameMap.setIfUnambiguous(
                            e.type.name.swiftName.value,
                            forKey: e.type.fieldDescriptor.mangledTypeName.swiftName.value)
                    case .Struct:
                        let s = SwiftStruct.SS(binary, offset: offsetS+4, flags: flags)
                        MachOData.shared.swiftStruct.append(s)
                        MachOData.shared.nominalOffsetMap.setDeterministically(s.type.name.swiftName.value,
                                                                                forKey: offsetS)
                        MachOData.shared.mangledNameMap.setIfUnambiguous(
                            s.type.name.swiftName.value,
                            forKey: s.type.fieldDescriptor.mangledTypeName.swiftName.value)
                    default:
                        break
                    }
                }
                progress?.advance()
                categoryGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_assocty(_ binary: Data, section: SectionRange) {
        symbolGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueSwiftAssocty, group: symbolGroup, count: activeProcessorCount) {
            var index = Int(section.offset)
            let end = Int(section.offset) + Int(section.size)
            while index < end {
                MachOData.shared.swiftAssocty.append(SwiftAssocty.SA(binary, offset: &index))
            }
            symbolGroup.leave()
        }
    }
    
    private static func handle__swift5_builtin(_ binary: Data, section: SectionRange) {
        symbolGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueSwiftBuiltin, group: symbolGroup, count: activeProcessorCount) {
            var index = Int(section.offset)
            let end = Int(section.offset) + Int(section.size)
            while index < end {
                MachOData.shared.swiftBuiltin.append(SwiftBuiltin.SB(binary, offset: &index))
            }
            symbolGroup.leave()
        }
    }
    
    private static func handle__swift5_capture(_ binary: Data, section: SectionRange,
                                               progress: ProgressDisplay? = nil) {
        categoryGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueSwiftCapture, group: categoryGroup, count: activeProcessorCount) {
            var index = Int(section.offset)
            let end = Int(section.offset) + Int(section.size)
            while index < end {
                MachOData.shared.swiftCapture.append(SwiftCapture.SC(binary, offset: &index,
                                                                     sectionAddress: section.address,
                                                                     sectionOffset: section.offset))
                progress?.advance()
            }
            categoryGroup.leave()
        }
    }
}


extension Section {
    private static func handle_string_table(_ binary: Data, symtab: symtab_command) {
        let stringOffset = Int(symtab.stroff)
        let stringSize = Int(symtab.strsize)
        guard stringOffset >= 0, stringSize >= 0,
              stringOffset <= binary.count,
              stringSize <= binary.count - stringOffset else {
            ConsoleIO.writeMessage("Invalid Mach-O string table", .debug)
            return
        }
        let stringTable = binary.subdata(in: stringOffset..<(stringOffset + stringSize))
        dyldGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueStringTable, group: dyldGroup, count: activeProcessorCount) {
            var index = 0
            while index < stringTable.count {
                var strData = Data()
                var item = stringTable[index]
                let start = index
                while index < stringTable.count, item != 0, strData.count < 256 {
                    strData.append(item)
                    index += 1
                    if index < stringTable.count { item = stringTable[index] }
                }
                if let s = String(data: strData, encoding: String.Encoding.utf8), s.count > 0  {
                    MachOData.shared.stringTable[start.string16()] = s
                }
                while index < stringTable.count, stringTable[index] != 0, strData.count >= 256 { index += 1 }
                if index < stringTable.count { index += 1 }
            }
            dyldGroup.leave()
        }
    }
    
    private static func handle_symbol_table(_ binary: Data, symtab: symtab_command, dumpSymbol: Bool = false) {
        let offsetStart = Int(symtab.symoff)
        let entrySize = MemoryLayout<nlist_64>.size
        let symbolCount = Int(symtab.nsyms)
        guard offsetStart >= 0, symbolCount >= 0,
              offsetStart <= binary.count,
              symbolCount <= (binary.count - offsetStart) / entrySize else {
            ConsoleIO.writeMessage("Invalid Mach-O symbol table", .debug)
            return
        }
        for i in 0..<symtab.nsyms {
            symbolGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSymbol, group: symbolGroup, count: activeProcessorCount) {
                let nlist = Nlist.nlist(binary, offset: offsetStart + Int(i) * entrySize)
                if dumpSymbol {
                    ConsoleIO.writeMessage("\(nlist.valueAddress.value) \(nlist.name() ?? "")")
                } else {
                    MachOData.shared.symbolTable[nlist.valueAddress.value] = nlist
                    if let raw = nlist.name() {
                        ProtocolWitnessIndex.shared.ingest(mangled: raw)
                    }
                    if let raw = nlist.name(), raw.hasPrefix("$s") || raw.hasPrefix("_$s") {
                        let demangled = swift_demangle(raw) ?? ""
                        if let type = accessorType(from: demangled), let property = accessorProperty(from: demangled) {
                            if let owner = accessorOwner(from: demangled), !owner.isEmpty {
                                MachOData.shared.accessorTypes.setIfUnambiguous(
                                    type, forKey: "\(owner)|\(property)")
                            } else {
                                MachOData.shared.accessorTypes.setIfUnambiguous(type,
                                                                                     forKey: property)
                            }
                        }
                    }
                }
                symbolGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_ref(_ binary: Data, section: SectionRange) {
        let profileStart = DispatchTime.now().uptimeNanoseconds
        defer { PerformanceProfile.report("swift-reflection-dispatch", start: profileStart,
                                          count: Int(section.size)) }
        guard let stringTable = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        dyldGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueSwiftRef, group: dyldGroup, count: activeProcessorCount) {
            var index = 0
            while index < stringTable.count {
                var strData = Data()
                var item = stringTable[index]
                let start = index
                while index < stringTable.count, item != 0, strData.count < 256 {
                    strData.append(item)
                    index += 1
                    if index < stringTable.count { item = stringTable[index] }
                }
                if let s = String(data: strData, encoding: String.Encoding.utf8), s.count > 0 {
                    MachOData.shared.nominalOffsetMap.setDeterministically(
                        s, forKey: Int(section.offset) + start)
                }
                while index < stringTable.count, stringTable[index] != 0, strData.count >= 256 { index += 1 }
                if index < stringTable.count { index += 1 }
            }
            dyldGroup.leave()
        }
    }

    private static func accessorProperty(from name: String) -> String? {
        guard name.contains("getter") || name.contains("setter") || name.contains("modify") || name.contains("read") else { return nil }
        let declaration = name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? name
        let parts = declaration.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }

    private static func accessorOwner(from name: String) -> String? {
        let declaration = name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? name
        let parts = declaration.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.dropLast(2).joined(separator: ".")
    }

    private static func accessorType(from name: String) -> String? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let type = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return type.isEmpty ? nil : type
    }
}
