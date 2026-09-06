//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/2/14.
//

import Foundation
import MachO

struct CaptureTypeRecord {
    let mangledTypeName: SwiftName
    
    static func CTR(_ binary: Data, offset: inout Int) -> CaptureTypeRecord {
        let mangledTypeName = SwiftName.SN(binary, offset: offset, isMangledName: false, isClassName: false)
        offset += 4
        return CaptureTypeRecord(mangledTypeName: mangledTypeName)
    }
}

struct MetadataSourceRecord {
    let mangledTypeName: SwiftName
    let mangledMetadataSource: SwiftName
    
    static func MSR(_ binary: Data, offset: inout Int) -> MetadataSourceRecord {
        let mangledTypeName = SwiftName.SN(binary, offset: offset, isMangledName: false, isClassName: false)
        offset += 4
        let mangledMetadataSource = SwiftName.SN(binary, offset: offset, isMangledName: false, isClassName: false)
        offset += 4
        return MetadataSourceRecord(mangledTypeName: mangledTypeName, mangledMetadataSource: mangledMetadataSource)
    }
}

struct SwiftCapture {
    let descriptorAddress: UInt64
    let symbolName: String?
    let numCaptureTypes: DataStruct
    let numMetadataSources: DataStruct
    let numBindings: DataStruct
    let captureTypeRecords: [CaptureTypeRecord]
    let metadataSourceRecords: [MetadataSourceRecord]
    
    static func SC(_ binary: Data, offset: inout Int, sectionAddress: UInt64, sectionOffset: UInt32) -> SwiftCapture {
        let descriptorOffset = offset
        let descriptorAddress = sectionAddress + UInt64(descriptorOffset - Int(sectionOffset))
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
        
        return SwiftCapture(descriptorAddress: descriptorAddress,
                            symbolName: resolveSymbol(at: descriptorAddress),
                            numCaptureTypes: numCaptureTypes,
                            numMetadataSources: numMetadataSources,
                            numBindings: numBindings,
                            captureTypeRecords: captureTypeRecords,
                            metadataSourceRecords: metadataSourceRecords)
    }

    private static func resolveSymbol(at address: UInt64) -> String? {
        let absoluteKey = String(format: "%016llx", address)
        if let name = MachOData.shared.symbolTable[absoluteKey]?.name(demangle: true), !name.isEmpty {
            return name
        }
        let relativeAddress = address > RVA ? address - RVA : address
        if let name = MachOData.shared.dylbMap[String(relativeAddress, radix: 16)], !name.isEmpty {
            return swift_demangle(name) ?? name
        }
        return nil
    }
    
    
    func serialization() {
        let label = symbolName ?? String(format: "0x%016llx", descriptorAddress)
        var result = "block \(label) {\n"
        result += "\t// captureTypeRecords\n"
        for item in captureTypeRecords {
            result += "\t\(fixMangledTypeName(item.mangledTypeName.swiftName))\n"
        }
        result += "\t// metadataSourceRecords\n"
        for item in metadataSourceRecords {
            result += "\t\(fixMangledTypeName(item.mangledTypeName.swiftName)): \(fixMangledTypeName(item.mangledMetadataSource.swiftName))\n"
        }
        result += "}\n"
        ConsoleIO.writeMessage(result)
    }
}
