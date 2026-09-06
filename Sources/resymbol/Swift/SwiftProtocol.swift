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
        let rawFlags = UInt32(DataStruct.data(binary, offset: offset, length: 4).value,
                              radix: 16) ?? 0
        let rawRelative = DataStruct.data(binary, offset: offset + 4, length: 4).value
        let kinds = ["base protocol", "method", "initializer", "getter", "setter",
                     "read coroutine", "modify coroutine", "associated type access",
                     "associated conformance access"]
        let rawKind = Int(rawFlags & 0x0f)
        let kind = rawKind < kinds.count ? kinds[rawKind] : "unknown requirement \(rawKind)"
        let implementation = rawRelative == "00000000" ? nil :
            MachOData.shared.resolveRelativePointer(base: offset + 4, raw: rawRelative)
        return SwiftProtocolRequirement(flags: rawFlags, kind: kind,
                                        isInstance: rawFlags & 0x10 != 0,
                                        defaultImplementationOffset: implementation,
                                        defaultImplementationAddress: implementation.flatMap(addressResolver))
    }

    static func parse(_ binary: Data, offset: Int,
                      resolver: MachOAddressResolver) -> SwiftProtocolRequirement? {
        guard offset >= 0, offset <= binary.count - 8 else { return nil }
        var rawFlags = binary.extract(UInt32.self, offset: offset)
        var rawRelative = binary.extract(UInt32.self, offset: offset + 4)
        if resolver.file.isByteSwapped {
            rawFlags = rawFlags.byteSwapped
            rawRelative = rawRelative.byteSwapped
        }
        let kinds = ["base protocol", "method", "initializer", "getter", "setter",
                     "read coroutine", "modify coroutine", "associated type access",
                     "associated conformance access"]
        let rawKind = Int(rawFlags & 0x0f)
        let kind = rawKind < kinds.count ? kinds[rawKind] : "unknown requirement \(rawKind)"
        let implementation = rawRelative == 0 ? nil :
            resolver.resolveRelativePointer(fieldOffset: offset + 4, raw: rawRelative)
        return SwiftProtocolRequirement(flags: rawFlags, kind: kind,
                                        isInstance: rawFlags & 0x10 != 0,
                                        defaultImplementationOffset: implementation,
                                        defaultImplementationAddress: implementation.flatMap(resolver.vmAddress(forFileOffset:)))
    }
}

enum SwiftGenericRequirementKind: Equatable {
    case protocolConformance
    case sameType
    case baseClass
    case sameShape
    case layout
    case unknown(UInt32)
}

struct SwiftGenericRequirement {
    let flags: UInt32
    let kind: SwiftGenericRequirementKind
    let hasExtraArgument: Bool
    let hasKeyArgument: Bool
    let parameter: SwiftName
    let constraint: SwiftName

    static func parse(_ binary: Data, offset: Int) -> SwiftGenericRequirement? {
        guard offset >= 0, offset <= binary.count - 12 else { return nil }
        let flags = UInt32(DataStruct.data(binary, offset: offset, length: 4).value,
                           radix: 16) ?? 0
        let rawKind = flags & 0x1f
        let kind: SwiftGenericRequirementKind
        switch rawKind {
        case 0: kind = .protocolConformance
        case 1: kind = .sameType
        case 2: kind = .baseClass
        case 3: kind = .sameShape
        case 4: kind = .layout
        default: kind = .unknown(rawKind)
        }
        return SwiftGenericRequirement(
            flags: flags,
            kind: kind,
            hasExtraArgument: flags & 0x40 != 0,
            hasKeyArgument: flags & 0x80 != 0,
            parameter: SwiftName.SN(binary, offset: offset + 4, isMangledName: true, isClassName: false),
            constraint: SwiftName.SN(binary, offset: offset + 8, isMangledName: true, isClassName: false)
        )
    }
}

