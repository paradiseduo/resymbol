//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

struct DataStruct {
    let address: String
    let data: Data
    let dataString: String
    let value: String
    
    static func data(_ binary: Data, offset: Int, length: Int) -> DataStruct {
        let b = binary.subdata(in: Range<Data.Index>(NSRange(location: offset, length: length))!)
        return DataStruct(address: String(format: "%08x", offset), data: b, dataString: b.rawValue(), value: b.rawValueBig())
    }
    
    static func textData(_ binary: Data, offset: Int) -> DataStruct {
        var start = offset
        var strData = Data()
        while true {
            let item = binary[start]
            if item != 0 {
                strData.append(item)
            } else {
                if strData.count > 0 {
                    let strValue = String(data: strData, encoding: String.Encoding.ascii) ?? ""
                    return DataStruct(address: (Int(offset)-strData.count).string16(), data: strData, dataString: strData.rawValue(), value: strValue)
                }
            }
            start += 1
        }
    }
}
