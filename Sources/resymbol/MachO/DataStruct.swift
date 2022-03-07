//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

let None = "00000000"

struct DataStruct {
    let address: String
    #if DEBUG_FLAG
    let data: Data
    let dataString: String
    #endif
    let value: String
    
    static func data(_ binary: Data, offset: Int, length: Int) -> DataStruct {
        if offset > 0 && offset < binary.count {
            let b = binary.subdata(in: Range<Data.Index>(NSRange(location: offset, length: length))!)
            #if DEBUG_FLAG
            return DataStruct(address: offset.string16(), data: b, dataString: b.rawValue(), value: b.rawValueBig())
            #endif
            return DataStruct(address: offset.string16(), value: b.rawValueBig())
        } else {
            return DataStruct(address: offset.string16(), value: None)
        }
    }

    static func textData(_ binary: Data, offset: Int, demangle: Bool = false) -> DataStruct {
        // 如果上来就是空的，说明没有这个东西
        if offset < 0 || offset > binary.count || binary[offset] == 0 {
            return DataStruct(address: offset.string16(), value: None)
        }
        var start = offset
        var strData = Data()
        while true {
            let item = binary[start]
            if item != 0 {
                strData.append(item)
            } else {
                if strData.count > 0 {
                    let strValue = String(data: strData, encoding: String.Encoding.utf8) ?? ""
                    let address = offset.string16()
                    if strValue.count > 0 && (demangle || strValue.hasPrefix("_")) {
                        if let s = swift_demangle(strValue) {
                            #if DEBUG_FLAG
                            return DataStruct(address: address, data: strData, dataString: strData.rawValue(), value: s)
                            #endif
                            return DataStruct(address: address, value: s)
                        }
                    }
                    #if DEBUG_FLAG
                    return DataStruct(address: address, data: strData, dataString: strData.rawValue(), value: strValue)
                    #endif
                    return DataStruct(address: address, value: strValue)
                }
            }
            start += 1
        }
    }
    
    static func textSwiftData(_ binary: Data, offset: Int, isMangledName: Bool, isClassName: Bool) -> DataStruct {
        // 如果上来就是空的，说明没有这个东西
        if offset < 0 || offset > binary.count || binary[offset] == 0 {
            return DataStruct(address: offset.string16(), value: None)
        }
        var start = offset
        var strData = Data()
        while true {
            let item = binary[start]
//            let itemNext = binary[start+1]
//            if isMangledName && strData.first == 0x2 {
//                if item == 0 && itemNext == 0 {
//                    return read(strData: strData, offset: offset, isMangledName: isMangledName, isClassName: isClassName)
//                }
//            } else {
                if item == 0 {
                    return read(strData: strData, offset: offset, isMangledName: isMangledName, isClassName: isClassName)
                }
//            }
            strData.append(item)
            start += 1
        }
    }
    
    private static func read(strData: Data, offset: Int, isMangledName: Bool, isClassName: Bool) -> DataStruct {
        var strValue = ""
        let address = offset.string16()
        if let s = String(data: strData, encoding: String.Encoding.utf8), s.isAsciiStr() {
            strValue = s
        } else {
            strValue = "0x\(strData.rawValue())"
        }
        if isClassName, let s = swift_demangle(strValue) {
            #if DEBUG_FLAG
            return DataStruct(address: address, data: strData, dataString: strData.rawValue(), value: s)
            #endif
            return DataStruct(address: address, value: s)
        } else {
            let result = getTypeFromMangledName(strValue)
            if result == strValue, let s = swift_demangle("$s" + strValue), s != result {
                #if DEBUG_FLAG
                return DataStruct(address: address, data: strData, dataString: strData.rawValue(), value: s)
                #endif
                return DataStruct(address: address, value: s)
            } else {
                #if DEBUG_FLAG
                return DataStruct(address: address, data: strData, dataString: strData.rawValue(), value: getTypeFromMangledName(strValue))
                #endif
                return DataStruct(address: address, value: getTypeFromMangledName(strValue))
            }
        }
    }
}
