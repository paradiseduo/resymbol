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
    
    static func readSection(_ binary: Data, type:BitType, isByteSwapped: Bool, handle: @escaping (Bool)->()) async {
        if type == .x64_fat || type == .x86_fat || type == .none || type == .x86 {
            print("Only Support x64")
            handle(false)
            return
        }
        
        var needSymbol = false
        
        let header = binary.extract(mach_header_64.self)
        var offset_machO = MemoryLayout.size(ofValue: header)
        for _ in 0..<header.ncmds {
            let loadCommand = binary.extract(load_command.self, offset: offset_machO)
            if loadCommand.cmd == LC_SEGMENT_64 {
                var segment = binary.extract(segment_command_64.self, offset: offset_machO)
                if isByteSwapped {
                    swap_segment_command_64(&segment, byteSwappedOrder)
                }
                let segmentSegname = String(rawCChar: segment.segname)
                MachOData.shared.vmAddress.append(segment.vmaddr)
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
                                MachOData.shared.classSections.append(section)
                            } else if sectname.contains("objc_catlist") || sectname.contains("objc_nlcatlist"){
                                MachOData.shared.categorySections.append(section)
                            } else if sectname.contains("objc_protolist") {
                                MachOData.shared.objc_protolist = section
                            }
                        } else if sectionSegname.hasPrefix("__TEXT") {
                            let sectname = String(rawCChar: section.sectname)
                            if sectname == "__swift5_proto" {
                                MachOData.shared.swiftProtoSection = section
                            } else if sectname.contains("__swift5_protos") {
                                MachOData.shared.swift5_protos = section
                            } else if sectname.contains("__swift5_types") {
                                MachOData.shared.swiftTypeSection = section
                            } else if sectname.contains("__swift5_typeref") || sectname.contains("__swift5_reflstr") {
                                MachOData.shared.swift5_ref = section
                            } else if sectname.contains("__swift5_assocty") {
                                MachOData.shared.assocty = section
                            } else if sectname.contains("__swift5_builtin") {
                                MachOData.shared.builtin = section
                            } else if sectname.contains("__swift5_capture") {
                                MachOData.shared.capture = section
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
                MachOData.shared.dylib = dylib
            } else if loadCommand.cmd == LC_SYMTAB {
                if needSymbol {
                    var symtab = binary.extract(symtab_command.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_symtab_command(&symtab, byteSwappedOrder)
                    }
                    MachOData.shared.symtab = symtab
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
        
        Task {
            await withTaskGroup(of: Void.self, body: { dyldGroup in
                dyldGroup.addTask {
                    await bindingDylb(binary)
                }
                dyldGroup.addTask {
                    await readSymbol(binary)
                }
                dyldGroup.addTask {
                    if let section = MachOData.shared.objc_protolist {
                        await handle__objc_protolist(binary, section: section)
                    }
                }
                dyldGroup.addTask {
                    if let section = MachOData.shared.swift5_protos {
                        await handle__swift5_protos(binary, section: section)
                    }
                }
                dyldGroup.addTask {
                    if let section = MachOData.shared.swift5_ref {
                        await handle__swift5_ref(binary, section: section)
                    }
                }
                dyldGroup.addTask {
                    if let section = MachOData.shared.assocty {
                        await handle__swift5_assocty(binary, section: section)
                    }
                }
                dyldGroup.addTask {
                    if let section = MachOData.shared.builtin {
                        await handle__swift5_builtin(binary, section: section)
                    }
                }
                dyldGroup.addTask {
                    if let section = MachOData.shared.capture {
                        await handle__swift5_capture(binary, section: section)
                    }
                }
            })
            Task {
                await withTaskGroup(of: Void.self, body: { classGroup in
                    classGroup.addTask {
                        for section in MachOData.shared.classSections {
                            await handle__objc_classlist(binary, section: section)
                        }
                    }
                    classGroup.addTask {
                        if let section = MachOData.shared.swiftProtoSection {
                            await handle__swift5_proto(binary, section: section)
                        }
                    }
                })
                Task {
                    await withTaskGroup(of: Void.self, body: { categoryGroup in
                        categoryGroup.addTask {
                            if let section = MachOData.shared.swiftTypeSection {
                                await handle__swift5_types(binary, section: section)
                            }
                        }
                        categoryGroup.addTask {
                            for section in MachOData.shared.categorySections {
                                await handle__objc_catlist(binary, section: section)
                            }
                        }
                    })
                    Task {
                        await withTaskGroup(of: Void.self, body: { printGroup in
                            printGroup.addTask {
                                let c = await MachOData.shared.swiftClasses.count
                                for i in 0..<c {
                                    await MachOData.shared.swiftClasses[i]?.serialization()
                                }
                            }
                            printGroup.addTask {
                                let c = await MachOData.shared.swiftStruct.count
                                for i in 0..<c {
                                    await MachOData.shared.swiftStruct[i]?.serialization()
                                }
                            }
                            printGroup.addTask {
                                let c = await MachOData.shared.swiftEnum.count
                                for i in 0..<c {
                                    await MachOData.shared.swiftEnum[i]?.serialization()
                                }
                            }
                            printGroup.addTask {
                                let c = await MachOData.shared.swiftAssocty.count
                                for i in 0..<c {
                                    await MachOData.shared.swiftAssocty[i]?.serialization()
                                }
                            }
                            printGroup.addTask {
                                let c = await MachOData.shared.swiftBuiltin.count
                                for i in 0..<c {
                                    await MachOData.shared.swiftBuiltin[i]?.serialization()
                                }
                            }
                            printGroup.addTask {
                                let c = await MachOData.shared.swiftCapture.count
                                for i in 0..<c {
                                    await MachOData.shared.swiftCapture[i]?.serialization()
                                }
                            }
                        })
                        DispatchQueue.main.async {
                            handle(true)
                        }
                    }
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
        Task {
            await withTaskGroup(of: Void.self, body: { group in
                group.addTask {
                    let header = binary.extract(mach_header_64.self)
                    var offset_machO = MemoryLayout.size(ofValue: header)
                    for _ in 0..<header.ncmds {
                        let loadCommand = binary.extract(load_command.self, offset: offset_machO)
                        if loadCommand.cmd == LC_SYMTAB {
                            var symtab = binary.extract(symtab_command.self, offset: offset_machO)
                            if isByteSwapped {
                                swap_symtab_command(&symtab, byteSwappedOrder)
                            }
                            MachOData.shared.symtab = symtab
                            await readSymbol(binary)
                            break
                        }
                        offset_machO += Int(loadCommand.cmdsize)
                    }
                }
                DispatchQueue.main.async {
                    handle(true)
                }
            })
        }
    }
    
    private static func bindingDylb(_ binary: Data) async {
        if let dylib = MachOData.shared.dylib {
            await Dyld.binding(binary, vmAddress: MachOData.shared.vmAddress, start: Int(dylib.bind_off), end: Int(dylib.bind_off+dylib.bind_size))
            await Dyld.binding(binary, vmAddress: MachOData.shared.vmAddress, start: Int(dylib.weak_bind_off), end: Int(dylib.weak_bind_off+dylib.weak_bind_size))
            await Dyld.binding(binary, vmAddress: MachOData.shared.vmAddress, start: Int(dylib.lazy_bind_off), end: Int(dylib.lazy_bind_off+dylib.lazy_bind_size), isLazy: true)
        }
    }
    
    private static func readSymbol(_ binary: Data, dumpSymbol: Bool = false) async {
        if let symtab = MachOData.shared.symtab {
            await handle_string_table(binary, symtab: symtab)
            await handle_symbol_table(binary, symtab: symtab, dumpSymbol: dumpSymbol)
        }
    }
}


extension Section {
    private static func handle__objc_classlist(_ binary: Data, section: section_64) async {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
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
                await MachOData.shared.objcClasses.set(oc.isa.address.int16(), oc.classRO.name.className.value)
                await oc.serialization()
            }
        }
    }
    
    private static func handle__objc_catlist(_ binary: Data, section: section_64) async {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            await ObjcCategory.OCCG(binary, offset: offsetS).serialization()
        }
    }
    
    private static func handle__objc_protolist(_ binary: Data, section: section_64) async {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            let pr = ObjcProtocol.OCPT(binary, offset: offsetS)
            await MachOData.shared.objcProtocols.set(pr.isa.address.int16(), pr.name.className.value)
            pr.serialization()
        }
    }
}


extension Section {
    private static func handle__swift5_protos(_ binary: Data, section: section_64) async {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            let location = i<<2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            var offsetS = Int(section.offset) + location + sub.rawValueBig().int16Subtraction()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            let p = ProtocolDescriptor.PD(binary, offset: offsetS)
            p.serialization()
            await MachOData.shared.swiftProtocols.set(offsetS, p.name.swiftName.value)
        }
    }
    
    private static func handle__swift5_proto(_ binary: Data, section: section_64) async {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            let location = i<<2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            var offsetS = Int(section.offset) + location + sub.rawValueBig().int16Subtraction()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            let p = SwiftProtocol.SP(binary, offset: offsetS)
            var nominalName = ""
            switch p.nominalTypeDescriptor.nominalTypeDescriptor.value.int16Subtraction() & 0x3 {
            case 0:
                nominalName = await MachOData.shared.nominalOffsetMap.get(p.nominalTypeDescriptor.nominalTypeDescriptor.address.int16()) ?? ""
                if nominalName.isEmpty {
                    await MachOData.shared.nominalOffsetMap.set(p.nominalTypeDescriptor.nominalTypeDescriptor.address.int16(), p.nominalTypeDescriptor.nominalTypeName.value)
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
    }
    
    private static func handle__swift5_types(_ binary: Data, section: section_64) async {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>2
        for i in 0..<count {
            let location = i<<2
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: location, length: 4))!)
            var offsetS = Int(section.offset) + location + sub.rawValueBig().int16Subtraction()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            let flags = SwiftFlags.SF(binary, offset: offsetS)
            switch flags.kind {
            case .Class:
                let c = SwiftClass.SC(binary, offset: offsetS+4, flags: flags)
                await MachOData.shared.swiftClasses.append(c)
                await MachOData.shared.nominalOffsetMap.set(offsetS, c.type.name.swiftName.value)
                await MachOData.shared.mangledNameMap.set(c.type.fieldDescriptor.mangledTypeName.swiftName.value, c.type.name.swiftName.value)
                break
            case .Enum:
                let e = SwiftEnum.SE(binary, offset: offsetS+4, flags: flags)
                await MachOData.shared.swiftEnum.append(e)
                await MachOData.shared.nominalOffsetMap.set(offsetS, e.type.name.swiftName.value)
                await MachOData.shared.mangledNameMap.set(e.type.fieldDescriptor.mangledTypeName.swiftName.value, e.type.name.swiftName.value)
                break
            case .Struct:
                let s = SwiftStruct.SS(binary, offset: offsetS+4, flags: flags)
                await MachOData.shared.swiftStruct.append(s)
                await MachOData.shared.nominalOffsetMap.set(offsetS, s.type.name.swiftName.value)
                await MachOData.shared.mangledNameMap.set(s.type.fieldDescriptor.mangledTypeName.swiftName.value, s.type.name.swiftName.value)
                break
            default:
                break
            }
        }
    }
    
    private static func handle__swift5_assocty(_ binary: Data, section: section_64) async {
        var index = Int(section.offset)
        let end = Int(section.offset) + Int(section.size)
        while index < end {
            await MachOData.shared.swiftAssocty.append(SwiftAssocty.SA(binary, offset: &index))
        }
    }
    
    private static func handle__swift5_builtin(_ binary: Data, section: section_64) async {
        var index = Int(section.offset)
        let end = Int(section.offset) + Int(section.size)
        while index < end {
            await MachOData.shared.swiftBuiltin.append(SwiftBuiltin.SB(binary, offset: &index))
        }
    }
    
    private static func handle__swift5_capture(_ binary: Data, section: section_64) async {
        var index = Int(section.offset)
        let end = Int(section.offset) + Int(section.size)
        while index < end {
            await MachOData.shared.swiftCapture.append(SwiftCapture.SC(binary, offset: &index))
        }
    }
}


