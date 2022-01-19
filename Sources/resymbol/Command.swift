//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/9/10.
//

import Foundation
import MachO

let byteSwappedOrder = NXByteOrder(rawValue: 0)

// 先进行dyld绑定和protocol的dump
let dyldGroup = DispatchGroup()
let queueDyld = DispatchQueue(label: "com.Dyld", qos: .unspecified, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSymbol = DispatchQueue(label: "com.Symbol", qos: .unspecified, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueProtocol = DispatchQueue(label: "com.Protocol", qos: .unspecified, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
let queueSwiftProtocol = DispatchQueue(label: "com.Swift.Protocol", qos: .unspecified, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)

// 再进行class的dump，因为superclass依赖dyld的绑定结果和protocol
let resymbolGroup = DispatchGroup()
let queueClass = DispatchQueue(label: "com.Class", qos: .unspecified, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)

// 再进行category的dump，因为category依赖于class list和dyld
let categoryGroup = DispatchGroup()
let queueCategory = DispatchQueue(label: "com.Category", qos: .unspecified, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)

let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount/2

struct Section {
    
    static func readSection(_ binary: Data, type:BitType, isByteSwapped: Bool, handle: @escaping (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            print("Only Support x64")
            handle(false)
            return
        }
        
        var categorySections = [section_64]()
        var classSections = [section_64]()
        var swiftProtoSection: section_64?
        var needSymbol = false
        
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
                            } else if sectname == "__swift5_protos" {
                                handle__swift5_protos(binary, section: section)
                            } else if sectname == "__swift5_types" {
                                handle__swift5_types(binary, section: section)
                            }
                        }
                        offset_segment += 0x50
                    }
                }
            } else if loadCommand.cmd == LC_DYLD_INFO || loadCommand.cmd == LC_DYLD_INFO_ONLY {
                bindingDylb(binary, offSet: offset_machO, isByteSwapped: isByteSwapped, vmAddress: vmAddress)
            } else if loadCommand.cmd == LC_SYMTAB {
                if needSymbol {
                    readSymbol(binary, offSet: offset_machO, isByteSwapped: isByteSwapped)
                }
            } else if loadCommand.cmd == LC_DYSYMTAB {
//                var dysymtab = binary.extract(dysymtab_command.self, offset: offset_machO)
//                if isByteSwapped {
//                    swap_dysymtab_command(&dysymtab, byteSwappedOrder)
//                }
//                let indirectSymbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(dysymtab.indirectsymoff), length: Int(dysymtab.nindirectsyms*4)))!)
//                printf(indirectSymbolTable)
            }
            offset_machO += Int(loadCommand.cmdsize)
        }
        
        dyldGroup.notify(queue: queueClass) {
            for section in classSections {
                handle__objc_classlist(binary, section: section)
            }
            if let section = swiftProtoSection {
                handle__swift5_proto(binary, section: section)
            }
            resymbolGroup.notify(queue: queueCategory) {
                for section in categorySections {
                    handle__objc_catlist(binary, section: section)
                }
                categoryGroup.notify(queue: DispatchQueue.main) {
                    handle(true)
                }
            }
        }
    }
    
    static func dumpSymbol(_ binary: Data, type:BitType, isByteSwapped: Bool, handle: @escaping (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            print("Only Support x64")
            handle(false)
            return
        }
        
        let header = binary.extract(mach_header_64.self)
        var offset_machO = MemoryLayout.size(ofValue: header)
        for _ in 0..<header.ncmds {
            let loadCommand = binary.extract(load_command.self, offset: offset_machO)
            if loadCommand.cmd == LC_SYMTAB {
                readSymbol(binary, offSet: offset_machO, isByteSwapped: isByteSwapped, dumpSymbol: true)
                break
            }
            offset_machO += Int(loadCommand.cmdsize)
        }
        dyldGroup.notify(queue: DispatchQueue.main) {
            handle(true)
        }
    }
    
    private static func bindingDylb(_ binary: Data, offSet: Int, isByteSwapped: Bool, vmAddress: [UInt64]) {
        var dylib = binary.extract(dyld_info_command.self, offset: offSet)
        if isByteSwapped {
            swap_dyld_info_command(&dylib, byteSwappedOrder)
        }
        queueDyld.async(group: dyldGroup) {
            readDyld(binary, vmAddress: vmAddress, start: Int(dylib.bind_off), end: Int(dylib.bind_off+dylib.bind_size))
        }
        queueDyld.async(group: dyldGroup) {
            readDyld(binary, vmAddress: vmAddress, start: Int(dylib.weak_bind_off), end: Int(dylib.weak_bind_off+dylib.weak_bind_size))
        }
        queueDyld.async(group: dyldGroup) {
            readDyld(binary, vmAddress: vmAddress, start: Int(dylib.lazy_bind_off), end: Int(dylib.lazy_bind_off+dylib.lazy_bind_size), isLazy: true)
        }
    }
    
    private static func readSymbol(_ binary: Data, offSet: Int, isByteSwapped: Bool, dumpSymbol: Bool = false) {
        var symtab = binary.extract(symtab_command.self, offset: offSet)
        if isByteSwapped {
            swap_symtab_command(&symtab, byteSwappedOrder)
        }
        queueSymbol.async(group: dyldGroup) {
            handle_string_table(binary, symtab: symtab)
        }
        queueSymbol.async(group: dyldGroup) {
            handle_symbol_table(binary, symtab: symtab, dumpSymbol: dumpSymbol)
        }
    }
    
    private static func handle__objc_classlist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            DispatchLimitQueue.shared.limit(queue: queueClass, group: resymbolGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                var offsetS = sub.rawValueBig().int16Replace()
                if offsetS % 4 != 0 {
                    offsetS -= offsetS%4
                }
                if offsetS > 0 {
                    var oc = ObjcClass.OC(binary, offset: offsetS)
                    
                    let isa = DataStruct.data(binary, offset: offsetS, length: 8)
                    var metaClassOffset = isa.value.int16Replace()
                    if metaClassOffset % 4 != 0 {
                        metaClassOffset -= metaClassOffset%4
                    }
                    oc.classMethods = ObjcClass.OC(binary, offset: metaClassOffset).classRO.baseMethod
                    MachOData.shared.objcClasses.set(key: oc.isa.address.int16(), vaule: oc.classRO.name.className.value)
                    oc.serialization()
                }
            }
        }
    }
    
    private static func handle__objc_catlist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            DispatchLimitQueue.shared.limit(queue: queueCategory, group: categoryGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                var offsetS = sub.rawValueBig().int16Replace()
                if offsetS % 4 != 0 {
                    offsetS -= offsetS%4
                }
                ObjcCategory.OCCG(binary, offset: offsetS).serialization()
            }
        }
    }
    
    private static func handle__swift5_protos(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            DispatchLimitQueue.shared.limit(queue: queueProtocol, group: dyldGroup, count: activeProcessorCount) {
                let location = i<<2
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
                var offsetS = Int(section.offset) + location + sub.rawValueBig().int16Subtraction()
                if offsetS % 4 != 0 {
                    offsetS -= offsetS%4
                }
                let p = ProtocolDescriptor.PD(binary, offset: offsetS)
                MachOData.shared.swiftProtocols.set(key: offsetS, vaule: p.name.swiftName.value)
            }
        }
    }
    
    private static func handle__swift5_proto(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            let location = i<<2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            var offsetS = Int(section.offset) + location + sub.rawValueBig().int16Subtraction()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            SwiftProtocol.SP(binary, offset: offsetS)
        }
    }
    
    private static func handle__swift5_types(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            let location = i<<2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            var offsetS = Int(section.offset) + location + sub.rawValueBig().int16Subtraction()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            let flags = DataStruct.data(binary, offset: offsetS, length:4)
        }
    }
    
    private static func handle__objc_protolist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            DispatchLimitQueue.shared.limit(queue: queueProtocol, group: dyldGroup, count: activeProcessorCount) {
                let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                
                var offsetS = sub.rawValueBig().int16Replace()
                if offsetS % 4 != 0 {
                    offsetS -= offsetS%4
                }
                let pr = ObjcProtocol.OCPT(binary, offset: offsetS)
                MachOData.shared.objcProtocols.set(key: pr.isa.address.int16(), vaule: pr.name.className.value)
                pr.serialization()
            }
        }
    }
    
    private static func handle_string_table(_ binary: Data, symtab: symtab_command) {
        let stringTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.stroff), length: Int(symtab.strsize)))!)
        var index = 0
        while index < stringTable.count {
            var strData = Data()
            var item = stringTable[index]
            while item != 0 {
                strData.append(item)
                index += 1
                item = stringTable[index]
            }
            index += 1
            MachOData.shared.stringTable.set(key: index.string16(), vaule: String(data: strData, encoding: String.Encoding.ascii) ?? "")
        }
    }
    
    private static func handle_symbol_table(_ binary: Data, symtab: symtab_command, dumpSymbol: Bool = false) {
        let offsetStart = Int(symtab.symoff)
        for i in 0..<symtab.nsyms {
            let nlist = Nlist.nlist(binary, offset: offsetStart+Int(i)*16)
            if dumpSymbol {
                print("\(nlist.valueAddress.value) \(nlist.name.count > 0 ? nlist.name : "PD\(i)")")
            } else {
                MachOData.shared.symbolTable.set(key: nlist.valueAddress.value, vaule: nlist.name.count > 0 ? nlist.name : "PD\(i)")
            }
        }
    }
    
    private static func readDyld(_ binary: Data, vmAddress:[UInt64], start: Int, end: Int, isLazy: Bool = false) {
        var done = false
        var symbolName = ""
        var libraryOrdinal: Int32 = 0
        var symbolFlags: Int32 = 0
        var type: Int32 = 0
        var addend: Int64 = 0
        var segmentIndex: Int32 = 0
        let ptrSize = UInt64(MemoryLayout<UInt64>.size)
        var bindCount: UInt64 = 0
        
        var index = start
        var address = vmAddress[0]
        var cccccc = 0
        while index < end && !done {
            let item = Int32(binary[index])
            let immediate = item & BIND_IMMEDIATE_MASK
            let opcode = item & BIND_OPCODE_MASK
            index += 1
            cccccc += 1
            switch opcode {
            case BIND_OPCODE_DONE:
                printf("BIND_OPCODE: DONE")
                if !isLazy {
                    done = true
                }
                break
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
                libraryOrdinal = immediate
                printf("BIND_OPCODE: SET_DYLIB_ORDINAL_IMM,          libraryOrdinal = \(libraryOrdinal)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
                libraryOrdinal = Int32(binary.read_uleb128(index: &index, end: end))
                printf("BIND_OPCODE: SET_DYLIB_ORDINAL_ULEB,         libraryOrdinal = \(libraryOrdinal)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
                if immediate == 0 {
                    libraryOrdinal = 0
                } else {
                    libraryOrdinal = immediate | BIND_OPCODE_MASK
                }
                printf("BIND_OPCODE: SET_DYLIB_SPECIAL_IMM,          libraryOrdinal = \(libraryOrdinal)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                var strData = Data()
                while binary[index] != 0 {
                    strData.append(contentsOf: [binary[index]])
                    index += 1
                }
                index += 1
                symbolName = String(data: strData, encoding: String.Encoding.utf8) ?? ""
                symbolFlags = immediate
                printf("BIND_OPCODE: SET_SYMBOL_TRAILING_FLAGS_IMM,  flags: \(String(format: "%02x", symbolFlags)), str = \(symbolName)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_TYPE_IMM:
                type = immediate
                printf("BIND_OPCODE: SET_TYPE_IMM,                   type = \(type) \(BindType.description(immediate))   index: \(cccccc)")
                break
            case BIND_OPCODE_SET_ADDEND_SLEB:
                addend = binary.read_sleb128(index: &index, end: end)
                printf("BIND_OPCODE: SET_ADDEND_SLEB,                addend = \(addend)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                segmentIndex = immediate
                let r = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: SET_SEGMENT_AND_OFFSET_ULEB,    segmentIndex: \(segmentIndex), offset: \(String(format: "0x%016llx", r))  index: \(cccccc)")
                address = (vmAddress[Int(segmentIndex)] &+ r)
                printf("    address = \(String(format: "0x%016llx", address))")
                break
            case BIND_OPCODE_ADD_ADDR_ULEB:
                let r = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: ADD_ADDR_ULEB,                  \(address) += \(String(format: "0x%016llx", r))  index: \(cccccc)")
                address &+= r
                break
            case BIND_OPCODE_DO_BIND:
                printf("BIND_OPCODE: DO_BIND")
                MachOData.shared.dylbMap.set(address: address, vaule: symbolName)
                bindCount += 1
                address &+= ptrSize
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
                let r = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: DO_BIND_ADD_ADDR_ULEB,          \(address) += \(ptrSize) + \(String(format: "%016llx", r))  index: \(cccccc)")
                MachOData.shared.dylbMap.set(address: address, vaule: symbolName)
                bindCount += 1
                address &+= (ptrSize &+ r)
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
                printf("BIND_OPCODE: DO_BIND_ADD_ADDR_IMM_SCALED,    \(address) += \(ptrSize) * \((ptrSize * UInt64(immediate)))  index: \(cccccc)")
                MachOData.shared.dylbMap.set(address: address, vaule: symbolName)
                bindCount += 1
                address &+= (ptrSize &+ (ptrSize * UInt64(immediate)))
                break
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
                let count = binary.read_uleb128(index: &index, end: end)
                let skip = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: DO_BIND_ULEB_TIMES_SKIPPING_ULEB, count: \(String(format: "%016llx", count)), skip: \(String(format: "%016llx", skip))  index: \(cccccc)")
                for _ in 0 ..< count {
                    MachOData.shared.dylbMap.set(address: address, vaule: symbolName)
                    address &+= (ptrSize &+ skip)
                }
                bindCount += count
                break
            default:
                break
            }
        }
    }
}
