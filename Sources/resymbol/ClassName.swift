//
//  File.swift
//  
//
//  Created by admin on 2021/12/22.
//

import Foundation

struct ClassName {
    let name: DataStruct
    let className: DataStruct
    
    static func className(_ binary: Data, startOffset: Int) -> ClassName {
        let name = DataStruct.data(binary, offset: startOffset, length: 8)
        var className = DataStruct(address: "", data: Data(), dataString: "", value: "")
        let newOffset = name.value.int16Replace()
        let sub = binary.subdata(in: Range<Data.Index>(NSRange(location: newOffset, length: 128))!)
        let end = newOffset + 128
        var offset = newOffset
        var strData = Data()
        for item in sub {
            if offset >= end {
                break
            } else {
                if item != 0 {
                    strData.append(item)
                } else {
                    if strData.count > 0 {
                        let strValue = String(data: strData, encoding: String.Encoding.utf8) ?? ""
                        let address = (Int(offset)-strData.count).string16()
                        className = DataStruct(address: address, data: strData, dataString: strData.rawValue(), value: strValue)
                    }
                    break
                }
            }
            offset += 1
        }
        
        return ClassName(name: name, className: className)
    }
}
