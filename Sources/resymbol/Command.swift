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
    
    static func readSection(type:BitType, isByteSwapped: Bool, handle: (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none {
            handle(false)
            return
        }
        let binary = MachOData.shared.binary
                
        if type == .x86 {
            print("Not Support x86")
            handle(false)
            return
        } else {
            let header = binary.extract(mach_header_64.self)
            var offset_machO = MemoryLayout.size(ofValue: header)
            for _ in 0..<header.ncmds {
                let loadCommand = binary.extract(load_command.self, offset: offset_machO)
                if loadCommand.cmd == LC_SEGMENT_64 {
                    var segment = binary.extract(segment_command_64.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_segment_command_64(&segment, byteSwappedOrder)
                    }
                    var offset_segment = offset_machO + 0x48
                    for _ in 0..<segment.nsects {
                        let sect = binary.extract(section_64.self, offset: offset_segment)
                        let segname = String(rawCChar: sect.segname)
                        if segname.hasPrefix("__DATA") {
                            let sectname = String(rawCChar: sect.sectname)
                            if sectname == "__objc_classlist__objc_classlist" {
                                handle__objc_classlist(binary, section: sect)
                            } else if sectname == "__objc_catlist" {
                                handle__objc_catlist(binary, section: sect)
                            }
                        }
                        offset_segment += 0x50
                    }
                } else if loadCommand.cmd == LC_SYMTAB {
                    var symtab = binary.extract(symtab_command.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_symtab_command(&symtab, byteSwappedOrder)
                    }
                    let symbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.symoff), length: Int(symtab.nsyms*16)))!)
                    print(symbolTable)
                    let stringTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.stroff), length: Int(symtab.strsize)))!)
                    print(stringTable)
                } else if loadCommand.cmd == LC_DYSYMTAB {
                    var dysymtab = binary.extract(dysymtab_command.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_dysymtab_command(&dysymtab, byteSwappedOrder)
                    }
                    let indirectSymbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(dysymtab.indirectsymoff), length: Int(dysymtab.nindirectsyms*4)))!)
                    print(indirectSymbolTable)
                }
                offset_machO += Int(loadCommand.cmdsize)
            }
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
            let isa = DataStruct.data(binary, offset: offsetS, length: 8)
            let superClass = DataStruct.data(binary, offset: offsetS+8, length: 8)
            let cache = DataStruct.data(binary, offset: offsetS+16, length: 8)
            let cacheMask = DataStruct.data(binary, offset: offsetS+24, length: 4)
            let cacheOccupied = DataStruct.data(binary, offset: offsetS+28, length: 4)
            let classData = DataStruct.data(binary, offset: offsetS+32, length: 8)

            var offsetCD = classData.value.int16Replace()
            if offsetCD % 4 != 0 {
                offsetCD -= offsetCD%4
            }
            let flag = DataStruct.data(binary, offset: offsetCD, length: 4)
            let instanceStart = DataStruct.data(binary, offset: offsetCD+4, length: 4)
            let instanceSize = DataStruct.data(binary, offset: offsetCD+8, length: 4)
            let reserved = DataStruct.data(binary, offset: offsetCD+12, length: 4)
            let ivarlayout = DataStruct.data(binary, offset: offsetCD+16, length: 8)
            let name = ClassName.className(binary, startOffset: offsetCD+24)
            
            let baseMethod = Methods.methods(binary, startOffset: offsetCD+32)
            let baseProtocol = Protocols.protocols(binary, startOffset: offsetCD+40)
            let ivars = InstanceVariables.instances(binary, startOffset: offsetCD+48)
            let weakIvarLayout = DataStruct.data(binary, offset: offsetCD+56, length: 8)
            let baseProperties = Properties.properties(binary, startOffset: offsetCD+64)

            ObjcClassData(isa: isa,
                          superClass: superClass,
                          cache: cache,
                          cacheMask: cacheMask,
                          cacheOccupied: cacheOccupied,
                          classData: classData,
                          flags: (flag, RO.flags(flag.value.int16())),
                          instanceStart: instanceStart,
                          instanceSize: instanceSize,
                          reserved: reserved,
                          ivarlayout: ivarlayout,
                          name: name,
                          baseMethod: baseMethod,
                          baseProtocol: baseProtocol,
                          ivars: ivars,
                          weakIvarLayout: weakIvarLayout,
                          baseProperties: baseProperties
            ).write()
        }
    }
    
    private static func handle__objc_catlist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            let name = DataStruct.data(binary, offset: offsetS, length: 8)
            let _class = DataStruct.data(binary, offset: offsetS+8, length: 8)
            let methodList = DataStruct.data(binary, offset: offsetS+8, length: 8)
        }
    }
}