/// Convert descriptor generic requirements into the subset of Swift source
/// syntax that has an unambiguous representation on a protocol declaration.
/// Layout and same-shape requirements intentionally remain comments because
/// their ABI forms do not carry enough information for a faithful spelling.
func protocolGenericConstraintParts(associatedTypes: [String],
                                    requirements: [SwiftGenericRequirement])
    -> (associated: [String: [String]], whereClauses: [String], recognized: Set<Int>) {
    var associated = [String: [String]]()
    var whereClauses = [String]()
    var recognized = Set<Int>()

    func normalize(_ value: String) -> String {
        var result = sanitizeRecoveredType(fixMangledTypeName(
            DataStruct(address: "0", value: value)))
        guard !result.isEmpty else { return "" }
        result = normalizeGenericPlaceholders(result, names: associatedTypes)
        for (index, name) in associatedTypes.enumerated() where index < 26 {
            result = result.replacingOccurrences(of: "A.\(name)", with: name)
        }
        return sanitizeRecoveredType(result)
    }

    func associatedName(_ value: String) -> String? {
        if let exact = associatedTypes.first(where: { $0 == value }) { return exact }
        return associatedTypes.first(where: { value.hasSuffix(".\($0)") })
    }

    func usableConstraint(_ value: String) -> Bool {
        guard value.count > 1, value != None, !value.hasPrefix("0x") else { return false }
        // Single-letter values are generic placeholders or stripped pointer
        // artifacts in metadata. Treating them as nominal types creates
        // declarations such as `where A: C` that cannot be source-verified.
        if value.count == 1, value.first?.isUppercase == true { return false }
        return value.allSatisfy { $0.isASCII &&
            ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." ||
             $0 == "<" || $0 == ">" || $0 == "," || $0 == " " || $0 == "&") }
    }

    for (index, requirement) in requirements.enumerated() {
        let parameter = normalize(requirement.parameter.swiftName.value)
        let constraint = normalize(requirement.constraint.swiftName.value)
        guard !parameter.isEmpty, usableConstraint(constraint) else { continue }
        switch requirement.kind {
        case .protocolConformance, .baseClass:
            if let name = associatedName(parameter) {
                guard !associated[name, default: []].contains(constraint) else { continue }
                associated[name, default: []].append(constraint)
                recognized.insert(index)
            }
        case .sameType:
            guard associatedName(parameter) != nil || parameter == "Self" else { continue }
            let clause = "\(parameter) == \(constraint)"
            if !whereClauses.contains(clause) { whereClauses.append(clause) }
            recognized.insert(index)
        case .sameShape, .layout, .unknown:
            continue
        }
    }
    return (associated, whereClauses, recognized)
}

struct ProtocolDescriptor {
    let descriptorOffset: Int
    let flags: SwiftFlags
    let parent: SwiftParent
    let name: SwiftName
    let numRequirementsInSignature: DataStruct
    let numRequirements: DataStruct
    let associatedTypeNames: DataStruct
    let associatedTypes: [String]
    let signatureRequirements: [SwiftGenericRequirement]
    let requirements: [SwiftProtocolRequirement]

