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

    private static let parseCoordinator = DispatchQueue(label: "com.resymbol.parse-coordinator", qos: .userInitiated)

    static func readSection(_ input: Data, type: BitType, isByteSwapped: Bool, symbol: Bool = false, handle: @escaping (Bool) -> Void) {
        parseCoordinator.async {
            let completion = DispatchSemaphore(value: 0)
            MachOData.shared.reset()
            MachOData.shared.binary = input
            readSectionImpl(input, type: type, isByteSwapped: isByteSwapped, symbol: symbol) { result in
                handle(result)
                completion.signal()
            }
            completion.wait()
        }
    }

    private static func readSectionImpl(_ input: Data, type:BitType, isByteSwapped: Bool, symbol: Bool, handle: @escaping (Bool)->()) {
        var binary = input
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            ConsoleIO.writeMessage("Only Support x64", .error)
            handle(false)
            return
        }
        
        // Chained pointers must be materialized before any section is parsed. Some
        // protocol handlers run while the load-command table is being scanned.
        var preliminaryHeader = binary.extract(mach_header_64.self)
        if isByteSwapped { swap_mach_header_64(&preliminaryHeader, byteSwappedOrder) }
        var preliminaryOffset = MemoryLayout<mach_header_64>.size
        var preliminarySegments = [ChainedFixups.Segment]()
        var preliminaryFixups: Int?
        for _ in 0..<preliminaryHeader.ncmds {
            guard preliminaryOffset + MemoryLayout<load_command>.size <= binary.count else { break }
            var command = binary.extract(load_command.self, offset: preliminaryOffset)
            if isByteSwapped { swap_load_command(&command, byteSwappedOrder) }
            guard command.cmdsize >= UInt32(MemoryLayout<load_command>.size), preliminaryOffset + Int(command.cmdsize) <= binary.count else { break }
            if command.cmd == LC_SEGMENT_64 {
                var segment = binary.extract(segment_command_64.self, offset: preliminaryOffset)
                if isByteSwapped { swap_segment_command_64(&segment, byteSwappedOrder) }
                preliminarySegments.append(.init(vmaddr: segment.vmaddr, fileoff: segment.fileoff))
            } else if command.cmd == LC_DYLD_CHAINED_FIXUPS {
                preliminaryFixups = preliminaryOffset
            }
            preliminaryOffset += Int(command.cmdsize)
        }
        if let command = preliminaryFixups {
            binary = ChainedFixups.apply(to: binary, commandOffset: command, segments: preliminarySegments)
        }
        guard let machOFile = MachOFile.parse(binary) else {
            ConsoleIO.writeMessage("Invalid 64-bit Mach-O structure", .error)
            handle(false)
            return
        }
        MachOData.shared.machOFile = machOFile
        MachOData.shared.segments = machOFile.segments.map {
            MachOSegmentInfo(vmaddr: $0.vmaddr, vmsize: $0.vmsize,
                             fileoff: $0.fileoff, filesize: $0.filesize)
        }
        var categorySections = [section_64]()
        var classSections = [section_64]()
        var swiftProtoSection: section_64?
        var swiftProtocolsSection: section_64?
        var swiftTypeSection: section_64?
        var assocty: section_64?
        var builtin: section_64?
        var capture: section_64?
        var symtab: symtab_command!
        var needSymbol = symbol
        
        var header = binary.extract(mach_header_64.self)
        if isByteSwapped { swap_mach_header_64(&header, byteSwappedOrder) }
        var offset_machO = MemoryLayout.size(ofValue: header)
        var vmAddress = [UInt64]()
        for _ in 0..<header.ncmds {
            guard offset_machO >= 0, offset_machO + MemoryLayout<load_command>.size <= binary.count else {
                ConsoleIO.writeMessage("Invalid Mach-O load command table", .error)
                handle(false)
                return
            }
            var loadCommand = binary.extract(load_command.self, offset: offset_machO)
            if isByteSwapped { swap_load_command(&loadCommand, byteSwappedOrder) }
            let commandSize = Int(loadCommand.cmdsize)
            guard commandSize >= MemoryLayout<load_command>.size,
                  offset_machO + commandSize <= binary.count else {
                ConsoleIO.writeMessage("Invalid Mach-O load command size", .error)
                handle(false)
                return
            }
            if loadCommand.cmd == LC_SEGMENT_64 {
                var segment = binary.extract(segment_command_64.self, offset: offset_machO)
                if isByteSwapped {
                    swap_segment_command_64(&segment, byteSwappedOrder)
                }
                let segmentSegname = String(rawCChar: segment.segname)
                vmAddress.append(segment.vmaddr)
                if segmentSegname == "" {
                    needSymbol = true
                }
                if segmentSegname.contains("__DATA") || segmentSegname.contains("__TEXT") {
                    var offset_segment = offset_machO + MemoryLayout<segment_command_64>.size
                    for _ in 0..<segment.nsects {
                        guard offset_segment + MemoryLayout<section_64>.size <= binary.count else { break }
                        let section = binary.extract(section_64.self, offset: offset_segment)
                        let sectionSegname = String(rawCChar: section.segname)
                        if sectionSegname.hasPrefix("__DATA") {
                            let sectname = String(rawCChar: section.sectname)
                            if sectname.contains("objc_classlist") || sectname.contains("objc_nlclslist") {
                                classSections.append(section)
                            } else if sectname.contains("objc_catlist") || sectname.contains("objc_nlcatlist"){
                                categorySections.append(section)
                            } else if sectname.contains("objc_protolist") {
                                handle__objc_protolist(binary, section: section)
                            }
                        } else if sectionSegname.hasPrefix("__TEXT") {
                            let sectname = String(rawCChar: section.sectname)
                            if sectname == "__swift5_proto" {
                                swiftProtoSection = section
                            } else if sectname.contains("__swift5_protos") {
                                swiftProtocolsSection = section
                                needSymbol = true
                            } else if sectname.contains("__swift5_types") {
                                swiftTypeSection = section
                            } else if sectname.contains("__swift5_typeref") {
                                MachOData.shared.swiftTypeRefRange = Int(section.offset)..<(Int(section.offset) + Int(section.size))
                                handle__swift5_ref(binary, section: section)
                            } else if sectname.contains("__swift5_reflstr") {
                                MachOData.shared.swiftReflectionStringRange = Int(section.offset)..<(Int(section.offset) + Int(section.size))
                                handle__swift5_ref(binary, section: section)
                            } else if sectname.contains("__swift5_assocty") {
                                assocty = section
                            } else if sectname.contains("__swift5_builtin") {
                                builtin = section
                            } else if sectname.contains("__swift5_capture") {
                                capture = section
                                needSymbol = true
                            }
                        }
                        offset_segment += MemoryLayout<section_64>.size
                    }
                }
            } else if loadCommand.cmd == LC_DYLD_INFO || loadCommand.cmd == LC_DYLD_INFO_ONLY {
                bindingDylb(binary, offSet: offset_machO, isByteSwapped: isByteSwapped, vmAddress: vmAddress)
            } else if loadCommand.cmd == LC_SYMTAB {
                symtab = binary.extract(symtab_command.self, offset: offset_machO)
                if isByteSwapped {
                    swap_symtab_command(&symtab, byteSwappedOrder)
                }
            } else if loadCommand.cmd == LC_DYSYMTAB {
                // Parsed after the command scan so LC_SYMTAB and every relevant
                // section are available regardless of load-command ordering.
            } else if loadCommand.cmd == LC_DYLD_EXPORTS_TRIE {
                ExportTrie.apply(binary, commandOffset: offset_machO)
            } else if loadCommand.cmd == LC_DYLD_CHAINED_FIXUPS {
                // Applied in the preliminary pass above.
            }
            offset_machO += commandSize
        }
        if needSymbol, symtab != nil {
            handle_string_table(binary, symtab: symtab)
        }
        DynamicSymbolTable.apply(binary, isByteSwapped: isByteSwapped)
        dyldGroup.wait()
        dyldGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: queueWait) {
            if needSymbol, symtab != nil {
                handle_symbol_table(binary, symtab: symtab)
            }
            for section in classSections {
                handle__objc_classlist(binary, section: section)
            }
            if let section = swiftProtoSection {
                handle__swift5_proto(binary, section: section)
            }
            if let section = assocty {
                handle__swift5_assocty(binary, section: section)
            }
            if let section = builtin {
                handle__swift5_builtin(binary, section: section)
            }
            symbolGroup.wait()
            symbolGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: queueWait) {
                if let section = swiftProtocolsSection {
                    handle__swift5_protos(binary, section: section, segments: preliminarySegments)
                }
                if let section = swiftTypeSection {
                    handle__swift5_types(binary, section: section)
                }
                for section in categorySections {
                    handle__objc_catlist(binary, section: section)
                }
                if let section = capture {
                    handle__swift5_capture(binary, section: section)
                }
                categoryGroup.wait()
                categoryGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: queueWait) {
                    printSwiftType()
                    printGroup.wait()
                    printGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: DispatchQueue.main) {
                        handle(true)
                    }
                }
            }
        }
    }
    
    static func printSwiftType() {
        let classes = MachOData.shared.swiftClasses.sorted {
            $0.type.name.swiftName.value < $1.type.name.swiftName.value
        }
        for item in classes {
            // Serialization writes to stdout. Keep this final stage
            // synchronous so output order is stable across runs; parsing
            // itself remains concurrent.
            item.serialization()
        }
        
        let structs = MachOData.shared.swiftStruct.sorted {
            $0.type.name.swiftName.value < $1.type.name.swiftName.value
        }
        for item in structs {
            item.serialization()
        }
        
        let enums = MachOData.shared.swiftEnum.sorted {
            $0.type.name.swiftName.value < $1.type.name.swiftName.value
        }
        for item in enums {
            item.serialization()
        }
        for i in 0..<MachOData.shared.swiftAssocty.count {
            MachOData.shared.swiftAssocty[i]?.serialization()
        }
        for i in 0..<MachOData.shared.swiftBuiltin.count {
            MachOData.shared.swiftBuiltin[i]?.serialization()
        }
        for i in 0..<MachOData.shared.swiftCapture.count {
            MachOData.shared.swiftCapture[i]?.serialization()
        }
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
        
        var header = binary.extract(mach_header_64.self)
        if isByteSwapped { swap_mach_header_64(&header, byteSwappedOrder) }
        var symtab: symtab_command!
        var offset_machO = MemoryLayout.size(ofValue: header)
        for _ in 0..<header.ncmds {
            guard offset_machO + MemoryLayout<load_command>.size <= binary.count else {
                handle(false)
                return
            }
            var loadCommand = binary.extract(load_command.self, offset: offset_machO)
            if isByteSwapped { swap_load_command(&loadCommand, byteSwappedOrder) }
            let commandSize = Int(loadCommand.cmdsize)
            guard commandSize >= MemoryLayout<load_command>.size,
                  offset_machO + commandSize <= binary.count else {
                handle(false)
                return
            }
            if loadCommand.cmd == LC_SYMTAB {
                symtab = binary.extract(symtab_command.self, offset: offset_machO)
                if isByteSwapped {
                    swap_symtab_command(&symtab, byteSwappedOrder)
                }
                break
            }
            offset_machO += commandSize
        }
        guard symtab != nil else {
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
    private static func handle__objc_classlist(_ binary: Data, section: section_64) {
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
                    }
                    oc.serialization()
                }
                symbolGroup.leave()
            }
        }
    }
    
    private static func handle__objc_catlist(_ binary: Data, section: section_64) {
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
                categoryGroup.leave()
            }
        }
    }
    
    private static func handle__objc_protolist(_ binary: Data, section: section_64) {
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>3
        for i in 0..<count {
            dyldGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueProtocol, group: dyldGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                let rawPointer = UInt64(sub.rawValueBig(), radix: 16) ?? 0
                if let offsetS = MachOData.shared.resolvePointer(rawPointer), offsetS > 0 {
                    let pr = ObjcProtocol.OCPT(binary, offset: offsetS)
                    MachOData.shared.objcProtocols[pr.isa.address.int16()] = pr.name.className.value
                    pr.serialization()
                }
                dyldGroup.leave()
            }
        }
    }
}


