import Foundation

final class ProtocolWitnessIndex {
    static let shared = ProtocolWitnessIndex()
    // Ingestion happens from many symbol parsing workers; a serial queue keeps
    // updates cheap and guarantees the index is complete before serialization.
    private let queue = DispatchQueue(label: "ProtocolWitnessIndex")
    private var storage = [String: Set<String>]()

    func reset() {
        queue.sync { storage.removeAll(keepingCapacity: true) }
    }

    func ingest(mangled raw: String) {
        // Witness thunks use the TW suffix. Filtering first avoids demangling
        // every symbol in large binaries.
        guard raw.hasSuffix("TW") || raw.contains("TW.") else { return }
        let normalized = raw.hasPrefix("_") ? String(raw.dropFirst()) : raw
        guard normalized.utf8.count <= 4096 else { return }
        let demangled = _stdlib_demangleName(normalized)
        guard demangled.hasPrefix("protocol witness for "),
              let conformance = demangled.range(of: " in conformance ") else { return }

        let prefixEnd = demangled.index(demangled.startIndex, offsetBy: "protocol witness for ".count)
        let requirement = String(demangled[prefixEnd..<conformance.lowerBound])
        let conformanceText = demangled[conformance.upperBound...]
        guard let colon = conformanceText.range(of: " : "),
              let module = conformanceText.range(of: " in ", range: colon.upperBound..<conformanceText.endIndex) else { return }
        let qualifiedProtocol = String(conformanceText[colon.upperBound..<module.lowerBound])
        let protocolName = qualifiedProtocol.split(separator: ".").last.map(String.init) ?? qualifiedProtocol
        let marker = ".\(protocolName)."
        guard let markerRange = requirement.range(of: marker) else { return }
        let member = String(requirement[markerRange.upperBound...])
        guard !member.isEmpty else { return }
        _ = queue.sync { storage[protocolName, default: []].insert(member) }
    }

    func signatures(for protocolName: String) -> [String] {
        queue.sync { (storage[protocolName] ?? []).sorted() }
    }
}

enum ProtocolRequirementResolver {
    static func witnessSignatures(protocolName: String) -> [String] {
        ProtocolWitnessIndex.shared.signatures(for: protocolName)
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
}