    var qualifiedName: String {
        let parentName = parent.swiftParent.value
        guard parentName.count > 1, parentName != None, !parentName.hasPrefix("0x"),
              parentName.allSatisfy({ $0.isASCII &&
                  ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) else {
            return name.swiftName.value
        }
        return "\(parentName).\(name.swiftName.value)"
    }
    
    static func PD(_ binary: Data, offset: Int,
                   addressResolver: (Int) -> UInt64? = { _ in nil },
                   resolver: MachOAddressResolver? = nil) -> ProtocolDescriptor {
        let flag = SwiftFlags.SF(binary, offset: offset)
        let parent = SwiftParent.SP(binary, offset: offset+4)
        let name = SwiftName.SN(binary, offset: offset+8, isMangledName: false, isClassName: true)
        let numRequirementsInSignature = DataStruct.data(binary, offset: offset+12, length: 4)
        let numRequirements = DataStruct.data(binary, offset: offset+16, length: 4)
        let associatedTypeNames = DataStruct.data(binary, offset: offset+20, length: 4)
        let associatedNamesOffset = MachOData.shared.resolveRelativePointer(base: offset + 20,
                                                                              raw: associatedTypeNames.value) ?? binary.count
        let associatedNames = associatedTypeNames.value == None
            ? []
            : DataStruct.textData(binary, offset: associatedNamesOffset).value
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)

        var cursor = offset + 24
        var signatureRequirements = [SwiftGenericRequirement]()
        let signatureCount = min(numRequirementsInSignature.value.unsignedHexInt(), max(0, (binary.count - cursor) / 12))
        for _ in 0..<signatureCount {
            if let requirement = SwiftGenericRequirement.parse(binary, offset: cursor) {
                signatureRequirements.append(requirement)
            }
            cursor += 12
        }

        var requirements = [SwiftProtocolRequirement]()
        let requirementCount = min(numRequirements.value.unsignedHexInt(), max(0, (binary.count - cursor) / 8))
        for _ in 0..<requirementCount {
            let requirement = resolver.flatMap {
                SwiftProtocolRequirement.parse(binary, offset: cursor, resolver: $0)
            } ?? SwiftProtocolRequirement.parse(binary, offset: cursor,
                                                addressResolver: addressResolver)
            if let requirement {
                requirements.append(requirement)
            }
            cursor += 8
        }
        return ProtocolDescriptor(descriptorOffset: offset, flags: flag, parent: parent, name: name,
                                  numRequirementsInSignature: numRequirementsInSignature,
                                  numRequirements: numRequirements,
                                  associatedTypeNames: associatedTypeNames,
                                  associatedTypes: associatedNames,
                                  signatureRequirements: signatureRequirements,
                                  requirements: requirements)
    }
    