extension Section {
    private static func handle_string_table(_ binary: Data, symtab: symtab_command) async {
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
            await MachOData.shared.stringTable.set(index.string16(), String(data: strData, encoding: String.Encoding.utf8) ?? "")
        }
    }
    
    private static func handle_symbol_table(_ binary: Data, symtab: symtab_command, dumpSymbol: Bool = false) async {
        let offsetStart = Int(symtab.symoff)
        for i in 0..<symtab.nsyms {
            let nlist = Nlist.nlist(binary, offset: offsetStart+Int(i)*16)
            let name = await MachOData.shared.stringTable.get(nlist.stringTableIndex.value) ?? ""
            if dumpSymbol {
                print("\(nlist.valueAddress.value) \(name.count > 0 ? name : "PD\(i)")")
            } else {
                await MachOData.shared.symbolTable.set(nlist.valueAddress.value, name.count > 0 ? name : "PD\(i)")
            }
        }
    }
    
    private static func handle__swift5_ref(_ binary: Data, section: section_64) async {
        let stringTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        var index = 0
        while index < stringTable.count {
            var strData = Data()
            var item = stringTable[index]
            while item != 0 {
                strData.append(item)
                index += 1
                item = stringTable[index]
            }
            if let s = String(data: strData, encoding: String.Encoding.utf8), s.count > 0 {
                await MachOData.shared.nominalOffsetMap.set(Int(section.offset)+index-s.count, s)
            }
            index += 1
        }
    }
}
