//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftProtocolRequirement {
    let flags: UInt32
    let kind: String
    let isInstance: Bool
    let defaultImplementationOffset: Int?
    let defaultImplementationAddress: UInt64?

    var isAssociatedTypeRequirement: Bool {
        kind == "associated type access" || kind == "associated conformance access"
    }

    static func parse(_ binary: Data, offset: Int,
                      addressResolver: (Int) -> UInt64?) -> SwiftProtocolRequirement? {
        guard offset >= 0, offset <= binary.count - 8 else { return nil }
        let rawFlags = UInt32(DataStruct.data(binary, offset: offset, length: 4).value.int16())
        let relative = DataStruct.data(binary, offset: offset + 4, length: 4).value.int16Subtraction()
        let kinds = ["base protocol", "method", "initializer", "getter", "setter",
                     "read coroutine", "modify coroutine", "associated type access",
                     "associated conformance access"]
        let rawKind = Int(rawFlags & 0x0f)
        let kind = rawKind < kinds.count ? kinds[rawKind] : "unknown requirement \(rawKind)"
        let implementation = relative == 0 ? nil : offset + 4 + relative
        return SwiftProtocolRequirement(flags: rawFlags, kind: kind,
                                        isInstance: rawFlags & 0x10 != 0,
                                        defaultImplementationOffset: implementation,
                                        defaultImplementationAddress: implementation.flatMap(addressResolver))
    }
}

struct SwiftGenericRequirement {
    let flags: UInt32
    let parameter: SwiftName
    let constraint: SwiftName

    static func parse(_ binary: Data, offset: Int) -> SwiftGenericRequirement? {
        guard offset >= 0, offset <= binary.count - 12 else { return nil }
        return SwiftGenericRequirement(
            flags: UInt32(DataStruct.data(binary, offset: offset, length: 4).value.int16()),
            parameter: SwiftName.SN(binary, offset: offset + 4, isMangledName: true, isClassName: false),
            constraint: SwiftName.SN(binary, offset: offset + 8, isMangledName: true, isClassName: false)
        )
    }
}

struct ProtocolDescriptor {
    let flags: SwiftFlags
    let parent: SwiftParent
    let name: SwiftName
    let numRequirementsInSignature: DataStruct
    let numRequirements: DataStruct
    let associatedTypeNames: DataStruct
    let associatedTypes: [String]
    let signatureRequirements: [SwiftGenericRequirement]
    let requirements: [SwiftProtocolRequirement]
    
    static func PD(_ binary: Data, offset: Int,
                   addressResolver: (Int) -> UInt64? = { _ in nil }) -> ProtocolDescriptor {
        let flag = SwiftFlags.SF(binary, offset: offset)
        let parent = SwiftParent.SP(binary, offset: offset+4)
        let name = SwiftName.SN(binary, offset: offset+8, isMangledName: false, isClassName: true)
        let numRequirementsInSignature = DataStruct.data(binary, offset: offset+12, length: 4)
        let numRequirements = DataStruct.data(binary, offset: offset+16, length: 4)
        let associatedTypeNames = DataStruct.data(binary, offset: offset+20, length: 4)
        let associatedNamesOffset = MachOData.shared.resolveRelativePointer(base: offset + 20, raw: associatedTypeNames.value)
            ?? (offset + 20 + associatedTypeNames.value.int16Subtraction())
        let associatedNames = associatedTypeNames.value == None
            ? []
            : DataStruct.textData(binary, offset: associatedNamesOffset).value
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)

        var cursor = offset + 24
        var signatureRequirements = [SwiftGenericRequirement]()
        let signatureCount = min(numRequirementsInSignature.value.int16(), max(0, (binary.count - cursor) / 12))
        for _ in 0..<signatureCount {
            if let requirement = SwiftGenericRequirement.parse(binary, offset: cursor) {
                signatureRequirements.append(requirement)
            }
            cursor += 12
        }