    func serialization() {
        if name.swiftName.value.count > 0 {
            let binary = MachOData.shared.binary
            let resolver = MachOData.shared.addressResolver()
            var baseProtocols = [String]()
            if let resolver {
                for requirement in requirements where requirement.kind == "base protocol" {
                    guard let descriptor = requirement.defaultImplementationOffset,
                          let parent = protocolName(binary, descriptorOffset: descriptor,
                                                     resolver: resolver),
                          !parent.isEmpty, parent != qualifiedName,
                          !baseProtocols.contains(parent) else { continue }
                    baseProtocols.append(parent)
                }
            }
            let inheritance = baseProtocols.isEmpty ? "" : ": " + baseProtocols.sorted().joined(separator: ", ")
            let genericConstraints = protocolGenericConstraintParts(
                associatedTypes: associatedTypes, requirements: signatureRequirements)
            let whereClause = genericConstraints.whereClauses.isEmpty
                ? "" : " where " + genericConstraints.whereClauses.joined(separator: ", ")
            var result = "protocol \(name.swiftName.value)\(inheritance)\(whereClause) {\n"
            var witnessSignatures = ProtocolRequirementResolver.witnessSignatures(
                protocolName: name.swiftName.value, qualifiedProtocolName: qualifiedName)
            var exactWitnesses = [Int: [String]]()
            let conformances = MachOData.shared.swiftProtocolConformances.filter {
                $0.protocolDescriptorOffset == descriptorOffset
            }
            for conformance in conformances {
                for binding in conformance.witnessBindings {
                    let signatures = binding.exactWitnessSignatures
                        .filter { $0.protocolName == name.swiftName.value }
                        .map(\.member)
                    if !signatures.isEmpty {
                        exactWitnesses[binding.requirementIndex, default: []].append(contentsOf: signatures)
                    }
                }
            }
            var emittedAssociatedTypes = Set<String>()
            for associatedType in associatedTypes {
                if associatedType.contains("Builtin.NativeObject") || associatedType.contains("variadic-marker") || associatedType.contains("empty-list") { continue }
                guard emittedAssociatedTypes.insert(associatedType).inserted else { continue }
                let constraints = genericConstraints.associated[associatedType] ?? []
                let suffix = constraints.isEmpty ? "" : ": " + constraints.joined(separator: " & ")
                result += "    associatedtype \(associatedType)\(suffix)\n"
            }
            for (requirementIndex, requirement) in signatureRequirements.enumerated() {
                if genericConstraints.recognized.contains(requirementIndex) { continue }
                let parameter = fixMangledTypeName(requirement.parameter.swiftName)
                let constraint = fixMangledTypeName(requirement.constraint.swiftName)
                if constraint != None && constraint != "0" && constraint != "00000000" {
                    result += "    // generic requirement \(parameter): \(constraint)\n"
                }
            }
            var emittedRequirements = Set<String>()
            var emittedWitnessMembers = Set<String>()
            for (requirementIndex, requirement) in requirements.enumerated() {
                if requirement.isAssociatedTypeRequirement { continue }
                if ["getter", "setter", "read coroutine", "modify coroutine"].contains(requirement.kind) {
                    // Accessor requirements are emitted as one property below.
                    continue
                }
                let scope = requirement.isInstance ? "instance " : ""
                let requirementKey = "\(requirementIndex)|\(requirement.kind)|\(requirement.isInstance)|\(requirement.defaultImplementationAddress ?? 0)"
                guard emittedRequirements.insert(requirementKey).inserted else { continue }
                if let address = requirement.defaultImplementationAddress {
                    let relative = address > RVA ? address - RVA : address
                    let symbol = defaultImplementationSymbol(address: address, relative: relative)
                    if let symbol, let declaration = MachOData.swiftMemberDeclaration(from: symbol)?.declaration {
                        result += "    \(normalizeWitnessSignature(declaration)) // inferred from default implementation\n"
                    } else if let symbol, !symbol.isEmpty {
                        result += "    // \(scope)\(requirement.kind): \(symbol)\n"
                    } else {
                        result += "    // \(scope)\(requirement.kind), default implementation @ 0x\(String(format: "%016llx", address))\n"
                    }
                } else if let exact = exactWitnesses[requirementIndex]?.first(where: {
                    ProtocolRequirementResolver.matches($0, requirement: requirement) &&
                    (requirement.kind != "method" ||
                     ProtocolRequirementResolver.isStaticWitness($0) == !requirement.isInstance)
                }) {
                    let signature = normalizeWitnessSignature(exact)
                    if let index = witnessSignatures.firstIndex(of: exact) {
                        witnessSignatures.remove(at: index)
                    }
                    if requirement.kind == "method" {
                        let formatted = formatWitnessMethod(signature, requirement: requirement)
                        result += "    \(formatted) // inferred from protocol witness\n"
                        emittedWitnessMembers.insert(canonicalWitnessMember(signature))
                    } else if requirement.kind == "initializer" {
                        result += "    \(formatWitnessInitializer(signature)) // inferred from protocol witness\n"
                        emittedWitnessMembers.insert(canonicalWitnessMember(signature))
                    } else {
                        result += "    // \(scope)\(requirement.kind): \(signature) (inferred from protocol witness)\n"
                    }
                } else if let index = witnessSignatures.firstIndex(where: {
                    ProtocolRequirementResolver.matches($0, requirement: requirement) &&
                    (requirement.kind != "method" ||
                     ProtocolRequirementResolver.isStaticWitness($0) == !requirement.isInstance)
                }) {
                    let signature = normalizeWitnessSignature(witnessSignatures.remove(at: index))
                    if requirement.kind == "method" {
                        let formatted = formatWitnessMethod(signature, requirement: requirement)
                        result += "    \(formatted) // inferred from protocol witness\n"
                        emittedWitnessMembers.insert(canonicalWitnessMember(signature))
                    } else if requirement.kind == "initializer" {
                        result += "    \(formatWitnessInitializer(signature)) // inferred from protocol witness\n"
                        emittedWitnessMembers.insert(canonicalWitnessMember(signature))
                    } else {
                        result += "    // \(scope)\(requirement.kind): \(signature) (inferred from protocol witness)\n"
                    }
                } else {
                    result += "    // \(scope)\(requirement.kind)\n"
                }
            }
            // Optimized Swift builds may omit a descriptor slot for an async,
            // operator, or resilient witness while retaining its TW symbol.
            // Emit only the remaining non-accessor witness signatures; this
            // recovers real syntax without inventing declarations from bytes.
            for signature in witnessSignatures {
                guard !emittedWitnessMembers.contains(canonicalWitnessMember(signature)) else { continue }
                if signature.contains(".getter") || signature.contains(".setter") ||
                    signature.contains(".modify") || signature.contains(".read") ||
                    signature.hasPrefix("init(") { continue }
                let formatted = formatWitnessMethod(signature, requirement: nil)
                result += "    \(formatted) // inferred from protocol witness\n"
                emittedWitnessMembers.insert(canonicalWitnessMember(signature))
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
                let type = parts.count > 1 ? normalizeWitnessSignature(parts[1].trimmingCharacters(in: .whitespaces)) : ""
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
                if name == "subscript", let arrow = property.type.range(of: " -> ") {
                    var indexType = String(property.type[..<arrow.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if indexType.hasPrefix("("), indexType.hasSuffix(")") {
                        indexType.removeFirst()
                        indexType.removeLast()
                    }
                    let valueType = String(property.type[arrow.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    result += "    subscript(_ index: \(indexType)) -> \(valueType) { \(access) } // inferred from protocol witness\n"
                } else {
                    result += "    var \(name): \(property.type) { \(access) } // inferred from protocol witness\n"
                }
            }
            result += "}\n"
            ConsoleIO.writeMessage(result)
        }
    }

    private func protocolName(_ binary: Data, descriptorOffset: Int,
                              resolver: MachOAddressResolver) -> String? {
        guard descriptorOffset >= 0, descriptorOffset <= binary.count - 12 else { return nil }
        var raw = binary.extract(UInt32.self, offset: descriptorOffset + 8)
        if resolver.file.isByteSwapped { raw = raw.byteSwapped }
        guard raw != 0,
              let nameOffset = resolver.resolveRelativePointer(fieldOffset: descriptorOffset + 8,
                                                                raw: raw) else { return nil }
        let value = DataStruct.textSwiftData(binary, offset: nameOffset,
                                              isMangledName: false,
                                              isClassName: true).value
        return value == None || value.hasPrefix("0x") ? nil : value
    }

    private func formatWitnessMethod(_ raw: String,
                                     requirement: SwiftProtocolRequirement?) -> String {
        var signature = raw.trimmingCharacters(in: .whitespaces)
        var staticWitness = false
        if signature.hasPrefix("static ") {
            staticWitness = true
            signature.removeFirst(7)
        }
        let operatorWitness = signature.hasPrefix("+") || signature.hasPrefix("-") ||
            signature.hasPrefix("*") || signature.hasPrefix("/") ||
            signature.hasPrefix("==") || signature.hasPrefix("!=") ||
            signature.contains(" infix(")
        let isStatic = staticWitness || operatorWitness || requirement?.isInstance == false
        if signature.contains(" infix(") {
            signature = signature.replacingOccurrences(of: " infix(", with: "(")
        }
        if operatorWitness {
            signature = formatOperatorSignature(signature)
        }
        return "\(isStatic ? "static " : "")func \(signature)"
    }

    private func formatOperatorSignature(_ signature: String) -> String {
        guard let open = signature.firstIndex(of: "("),
              let close = signature.lastIndex(of: ")"), close > open else { return signature }
        let name = String(signature[..<open]).trimmingCharacters(in: .whitespaces)
        let parameters = String(signature[signature.index(after: open)..<close])
        let parts = splitTopLevelParameters(parameters)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.contains(":") }) else { return signature }
        let labeled = "lhs: \(parts[0].trimmingCharacters(in: .whitespaces)), rhs: \(parts[1].trimmingCharacters(in: .whitespaces))"
        let suffixStart = signature.index(after: close)
        return "\(name)(\(labeled))\(String(signature[suffixStart...]))"
    }

    private func splitTopLevelParameters(_ value: String) -> [String] {
        var result = [String]()
        var start = value.startIndex
        var depth = 0
        for index in value.indices {
            switch value[index] {
            case "<", "(", "[": depth += 1
            case ">", ")", "]": depth = max(0, depth - 1)
            case "," where depth == 0:
                result.append(String(value[start..<index]))
                start = value.index(after: index)
            default: break
            }
        }
        result.append(String(value[start..<value.endIndex]))
        return result
    }

    private func normalizeWitnessSignature(_ raw: String) -> String {
        var signature = raw
        for associatedType in associatedTypes {
            signature = signature.replacingOccurrences(of: "A.\(associatedType)", with: associatedType)
        }
        let expression = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])A(?![A-Za-z0-9_])")
        let range = NSRange(signature.startIndex..<signature.endIndex, in: signature)
        return expression?.stringByReplacingMatches(in: signature, options: [], range: range,
                                                     withTemplate: "Self") ?? signature
    }