extension Section {
    private static func handle__swift5_protos(_ binary: Data, section: section_64,
                                               segments: [ChainedFixups.Segment]) {
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>2
        for i in 0..<count {
            let location = i<<2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            let offsetS = (Int(section.offset) + location + sub.rawValueBig().int16Subtraction()).alignment()
            if offsetS > 0 {
                let p = ProtocolDescriptor.PD(binary, offset: offsetS) { fileOffset in
                    guard let segment = segments
                        .filter({ Int($0.fileoff) <= fileOffset })
                        .max(by: { $0.fileoff < $1.fileoff }) else { return nil }
                    return segment.vmaddr + UInt64(fileOffset - Int(segment.fileoff))
                }
                p.serialization()
                MachOData.shared.swiftProtocols[offsetS] = p.name.swiftName.value
            }
        }
    }
    
    private static func handle__swift5_proto(_ binary: Data, section: section_64) {
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>2
        for i in 0..<count {
            symbolGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSwiftProtocol, group: symbolGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
                let offsetS = (Int(section.offset) + location + sub.rawValueBig().int16Subtraction()).alignment()
                if offsetS > 0 {
                    let p = SwiftProtocol.SP(binary, offset: offsetS)
                    var nominalName = ""
                    switch p.nominalTypeDescriptor.nominalTypeDescriptor.value.int16Subtraction() & 0x3 {
                    case 0:
                        nominalName = MachOData.shared.nominalOffsetMap[p.nominalTypeDescriptor.nominalTypeDescriptor.address.int16()] ?? ""
                        if nominalName.isEmpty {
                            MachOData.shared.nominalOffsetMap[p.nominalTypeDescriptor.nominalTypeDescriptor.address.int16()] = p.nominalTypeDescriptor.nominalTypeName.value
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
                symbolGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_types(_ binary: Data, section: section_64) {
        guard let d = binary.safeSubdata(offset: Int(section.offset), length: Int(section.size)) else { return }
        let count = d.count>>2
        for i in 0..<count {
            categoryGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSwiftTypes, group: categoryGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
                let offsetS = (Int(section.offset) + location + sub.rawValueBig().int16Subtraction()).alignment()
                if offsetS > 0 {
                    let flags = SwiftFlags.SF(binary, offset: offsetS)
                    switch flags.kind {
                    case .Class:
                        let c = SwiftClass.SC(binary, offset: offsetS+4, flags: flags)
                        MachOData.shared.swiftClasses.append(c)
                        MachOData.shared.nominalOffsetMap[offsetS] = c.type.name.swiftName.value
                        MachOData.shared.mangledNameMap[c.type.fieldDescriptor.mangledTypeName.swiftName.value] = c.type.name.swiftName.value
                    case .Enum:
                        let e = SwiftEnum.SE(binary, offset: offsetS+4, flags: flags)
                        MachOData.shared.swiftEnum.append(e)
                        MachOData.shared.nominalOffsetMap[offsetS] = e.type.name.swiftName.value
                        MachOData.shared.mangledNameMap[e.type.fieldDescriptor.mangledTypeName.swiftName.value] = e.type.name.swiftName.value
                    case .Struct:
                        let s = SwiftStruct.SS(binary, offset: offsetS+4, flags: flags)
                        MachOData.shared.swiftStruct.append(s)
                        MachOData.shared.nominalOffsetMap[offsetS] = s.type.name.swiftName.value
                        MachOData.shared.mangledNameMap[s.type.fieldDescriptor.mangledTypeName.swiftName.value] = s.type.name.swiftName.value
                    default:
                        break
                    }
                }
                categoryGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_assocty(_ binary: Data, section: section_64) {
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
    
    private static func handle__swift5_builtin(_ binary: Data, section: section_64) {
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
    
    private static func handle__swift5_capture(_ binary: Data, section: section_64) {
        categoryGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueSwiftCapture, group: categoryGroup, count: activeProcessorCount) {
            var index = Int(section.offset)
            let end = Int(section.offset) + Int(section.size)
            while index < end {
                MachOData.shared.swiftCapture.append(SwiftCapture.SC(binary, offset: &index, section: section))
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
                            MachOData.shared.accessorTypes[property] = type
                        }
                    }
                }
                symbolGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_ref(_ binary: Data, section: section_64) {
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
                    MachOData.shared.nominalOffsetMap[Int(section.offset)+start] = s
                }
                while index < stringTable.count, stringTable[index] != 0, strData.count >= 256 { index += 1 }
                if index < stringTable.count { index += 1 }
            }
            dyldGroup.leave()
        }
    }

    private static func accessorProperty(from name: String) -> String? {
        guard name.contains("getter") || name.contains("setter") || name.contains("modify") || name.contains("read") else { return nil }
        let parts = name.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }

    private static func accessorType(from name: String) -> String? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let type = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return type.isEmpty ? nil : type
    }
}
