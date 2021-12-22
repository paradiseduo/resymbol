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
    
    static var objcClassArr = [ObjcClassData]()
    static var classNames = [DataStruct]()
    static var methoedNames = [DataStruct]()
    
    static func readSection(binary: Data, type:BitType, isByteSwapped: Bool, handle: (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none {
            handle(false)
            return
        }
        
        if type == .x86 {
            
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
                        if String(rawCChar: sect.segname).contains("__TEXT") {
                            let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(sect.offset), length: Int(sect.size)))!)
                            if let s = String(data: d, encoding: String.Encoding.utf8) {
                                var valueStr = ""
                                var offset = sect.offset
                                let end = UInt64(offset) + sect.size
                                var length = 0
                                for item in s {
                                    if offset >= end {
                                        break
                                    } else {
                                        if item != "\0" {
                                            valueStr += String(item)
                                            length += 1
                                        } else {
                                            if valueStr.count > 0 {
                                                let dataValue = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(offset-UInt32(valueStr.count)), length: length))!)
                                                let ds = DataStruct(address: String(format: "%08x", offset-UInt32(length)), data: dataValue, dataString: dataValue.rawValue(), value: valueStr)
                                                switch String(rawCChar: sect.sectname) {
                                                case "__objc_classname__objc_classname":
                                                    classNames.append(ds)
                                                    break
                                                case "__objc_methname":
                                                    methoedNames.append(ds)
                                                    break
                                                default:
                                                    break
                                                }
                                            }
                                            valueStr = ""
                                            length = 0
                                        }
                                    }
                                    offset += 1
                                }
                            }
                        } else if String(rawCChar: sect.segname).contains("__DATA") {
                            switch String(rawCChar: sect.sectname) {
                            case "__objc_classlist__objc_classlist":
                                let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(sect.offset), length: Int(sect.size)))!)
                                let count = d.count>>3
                                for i in 0..<count {
                                    let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
                                    let offsetS = Int(sub.rawValueBig().replacingOccurrences(of: "00000001", with: ""), radix: 16) ?? 0
                                    let isa = DataStruct.data(binary, offset: offsetS, length: 8)
                                    let superClass = DataStruct.data(binary, offset: offsetS+8, length: 8)
                                    let cache = DataStruct.data(binary, offset: offsetS+16, length: 8)
                                    let cacheMask = DataStruct.data(binary, offset: offsetS+24, length: 4)
                                    let cacheOccupied = DataStruct.data(binary, offset: offsetS+28, length: 4)
                                    let classData = DataStruct.data(binary, offset: offsetS+32, length: 8)
                                    
                                    let offsetCD = Int(classData.value.replacingOccurrences(of: "00000001", with: ""), radix: 16) ?? 0
                                    let flag = DataStruct.data(binary, offset: offsetCD, length: 4)
                                    let instanceStart = DataStruct.data(binary, offset: offsetCD+4, length: 4)
                                    let instanceSize = DataStruct.data(binary, offset: offsetCD+8, length: 4)
                                    let reserved = DataStruct.data(binary, offset: offsetCD+12, length: 4)
                                    let ivarlayout = DataStruct.data(binary, offset: offsetCD+16, length: 8)
                                    let name = DataStruct.data(binary, offset: offsetCD+24, length: 8)
                                    
                                    var classds = DataStruct(address: "", data: Data(), dataString: "", value: "")
                                    for item in classNames {
                                        if item.address == name.value.replacingOccurrences(of: "00000001", with: "") {
                                            classds = item
                                        }
                                    }
                                    
                                    let baseMethod = DataStruct.data(binary, offset: offsetCD+32, length: 8)
                                    let baseProtocol = DataStruct.data(binary, offset: offsetCD+40, length: 8)
                                    let ivars = DataStruct.data(binary, offset: offsetCD+48, length: 8)
                                    let weakIvarLayout = DataStruct.data(binary, offset: offsetCD+56, length: 8)
                                    let baseProperties = DataStruct.data(binary, offset: offsetCD+64, length: 8)
                                    
                                    let objcClass = ObjcClassData(isa: isa,
                                                                  superClass: superClass,
                                                                  cache: cache,
                                                                  cacheMask: cacheMask,
                                                                  cacheOccupied: cacheOccupied,
                                                                  classData: classData,
                                                                  flags: (flag, RO.flags(Int(flag.value, radix: 16) ?? 0)),
                                                                  instanceStart: instanceStart,
                                                                  instanceSize: instanceSize,
                                                                  reserved: reserved,
                                                                  ivarlayout: ivarlayout,
                                                                  name: (name, classds),
                                                                  baseMethod: baseMethod,
                                                                  baseProtocol: baseProtocol,
                                                                  ivars: ivars,
                                                                  weakIvarLayout: weakIvarLayout,
                                                                  baseProperties: baseProperties
                                    )
                                    objcClassArr.append(objcClass)
                                }
                                break
                            default:
                                break
                            }
                        }
                        
                        offset_segment += 0x50
                    }
                }
                offset_machO += Int(loadCommand.cmdsize)
            }
        }
        for item in objcClassArr {
            item.description()
        }
        handle(true)
    }
}