    private func canonicalWitnessMember(_ raw: String) -> String {
        raw.hasPrefix("static ") ? String(raw.dropFirst(7)) : raw
    }

    private func formatWitnessInitializer(_ raw: String) -> String {
        var signature = raw.trimmingCharacters(in: .whitespaces)
        if let arrow = signature.range(of: " -> ") {
            signature = String(signature[..<arrow.lowerBound])
        }
        return signature.hasPrefix("init(") ? signature : "init()"
    }

    private func defaultImplementationSymbol(address: UInt64, relative: UInt64) -> String? {
        let offsets = [address, relative].compactMap { value -> UInt64? in
            guard value != 0 else { return nil }
            return value
        }
        for candidate in offsets {
            let records = MachOData.shared.symbols(at: candidate)
            if let name = records.lazy.compactMap({ swift_demangle($0.name) ?? $0.name })
                .first(where: { !$0.isEmpty }) {
                return name
            }
        }
        let keys = offsets.map { String(format: "%016llx", $0) } +
            offsets.map { String(format: "%08llx", $0) }
        for key in keys {
            if let symbol = MachOData.shared.symbolTable[key]?.name(demangle: true), !symbol.isEmpty {
                return symbol
            }
        }
        if let bound = MachOData.shared.dylbMap[String(relative, radix: 16)] {
            return swift_demangle(bound) ?? bound
        }
        return nil
    }
}

