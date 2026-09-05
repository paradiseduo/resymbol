import Foundation

indirect enum SwiftTypeReference: CustomStringConvertible {
    case builtin(String)
    case nominal(String)
    case optional(SwiftTypeReference)
    case array(SwiftTypeReference)
    case set(SwiftTypeReference)
    case dictionary(SwiftTypeReference, SwiftTypeReference)
    case unresolved(String)

    var description: String {
        switch self {
        case .builtin(let value), .nominal(let value): return value
        case .optional(let value): return "\(value)?"
        case .array(let value): return "[\(value)]"
        case .set(let value): return "Set<\(value)>"
        case .dictionary(let key, let value): return "[\(key): \(value)]"
        case .unresolved(let value): return value
        }
    }
}

enum SwiftTypeReferenceParser {
    static func parse(_ value: String) -> SwiftTypeReference {
        guard !value.isEmpty else { return .unresolved(value) }
        if value == "Si" { return .builtin("Swift.Int") }
        if value == "SS" { return .builtin("Swift.String") }
        if value == "Sb" { return .builtin("Swift.Bool") }
        if value == "Sd" { return .builtin("Swift.Double") }
        if value == "Sf" { return .builtin("Swift.Float") }
        if value == "Su" { return .builtin("Swift.UInt") }
        if value == "Sg" { return .unresolved(value) }
        if value.hasPrefix("Say"), value.hasSuffix("G") {
            return .array(parse(String(value.dropFirst(3).dropLast())))
        }
        if value.hasPrefix("Shy"), value.hasSuffix("G") {
            return .set(parse(String(value.dropFirst(3).dropLast())))
        }
        if value.hasPrefix("SDy"), value.hasSuffix("G") {
            let body = String(value.dropFirst(3).dropLast())
            if let split = body.firstIndex(of: "_") {
                return .dictionary(parse(String(body[..<split])), parse(String(body[body.index(after: split)...])))
            }
        }
        if value.hasPrefix("So"), value.hasSuffix("C") {
            let body = String(value.dropFirst(2).dropLast())
            var digits = ""
            for character in body {
                if character.isNumber { digits.append(character) } else { break }
            }
            if let length = Int(digits), length > 0 {
                let name = String(body.dropFirst(digits.count))
                return .nominal(String(name.prefix(length)))
            }
        }
        return .unresolved(value)
    }
}
