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

let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount/2

struct Section {
    
    static func readSection(_ binary: Data, type:BitType, isByteSwapped: Bool, symbol: Bool = false, handle: @escaping (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            ConsoleIO.writeMessage("Only Support x64", .error)
            handle(false)
            return
        }
        
        var categorySections = [section_64]()
        var classSections = [section_64]()
        var swiftProtoSection: section_64?
        var swiftTypeSection: section_64?
        var assocty: section_64?
        var builtin: section_64?
        var capture: section_64?
        var symtab: symtab_command!
        var needSymbol = symbol
        
        let header = binary.extract(mach_header_64.self)
        var offset_machO = MemoryLayout.size(ofValue: header)
        var vmAddress = [UInt64]()
        for _ in 0..<header.ncmds {
            let loadCommand = binary.extract(load_command.self, offset: offset_machO)
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
                    var offset_segment = offset_machO + 0x48
                    for _ in 0..<segment.nsects {
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
                                handle__swift5_protos(binary, section: section)
                            } else if sectname.contains("__swift5_types") {
                                swiftTypeSection = section
                            } else if sectname.contains("__swift5_typeref") || sectname.contains("__swift5_reflstr") {
                                handle__swift5_ref(binary, section: section)
                            } else if sectname.contains("__swift5_assocty") {
                                assocty = section
                            } else if sectname.contains("__swift5_builtin") {
                                builtin = section
                            } else if sectname.contains("__swift5_capture") {
                                capture = section
                            }
                        }
                        offset_segment += 0x50
                    }
                }
            } else if loadCommand.cmd == LC_DYLD_INFO || loadCommand.cmd == LC_DYLD_INFO_ONLY {
                bindingDylb(binary, offSet: offset_machO, isByteSwapped: isByteSwapped, vmAddress: vmAddress)
            } else if loadCommand.cmd == LC_SYMTAB {
                if needSymbol {
                    symtab = binary.extract(symtab_command.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_symtab_command(&symtab, byteSwappedOrder)
                    }
                    handle_string_table(binary, symtab: symtab)
                }
            } else if loadCommand.cmd == LC_DYSYMTAB {
//                var dysymtab = binary.extract(dysymtab_command.self, offset: offset_machO)
//                if isByteSwapped {
//                    swap_dysymtab_command(&dysymtab, byteSwappedOrder)
//                }
//                let indirectSymbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(dysymtab.indirectsymoff), length: Int(dysymtab.nindirectsyms*4)))!)
//                ConsoleIO.writeMessage(indirectSymbolTable, .debug)
            }
            offset_machO += Int(loadCommand.cmdsize)
        }
        dyldGroup.wait()
        dyldGroup.notify(qos: DispatchQoS.userInteractive, flags: DispatchWorkItemFlags.barrier, queue: queueWait) {
            if needSymbol {
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
        for i in 0..<MachOData.shared.swiftClasses.count {
            printGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queuePrint, group: printGroup, count: activeProcessorCount) {
                MachOData.shared.swiftClasses[i]?.serialization()
                printGroup.leave()
            }
        }
        
        for i in 0..<MachOData.shared.swiftStruct.count {
            printGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queuePrint, group: printGroup, count: activeProcessorCount) {
                MachOData.shared.swiftStruct[i]?.serialization()
                printGroup.leave()
            }
        }
        
        for i in 0..<MachOData.shared.swiftEnum.count {
            printGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queuePrint, group: printGroup, count: activeProcessorCount) {
                MachOData.shared.swiftEnum[i]?.serialization()
                printGroup.leave()
            }
        }
        for i in 0..<MachOData.shared.swiftAssocty.count {
            printGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queuePrint, group: printGroup, count: activeProcessorCount) {
                MachOData.shared.swiftAssocty[i]?.serialization()
                printGroup.leave()
            }
        }
        for i in 0..<MachOData.shared.swiftBuiltin.count {
            printGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queuePrint, group: printGroup, count: activeProcessorCount) {
                MachOData.shared.swiftBuiltin[i]?.serialization()
                printGroup.leave()
            }
        }
        for i in 0..<MachOData.shared.swiftCapture.count {
            printGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queuePrint, group: printGroup, count: activeProcessorCount) {
                MachOData.shared.swiftCapture[i]?.serialization()
                printGroup.leave()
            }
        }
    }
    
    static func dumpSymbol(_ binary: Data, type:BitType, isByteSwapped: Bool, handle: @escaping (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            ConsoleIO.writeMessage("Only Support x64", .error)
            handle(false)
            return
        }
        
        let header = binary.extract(mach_header_64.self)
        var symtab: symtab_command!
        var offset_machO = MemoryLayout.size(ofValue: header)
        for _ in 0..<header.ncmds {
            let loadCommand = binary.extract(load_command.self, offset: offset_machO)
            if loadCommand.cmd == LC_SYMTAB {
                symtab = binary.extract(symtab_command.self, offset: offset_machO)
                if isByteSwapped {
                    swap_symtab_command(&symtab, byteSwappedOrder)
                }
                break
            }
            offset_machO += Int(loadCommand.cmdsize)
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
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            symbolGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueClass, group: symbolGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                let offsetS = sub.rawValueBig().int16Replace().alignment()
                if offsetS > 0 {
                    var oc = ObjcClass.OC(binary, offset: offsetS)
                    
                    let isa = DataStruct.data(binary, offset: offsetS, length: 8)
                    let metaClassOffset = isa.value.int16Replace().alignment()
                    oc.classMethods = ObjcClass.OC(binary, offset: metaClassOffset).classRO?.baseMethod
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
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            categoryGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueCategory, group: categoryGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                let offsetS = sub.rawValueBig().int16Replace().alignment()
                ObjcCategory.OCCG(binary, offset: offsetS).serialization()
                categoryGroup.leave()
            }
        }
    }
    
    private static func handle__objc_protolist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            dyldGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueProtocol, group: dyldGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                let offsetS = sub.rawValueBig().int16Replace().alignment()
                let pr = ObjcProtocol.OCPT(binary, offset: offsetS)
                MachOData.shared.objcProtocols[pr.isa.address.int16()] = pr.name.className.value
                pr.serialization()
                dyldGroup.leave()
            }
        }
    }
}


