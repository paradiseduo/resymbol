//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/2/14.
//

import Foundation

struct CaptureTypeRecord {
    let mangledTypeName: SwiftName
    
    static func CTR(_ binary: Data, offset: inout Int) -> CaptureTypeRecord {
        let mangledTypeName = SwiftName.SN(binary, offset: offset, isClassName: false)
        offset += 4
        return CaptureTypeRecord(mangledTypeName: mangledTypeName)
    }
}

struct MetadataSourceRecord {
    let mangledTypeName: SwiftName
    let mangledMetadataSource: DataStruct
    
    static func MSR(_ binary: Data, offset: inout Int) -> MetadataSourceRecord {
        let mangledTypeName = SwiftName.SN(binary, offset: offset, isClassName: false)
        offset += 4
        let mangledMetadataSource = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        return MetadataSourceRecord(mangledTypeName: mangledTypeName, mangledMetadataSource: mangledMetadataSource)
    }
}

struct SwiftCapture {
    let numCaptureTypes: DataStruct
    let numMetadataSources: DataStruct
    let numBindings: DataStruct
    let captureTypeRecords: [CaptureTypeRecord]
    let metadataSourceRecords: [MetadataSourceRecord]
    
    static func SC(_ binary: Data, offset: inout Int) -> SwiftCapture {
        let numCaptureTypes = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let numMetadataSources = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        let numBindings = DataStruct.data(binary, offset: offset, length: 4)
        offset += 4
        
        var captureTypeRecords = [CaptureTypeRecord]()
        for _ in 0..<numCaptureTypes.value.int16() {
            captureTypeRecords.append(CaptureTypeRecord.CTR(binary, offset: &offset))
        }
        
        var metadataSourceRecords = [MetadataSourceRecord]()
        for _ in 0..<numMetadataSources.value.int16() {
            metadataSourceRecords.append(MetadataSourceRecord.MSR(binary, offset: &offset))
        }
        
        return SwiftCapture(numCaptureTypes: numCaptureTypes, numMetadataSources: numMetadataSources, numBindings: numBindings, captureTypeRecords: captureTypeRecords, metadataSourceRecords: metadataSourceRecords)
    }
    
    
    func serialization() {
        var result = "block \(numCaptureTypes.address) {\n"
        result += "\t// captureTypeRecords\n"
        for item in captureTypeRecords {
            result += "\t\(fixMangledTypeName(item.mangledTypeName.swiftName))\n"
        }
        result += "\t// metadataSourceRecords\n"
        for item in metadataSourceRecords {
            result += "\t\(fixMangledTypeName(item.mangledTypeName.swiftName)): \(item.mangledMetadataSource)\n"
        }
        result += "}\n"
        print(result)
    }
}

