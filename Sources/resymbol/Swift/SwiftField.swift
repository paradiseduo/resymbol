//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct FieldRecord {
    let flags: SwiftFlags
    let mangledTypeName: SwiftName
    let fieldName: SwiftName
    
    static func FR(_ binary: Data, offset: Int) -> FieldRecord {
        let flags = SwiftFlags.SF(binary, offset: offset)
        let mangledTypeName = SwiftName.SN(binary, offset: offset+4)
        let fieldName = SwiftName.SN(binary, offset: offset+8)
        return FieldRecord(flags: flags, mangledTypeName: mangledTypeName, fieldName: fieldName)
    }
    
    func fixMangledTypeName() -> String {
        let hexName: String = mangledTypeName.swiftName.value.ltrim("0x")
        let data = hexName.hexData
        let startAddress = data.count+mangledTypeName.swiftName.address.int16()
        
        var mangledName: String = ""
        var i: Int = 0
        
        while i < data.count {
            let val = data[i]
            if (val == 0x01) {
                //find
                let fromIdx: Int = i + 1 // ignore 0x01
                let toIdx: Int = i + 5 // 4 bytes
                if (toIdx > data.count) {
                    mangledName = mangledName + String(format: "%c", val)
                    i += 1
                    continue
                }
                let subData = data[fromIdx..<toIdx]
                let address = subData.rawValueBig().int16() + startAddress + fromIdx
                let result = MachOData.shared.nominalOffsetMap[address] ?? ""
                
                if (i == 0 && toIdx >= data.count) {
                    mangledName = mangledName + result // use original result
                } else {
                    let fixName = makeDemangledTypeName(result, header: "")
                    mangledName = mangledName + fixName
                }
                
                i += 5
            } else if (val == 0x02) {
                //indirectly
                let fromIdx: Int = i + 1 // ignore 0x02
                let toIdx: Int = ((i + 4) > data.count) ? data.count : (i + 4) // 4 bytes
                
                let subData = data[fromIdx..<toIdx]
                let address = subData.rawValueBig().int16() + startAddress + fromIdx
                let result = MachOData.shared.nominalOffsetMap[DataStruct.data(MachOData.shared.binary, offset: address, length: 4).value.int16()] ?? ""
                
                if (i == 0 && toIdx >= data.count) {
                    mangledName = mangledName + result
                } else {
                    let fixName = makeDemangledTypeName(result, header: mangledName)
                    mangledName = mangledName + fixName
                }
                i = toIdx + 1
            } else {
                //check next
                mangledName = mangledName + String(format: "%c", val)
                i += 1
            }
        }
        
        let result: String = getTypeFromMangledName(mangledName)
        if (result == mangledName) {
            if let s = swift_demangle("$s" + mangledName) {
                return s
            }
        }
        return result
    }
    
    func makeDemangledTypeName(_ type: String, header: String) -> String {
        let isArray: Bool = header.contains("Say") || header.contains("SDy")
        let suffix: String = isArray ? "G" : ""
        let fixName = "So\(type.count)\(type)C" + suffix
        return fixName
    }
}

struct FieldDescriptor {
    let fieldDescriptor: DataStruct
    let mangledTypeName: SwiftName
    let superclass: DataStruct
    let kind: DataStruct
    let fieldRecordSize: DataStruct
    let numFields: DataStruct
    let fieldRecords: [FieldRecord]
    
    static func FD(_ binary: Data, offset: Int) -> FieldDescriptor {
        let fieldDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        
        let newOffset = fieldDescriptor.address.int16()+fieldDescriptor.value.int16()
        
        let mangledTypeName = SwiftName.SN(binary, offset: newOffset)
        let superclass = DataStruct.data(binary, offset: newOffset+4, length: 4)
        let kind = DataStruct.data(binary, offset: newOffset+8, length: 2)
        let fieldRecordSize = DataStruct.data(binary, offset: newOffset+10, length: 2)
        let numFields = DataStruct.data(binary, offset: newOffset+12, length: 4)
        var fieldRecords = [FieldRecord]()
        
        if numFields.value.int16() < 128 {
            var fieldStart = newOffset+16
            for _ in 0..<numFields.value.int16() {
                fieldRecords.append(FieldRecord.FR(binary, offset: fieldStart))
                fieldStart += 12
            }
        }
        
        return FieldDescriptor(fieldDescriptor: fieldDescriptor, mangledTypeName: mangledTypeName, superclass: superclass, kind: kind, fieldRecordSize: fieldRecordSize, numFields: numFields, fieldRecords: fieldRecords)
    }
}