extension Section {
    private static func handle__swift5_protos(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            dyldGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSwiftProtocols, group: dyldGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
                let offsetS = (Int(section.offset) + location + sub.rawValueBig().int16Subtraction()).alignment()
                let p = ProtocolDescriptor.PD(binary, offset: offsetS)
                p.serialization()
                MachOData.shared.swiftProtocols[offsetS] = p.name.swiftName.value
                dyldGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_proto(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            symbolGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSwiftProtocol, group: symbolGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
                let offsetS = (Int(section.offset) + location + sub.rawValueBig().int16Subtraction()).alignment()
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
                symbolGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_types(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            categoryGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSwiftTypes, group: categoryGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
                let offsetS = (Int(section.offset) + location + sub.rawValueBig().int16Subtraction()).alignment()
                let flags = SwiftFlags.SF(binary, offset: offsetS)
                switch flags.kind {
                case .Class:
                    let c = SwiftClass.SC(binary, offset: offsetS+4, flags: flags)
                    MachOData.shared.swiftClasses.append(c)
                    MachOData.shared.nominalOffsetMap[offsetS] = c.type.name.swiftName.value
                    MachOData.shared.mangledNameMap[c.type.fieldDescriptor.mangledTypeName.swiftName.value] = c.type.name.swiftName.value
                    break
                case .Enum:
                    let e = SwiftEnum.SE(binary, offset: offsetS+4, flags: flags)
                    MachOData.shared.swiftEnum.append(e)
                    MachOData.shared.nominalOffsetMap[offsetS] = e.type.name.swiftName.value
                    MachOData.shared.mangledNameMap[e.type.fieldDescriptor.mangledTypeName.swiftName.value] = e.type.name.swiftName.value
                    break
                case .Struct:
                    let s = SwiftStruct.SS(binary, offset: offsetS+4, flags: flags)
                    MachOData.shared.swiftStruct.append(s)
                    MachOData.shared.nominalOffsetMap[offsetS] = s.type.name.swiftName.value
                    MachOData.shared.mangledNameMap[s.type.fieldDescriptor.mangledTypeName.swiftName.value] = s.type.name.swiftName.value
                    break
                default:
                    break
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
                MachOData.shared.swiftCapture.append(SwiftCapture.SC(binary, offset: &index))
            }
            categoryGroup.leave()
        }
    }
}


extension Section {
    private static func handle_string_table(_ binary: Data, symtab: symtab_command) {
        let stringTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.stroff), length: Int(symtab.strsize)))!)
        dyldGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueStringTable, group: dyldGroup, count: activeProcessorCount) {
            var index = 0
            while index < stringTable.count {
                var strData = Data()
                var item = stringTable[index]
                let start = index
                while item != 0 {
                    strData.append(item)
                    index += 1
                    item = stringTable[index]
                }
                if let s = String(data: strData, encoding: String.Encoding.utf8), s.count > 0  {
                    MachOData.shared.stringTable[start.string16()] = s
                }
                index += 1
            }
            dyldGroup.leave()
        }
    }
    
    private static func handle_symbol_table(_ binary: Data, symtab: symtab_command, dumpSymbol: Bool = false) {
        let offsetStart = Int(symtab.symoff)
        for i in 0..<symtab.nsyms {
            dyldGroup.enter()
            DispatchLimitQueue.shared.limit(queue: queueSymbol, group: symbolGroup, count: activeProcessorCount) {
                let nlist = Nlist.nlist(binary, offset: offsetStart+Int(i)*16)
                if dumpSymbol {
                    ConsoleIO.writeMessage("\(nlist.valueAddress.value) \(nlist.name() ?? "")")
                } else {
                    MachOData.shared.symbolTable[nlist.valueAddress.value] = nlist
                }
                dyldGroup.leave()
            }
        }
    }
    
    private static func handle__swift5_ref(_ binary: Data, section: section_64) {
        let stringTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        dyldGroup.enter()
        DispatchLimitQueue.shared.limit(queue: queueSwiftRef, group: dyldGroup, count: activeProcessorCount) {
            var index = 0
            while index < stringTable.count {
                var strData = Data()
                var item = stringTable[index]
                let start = index
                while item != 0 {
                    strData.append(item)
                    index += 1
                    item = stringTable[index]
                }
                if let s = String(data: strData, encoding: String.Encoding.utf8), s.count > 0 {
                    MachOData.shared.nominalOffsetMap[Int(section.offset)+start] = s
                }
                index += 1
            }
            dyldGroup.leave()
        }
    }
}
