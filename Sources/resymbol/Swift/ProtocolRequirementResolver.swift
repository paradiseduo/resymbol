import Foundation

final class ProtocolWitnessIndex {
    static let shared = ProtocolWitnessIndex()
    // Ingestion happens from many symbol parsing workers; a serial queue keeps
    // updates cheap and guarantees the index is complete before serialization.
    private let queue = DispatchQueue(label: "ProtocolWitnessIndex")
    private var storage = [String: Set<String>]()
    private var qualifiedStorage = [String: Set<String>]()
    private var shortQualifiedNames = [String: Set<String>]()

    func reset() {
        queue.sync {
            storage.removeAll(keepingCapacity: true)
            qualifiedStorage.removeAll(keepingCapacity: true)
            shortQualifiedNames.removeAll(keepingCapacity: true)
        }
    }

    func ingest(mangled raw: String) {
        // Witness thunks use the TW suffix. Filtering first avoids demangling
        // every symbol in large binaries.
        guard raw.hasSuffix("TW") || raw.contains("TW.") else { return }
        guard let witness = ProtocolRequirementResolver.witnessSignature(mangled: raw) else { return }
        queue.sync {
            storage[witness.protocolName, default: []].insert(witness.member)
            qualifiedStorage[witness.qualifiedProtocolName, default: []].insert(witness.member)
            shortQualifiedNames[witness.protocolName, default: []].insert(witness.qualifiedProtocolName)
        }
    }

    func signatures(for protocolName: String) -> [String] {
        queue.sync { (storage[protocolName] ?? []).sorted() }
    }

    func signatures(for protocolName: String, qualifiedProtocolName: String?) -> [String] {
        queue.sync {
            if let qualifiedProtocolName,
               let exact = qualifiedStorage[qualifiedProtocolName], !exact.isEmpty {
                return exact.sorted()
            }
            guard shortQualifiedNames[protocolName, default: []].count <= 1 else { return [] }
            return (storage[protocolName] ?? []).sorted()
        }
    }
}

struct ProtocolWitnessSignature: Equatable {
    let protocolName: String
    let qualifiedProtocolName: String
    let conformingTypeName: String
    let member: String
}

enum ProtocolRequirementResolver {
    static func isStaticWitness(_ signature: String) -> Bool {
        signature.hasPrefix("static ")
    }

    static func witnessSignatures(protocolName: String,
                                  qualifiedProtocolName: String? = nil) -> [String] {
        ProtocolWitnessIndex.shared.signatures(for: protocolName,
                                                qualifiedProtocolName: qualifiedProtocolName)
    }

    static func matches(_ signature: String, requirement: SwiftProtocolRequirement) -> Bool {
        switch requirement.kind {
        case "getter": return signature.contains(".getter")
        case "setter": return signature.contains(".setter")
        case "initializer": return signature.hasPrefix("init(")
        case "method":
            return !signature.contains(".getter") && !signature.contains(".setter")
                && !signature.contains(".read") && !signature.contains(".modify")
                && !signature.hasPrefix("init(")
        default: return true
        }
    }

    static func witnessSignature(mangled raw: String) -> ProtocolWitnessSignature? {
        let normalized = raw.hasPrefix("_") ? String(raw.dropFirst()) : raw
        guard normalized.utf8.count <= 4096 else { return nil }
        let demangled = _stdlib_demangleName(normalized)
        guard demangled.hasPrefix("protocol witness for "),
              let conformance = demangled.range(of: " in conformance ") else { return nil }

        let prefixEnd = demangled.index(demangled.startIndex,
                                        offsetBy: "protocol witness for ".count)
        let requirement = String(demangled[prefixEnd..<conformance.lowerBound])
        let conformanceText = demangled[conformance.upperBound...]
        guard let colon = conformanceText.range(of: " : "),
              let module = conformanceText.range(of: " in ",
                                                  range: colon.upperBound..<conformanceText.endIndex) else {
            return nil
        }
        let conformingType = conformanceText[..<colon.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let qualifiedProtocol = String(conformanceText[colon.upperBound..<module.lowerBound])
        let protocolName = qualifiedProtocol.split(separator: ".").last.map(String.init)
            ?? qualifiedProtocol
        let marker = ".\(protocolName)."
        guard let markerRange = requirement.range(of: marker) else { return nil }
        let memberBody = String(requirement[markerRange.upperBound...])
        let member = (requirement.hasPrefix("static ") ? "static " : "") + memberBody
        guard !member.isEmpty else { return nil }
        return ProtocolWitnessSignature(protocolName: protocolName,
                                        qualifiedProtocolName: qualifiedProtocol,
                                        conformingTypeName: conformingType,
                                        member: member)
    }
}
