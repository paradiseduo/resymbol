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
    
    static func textData(_ binary: Data, offset: UInt32, length: UInt64) -> [String: DataStruct] {
        var result = [String: DataStruct]()
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(offset), length: Int(length)))!)
        var offset = offset
        let end = UInt64(offset) + length
        var strData = Data()
        for item in d {
            if offset >= end {
                break
            } else {
                if item != 0 {
                    strData.append(item)
                } else {
                    if strData.count > 0 {
                        let strValue = String(data: strData, encoding: String.Encoding.utf8) ?? ""
                        let address = (Int(offset)-strData.count).string16()
                        result[address] = DataStruct(address: address, data: strData, dataString: strData.rawValue(), value: strValue)
                    }
                    strData = Data()
                }
            }
            offset += 1
        }
        return result
    }
}
