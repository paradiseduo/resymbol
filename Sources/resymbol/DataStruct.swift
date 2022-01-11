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
        let b = binary.subdata(in: Range<Data.Index>(NSRange(location: offset, length: length))!)
        #if DEBUG_FLAG
        return DataStruct(address: String(format: "%08x", offset), data: b, dataString: b.rawValue(), value: b.rawValueBig())
        #endif
        return DataStruct(address: String(format: "%08x", offset), value: b.rawValueBig())
    }
    
    static func textData(_ binary: Data, offset: Int, isClassName: Bool = false) -> DataStruct {
        var start = offset
        var strData = Data()
        while true {
            let item = binary[start]
            if item != 0 {
                strData.append(item)
            } else {
                if strData.count > 0 {
                    let strValue = String(data: strData, encoding: String.Encoding.ascii) ?? ""
                    if isClassName {
                        if let s = swift_demangle(strValue) {
                            #if DEBUG_FLAG
                            return DataStruct(address: (Int(offset)-strData.count).string16(), data: strData, dataString: strData.rawValue(), value: s)
                            #endif
                            return DataStruct(address: (Int(offset)-strData.count).string16(), value: s)
                        }
                    }
                    #if DEBUG_FLAG
                    return DataStruct(address: (Int(offset)-strData.count).string16(), data: strData, dataString: strData.rawValue(), value: strValue)
                    #endif
                    return DataStruct(address: (Int(offset)-strData.count).string16(), value: strValue)
                }
            }
            start += 1
        }
    }
}