        var requirements = [SwiftProtocolRequirement]()
        let requirementCount = min(numRequirements.value.int16(), max(0, (binary.count - cursor) / 8))
        for _ in 0..<requirementCount {
            if let requirement = SwiftProtocolRequirement.parse(binary, offset: cursor,
                                                                 addressResolver: addressResolver) {
                requirements.append(requirement)
            }
            cursor += 8
        }
        return ProtocolDescriptor(flags: flag, parent: parent, name: name,
                                  numRequirementsInSignature: numRequirementsInSignature,
                                  numRequirements: numRequirements,
                                  associatedTypeNames: associatedTypeNames,
                                  associatedTypes: associatedNames,
                                  signatureRequirements: signatureRequirements,
                                  requirements: requirements)
    }
    
    func serialization() {
        if name.swiftName.value.count > 0 {
            var result = "protocol \(name.swiftName.value) {\n"
            var witnessSignatures = ProtocolRequirementResolver.witnessSignatures(protocolName: name.swiftName.value)
            for associatedType in associatedTypes {
                if associatedType.contains("Builtin.NativeObject") || associatedType.contains("variadic-marker") || associatedType.contains("empty-list") { continue }
                result += "    associatedtype \(associatedType)\n"
            }
            for requirement in signatureRequirements {
                let parameter = fixMangledTypeName(requirement.parameter.swiftName)
                let constraint = fixMangledTypeName(requirement.constraint.swiftName)
                if constraint != None && constraint != "0" && constraint != "00000000" {
                    result += "    // generic requirement \(parameter): \(constraint)\n"
                }
            }
            for requirement in requirements {
                if requirement.isAssociatedTypeRequirement { continue }
                if ["getter", "setter", "read coroutine", "modify coroutine"].contains(requirement.kind) {
                    // Accessor requirements are emitted as one property below.
                    continue
                }
                let scope = requirement.isInstance ? "instance " : ""
                if let address = requirement.defaultImplementationAddress {
                    let key = String(format: "%016llx", address)
                    let relative = address > RVA ? address - RVA : address
                    let symbol = MachOData.shared.symbolTable[key]?.name(demangle: true)
                        ?? MachOData.shared.dylbMap[String(relative, radix: 16)].flatMap { swift_demangle($0) ?? $0 }
                    if let symbol = symbol, !symbol.isEmpty {
                        result += "    // \(scope)\(requirement.kind): \(symbol)\n"
                    } else {
                        result += "    // \(scope)\(requirement.kind), default implementation @ 0x\(String(format: "%016llx", address))\n"
                    }
                } else if let index = witnessSignatures.firstIndex(where: {
                    ProtocolRequirementResolver.matches($0, requirement: requirement)
                }) {
                    var signature = witnessSignatures.remove(at: index)
                    for associatedType in associatedTypes {
                        signature = signature.replacingOccurrences(of: "A.\(associatedType)", with: associatedType)
                    }
                    if requirement.kind == "method" {
                        let modifier = requirement.isInstance ? "" : "static "
                        result += "    \(modifier)func \(signature) // inferred from protocol witness\n"
                    } else {
                        result += "    // \(scope)\(requirement.kind): \(signature) (inferred from protocol witness)\n"
                    }
                } else {
                    result += "    // \(scope)\(requirement.kind)\n"
                }
            }
            let accessors = witnessSignatures.filter { $0.contains(".getter") || $0.contains(".setter") || $0.contains(".modify") || $0.contains(".read") }
            var properties = [String: (type: String, get: Bool, set: Bool)]()
            for accessor in accessors {
                let parts = accessor.split(separator: ":", maxSplits: 1).map(String.init)
                let head = parts.first ?? accessor
                let kind: String
                if head.contains(".getter") { kind = "get" }
                else if head.contains(".setter") { kind = "set" }
                else if head.contains(".modify") { kind = "set" }
                else { kind = "get" }
                let propertyName = head.components(separatedBy: ".").first ?? head
                let type = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                var current = properties[propertyName] ?? (type, false, false)
                current.get = current.get || kind == "get"
                current.set = current.set || kind == "set"
                if !type.isEmpty { current.type = type }
                properties[propertyName] = current
            }
            for name in properties.keys.sorted() {
                guard let property = properties[name] else { continue }
                var access = "get"
                if property.set { access += " set" }
                result += "    var \(name): \(property.type) { \(access) } // inferred from protocol witness\n"
            }
            result += "}\n"
            ConsoleIO.writeMessage(result)
        }
    }
}

struct NominalTypeDescriptor {
    let nominalTypeDescriptor: DataStruct
    let nominalTypeName: DataStruct
    
    static func NT(_ binary: Data, offset: Int) -> NominalTypeDescriptor {
        let nominalTypeDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        let nominalOffset = MachOData.shared.resolveRelativePointer(base: offset + 4, raw: nominalTypeDescriptor.value)
            ?? (offset + nominalTypeDescriptor.value.int16Subtraction())
        let nominalTypeName = DataStruct.textSwiftData(binary, offset: nominalOffset, isMangledName: false, isClassName: true)
        return NominalTypeDescriptor(nominalTypeDescriptor: nominalTypeDescriptor, nominalTypeName: nominalTypeName)
    }
}

struct SwiftProtocol {
    let protocolsDescriptor: DataStruct
    let nominalTypeDescriptor: NominalTypeDescriptor
    let protocolWitnessTable: DataStruct
    let conformanceFlags: DataStruct
    let protocolNameOffset: Int
    
    static func SP(_ binary: Data, offset: Int) -> SwiftProtocol {
        let protocolsDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        let nominalTypeDescriptor = NominalTypeDescriptor.NT(binary, offset: offset+4)
        let protocolWitnessTable = DataStruct.data(binary, offset: offset+8, length: 4)
        let conformanceFlags = DataStruct.data(binary, offset: offset+12, length: 4)
        
        let newOffSet = protocolsDescriptor.value.int16()
        var protocolNameOffset = 0
        if ((newOffSet & 0x1) == 1) { //如果是奇数
            // 相当于减1
            protocolNameOffset = DataStruct.data(binary, offset: (newOffSet&0xFFFE)+offset, length: 4).value.int16()
        } else {
            protocolNameOffset = newOffSet+offset
        }
        
        return SwiftProtocol(protocolsDescriptor: protocolsDescriptor, nominalTypeDescriptor: nominalTypeDescriptor, protocolWitnessTable: protocolWitnessTable, conformanceFlags: conformanceFlags, protocolNameOffset: protocolNameOffset)
    }
    
    func serialization() {
        if let protocolName = MachOData.shared.swiftProtocols[protocolNameOffset] {
            var result = "protocol \(protocolName) {\n"
            result += "}\n"
            ConsoleIO.writeMessage(result)
        }
    }
}
