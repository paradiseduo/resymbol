//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct ProtocolDescriptor {
    let flags: SwiftFlags
    let parent: SwiftParent
    let name: SwiftName
    let numRequirementsInSignature: DataStruct
    let numRequirements: DataStruct
    let associatedTypeNames: DataStruct
    
    static func PD(_ binary: Data, offset: Int) -> ProtocolDescriptor {
        let flag = SwiftFlags.SF(binary, offset: offset)
        let parent = SwiftParent.SP(binary, offset: offset+4)
        let name = SwiftName.SN(binary, offset: offset+8)
        let numRequirementsInSignature = DataStruct.data(binary, offset: offset+12, length: 4)
        let numRequirements = DataStruct.data(binary, offset: offset+16, length: 4)
        let associatedTypeNames = DataStruct.data(binary, offset: offset+20, length: 4)
        return ProtocolDescriptor(flags: flag, parent: parent, name: name, numRequirementsInSignature: numRequirementsInSignature, numRequirements: numRequirements, associatedTypeNames: associatedTypeNames)
    }
}

struct SwiftProtocol {
    let protocolsDescriptor: DataStruct
    let nominalTypeDescriptor: DataStruct
    let protocolWitnessTable: DataStruct
    let conformanceFlags: DataStruct
    let protocolName: String
    
    static func SP(_ binary: Data, offset: Int) -> SwiftProtocol {
        let protocolsDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        let nominalTypeDescriptor = DataStruct.data(binary, offset: offset+4, length: 4)
        let protocolWitnessTable = DataStruct.data(binary, offset: offset+8, length: 4)
        let conformanceFlags = DataStruct.data(binary, offset: offset+12, length: 4)
        
        let newOffSet = protocolsDescriptor.value.int16()
        var key = 0
        if ((newOffSet & 0x1) == 1) { //如果是奇数
            // 相当于减1
            key = DataStruct.data(binary, offset: (newOffSet&0xFFFE)+offset, length: 4).value.int16()
        } else {
            key = newOffSet+offset
        }
        let protocolName = (MachOData.shared.swiftProtocols.get(key) as? String) ?? ""
        return SwiftProtocol(protocolsDescriptor: protocolsDescriptor, nominalTypeDescriptor: nominalTypeDescriptor, protocolWitnessTable: protocolWitnessTable, conformanceFlags: conformanceFlags, protocolName: protocolName)
    }
}