struct NominalTypeDescriptor {
    let nominalTypeDescriptor: DataStruct
    let nominalTypeName: DataStruct
    
    static func NT(_ binary: Data, offset: Int) -> NominalTypeDescriptor {
        let nominalTypeDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        let nominalOffset = MachOData.shared.resolveRelativePointer(base: offset + 4, raw: nominalTypeDescriptor.value)
            ?? binary.count
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

/// A descriptor-native protocol conformance record from `__swift5_proto`.
/// Witness entries are retained as resolved file offsets when the runtime
/// pointer pattern can be materialized safely; no heuristic names are emitted.
struct SwiftProtocolWitnessBinding {
    let requirementIndex: Int
    let requirementDescriptorOffset: Int
    let requirementKind: String
    let isInstance: Bool
    let witnessTargetOffset: Int?
    let witnessTargetAddress: UInt64?
    let symbolNames: [String]
    let boundSymbolName: String?

    var exactWitnessSignatures: [ProtocolWitnessSignature] {
        symbolNames.compactMap(ProtocolRequirementResolver.witnessSignature(mangled:))
    }
}

struct SwiftProtocolConformance {
    let descriptorOffset: Int
    let protocolDescriptorOffset: Int?
    let nominalTypeDescriptorOffset: Int?
    let witnessTablePatternOffset: Int?
    let flags: UInt32
    let protocolName: String
    let conformingTypeName: String
    let protocolRequirementCount: Int
    let conditionalRequirements: [SwiftGenericRequirement]
    let witnessEntries: [Int?]
    let witnessBindings: [SwiftProtocolWitnessBinding]

    var isRetroactive: Bool { flags & 1 != 0 }
    var isSynthesizedNonUnique: Bool { flags & 2 != 0 }
    var conditionalRequirementCount: Int { Int((flags >> 8) & 0xff) }
    // Swift ABI reserves two bits (3...4) for the reference-kind enum.
    // Bit 5 belongs to the value-witness-table flags and must not be folded
    // into this classification.
    var typeReferenceKind: Int { Int((flags >> 3) & 0x3) }
    var hasResilientWitnesses: Bool { flags & 0x0001_0000 != 0 }
    var hasGenericWitnessTable: Bool { flags & 0x0002_0000 != 0 }
    var requirementWitnessEntries: [Int?] { Array(witnessEntries.dropFirst().prefix(protocolRequirementCount)) }

    static func parseHeader(_ binary: Data, offset: Int,
                            resolver: MachOAddressResolver) -> SwiftProtocolConformance? {
        parse(binary, offset: offset, resolver: resolver, decodeWitnesses: false)
    }

    static func parse(_ binary: Data, offset: Int,
                      resolver: MachOAddressResolver) -> SwiftProtocolConformance? {
        parse(binary, offset: offset, resolver: resolver, decodeWitnesses: true)
    }

    private static func parse(_ binary: Data, offset: Int, resolver: MachOAddressResolver,
                              decodeWitnesses: Bool) -> SwiftProtocolConformance? {
        guard offset >= 0, offset <= binary.count - 16 else { return nil }
        let swapped = resolver.file.isByteSwapped
        let protocolRaw: UInt32 = integer(binary, offset: offset, swapped: swapped)
        let nominalRaw: UInt32 = integer(binary, offset: offset + 4, swapped: swapped)
        let witnessRaw: UInt32 = integer(binary, offset: offset + 8, swapped: swapped)
        let flags: UInt32 = integer(binary, offset: offset + 12, swapped: swapped)
        let protocolOffset = protocolRaw == 0 ? nil : resolver.resolveIndirectRelativePointer(fieldOffset: offset, raw: protocolRaw)
        let referenceKind = Int((flags >> 3) & 0x3)
        let nominalOffset: Int?
        if nominalRaw == 0 { nominalOffset = nil }
        else if referenceKind == 1 || referenceKind == 3 {
            nominalOffset = resolver.resolveIndirectRelativePointer(fieldOffset: offset + 4, raw: nominalRaw)
        } else {
            nominalOffset = resolver.resolveRelativePointer(fieldOffset: offset + 4, raw: nominalRaw)
        }
        let witnessOffset = witnessRaw == 0 ? nil : resolver.resolveRelativePointer(fieldOffset: offset + 8, raw: witnessRaw)
        let protocolName = protocolOffset.flatMap { contextName(binary, descriptorOffset: $0, resolver: resolver) } ?? ""
        let conformingTypeName: String
        if referenceKind == 2, let nominalOffset {
            conformingTypeName = DataStruct.textData(binary, offset: nominalOffset, demangle: true).value
        } else if referenceKind == 0 || referenceKind == 1, let nominalOffset {
            conformingTypeName = contextName(binary, descriptorOffset: nominalOffset, resolver: resolver) ?? ""
        } else { conformingTypeName = "" }
        var conditional = [SwiftGenericRequirement]()
        let conditionalCount = min(Int((flags >> 8) & 0xff), max(0, (binary.count - offset - 16) / 12))
        for index in 0..<conditionalCount {
            if let requirement = SwiftGenericRequirement.parse(binary, offset: offset + 16 + index * 12) {
                conditional.append(requirement)
            }
        }
        let protocolLayout = protocolOffset.flatMap {
            requirementLayout(binary, protocolOffset: $0, resolver: resolver)
        }
        let requirementCount = protocolLayout?.requirements.count ?? 0
        var witnesses = [Int?]()
        if decodeWitnesses, let witnessOffset, witnessOffset >= 0, witnessOffset < binary.count {
            let count = requirementCount + 1
            if count <= (binary.count - witnessOffset) / 8 {
                for index in 0..<count {
                    let raw: UInt64 = integer(binary, offset: witnessOffset + index * 8, swapped: swapped)
                    let target = raw == 0 ? nil : resolver.resolveAbsolutePointer(raw)
                    witnesses.append(target)
                }
            }
        }
        var bindings = [SwiftProtocolWitnessBinding]()
        if let layout = protocolLayout, witnesses.count == layout.requirements.count + 1,
           let witnessOffset {
            bindings.reserveCapacity(layout.requirements.count)
            for (index, requirement) in layout.requirements.enumerated() {
                let targetOffset = witnesses[index + 1]
                let targetAddress = targetOffset.flatMap(resolver.vmAddress(forFileOffset:))
                let symbolNames = targetAddress.map {
                    MachOData.shared.symbols(at: $0).map(\.name).filter { !$0.isEmpty }
                } ?? []
                let entryOffset = witnessOffset + (index + 1) * 8
                let boundName = resolver.vmAddress(forFileOffset: entryOffset)
                    .flatMap(resolver.imageOffset(forVMAddress:))
                    .flatMap { MachOData.shared.boundSymbols[String($0, radix: 16)]?.name }
                bindings.append(SwiftProtocolWitnessBinding(
                    requirementIndex: index,
                    requirementDescriptorOffset: layout.requirementOffsets[index],
                    requirementKind: requirement.kind,
                    isInstance: requirement.isInstance,
                    witnessTargetOffset: targetOffset,
                    witnessTargetAddress: targetAddress,
                    symbolNames: symbolNames,
                    boundSymbolName: boundName
                ))
            }
        }
        return SwiftProtocolConformance(descriptorOffset: offset,
                                        protocolDescriptorOffset: protocolOffset,
                                        nominalTypeDescriptorOffset: nominalOffset,
                                        witnessTablePatternOffset: witnessOffset,
                                        flags: flags,
                                        protocolName: protocolName,
                                        conformingTypeName: conformingTypeName,
                                        protocolRequirementCount: requirementCount,
                                        conditionalRequirements: conditional,
                                        witnessEntries: witnesses,
                                        witnessBindings: bindings)
    }

    private static func requirementLayout(_ binary: Data, protocolOffset: Int,
                                          resolver: MachOAddressResolver)
        -> (requirements: [SwiftProtocolRequirement], requirementOffsets: [Int])? {
        guard protocolOffset >= 0, protocolOffset <= binary.count - 24 else { return nil }
        let swapped = resolver.file.isByteSwapped
        let signatureCount: UInt32 = integer(binary, offset: protocolOffset + 12, swapped: swapped)
        let requirementCount: UInt32 = integer(binary, offset: protocolOffset + 16, swapped: swapped)
        guard signatureCount <= 4095, requirementCount <= 4095 else { return nil }
        let signatureBytes = Int(signatureCount).multipliedReportingOverflow(by: 12)
        guard !signatureBytes.overflow else { return nil }
        let startResult = (protocolOffset + 24).addingReportingOverflow(signatureBytes.partialValue)
        guard !startResult.overflow, startResult.partialValue >= 0,
              Int(requirementCount) <= (binary.count - min(startResult.partialValue, binary.count)) / 8 else {
            return nil
        }
        var requirements = [SwiftProtocolRequirement]()
        var offsets = [Int]()
        requirements.reserveCapacity(Int(requirementCount))
        offsets.reserveCapacity(Int(requirementCount))
        for index in 0..<Int(requirementCount) {
            let requirementOffset = startResult.partialValue + index * 8
            guard let requirement = SwiftProtocolRequirement.parse(binary, offset: requirementOffset,
                                                                    resolver: resolver) else { return nil }
            requirements.append(requirement)
            offsets.append(requirementOffset)
        }
        return (requirements, offsets)
    }

    private static func contextName(_ binary: Data, descriptorOffset: Int,
                                    resolver: MachOAddressResolver) -> String? {
        let field = descriptorOffset + 8
        guard descriptorOffset >= 0, field >= descriptorOffset, field <= binary.count - 4 else { return nil }
        let raw: UInt32 = integer(binary, offset: field, swapped: resolver.file.isByteSwapped)
        guard raw != 0, let nameOffset = resolver.resolveRelativePointer(fieldOffset: field, raw: raw) else { return nil }
        let value = DataStruct.textSwiftData(binary, offset: nameOffset, isMangledName: false, isClassName: true).value
        return value == None || value.hasPrefix("0x") ? nil : value
    }

    private static func integer<T: FixedWidthInteger>(_ binary: Data, offset: Int,
                                                       swapped: Bool) -> T {
        var value = binary.extract(T.self, offset: offset)
        if swapped { value = value.byteSwapped }
        return value
    }
}
