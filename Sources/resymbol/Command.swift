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
            ObjcClass.OC(binary, offset: offsetS).write()
            
            let isa = DataStruct.data(binary, offset: offsetS, length: 8)
            var metaClassOffset = isa.value.int16Replace()
            if metaClassOffset % 4 != 0 {
                metaClassOffset -= metaClassOffset%4
            }

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
            let name = ClassName.className(binary, startOffset: offsetS)//DataStruct.data(binary, offset: offsetS, length: 8)
            let _class = DataStruct.data(binary, offset: offsetS+8, length: 8)
            let instanceMethods = Methods.methods(binary, startOffset: offsetS+16)
            let classMethods = Methods.methods(binary, startOffset: offsetS+24)
            let protocols = Protocols.protocols(binary, startOffset: offsetS+32)
            let instanceProperties = Properties.properties(binary, startOffset: offsetS+40)
            
            ObjcCatData(name: name,
                        _class: _class,
                        instanceMethods: instanceMethods,
                        classMethods: classMethods,
                        protocols: protocols,
                        instanceProperties: instanceProperties).write()
        }
    }
}
