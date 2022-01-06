//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/9/10.
//

import Foundation
import MachO

let byteSwappedOrder = NXByteOrder(rawValue: 0)

struct Section {
    
    static func readSection(_ binary: Data, type:BitType, isByteSwapped: Bool, handle: (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            print("Only Support x64")
            handle(false)
            return
        }
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
                if segmentSegname == "__DATA_CONST" || segmentSegname == "__DATA" {
                    var offset_segment = offset_machO + 0x48
                    for _ in 0..<segment.nsects {
                        let section = binary.extract(section_64.self, offset: offset_segment)
                        let sectionSegname = String(rawCChar: section.segname)
                        if sectionSegname.hasPrefix("__DATA") {
                            let sectname = String(rawCChar: section.sectname)
                            if sectname == "__objc_classlist__objc_classlist" || sectname == "__objc_nlclslist" {
                                handle__objc_classlist(binary, section: section)
                            } else if sectname == "__objc_catlist" {
                                handle__objc_catlist(binary, section: section)
                            } else if sectname == "__objc_protolist__objc_protolist" {
                                handle__objc_protolist(binary, section: section)
                            }
                        }
                        offset_segment += 0x50
                    }
                }
            } else if loadCommand.cmd == LC_DYLD_INFO || loadCommand.cmd == LC_DYLD_INFO_ONLY {
                var dylib = binary.extract(dyld_info_command.self, offset: offset_machO)
                if isByteSwapped {
                    swap_dyld_info_command(&dylib, byteSwappedOrder)
                }
                bindingDyld(binary, vmAddress: vmAddress, start: Int(dylib.bind_off), end: Int(dylib.bind_off+dylib.bind_size))
                bindingDyld(binary, vmAddress: vmAddress, start: Int(dylib.weak_bind_off), end: Int(dylib.weak_bind_off+dylib.weak_bind_size))
                bindingDyld(binary, vmAddress: vmAddress, start: Int(dylib.lazy_bind_off), end: Int(dylib.lazy_bind_off+dylib.lazy_bind_size), isLazy: true)
            } else if loadCommand.cmd == LC_SYMTAB {
                var symtab = binary.extract(symtab_command.self, offset: offset_machO)
                if isByteSwapped {
                    swap_symtab_command(&symtab, byteSwappedOrder)
                }
                let symbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.symoff), length: Int(symtab.nsyms*16)))!)
                printf(symbolTable)
                let stringTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.stroff), length: Int(symtab.strsize)))!)
                printf(stringTable)
            } else if loadCommand.cmd == LC_DYSYMTAB {
                var dysymtab = binary.extract(dysymtab_command.self, offset: offset_machO)
                if isByteSwapped {
                    swap_dysymtab_command(&dysymtab, byteSwappedOrder)
                }
                let indirectSymbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(dysymtab.indirectsymoff), length: Int(dysymtab.nindirectsyms*4)))!)
                printf(indirectSymbolTable)
            }
            offset_machO += Int(loadCommand.cmdsize)
        }
        handle(true)
    }
    
    private static func handle__objc_classlist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            var oc = ObjcClass.OC(binary, offset: offsetS)
            
            let isa = DataStruct.data(binary, offset: offsetS, length: 8)
            var metaClassOffset = isa.value.int16Replace()
            if metaClassOffset % 4 != 0 {
                metaClassOffset -= metaClassOffset%4
            }
            oc.classMethods = ObjcClass.OC(binary, offset: metaClassOffset).classRO.baseMethod
            oc.write()
        }
    }
    
    private static func handle__objc_catlist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        MachOData.shared.objcCategories.reserveCapacity(count)
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            MachOData.shared.objcCategories.append(ObjcCategory.OCCG(binary, offset: offsetS))
        }
    }
    
    private static func handle__objc_protolist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            ObjcProtocol.OCPT(binary, offset: offsetS).write()
        }
    }
    
    private static func bindingDyld(_ binary: Data, vmAddress:[UInt64], start: Int, end: Int, isLazy: Bool = false) {
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
                printf("BIND_OPCODE: SET_TYPE_IMM,                   type = \(type) \(CDBindType.description(immediate))   index: \(cccccc)")
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
                MachOData.shared.dylbMap(address, symbolName)
                bindCount += 1
                address &+= ptrSize
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
                let r = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: DO_BIND_ADD_ADDR_ULEB,          \(address) += \(ptrSize) + \(String(format: "%016llx", r))  index: \(cccccc)")
                MachOData.shared.dylbMap(address, symbolName)
                bindCount += 1
                address &+= (ptrSize &+ r)
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
                printf("BIND_OPCODE: DO_BIND_ADD_ADDR_IMM_SCALED,    \(address) += \(ptrSize) * \((ptrSize * UInt64(immediate)))  index: \(cccccc)")
                MachOData.shared.dylbMap(address, symbolName)
                bindCount += 1
                address &+= (ptrSize &+ (ptrSize * UInt64(immediate)))
                break
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
                let count = binary.read_uleb128(index: &index, end: end)
                let skip = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: DO_BIND_ULEB_TIMES_SKIPPING_ULEB, count: \(String(format: "%016llx", count)), skip: \(String(format: "%016llx", skip))  index: \(cccccc)")
                for _ in 0 ..< count {
                    MachOData.shared.dylbMap(address, symbolName)
                    address &+= (ptrSize &+ skip)
                }
                bindCount += count
                break
            default:
                break
            }
        }
        printf(MachOData.shared.dylbMap.keys.count, bindCount)
    }
}
