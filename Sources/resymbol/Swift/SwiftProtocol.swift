//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct ProtocolDescriptor {
    let flags: DataStruct
    let parent: SwiftParent
    let name: SwiftName
    let numRequirementsInSignature: DataStruct
    let numRequirements: DataStruct
    let associatedTypeNames: DataStruct
    
    static func PD(_ binary: Data, offset: inout Int) -> ProtocolDescriptor {
        let flag = DataStruct.swiftData(binary, offset: &offset)
        let parent = SwiftParent.SP(binary, offset: &offset)
        let name = SwiftName.SN(binary, offset: &offset)
        let numRequirementsInSignature = DataStruct.swiftData(binary, offset: &offset)
        let numRequirements = DataStruct.swiftData(binary, offset: &offset)
        let associatedTypeNames = DataStruct.swiftData(binary, offset: &offset)
        return ProtocolDescriptor(flags: flag, parent: parent, name: name, numRequirementsInSignature: numRequirementsInSignature, numRequirements: numRequirements, associatedTypeNames: associatedTypeNames)
    }
}

struct SwiftProtocol {
    let protocolsDescriptor: ProtocolDescriptor
    let nominalTypeDescriptor: DataStruct
    let protocolWitnessTable: DataStruct
    let conformanceFlags: DataStruct
    
    static func SP(_ binary: Data, offset: inout Int) -> SwiftProtocol {
        let protocolsDescriptor = ProtocolDescriptor.PD(binary, offset: &offset)
        let nominalTypeDescriptor = DataStruct.swiftData(binary, offset: &offset)
        let protocolWitnessTable = DataStruct.swiftData(binary, offset: &offset)
        let conformanceFlags = DataStruct.swiftData(binary, offset: &offset)
        return SwiftProtocol(protocolsDescriptor: protocolsDescriptor, nominalTypeDescriptor: nominalTypeDescriptor, protocolWitnessTable: protocolWitnessTable, conformanceFlags: conformanceFlags)
    }
}
