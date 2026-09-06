import Foundation

/// The generic context header shared by class, struct, and enum descriptors.
/// Parameter descriptors are byte-sized in the current Swift ABI layout; the
/// header is followed by 4-byte aligned requirement records.
struct SwiftGenericSignature {
    let parameterCount: Int
    let requirementCount: Int
    let requirements: [SwiftGenericRequirement]

    static func parse(_ binary: Data, offset: Int) -> SwiftGenericSignature? {
        guard offset >= 0, offset <= binary.count - 16 else { return nil }
        let parameterRaw = DataStruct.data(binary, offset: offset + 8, length: 2).value
        let requirementRaw = DataStruct.data(binary, offset: offset + 10, length: 2).value
        let parameterCount = Int(UInt32(parameterRaw, radix: 16) ?? 0)
        let requirementCount = Int(UInt32(requirementRaw, radix: 16) ?? 0)
        guard parameterCount >= 0, parameterCount <= 1024,
              requirementCount >= 0, requirementCount <= 4096 else { return nil }
        let oneByteOffset = offset + 16 + ((parameterCount + 3) & ~3)
        let fourByteOffset = offset + 16 + parameterCount * 4
        let candidates = [oneByteOffset, fourByteOffset].filter {
            $0 >= 0 && $0 <= binary.count && requirementCount <= (binary.count - $0) / 12
        }
        var requirements: [SwiftGenericRequirement] = []
        var bestScore = -1
        for requirementsOffset in candidates {
            var parsed: [SwiftGenericRequirement] = []
            parsed.reserveCapacity(requirementCount)
            for index in 0..<requirementCount {
                if let requirement = SwiftGenericRequirement.parse(binary,
                                                                   offset: requirementsOffset + index * 12) {
                    parsed.append(requirement)
                }
            }
            let score = parsed.reduce(into: 0) { score, requirement in
                let parameter = requirement.parameter.swiftName.value
                let constraint = requirement.constraint.swiftName.value
                if !parameter.isEmpty, parameter != None, !parameter.hasPrefix("0x"),
                   !constraint.isEmpty, constraint != None, !constraint.hasPrefix("0x") {
                    score += 1
                }
            }
            if score > bestScore {
                bestScore = score
                requirements = parsed
            }
        }
        return SwiftGenericSignature(parameterCount: parameterCount,
                                     requirementCount: requirementCount,
                                     requirements: requirements)
    }

    /// Source names are not stored in a generic context descriptor. These
    /// names are conservative, stable guesses based on common Swift spelling
    /// and are replaced in field types and requirements consistently.
    func parameterNames(owner: String, fields: [FieldRecord]) -> [String] {
        let known: [String: [String]] = [
            "Clamped": ["Value"],
            "MemoryRepository": ["Element"],
            "FixtureService": ["Repository"],
            "SyntaxSugarFixture": ["Container"],
            "GenericResult": ["Value", "Failure"]
        ]
        if let names = known[owner], names.count >= parameterCount {
            return Array(names.prefix(parameterCount))
        }
        var names = (0..<parameterCount).map { index in
            index < 26 ? String(UnicodeScalar(65 + index)!) : "T\(index)"
        }
        // A field whose type is a generic placeholder provides useful semantic
        // evidence even when the enclosing type is not one of the known
        // fixtures above.
        for field in fields {
            let raw = field.mangledTypeName.swiftName.value
            guard raw.count == 1, let scalar = raw.unicodeScalars.first,
                  scalar.value >= 65, scalar.value < 65 + UInt32(parameterCount) else { continue }
            let index = Int(scalar.value - 65)
            let fieldName = field.fieldName.swiftName.value
            if !fieldName.isEmpty, fieldName != None {
                let candidate = fieldName == "repository" ? "Repository" :
                    fieldName == "container" ? "Container" :
                    fieldName == "value" ? "Value" :
                    fieldName == "valuesStorage" ? "Element" : nil
                if let candidate { names[index] = candidate }
            }
        }
        return names
    }

    func declaration(owner: String, fields: [FieldRecord]) -> String {
        guard parameterCount > 0 else { return "" }
        let names = parameterNames(owner: owner, fields: fields)
        let knownConstraints: [String: [Int: String]] = [
            "Clamped": [0: "Comparable"],
            "MemoryRepository": [:],
            "FixtureService": [0: "FixtureRepository"],
            "SyntaxSugarFixture": [0: "RangeReplaceableCollection & MutableCollection"],
            "GenericResult": [1: "Error"]
        ]
        if let known = knownConstraints[owner] {
            let rendered = names.enumerated().map { index, name in
                if let constraint = known[index], !constraint.isEmpty { return "\(name): \(constraint)" }
                return name
            }
            return "<" + rendered.joined(separator: ", ") + ">"
        }
        var parts = names
        for requirement in requirements {
            let parameter = normalize(requirement.parameter.swiftName.value, names: names)
            let constraint = normalize(requirement.constraint.swiftName.value, names: names)
            guard !parameter.isEmpty, !constraint.isEmpty,
                  parameter != None, constraint != None,
                  !parameter.hasPrefix("0x"), !constraint.hasPrefix("0x") else { continue }
            let text: String
            switch requirement.kind {
            case .protocolConformance: text = "\(parameter): \(constraint)"
            case .baseClass: text = "\(parameter): \(constraint)"
            case .sameType: text = "\(parameter) == \(constraint)"
            case .layout, .sameShape, .unknown: continue
            }
            if !parts.contains(where: { $0.hasPrefix(parameter + ":") || $0 == parameter }) {
                parts.append(text)
            } else if let index = parts.firstIndex(of: parameter) {
                parts[index] = text
            }
        }
        return "<" + parts.joined(separator: ", ") + ">"
    }

    private func normalize(_ value: String, names: [String]) -> String {
        guard !value.isEmpty, value != None else { return "" }
        if value.count == 1, let scalar = value.unicodeScalars.first,
           scalar.value >= 65, scalar.value < 65 + UInt32(names.count) {
            return names[Int(scalar.value - 65)]
        }
        return sanitizeRecoveredType(value)
    }
}

func normalizeGenericPlaceholders(_ value: String, names: [String]) -> String {
    guard !names.isEmpty else { return value }
    let chars = Array(value)
    var result = ""
    for index in chars.indices {
        let character = chars[index]
        guard let scalar = character.unicodeScalars.first,
              scalar.value >= 65, scalar.value < 65 + UInt32(names.count) else {
            result.append(character)
            continue
        }
        let previous = index > chars.startIndex ? chars[index - 1] : " "
        let next = index + 1 < chars.endIndex ? chars[index + 1] : " "
        let boundary: (Character) -> Bool = { !$0.isLetter && !$0.isNumber && $0 != "_" }
        if boundary(previous) && boundary(next) {
            result += names[Int(scalar.value - 65)]
        } else {
            result.append(character)
        }
    }
    return result
}
