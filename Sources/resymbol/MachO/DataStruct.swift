//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct DataStruct {
    let address: String
    #if DEBUG_FLAG
    let data: Data
    let dataString: String
    #endif
    let value: String
    
    static func data(_ binary: Data, offset: Int, length: Int) -> DataStruct {
        if offset > 0 {
            let b = binary[offset..<offset+length]
            #if DEBUG_FLAG
            return DataStruct(address: offset.string16(), data: b, dataString: b.rawValue(), value: b.rawValueBig())
            #endif
            return DataStruct(address: offset.string16(), value: b.rawValueBig())
        } else {
            return DataStruct(address: offset.string16(), value: "00000000")
        }
    }

    static func textData(_ binary: Data, offset: Int, demangle: Bool = false) -> DataStruct {
        // 如果上来就是空的，说明没有这个东西
        if binary[offset] == 0 {
            return DataStruct(address: offset.string16(), value: "00000000")
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
    
    static func textSwiftData(_ binary: Data, offset: Int, isClassName: Bool = false) -> DataStruct {
        // 如果上来就是空的，说明没有这个东西
        if binary[offset] == 0 {
            return DataStruct(address: offset.string16(), value: "00000000")
        }
        var start = offset
        var strData = Data()
        while true {
            let item = binary[start]
            if item != 0 {
                strData.append(item)
            } else {
                if strData.count > 0 {
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
            start += 1
        }
    }
}
