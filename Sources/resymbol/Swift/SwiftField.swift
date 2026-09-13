//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

enum FieldDescriptorKindType: Int {
    case Struct
    case Class
    case Enum
    // Fixed-size multi-payload enums have a special descriptor format that encodes spare bits.
    case MultiPayloadEnum
    // A Swift opaque protocol. There are no fields, just a record for the type itself.
    case kProtocol
    // A Swift class-bound protocol.
    case ClassProtocol
    // An Objective-C protocol, which may be imported or defined in Swift.
    case ObjCProtocol
    // An Objective-C class, which may be imported or defined in Swift.
    // In the former case, field type metadata is not emitted, and must be obtained from the Objective-C runtime.
    case ObjCClass
    
    case Unknown
}

struct FieldDescriptorKind {
    let kind: DataStruct
    let kindType: FieldDescriptorKindType
    
    static func FDK(_ binary: Data, offset: Int) -> FieldDescriptorKind {
        let kind = DataStruct.data(binary, offset: offset, length: 2)
        let kindType = FieldDescriptorKindType(rawValue: kind.value.int16()) ?? .Unknown
        return FieldDescriptorKind(kind: kind, kindType: kindType)
    }
}

struct FieldRecordFlags {
    let flags: DataStruct
    /// Is this an indirect enum case?
    let isIndirectCase: Bool
    /// Is this a mutable `var` property?
    let isVar: Bool
    
    static func FRF(_ binary: Data, offset: Int) -> FieldRecordFlags {
        let flags = DataStruct.data(binary, offset: offset, length: 4)
        let isIndirectCase = (flags.value.int16() & 0x1) == 0x1
        let isVar = (flags.value.int16() & 0x2) == 0x2
        return FieldRecordFlags(flags: flags, isIndirectCase: isIndirectCase, isVar: isVar)
    }
}

struct FieldRecord {
    let flags: FieldRecordFlags
    let mangledTypeName: SwiftName
    let fieldName: SwiftName
    
    static func FR(_ binary: Data, offset: Int) -> FieldRecord {
        let flags = FieldRecordFlags.FRF(binary, offset: offset)
        let mangledTypeName = SwiftName.SN(binary, offset: offset+4, isMangledName: true, isClassName: false)
        let fieldName = SwiftName.SN(binary, offset: offset+8, isMangledName: false, isClassName: false)
        return FieldRecord(flags: flags, mangledTypeName: mangledTypeName, fieldName: fieldName)
    }
}

struct SwiftStoredProperty {
    let declaration: String
    let name: String

    static func from(_ record: FieldRecord) -> SwiftStoredProperty {
        let rawName = record.fieldName.swiftName.value
        let lazyPrefix = "$__lazy_storage_$_"
        if rawName.hasPrefix(lazyPrefix) {
            return SwiftStoredProperty(declaration: "lazy var",
                                       name: String(rawName.dropFirst(lazyPrefix.count)))
        }
        return SwiftStoredProperty(declaration: record.flags.isVar ? "var" : "let",
                                   name: rawName)
    }
}

func recoveredPropertyWrapper(_ record: FieldRecord, fieldType: String?, accessorType: String?) -> String? {
    guard let fieldType else { return nil }
    let rawName = record.fieldName.swiftName.value
    guard rawName.hasPrefix("_"), !rawName.hasPrefix("$__lazy_storage_$_") else { return nil }
    let propertyName = String(rawName.dropFirst())
    guard !propertyName.isEmpty, fieldType.contains("<"), fieldType.hasSuffix(">") else { return nil }
    let wrapper = fieldType.split(separator: "<", maxSplits: 1).first.map(String.init) ?? ""
    guard !wrapper.isEmpty, wrapper != "Swift.Array", wrapper != "Swift.Optional" else { return nil }
    guard let accessorType, !accessorType.isEmpty else { return nil }
    let wrappedType = accessorType
    return "@\(wrapper) var \(propertyName): \(wrappedType)"
}

/// Resolve a field-record type through the same evidence chain used by class
/// and struct output. Returning nil keeps an unresolved Release-only field
/// honest instead of printing pointer bytes as a source type.
func resolvedSwiftFieldType(_ record: FieldRecord, accessorType: String? = nil,
                            genericNames: [String] = [], owner: String? = nil,
                            fieldName: String? = nil) -> String? {
    if let accessorType, !accessorType.isEmpty {
        let normalizedAccessor = normalizeRecoveredSwiftType(accessorType)
        if let placeholder = resolveGenericPlaceholderABI(normalizedAccessor, names: genericNames) {
            return placeholder
        }
        let value = !genericNames.isEmpty
            ? normalizeRecoveredSwiftType(replaceGenericTokens(normalizedAccessor, names: genericNames))
            : normalizedAccessor
        // An accessor can itself retain an unparsed compact ABI function
        // string. Do not let that non-empty raw value suppress the field
        // descriptor, which may contain a form the parser can resolve.
        if isResolvedRecoveredType(value, original: accessorType) { return value }
    }
    var raw = record.mangledTypeName.swiftName.value
    if let placeholder = resolveGenericPlaceholderABI(raw, names: genericNames) {
        return placeholder
    }
    if raw.count == 1, let scalar = raw.unicodeScalars.first,
       scalar.value >= 65, scalar.value < 65 + UInt32(genericNames.count) {
        raw = genericNames[Int(scalar.value - 65)]
    }
    if !genericNames.isEmpty {
        raw = replaceGenericTokens(raw, names: genericNames)
        if let placeholder = resolveGenericPlaceholderABI(raw, names: genericNames) {
            return placeholder
        }
    }
    guard !raw.isEmpty, raw != None else { return nil }
    let structurallyNormalized = normalizeRecoveredSwiftType(raw)
    if isResolvedRecoveredType(structurallyNormalized, original: raw),
       structurallyNormalized != raw {
        return structurallyNormalized
    }
    if raw.hasPrefix("0x") {
        let fixed = fixMangledTypeName(record.mangledTypeName.swiftName)
        let value = normalizeRecoveredSwiftType(fixed)
        if isResolvedRecoveredType(value, original: fixed) { return value }
    }
    if !raw.hasPrefix("0x") {
        let parsed = SwiftTypeReferenceParser.parse(raw)
        let parsedValue = parsed.description
        if case .unresolved = parsed {
            let demangled = demangleSwiftTypeReference(raw) ?? parsedValue
            let value = normalizeRecoveredSwiftType(demangled)
            if isResolvedRecoveredType(value, original: raw) { return value }
        } else {
            let value = normalizeRecoveredSwiftType(parsedValue)
            if !value.isEmpty { return value }
        }
    }
    if let owner, let fieldName,
       let hint = MachOData.shared.swiftFieldTypeHint(owner: owner, field: fieldName) {
        var value = normalizeRecoveredSwiftType(hint)
        // ObjC metadata identifies the runtime class but does not encode
        // Swift optionality. Preserve the Optional marker from the original
        // field typeref when the runtime hint supplies only the nominal name.
        if raw.hasSuffix("Sg"), !value.hasSuffix("?") {
            value += "?"
        }
        if !value.isEmpty { return value }
    }
    return nil
}

private func isResolvedRecoveredType(_ value: String, original: String) -> Bool {
    guard !value.isEmpty else { return false }
    let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
    if isUnresolvedStrippedSymbolicNominal(source) ||
        isUnresolvedStrippedSymbolicNominal(value) {
        return false
    }
    // `y...c` is the compact Swift function-type grammar. Returning it
    // unchanged would leak ABI text into a declaration and, for accessor
    // evidence, prevent the field typeref fallback from being attempted.
    return value != source || !source.hasPrefix("y")
}

/// A stripped symbolic relative pointer can look like a valid ObjC nominal
/// (`So<N>x<hex>C`) after the typeref bytes are rendered as text. It contains
/// no source-level type name and must remain eligible for metadata fallback.
private func isUnresolvedStrippedSymbolicNominal(_ value: String) -> Bool {
    var text = value
    if text.hasSuffix("Sg") { text.removeLast(2) }
    guard text.hasPrefix("So"), text.hasSuffix("C") else { return false }
    let body = String(text.dropFirst(2).dropLast())
    var digitsEnd = body.startIndex
    while digitsEnd < body.endIndex, body[digitsEnd].isNumber {
        digitsEnd = body.index(after: digitsEnd)
    }
    guard digitsEnd > body.startIndex,
          body[digitsEnd...].first == "x" else { return false }
    let hex = body[body.index(after: digitsEnd)...]
    guard hex.count >= 8 else { return false }
    return hex.allSatisfy { $0.isNumber || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
}

private func resolveGenericPlaceholderABI(_ value: String, names: [String]) -> String? {
    var index = value.startIndex
    while index < value.endIndex, value[index].isNumber {
        index = value.index(after: index)
    }
    guard index > value.startIndex,
          let length = Int(value[value.startIndex..<index]), length > 0,
          let end = value.index(index, offsetBy: length, limitedBy: value.endIndex),
          value.distance(from: index, to: end) == length else { return nil }
    let name = String(value[index..<end])
    guard value[end...].contains("Qz") else { return nil }
    return name + (value[end...].contains("Sg") ? "?" : "")
}

/// Decode a field type when the field descriptor stores a Swift mangled name
/// rather than one of the small set of hand-parsed container forms. Metadata
/// uses several equivalent spellings: `$s...`, `s...`, and `_s...` are all
/// seen in stripped arm64 images.
func demangleSwiftTypeReference(_ raw: String) -> String? {
    var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.hasPrefix("_$s") {
        candidate.removeFirst()
    } else if candidate.hasPrefix("_s") {
        candidate = "$" + String(candidate.dropFirst())
    } else if candidate.hasPrefix("s") {
        candidate = "$" + candidate
    } else if !candidate.hasPrefix("$s") && candidate.hasPrefix("So") {
        candidate = "$s" + candidate
    }
    guard candidate.hasPrefix("$s") else { return nil }
    return strictSwiftDemangle(candidate)
}

/// Keep recovered declarations readable and stable while applying only Swift
/// ABI and standard-library transformations.
func normalizeRecoveredSwiftType(_ value: String) -> String {
    var result = sanitizeRecoveredType(value)
    guard !result.isEmpty else { return "" }
    result = normalizeKnownSwiftABIType(result)
    result = sourceDictionaryShorthand(result)
    return result
}

/// Render every recovered `Dictionary<Key, Value>` occurrence using Swift's
/// source-facing `[Key: Value]` shorthand, including dictionaries nested in
/// arrays, tuples, closures, and other dictionary values.
func sourceDictionaryShorthand(_ value: String) -> String {
    var result = value
    for _ in 0..<128 {
        func lastValidRange(of prefix: String) -> Range<String.Index>? {
            var upper = result.endIndex
            while let range = result.range(of: prefix, options: .backwards,
                                           range: result.startIndex..<upper) {
                if prefix == "Dictionary<", range.lowerBound > result.startIndex {
                    let previous = result[result.index(before: range.lowerBound)]
                    if previous.isLetter || previous.isNumber ||
                        previous == "_" || previous == "." {
                        upper = range.lowerBound
                        continue
                    }
                }
                return range
            }
            return nil
        }
        let ranges = ["Swift.Dictionary<", "Dictionary<"].compactMap(lastValidRange)
        guard let prefixRange = ranges.max(by: { $0.lowerBound < $1.lowerBound }) else {
            break
        }
        let open = result.index(before: prefixRange.upperBound)
        var depth = 0
        var close: String.Index?
        var cursor = open
        while cursor < result.endIndex {
            if result[cursor] == "<" {
                depth += 1
            } else if result[cursor] == ">",
                      cursor == result.startIndex ||
                      result[result.index(before: cursor)] != "-" {
                depth -= 1
                if depth == 0 {
                    close = cursor
                    break
                }
            }
            cursor = result.index(after: cursor)
        }
        guard let close else { break }
        let bodyStart = result.index(after: open)
        let body = result[bodyStart..<close]
        var angleDepth = 0
        var parenDepth = 0
        var bracketDepth = 0
        var separator: String.Index?
        for index in body.indices {
            switch body[index] {
            case "<": angleDepth += 1
            case ">" where index == body.startIndex ||
                body[body.index(before: index)] != "-":
                angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            case "," where angleDepth == 0 && parenDepth == 0 && bracketDepth == 0:
                separator = index
            default: break
            }
            if separator != nil { break }
        }
        guard let separator else { break }
        let key = String(body[..<separator]).trimmingCharacters(in: .whitespaces)
        let valueStart = body.index(after: separator)
        let element = String(body[valueStart...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !element.isEmpty else { break }
        result.replaceSubrange(prefixRange.lowerBound...close,
                               with: "[\(key): \(element)]")
    }
    return result
}

/// Recover the readable spelling from ABI-shaped references that are commonly
/// left behind when a field typeref contains symbolic relative pointers. Keep
/// this deliberately limited to stable ABI and standard-library spellings;
/// unknown names must remain unresolved instead of being guessed.
private func normalizeKnownSwiftABIType(_ value: String) -> String {
    if let reported = parseReportedDictionaryABI(value) {
        return reported
    }
    if let autoclosure = parseAutoclosureFunctionABI(value) {
        return autoclosure
    }
    if let expanded = normalizeHalfDemangledGenericDictionary(value) {
        return expanded
    }
    if let callback = normalizeOptionalDictionaryCallbackABI(value) {
        return callback
    }
    if value.hasPrefix("Say"),
       let element = parseGenericCaptureArchetypeABI(String(value.dropFirst(3))) {
        return "[\(element)]"
    }
    if let archetype = parseGenericCaptureArchetypeABI(value) {
        return archetype
    }
    if let composition = parseProtocolCompositionABI(value) {
        return composition
    }
    // Swift 5.5+ commonly records `Task` as `_sScTMny...G` rather than the
    // shorter `ScTy...G` form. Treat the module marker as syntax, not an
    // unresolved nominal reference, before generic-token normalization.
    for prefix in ["_s", "_$s", "$s", "s"] where value.hasPrefix(prefix) {
        let task = String(value.dropFirst(prefix.count))
        if let parsed = parseSwiftTaskABIType(task, start: task.startIndex),
           parsed.end == task.endIndex {
            return parsed.type
        }
    }
    if let continuation = parseCheckedContinuationABI(value) {
        return continuation
    }
    if let parsed = parseSwiftTaskABIType(value, start: value.startIndex),
       parsed.end == value.endIndex {
        return parsed.type
    }
    if let placeholder = resolveGenericPlaceholderABI(value, names: []) {
        return placeholder
    }
    if let associated = parseDependentAssociatedType(value) {
        return associated
    }
    if let half = parseHalfDemangledDictionary(value) {
        return half
    }
    let rewritten = rewriteEmbeddedCompactABIContainers(value)
    if rewritten != value {
        return normalizeKnownSwiftABIType(rewritten)
    }
    if value.hasPrefix("yy_") {
        let optional = value.hasSuffix("cSg")
        let suffixLength = optional ? 3 : (value.hasSuffix("c") ? 1 : 0)
        if suffixLength > 0 {
            let body = String(value.dropFirst(3).dropLast(suffixLength))
            let argument = normalizeKnownSwiftABIType(body)
            if !argument.isEmpty, argument != body {
                return "((\(argument)) -> Void)" + (optional ? "?" : "")
            }
        }
    }
    if let tuple = parseTupleABI(value) {
        return tuple
    }
    if let function = parseFunctionABI(value) {
        return function
    }
    if value.hasPrefix("yy") {
        let body = String(value.dropFirst(2))
        let optional = body.contains("Sg")
        let argument = normalizeKnownSwiftABIType(body.replacingOccurrences(of: "Sg", with: ""))
        if !argument.isEmpty, argument != body {
            return "((\(argument)) -> Void)" + (optional ? "?" : "")
        }
    }

    // Decode a complete nominal/container first. This preserves the richer
    // handling for ObjC generic arguments (for example `So7IpRangeC`).
    if let generic = parseSwiftABIGenericType(value) {
        return generic
    }
    if let compact = parseCompactABIGenericType(value) {
        return compact
    }
    if value.count > 1, value.first == "_",
       value.dropFirst().first?.isNumber == true,
       let generic = parseSwiftABIGenericType("_s" + String(value.dropFirst())) {
        return generic
    }
    let result = normalizeNestedSwiftABITokens(value)
    // Symbolic references are normalized one token at a time. That can turn
    // an initially unparsable typeref into a complete compact function or
    // tuple (for example `y_ss6Result...c` -> `yResult<...>c`). Run the
    // structural parsers once more over this normalized intermediate form.
    if result != value {
        if let tuple = parseTupleABI(result) { return tuple }
        if let function = parseFunctionABI(result) { return function }
        if let generic = parseSwiftABIGenericType(result) { return generic }
        if let compact = parseCompactABIGenericType(result) { return compact }
    }

    let optionalContainer = result.hasSuffix("Sg")
    let containerBody = optionalContainer ? String(result.dropLast(2)) : result
    if containerBody.hasPrefix("Say") && containerBody.hasSuffix("G") {
        let body = String(containerBody.dropFirst(3).dropLast())
        let element = normalizeKnownSwiftABIType(body)
        if !element.isEmpty, element != body || body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) {
            return "[\(element)]" + (optionalContainer ? "?" : "")
        }
    }
    if containerBody.hasPrefix("Shy") && containerBody.hasSuffix("G") {
        let body = String(containerBody.dropFirst(3).dropLast())
        let element = normalizeKnownSwiftABIType(body)
        if !element.isEmpty, element != body || body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) {
            return "Set<\(element)>" + (optionalContainer ? "?" : "")
        }
    }

    // Some accessor signatures retain only the compact function marker after
    // their argument has already been demangled (for example yIndexPath?).
    // Recover the common Void-returning callback shape while preserving
    // unknown function forms verbatim.
    if result.hasPrefix("y"), result.count > 1 {
        var body = String(result.dropFirst())
        let optional = body.hasSuffix("?") || body.hasSuffix("Sg")
        if body.hasSuffix("?") { body.removeLast() }
        if body.hasSuffix("Sg") { body.removeLast(2) }
        if body.hasSuffix("c") { body.removeLast() }
        let canParseSingleArgument = !body.contains("So") && !body.contains("_")
        let argument = normalizeKnownSwiftABIType(body)
        if canParseSingleArgument,
           !argument.isEmpty,
           argument != body || body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) {
            return "((\(argument)) -> Void)" + (optional ? "?" : "")
        }
    }

    // `So<N><Name>C` is the ABI spelling used for ObjC classes/protocols.
    // Some malformed concatenations append another symbolic token after the
    // first nominal; recover the first complete token and preserve Optional.
    if result.hasPrefix("So"), let parsed = parseSwiftNominalTokenWithEnd(result) {
        let suffix = String(result[parsed.end...])
        return parsed.name + (suffix.contains("Sg") || suffix.contains("?") ? "?" : "")
    }
    return result
}

private func parseReportedDictionaryABI(_ value: String) -> String? {
    guard value.hasPrefix("SDy") else { return nil }
    var index = value.index(value.startIndex, offsetBy: 3)
    guard let key = parseABITypeToken(value, start: index, allowNominalContainerGSg: false) else { return nil }
    index = key.end
    if key.type == "AnyHashable", let tuple = parseReportedTuple(value, start: index) {
        return "[AnyHashable: \(tuple.type)]"
    }
    guard key.type == "String" || key.type == "Int64" else { return nil }
    while index < value.endIndex {
        if value[index] == "G" {
            index = value.index(after: index)
            continue
        }
        if value[index] == "_" {
            let next = value.index(after: index)
            if next < value.endIndex, value[next] == "s" || value[next] == "$" {
                break
            }
            index = next
            continue
        }
        break
    }
    if key.type == "String", value[index...].hasPrefix("_s") {
        guard let parsed = parseReportedGenericNominal(value, start: index) else { return nil }
        var end = parsed.end
        while end < value.endIndex, value[end] == "G" { end = value.index(after: end) }
        guard end == value.endIndex else { return nil }
        return "[String: \(parsed.type)]"
    }
    guard key.type == "Int64", value[index...].hasPrefix("Say") else { return nil }
    index = value.index(index, offsetBy: 3)
    guard let element = parseContextualSwiftNominalToken(value, start: index) else { return nil }
    var end = element.end
    guard end < value.endIndex, value[end] == "G" else { return nil }
    end = value.index(after: end)
    while end < value.endIndex, value[end] == "G" { end = value.index(after: end) }
    guard end == value.endIndex else { return nil }
    let name = element.type.split(separator: ".").last.map(String.init) ?? element.type
    return "[Int64: [\(name)]]"
}

private func parseReportedTuple(_ value: String, start: String.Index)
    -> (type: String, end: String.Index)? {
    var index = start
    while index < value.endIndex, value[index] == "_" { index = value.index(after: index) }
    guard let first = parseABITypeToken(value, start: index, allowNominalContainerGSg: false) else { return nil }
    index = first.end
    var labels = SwiftABIIdentifierDecoder()
    guard let from = labels.parse(value, start: index) else { return nil }
    index = from.end
    guard index < value.endIndex, value[index] == "_" else { return nil }
    index = value.index(after: index)
    // The second element reuses the first type (`A`) and its label is encoded
    // after an additional substitution marker (`B2to`). Decode the readable
    // length-prefixed label without assuming any application identifier.
    guard index < value.endIndex, value[index] == "A" else { return nil }
    index = value.index(after: index)
    while index < value.endIndex, value[index].isLetter,
          value[index].isUppercase {
        index = value.index(after: index)
    }
    let secondLabelName: String
    if let secondLabel = labels.parse(value, start: index) {
        secondLabelName = secondLabel.name
        index = secondLabel.end
    } else {
        guard index < value.endIndex, value[index].isNumber,
              let parsed = parseLengthPrefixedName(String(value[index...])) else {
            return nil
        }
        secondLabelName = parsed.name
        index = value.index(index, offsetBy: parsed.consumed)
    }
    guard index < value.endIndex, value[index] == "t" else { return nil }
    index = value.index(after: index)
    while index < value.endIndex, value[index] == "G" { index = value.index(after: index) }
    guard index == value.endIndex else { return nil }
    return ("(\(from.name): \(first.type), \(secondLabelName): \(first.type))", index)
}

private func parseReportedGenericNominal(_ value: String, start: String.Index)
    -> (type: String, end: String.Index)? {
    let suffix = String(value[start...])
    guard suffix.hasPrefix("_s") else { return nil }
    let body = String(suffix.dropFirst(2))
    guard let module = parseLengthPrefixedName(body) else { return nil }
    var cursor = body.index(body.startIndex, offsetBy: module.consumed)
    guard body[cursor...].hasPrefix("0A0C") else { return nil }
    cursor = body.index(cursor, offsetBy: 4)
    guard body[cursor...].hasPrefix("Mn") else { return nil }
    cursor = body.index(cursor, offsetBy: 2)
    guard cursor < body.endIndex, body[cursor] == "y" else { return nil }
    let genericStart = body.index(after: cursor)
    let chars = Array(body)
    let absoluteStart = body.distance(from: body.startIndex, to: genericStart)
    guard let genericEnd = nestedGenericEnd(chars, start: absoluteStart) else { return nil }
    let argumentBody = String(body[genericStart..<body.index(body.startIndex, offsetBy: genericEnd)])
    let args = parseABITypeArguments(argumentBody)
    guard !args.isEmpty else { return nil }
    let name = module.name.hasSuffix("Kit") ? String(module.name.dropLast(3)) : module.name
    let endInBody = body.index(body.startIndex, offsetBy: genericEnd + 1)
    return ("\(name)<\(args.joined(separator: ", "))>", value.index(start, offsetBy: 2 + body.distance(from: body.startIndex, to: endInBody)))
}

private func parseContextualSwiftNominalToken(_ value: String, start: String.Index)
    -> (type: String, end: String.Index)? {
    let suffix = String(value[start...])
    guard let module = parseLengthPrefixedName(suffix) else { return nil }
    var cursor = suffix.index(suffix.startIndex, offsetBy: module.consumed)
    var identifiers = SwiftABIIdentifierDecoder()
    identifiers.register(module.name)
    guard let decoded = identifiers.parse(suffix, start: cursor) else { return nil }
    cursor = decoded.end
    guard suffix[cursor...].hasPrefix("_p") else { return nil }
    cursor = suffix.index(cursor, offsetBy: 2)
    return (decoded.name, value.index(start, offsetBy: cursor.utf16Offset(in: suffix)))
}

private func parseAutoclosureFunctionABI(_ value: String) -> String? {
    guard value.hasPrefix("y"), value.hasSuffix("c") || value.hasSuffix("tc") else { return nil }
    var index = value.index(after: value.startIndex)
    var arguments = [String]()
    while index < value.endIndex, value[index] != "c" {
        if value[index] == "t" { index = value.index(after: index); continue }
        guard let token = parseABITypeToken(value, start: index,
                                             allowNominalContainerGSg: false) else { return nil }
        index = token.end
        var type = token.type
        if value[index...].hasPrefix("yXK") {
            type = "@autoclosure () -> \(type)"
            index = value.index(index, offsetBy: 3)
            if index < value.endIndex, value[index] == "_" { index = value.index(after: index) }
        }
        arguments.append(type)
    }
    guard index < value.endIndex, value[index] == "c" else { return nil }
    return "((\(arguments.joined(separator: ", "))) -> Void)"
}

private func normalizeHalfDemangledGenericDictionary(_ value: String) -> String? {
    guard value.first == "[", let close = value.firstIndex(of: "]"),
          value.index(after: close) < value.endIndex,
          value[value.index(after: close)] == "y" else { return nil }
    let bracket = String(value[value.startIndex...close])
    guard let colon = bracket.firstIndex(of: ":"), value.hasSuffix("GGG") else { return nil }
    let key = String(bracket[bracket.index(after: bracket.startIndex)..<colon]).trimmingCharacters(in: .whitespaces)
    let base = String(bracket[bracket.index(after: colon)..<bracket.index(before: bracket.endIndex)]).trimmingCharacters(in: .whitespaces)
    let encoded = String(value[value.index(after: close)..<value.index(value.endIndex, offsetBy: -3)]).dropFirst()
    let args = parseABITypeArguments(String(encoded))
    guard !key.isEmpty, !base.isEmpty, args.count == 1 else { return nil }
    return "[\(key): \(base)<\(args[0])>]"
}

/// Decode Swift concurrency's standard `CheckedContinuation<T, E>` spelling.
/// `ScC` is the ABI substitution for the nominal; generic arguments remain
/// encoded in the same concatenated stream used by other Swift containers.
private func parseCheckedContinuationABI(_ value: String) -> String? {
    guard value.hasPrefix("ScCy"), value.hasSuffix("G") else { return nil }
    let body = String(value.dropFirst(4).dropLast())
    var arguments = [String]()
    var index = body.startIndex
    while index < body.endIndex {
        if body[index] == "_" || body[index] == "t" || body[index] == "G" {
            index = body.index(after: index)
            continue
        }
        guard let parsed = parseABITypeToken(body, start: index), parsed.end > index else {
            return nil
        }
        arguments.append(parsed.type)
        index = parsed.end
    }
    guard arguments.count >= 2 else { return nil }
    return "CheckedContinuation<\(arguments.joined(separator: ", "))>"
}

/// Decode generic archetype references retained by Swift closure capture
/// metadata. These strings carry a readable archetype seed (`x` or a
/// length-prefixed `T`) followed by generic-signature constraints and
/// ownership markers, ending in `XX`. The constraints do not change the
/// source-level captured value type, so they are consumed only after their
/// structural markers are validated.
private func parseGenericCaptureArchetypeABI(_ value: String) -> String? {
    guard value.hasSuffix("XX") else { return nil }
    var index = value.startIndex
    let base: String
    if value[index] == "x" {
        base = "A"
        index = value.index(after: index)
    } else if value[index...].hasPrefix("qd__") {
        // Opaque/dependent generic parameters use `qd__` when the source
        // parameter name is unavailable. Preserve only a stable placeholder.
        base = "A"
        index = value.index(index, offsetBy: 4)
    } else if let length = parseLengthPrefixedName(String(value[index...])) {
        base = length.name
        index = value.index(index, offsetBy: length.consumed)
    } else {
        return nil
    }

    var optional = false
    if value[index...].hasPrefix("Sg") {
        optional = true
        index = value.index(index, offsetBy: 2)
    }
    if value[index...].hasPrefix("Xw") || value[index...].hasPrefix("Xo") {
        index = value.index(index, offsetBy: 2)
    }

    // `Sayqd__Gz...` carries the Array generic marker immediately before the
    // generic-signature marker. The outer `Say` wrapper is handled by the
    // caller, so consume this marker here when present.
    if value[index...].hasPrefix("G") {
        index = value.index(after: index)
    }

    let suffix = value[index...]
    guard suffix.contains("z"), suffix.contains("R"),
          suffix.hasSuffix("XX") else { return nil }
    // Validate at least one nominal/protocol constraint token rather than
    // accepting arbitrary text ending in XX as an archetype.
    let constraintBody = String(suffix)
    guard constraintBody.contains("So") || constraintBody.contains("_s") ||
          constraintBody.contains("$s") else { return nil }
    return base + (optional ? "?" : "")
}

/// Decode an existential composition ending in `Xc`, followed by Optional and
/// ownership markers. Components are emitted in ABI stack order: superclass
/// first, followed by protocols. Identifier word substitutions are decoded
/// from the string itself.
private func parseProtocolCompositionABI(_ value: String) -> String? {
    var cursor = value.startIndex
    var components = [String]()

    if cursor < value.endIndex, value[cursor].isNumber {
        var identifiers = SwiftABIIdentifierDecoder()
        guard let seed = identifiers.parse(value, start: cursor) else { return nil }
        cursor = seed.end
        var last = seed.name
        while cursor < value.endIndex, value[cursor].isNumber,
              let decoded = identifiers.parse(value, start: cursor) {
            last = decoded.name
            cursor = decoded.end
        }
        components.append(last)
    }
    while cursor < value.endIndex, value[cursor] == "_" {
        cursor = value.index(after: cursor)
    }
    while cursor < value.endIndex {
        while cursor < value.endIndex, value[cursor] == "_" {
            cursor = value.index(after: cursor)
        }
        let suffix = String(value[cursor...])
        if let nominal = parseSwiftNominalTokenWithEnd(suffix) {
            components.append(nominal.name)
            cursor = value.index(cursor,
                                 offsetBy: nominal.end.utf16Offset(in: suffix))
            if value[cursor...].hasPrefix("_p") {
                cursor = value.index(cursor, offsetBy: 2)
            }
            continue
        }
        if let nominal = parseNestedSwiftABIToken(Array(suffix), start: 0),
           nominal.end > 0 {
            components.append(nominal.name)
            cursor = value.index(cursor, offsetBy: nominal.end)
            continue
        }
        break
    }
    guard components.count >= 2, value[cursor...].hasPrefix("Xc") else { return nil }
    cursor = value.index(cursor, offsetBy: 2)
    var optional = false
    if value[cursor...].hasPrefix("Sg") {
        optional = true
        cursor = value.index(cursor, offsetBy: 2)
    }
    if value[cursor...].hasPrefix("Xw") {
        cursor = value.index(cursor, offsetBy: 2)
    }
    guard cursor == value.endIndex else { return nil }
    return "(" + components.reversed().joined(separator: " & ") + ")" +
        (optional ? "?" : "")
}

/// A frequent reflection spelling for optional callbacks is
/// `ySDy<Key>_<Protocol>GSgcSg`. The dictionary is one callback argument,
/// but its protocol existential is separated by an underscore and older
/// generic token walkers can otherwise split it into four arguments.
private func normalizeOptionalDictionaryCallbackABI(_ value: String) -> String? {
    guard value.hasPrefix("ySDy"), value.hasSuffix("cSg") else { return nil }
    let body = String(value.dropFirst().dropLast(3))
    guard let dictionary = parseCompactABIContainerPrefix(body),
          dictionary.consumed == body.count else { return nil }
    return "((\(sourceDictionaryShorthand(dictionary.type))) -> Void)?"
}

private func parseFunctionABI(_ value: String) -> String? {
    guard value.count <= 4096,
          let parsed = parseFunctionABIType(value, start: value.startIndex),
          parsed.end == value.endIndex else { return nil }
    return parsed.type
}

/// Parse the postfix Swift function-type grammar used by reflection typerefs:
/// result type, parameter type/tuple, then `c`, optionally followed by `Sg`.
/// The currently observed compact forms use `y` for a Void result. Nested
/// function parameters are parsed recursively instead of being mistaken for
/// an outer return type.
private func parseFunctionABIType(_ value: String, start: String.Index,
                                   substitutions: [String] = [])
    -> (type: String, end: String.Index, labels: [String])? {
    guard start < value.endIndex else { return nil }
    let returnType: String
    let returnSubstitutions: [String]
    let returnLabels: [String]
    var index: String.Index
    if value[start] == "y" {
        returnType = "Void"
        returnSubstitutions = []
        returnLabels = []
        index = value.index(after: start)
    } else if let tuple = parseTupleABIPrefix(value, start: start),
              tuple.elementTypes.count >= 2, tuple.labelCount > 0 {
        returnType = tuple.type
        returnSubstitutions = tuple.elementTypes
        returnLabels = tuple.labels
        index = tuple.end
    } else {
        guard let result = parseABITypeToken(value, start: start,
                                             substitutions: substitutions),
              result.end > start else { return nil }
        returnType = result.type
        returnSubstitutions = []
        returnLabels = []
        index = result.end
    }
    var arguments = [String]()

    // `y` is also the empty parameter-list marker, as in `yyc`.
    if index < value.endIndex, value[index] == "y" {
        // In older reflection spellings the second leading `y` is an empty
        // tuple marker before the real parameter type (`yy_TypecSg`).
        // Nested function parameters occur later in the argument sequence.
        index = value.index(after: index)
    }

    while index < value.endIndex, value[index] != "c" {
        if value[index...].hasPrefix("Sg") {
            // Some symbolic nominal tokens expose Optional's marker as a
            // separate token after the parser has already consumed the base
            // nominal. It is not a standalone function argument.
            index = value.index(index, offsetBy: 2)
            continue
        }
        if value[index] == "t" {
            index = value.index(after: index)
            break
        }
        if value[index] == "G" {
            let next = value.index(after: index)
            if next < value.endIndex,
               value[next] == "c" || value[next] == "t" ||
               !value[next...].hasPrefix("Sg") {
                index = next
                continue
            }
        }
        if value[index] == "_" {
            index = value.index(after: index)
            continue
        }
        if let repeated = parseStdlibRepeatedSubstitution(value, start: index) {
            arguments.append(contentsOf: repeated.types)
            index = repeated.end
            continue
        }
        let knownTypes = substitutions + returnSubstitutions + arguments
        if let autoclosure = parseAutoclosureABIType(value, start: index,
                                                     substitutions: knownTypes) {
            arguments.append(autoclosure.type)
            index = autoclosure.end
            continue
        }
        if let substituted = parseFunctionTypeSubstitution(
            value, start: index, previousTypes: knownTypes) {
            arguments.append(contentsOf: substituted.types)
            index = substituted.end
            continue
        }
        let objcContext = returnType == "Void" ? arguments : [returnType] + arguments
        if let substituted = parseObjCWordSubstitutionNominal(
            value, start: index,
            previousTypes: objcContext.isEmpty ? substitutions : objcContext) {
            arguments.append(substituted.type)
            index = substituted.end
            continue
        }
        guard let parsed = parseABITypeToken(value, start: index,
                                             substitutions: knownTypes),
              parsed.end > index else {
            return nil
        }
        arguments.append(parsed.type)
        index = parsed.end
    }
    guard index < value.endIndex, value[index] == "c" else { return nil }
    index = value.index(after: index)

    var optional = false
    if value[index...].hasPrefix("Sg") {
        optional = true
        index = value.index(index, offsetBy: 2)
    }
    guard !arguments.contains(where: {
        $0 == "GSg" || $0 == "G" ||
            $0.contains("OMn") || $0.hasPrefix("_s") ||
            ($0.hasPrefix("ss") && $0.contains("Mn"))
    }) else { return nil }
    let parameters = arguments.joined(separator: ", ")
    return ("((\(parameters)) -> \(returnType))" + (optional ? "?" : ""),
            index, returnLabels)
}

private func parseAutoclosureABIType(_ value: String, start: String.Index,
                                     substitutions: [String])
    -> (type: String, end: String.Index)? {
    guard let wrapped = parseABITypeToken(value, start: start,
                                          substitutions: substitutions),
          wrapped.end > start,
          value[wrapped.end...].hasPrefix("yXK") else { return nil }
    return ("@autoclosure () -> \(wrapped.type)",
            value.index(wrapped.end, offsetBy: 3))
}

private func parseABITypeToken(_ value: String, start: String.Index,
                                substitutions: [String] = [],
                                allowNominalContainerGSg: Bool = true,
                                stopAtTupleLabel: Bool = false)
    -> (type: String, end: String.Index)? {
    let suffix = String(value[start...])
    // These source-facing standard-library spellings are emitted without the
    // usual ABI length prefix in reflection strings. Recognize them before
    // nominal/plain-token parsing so a following token (for example `Su` in
    // `StaticStringSu`) remains available to the caller.
    if let source = parseSourceFacingTypeToken(value, start: start) {
        return source
    }
    // Protocol-existential arrays use `_p` before the array terminator. The
    // nested parser consumes that marker and the closing `G` precisely; let it
    // run before the generic compact parser, which intentionally accepts more
    // abbreviated spellings.
    if suffix.hasPrefix("SaySo"),
       let nested = parseNestedContainerToken(Array(suffix), start: 0) {
        return (nested.name, value.index(start, offsetBy: nested.end))
    }
    if let compact = parseCompactABIContainerPrefix(suffix, substitutions: substitutions) {
        var end = value.index(start, offsetBy: compact.consumed)
        // Reflection containers can carry one additional generic-context G
        // before a tuple label. It is not a parent container terminator.
        if allowNominalContainerGSg, end < value.endIndex, value[end] == "G" {
            let next = value.index(after: end)
            if next < value.endIndex, value[next].isNumber {
                end = next
            }
        }
        return (compact.type, end)
    }
    if let container = parseNestedContainerToken(Array(suffix), start: 0) {
        return (container.name, value.index(start, offsetBy: container.end))
    }
    if let nominal = parseSwiftNominalTokenWithEnd(suffix) {
        var type = nominal.name
        var end = value.index(start, offsetBy: nominal.end.utf16Offset(in: suffix))
        if value[end...].hasPrefix("_pXp") {
            type += ".Type"
            end = value.index(end, offsetBy: 4)
        } else if value[end...].hasPrefix("_p") {
            end = value.index(end, offsetBy: 2)
        } else if value[end...].hasPrefix("G_p") {
            end = value.index(end, offsetBy: 3)
        }
        if end < value.endIndex, value[end] == "_",
           value[end...].hasPrefix("_So") {
            let classStart = value.index(after: end)
            if let classNominal = parseSwiftNominalTokenWithEnd(String(value[classStart...])) {
                let classConsumed = classNominal.end.utf16Offset(in: String(value[classStart...]))
                let classEnd = value.index(classStart, offsetBy: classConsumed)
                if value[classEnd...].hasPrefix("Xc") {
                    type = "\(classNominal.name) & \(type)"
                    end = value.index(classEnd, offsetBy: 2)
                }
            }
        }
        if allowNominalContainerGSg,
           end < value.endIndex, value[end] == "G",
           value.index(after: end) < value.endIndex,
           value[value.index(after: end)] == "y" {
            end = value.index(after: end)
        }
        if end < value.endIndex, value[end] == "y" {
            let characters = Array(value)
            let genericStart = value.distance(from: value.startIndex, to: end) + 1
            if let genericEnd = nestedGenericEnd(characters, start: genericStart) {
                let bodyStart = value.index(after: end)
                let bodyEnd = value.index(value.startIndex, offsetBy: genericEnd)
                let body = String(value[bodyStart..<bodyEnd])
                let arguments: [String]
                if let tuple = parseTupleABI(body) {
                    arguments = [tuple]
                } else {
                    arguments = parseABITypeArguments(body)
                }
                if !arguments.isEmpty {
                    type += "<\(arguments.joined(separator: ", "))>"
                    end = value.index(after: bodyEnd)
                }
            }
        }
        // Function arguments use `...CGSg` for an optional nominal. Inside a
        // compact dictionary the trailing `GSg` is the container closer.
        if allowNominalContainerGSg,
           value[end...].hasPrefix("G"),
           value[value.index(after: end)...].hasPrefix("Sg") {
            end = value.index(after: end)
        }
        if value[end...].hasPrefix("Sg") {
            type += "?"
            end = value.index(end, offsetBy: 2)
        }
        // A nominal used as a function argument may carry the generic
        // context terminator `G` even when no generic arguments are rendered
        // (for example `...ModelCGSay...`). It belongs to the nominal token,
        // not to the following argument.
        if allowNominalContainerGSg, end < value.endIndex, value[end] == "G" {
            let next = value.index(after: end)
            if next < value.endIndex, value[next] != "c", value[next] != "t" {
                end = next
            }
        }
        if stopAtTupleLabel, end < value.endIndex, value[end] == "G" {
            let next = value.index(after: end)
            if next < value.endIndex, value[next].isNumber {
                end = next
            }
        }
        return (type, end)
    }
    if suffix.hasPrefix("_s") || suffix.hasPrefix("_$s") ||
       suffix.hasPrefix("$s") ||
       (suffix.first == "s" && suffix.dropFirst().first?.isNumber == true) ||
       (suffix.hasPrefix("ss") && suffix.dropFirst(2).first?.isNumber == true) {
        if let parsed = parseNestedSwiftABIToken(Array(suffix), start: 0) {
            return (parsed.name, value.index(start, offsetBy: parsed.end))
        }
    }
    if suffix.hasPrefix("Si") { return ("Int", value.index(start, offsetBy: 2)) }
    if suffix.hasPrefix("SS") {
        var type = "String"
        var end = value.index(start, offsetBy: 2)
        if value[end...].hasPrefix("Sg") {
            type += "?"
            end = value.index(end, offsetBy: 2)
        }
        return (type, end)
    }
    if suffix.hasPrefix("Sb") || suffix.hasPrefix("sb") {
        var end = value.index(start, offsetBy: 2)
        var type = "Bool"
        if value[end...].hasPrefix("Sg") {
            type += "?"
            end = value.index(end, offsetBy: 2)
        }
        return (type, end)
    }
    if suffix.hasPrefix("Never") {
        return ("Never", value.index(start, offsetBy: 5))
    }
    if suffix.hasPrefix("Sd") { return ("Double", value.index(start, offsetBy: 2)) }
    if suffix.hasPrefix("Sf") { return ("Float", value.index(start, offsetBy: 2)) }
    if suffix.hasPrefix("Su") { return ("UInt", value.index(start, offsetBy: 2)) }
    if suffix.hasPrefix("SO") {
        return ("ObjectIdentifier", value.index(start, offsetBy: 2))
    }
    if suffix.hasPrefix("yp") {
        return ("Any", value.index(start, offsetBy: 2))
    }
    if suffix.hasPrefix("SE") {
        var end = value.index(start, offsetBy: 2)
        if value[end...].hasPrefix("_p") {
            end = value.index(end, offsetBy: 2)
        }
        return ("Encodable", end)
    }
    if suffix.hasPrefix("Result<"), let close = suffix.firstIndex(of: ">") {
        let inner = String(suffix[suffix.index(suffix.startIndex, offsetBy: 7)..<close])
        var type = inner.contains(",") ? "Result<\(inner)>" : "Result<\(inner), Error>"
        var end = value.index(start, offsetBy: suffix.distance(from: suffix.startIndex, to: close) + 1)
        if value[end...].hasPrefix("?") {
            type += "?"
            end = value.index(after: end)
        } else if value[end...].hasPrefix("Sg") {
            type += "?"
            end = value.index(end, offsetBy: 2)
        }
        return (type, end)
    }
    if suffix.hasPrefix("ScT") {
        return parseSwiftTaskABIType(value, start: start)
    }
    if let wrapper = parseBracketedWrapperABIType(value, start: start) {
        return wrapper
    }
    if suffix.hasPrefix("[") {
        return parseAlreadyDemangledBracketType(value, start: start)
    }
    if suffix.first == "x", suffix.count > 1 {
        let next = suffix.index(after: suffix.startIndex)
        if suffix[next].isUppercase || suffix[next] == "S" || suffix[next] == "y" {
            return ("A", value.index(after: start))
        }
    }
    if suffix.hasPrefix("y") {
        if let function = parseFunctionABIType(value, start: start, substitutions: substitutions) {
            return (function.type, function.end)
        }
        if suffix.hasPrefix("yResult<"),
           let result = parseABITypeToken(value, start: value.index(after: start),
                                          substitutions: substitutions) {
            return result
        }
        return nil
    }
    return parsePlainABITypeToken(value, start: start,
                                  stopAtTupleLabel: stopAtTupleLabel)
}

private func parseSourceFacingTypeToken(_ value: String, start: String.Index)
    -> (type: String, end: String.Index)? {
    let names = ["StaticString", "AnyHashable", "CGFloat", "Int64", "UInt64", "Int32", "UInt32"]
    let suffix = value[start...]
    guard let name = names.sorted(by: { $0.count > $1.count }).first(where: { suffix.hasPrefix($0) }) else {
        return nil
    }
    return (name, value.index(start, offsetBy: name.count))
}

/// Replace complete `SDy`/`Say`/`Shy` fragments that sit inside already
/// demangled wrappers such as `[SDySSAnyHashableG]` or `((SDy...) -> Void)?`.
private func rewriteEmbeddedCompactABIContainers(_ value: String) -> String {
    var result = value
    var searchFrom = result.startIndex
    var steps = 0
    while steps < 64, searchFrom < result.endIndex {
        steps += 1
        let starts = ["SDy"].compactMap { prefix -> String.Index? in
            result.range(of: prefix, range: searchFrom..<result.endIndex)?.lowerBound
        }
        guard let start = starts.min() else { break }
        let suffix = String(result[start...])
        if let parsed = parseCompactABIContainerPrefix(suffix) {
            let end = result.index(start, offsetBy: parsed.consumed)
            let rewritten = sourceDictionaryShorthand(parsed.type)
            result.replaceSubrange(start..<end, with: rewritten)
            searchFrom = result.index(start, offsetBy: rewritten.count)
        } else {
            searchFrom = result.index(after: start)
        }
    }
    return result
}

/// Half-demangled dictionaries such as `SDyUUID<DuPopFlowState>` or
/// `SDyUInt64<Repeater>` keep `SDy` but already expanded the two arguments.
private func parseHalfDemangledDictionary(_ value: String) -> String? {
    guard value.hasPrefix("SDy") else { return nil }
    var body = String(value.dropFirst(3))
    var optional = false
    if body.hasSuffix("?") { optional = true; body.removeLast() }
    if body.hasSuffix("Sg") { optional = true; body.removeLast(2) }
    guard let open = body.firstIndex(of: "<"), body.hasSuffix(">"),
          !body.contains("SDy") else { return nil }
    let key = String(body[..<open])
    let element = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
    guard !key.isEmpty, !element.isEmpty,
          key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else {
        return nil
    }
    return "[\(key): \(element)]" + (optional ? "?" : "")
}

private func isUntypedAnyHashableDictionaryKey(_ type: String) -> Bool {
    type == "AnyHashable" || type == "AnyHashable?"
}

/// Terminators that mean the `yp` / `Any` value was omitted, not that another
/// dictionary argument is still waiting to be parsed.
private func isUntypedAnyHashableDictionaryTerminator(_ value: String,
                                                       at index: String.Index) -> Bool {
    guard index < value.endIndex else { return true }
    let rest = value[index...]
    return rest.hasPrefix("?") || rest.hasPrefix("G") || rest.hasPrefix("Sg") ||
        rest.hasPrefix("c") || rest.hasPrefix("t")
}

private func parseAlreadyDemangledBracketType(_ value: String, start: String.Index)
    -> (type: String, end: String.Index)? {
    guard start < value.endIndex, value[start] == "[" else { return nil }
    var depth = 0
    var cursor = start
    while cursor < value.endIndex {
        if value[cursor] == "[" { depth += 1 }
        else if value[cursor] == "]" {
            depth -= 1
            if depth == 0 {
                var end = value.index(after: cursor)
                var type = String(value[start..<end])
                if end < value.endIndex, value[end] == "?" {
                    type += "?"
                    end = value.index(after: end)
                }
                return (type, end)
            }
        }
        cursor = value.index(after: cursor)
    }
    return nil
}

private func parseSwiftTaskABIType(_ value: String, start: String.Index)
    -> (type: String, end: String.Index)? {
    guard value[start...].hasPrefix("ScT") else { return nil }
    var index = value.index(start, offsetBy: 3)
    // `Mn` is the nominal metadata accessor marker used by current Swift
    // reflection strings (`_sScTMny...G`). It is not part of Task's generic
    // argument list.
    if value[index...].hasPrefix("Mn") {
        index = value.index(index, offsetBy: 2)
    }
    guard index < value.endIndex, value[index] == "y" else { return nil }
    let characters = Array(value)
    let genericStart = value.distance(from: value.startIndex, to: index) + 1
    guard let genericEnd = nestedGenericEnd(characters, start: genericStart) else { return nil }
    let bodyStart = value.index(after: index)
    let bodyEnd = value.index(value.startIndex, offsetBy: genericEnd)
    let arguments = parseABITypeArguments(String(value[bodyStart..<bodyEnd]))
    guard arguments.count >= 2 else { return nil }
    let failure = arguments.last!
    let success: String
    if arguments.count == 2 {
        success = arguments[0]
    } else {
        success = "(\(arguments.dropLast().joined(separator: ", ")))"
    }
    index = value.index(after: bodyEnd)
    var type = "Task<\(success), \(failure)>"
    if value[index...].hasPrefix("Sg") {
        type += "?"
        index = value.index(index, offsetBy: 2)
    }
    return (type, index)
}

private func parseBracketedWrapperABIType(_ value: String, start: String.Index)
    -> (type: String, end: String.Index)? {
    guard start < value.endIndex, value[start] == "[",
          let close = value[start...].firstIndex(of: "]") else { return nil }
    let nameStart = value.index(after: start)
    let wrapper = String(value[nameStart..<close])
    guard !wrapper.isEmpty,
          wrapper.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else {
        return nil
    }
    let marker = value.index(after: close)
    guard marker < value.endIndex, value[marker] == "y" else { return nil }
    let characters = Array(value)
    let genericStart = value.distance(from: value.startIndex, to: marker) + 1
    guard let genericEnd = nestedGenericEnd(characters, start: genericStart) else { return nil }
    let bodyStart = value.index(after: marker)
    let bodyEnd = value.index(value.startIndex, offsetBy: genericEnd)
    let arguments = parseABITypeArguments(String(value[bodyStart..<bodyEnd]))
    guard let element = arguments.first else { return nil }
    var end = value.index(after: bodyEnd)
    var type = "\(wrapper)<\(element)>"
    if value[end...].hasPrefix("Sg") {
        type += "?"
        end = value.index(end, offsetBy: 2)
    }
    return (type, end)
}

private func parseStdlibRepeatedSubstitution(_ value: String, start: String.Index)
    -> (types: [String], end: String.Index)? {
    guard start < value.endIndex, value[start] == "S" else { return nil }
    var cursor = value.index(after: start)
    guard cursor < value.endIndex, value[cursor].isNumber else { return nil }
    var digits = ""
    while cursor < value.endIndex, value[cursor].isNumber {
        digits.append(value[cursor])
        cursor = value.index(after: cursor)
    }
    guard let count = Int(digits), count > 1, count <= 8,
          cursor < value.endIndex else { return nil }
    let type: String
    switch value[cursor] {
    case "S": type = "String"
    case "i": type = "Int"
    case "b": type = "Bool"
    case "d": type = "Double"
    case "f": type = "Float"
    case "u": type = "UInt"
    default: return nil
    }
    return (Array(repeating: type, count: count), value.index(after: cursor))
}

private func parsePlainABITypeToken(_ value: String, start: String.Index,
                                    stopAtTupleLabel: Bool = false)
    -> (type: String, end: String.Index)? {
    let suffix = String(value[start...])
    var plainEnd = suffix.startIndex
    while plainEnd < suffix.endIndex {
        let character = suffix[plainEnd]
        let tail = String(suffix[plainEnd...])
        if plainEnd > suffix.startIndex {
            let previous = suffix[suffix.index(before: plainEnd)]
            if stopAtTupleLabel, character.isNumber {
                var identifiers = SwiftABIIdentifierDecoder()
                if let label = identifiers.parse(suffix, start: plainEnd),
                   label.end > plainEnd {
                    break
                }
            }
            if previous == "?", character.isLetter {
                break
            }
            if tail == "tc" || tail == "tcSg" {
                break
            }
            if isABISubstitutionSuffix(tail) {
                break
            }
            if tail.hasPrefix("Say") || tail.hasPrefix("Shy") || tail.hasPrefix("SDy") ||
               tail.hasPrefix("_s") || tail.hasPrefix("$s") || tail.hasPrefix("yp") ||
               tail.hasPrefix("Sg") || tail.hasPrefix("ScT") ||
               tail.hasPrefix("ySo") || tail.hasPrefix("y_s") ||
               tail.hasPrefix("yResult<") {
                break
            }
            if let std = ["Si", "SS", "Sb", "Sd", "Sf", "Su", "SO", "So"].first(where: { tail.hasPrefix($0) }) {
                let after = tail.index(tail.startIndex, offsetBy: std.count)
                if after == tail.endIndex || !tail[after].isLowercase {
                    break
                }
            }
            if character == "G", isGenericCloserG(suffix, at: plainEnd, tokenStart: suffix.startIndex) {
                break
            }
            if character == "c" {
                let next = suffix.index(after: plainEnd)
                // Only `c` / `cSg` terminate a token. `ct` is a common
                // English pair inside readable nominal identifiers.
                if next == suffix.endIndex || suffix[next...].hasPrefix("Sg") {
                    break
                }
            }
        }
        guard character.isLetter || character.isNumber || character == "." || character == "?" else {
            break
        }
        plainEnd = suffix.index(after: plainEnd)
    }
    guard plainEnd > suffix.startIndex else { return nil }
    var type = String(suffix[..<plainEnd])
    var consumed = type.count
    if !type.hasSuffix("?"), suffix[plainEnd...].hasPrefix("Sg") {
        type += "?"
        consumed += 2
    }
    guard !type.isEmpty, type != "G", type != "Sg", type != "?" else { return nil }
    return (type, value.index(start, offsetBy: consumed))
}

/// Recognize a complete function-argument substitution suffix such as `ABtc`
/// or `A2Etc`. The substituted type itself is resolved from earlier arguments;
/// the readable identifier before it can therefore be arbitrary.
private func isABISubstitutionSuffix(_ value: String) -> Bool {
    guard value.first == "A" else { return false }
    var cursor = value.index(after: value.startIndex)
    while cursor < value.endIndex, value[cursor].isNumber {
        cursor = value.index(after: cursor)
    }
    guard cursor < value.endIndex, value[cursor].isUppercase else { return false }
    cursor = value.index(after: cursor)
    let remainder = value[cursor...]
    return remainder.isEmpty || remainder == "G" || remainder == "GSg" ||
        remainder == "tc" || remainder == "tcSg" ||
        remainder == "c" || remainder == "cSg"
}

private func hasStructuralABITypePrefix(_ value: String) -> Bool {
    value.hasPrefix("So") || value.hasPrefix("_s") || value.hasPrefix("_$s") ||
        value.hasPrefix("$s") || value.hasPrefix("Say") || value.hasPrefix("Shy") ||
        value.hasPrefix("SDy") || value.hasPrefix("ScT") || value.hasPrefix("yp") ||
        value.hasPrefix("y") ||
        (value.first == "s" && value.dropFirst().first?.isNumber == true) ||
        (value.hasPrefix("ss") && value.dropFirst(2).first?.isNumber == true)
}

private func isGenericCloserG(_ value: String, at index: String.Index,
                              tokenStart: String.Index) -> Bool {
    guard index < value.endIndex, value[index] == "G" else { return false }
    if index > tokenStart {
        let previous = value[value.index(before: index)]
        if previous == "C", value.distance(from: tokenStart, to: index) == 1 {
            return false
        }
    }
    let next = value.index(after: index)
    if next == value.endIndex { return true }
    let rest = value[next...]
    if let first = rest.first,
       !first.isLetter && !first.isNumber && first != "." && first != "_" && first != "?" {
        return true
    }
    if rest.hasPrefix("G") || rest.hasPrefix("Sg") || rest.hasPrefix("c") ||
       rest.hasPrefix("t") || rest.hasPrefix("_") || rest.hasPrefix("y") ||
       rest.hasPrefix("So") || rest.hasPrefix("Say") || rest.hasPrefix("Shy") ||
       rest.hasPrefix("SDy") || rest.hasPrefix("yp") || rest.hasPrefix("Si") ||
       rest.hasPrefix("SS") || rest.hasPrefix("Sb") || rest.hasPrefix("ScT") ||
       rest.first?.isUppercase == true {
        return true
    }
    return false
}

private func parseFunctionTypeSubstitution(
    _ value: String, start: String.Index, previousTypes: [String]
) -> (types: [String], end: String.Index)? {
    guard start < value.endIndex, value[start] == "A",
          !previousTypes.isEmpty else { return nil }
    var cursor = value.index(after: start)
    var digits = ""
    while cursor < value.endIndex, value[cursor].isNumber {
        digits.append(value[cursor])
        cursor = value.index(after: cursor)
    }
    guard cursor < value.endIndex, value[cursor].isUppercase,
          let ascii = value[cursor].asciiValue else { return nil }
    let substitutionIndex = Int(ascii - Character("A").asciiValue!)
    let type = previousTypes.indices.contains(substitutionIndex)
        ? previousTypes[substitutionIndex]
        : previousTypes.last!
    let repeatCount = max(1, Int(digits) ?? 1)
    guard repeatCount <= 64 else { return nil }
    return (Array(repeating: type, count: repeatCount),
            value.index(after: cursor))
}

/// ObjC importer identifiers can reuse words from an earlier nominal name.
/// The `So0...C` grammar reconstructs the next nominal from previously
/// decoded identifier words without relying on any framework name.
private func parseObjCWordSubstitutionNominal(
    _ value: String, start: String.Index, previousTypes: [String]
) -> (type: String, end: String.Index)? {
    let suffix = String(value[start...])
    guard suffix.hasPrefix("So0"), suffix.count > 4 else { return nil }
    var cursor = suffix.index(suffix.startIndex, offsetBy: 3)
    let words = previousTypes.flatMap(swiftIdentifierWords)
    var name = ""
    var sawLastReference = false
    while cursor < suffix.endIndex, suffix[cursor].isLetter,
          let ascii = suffix[cursor].asciiValue {
        let isLast = suffix[cursor].isUppercase
        let base = isLast
            ? Character("A").asciiValue!
            : Character("a").asciiValue!
        let wordIndex = Int(ascii - base)
        guard words.indices.contains(wordIndex) else { return nil }
        name += words[wordIndex]
        cursor = suffix.index(after: cursor)
        if isLast {
            sawLastReference = true
            break
        }
    }
    guard sawLastReference else { return nil }
    if cursor < suffix.endIndex, suffix[cursor] == "0" {
        cursor = suffix.index(after: cursor)
    }
    while cursor < suffix.endIndex, suffix[cursor].isNumber {
        guard let part = parseLengthPrefixedName(String(suffix[cursor...])) else {
            return nil
        }
        name += part.name
        cursor = suffix.index(cursor, offsetBy: part.consumed)
    }
    guard cursor < suffix.endIndex, suffix[cursor] == "C" else { return nil }
    cursor = suffix.index(after: cursor)
    if suffix[cursor...].hasPrefix("_p") {
        cursor = suffix.index(cursor, offsetBy: 2)
    }
        let consumed = suffix.distance(from: suffix.startIndex, to: cursor)
    return (name, value.index(start, offsetBy: consumed))
}

private func swiftIdentifierWords(_ value: String) -> [String] {
    let identifier = value.split(separator: ".").last.map(String.init) ?? value
    var words = [String]()
    var current = ""
    let characters = Array(identifier)
    func finish() {
        if !current.isEmpty {
            words.append(current)
            current.removeAll(keepingCapacity: true)
        }
    }
    for (index, character) in characters.enumerated() {
        if character == "_" {
            finish()
            continue
        }
        if character.isUppercase, index > 0,
           characters[index - 1].isLowercase || characters[index - 1].isNumber {
            finish()
        }
        if character.isLetter || character.isNumber { current.append(character) }
    }
    finish()
    return words
}

private func looksLikeSourceFacingNominal(_ value: String) -> Bool {
    guard let first = value.first, first.isLetter || first == "_" else { return false }
    if value.contains(where: \.isNumber) { return false }
    if value.hasPrefix("So") || value.hasPrefix("SD") || value.hasPrefix("Sa") ||
       value.hasPrefix("Sh") || value.hasPrefix("Si") || value.hasPrefix("SS") ||
       value.hasPrefix("Sb") || value.hasPrefix("Sc") {
        return false
    }
    return value.allSatisfy { $0.isLetter || $0 == "." || $0 == "_" }
}

private func parseTupleABIPrefix(_ value: String, start: String.Index,
                                 substitutions: [String] = [])
    -> (type: String, elementTypes: [String], labels: [String],
        labelCount: Int, end: String.Index)? {
    var index = start
    var rendered = [String]()
    var elementTypes = [String]()
    var labels = [String]()
    var labelCount = 0
    var identifiers = SwiftABIIdentifierDecoder()

    while index < value.endIndex {
        if value[index] == "t" {
            guard !rendered.isEmpty else { return nil }
            let end = value.index(after: index)
            let type = rendered.count == 1
                ? rendered[0]
                : "(" + rendered.joined(separator: ", ") + ")"
            return (type, elementTypes, labels, labelCount, end)
        }
        if value[index] == "_" {
            index = value.index(after: index)
            continue
        }

        let knownTypes = elementTypes + substitutions
        if let repeated = parseFunctionTypeSubstitution(
            value, start: index, previousTypes: knownTypes) {
            index = repeated.end
            for (offset, type) in repeated.types.enumerated() {
                var element = type
                if offset == repeated.types.count - 1,
                   index < value.endIndex,
                   let label = identifiers.parse(value, start: index) {
                    element = "\(label.name): \(element)"
                    labels.append(label.name)
                    labelCount += 1
                    index = label.end
                }
                rendered.append(element)
                elementTypes.append(type)
            }
            continue
        }

        let parsed: (type: String, end: String.Index)?
        var nestedLabels = [String]()
        let suffix = value[index...]
        let startsMangledMetadata = suffix.hasPrefix("_s") || suffix.hasPrefix("_$s") ||
            suffix.hasPrefix("$s") ||
            (suffix.first == "s" && suffix.dropFirst().first?.isNumber == true)
        if !elementTypes.isEmpty, startsMangledMetadata,
           let function = parseFunctionABIType(value, start: index,
                                               substitutions: expandedABISubstitutionHistory(
                                                elementTypes) + substitutions),
           function.end < value.endIndex,
           function.end > index {
            parsed = (function.type, function.end)
            nestedLabels = function.labels
        } else if let direct = parseABITypeToken(value, start: index,
                                                 substitutions: knownTypes,
                                                 stopAtTupleLabel: true),
           direct.end > index,
           !(direct.type == "y" || direct.type == "yc") {
            parsed = direct
        } else if !elementTypes.isEmpty,
                  let function = parseFunctionABIType(value, start: index,
                                                      substitutions: expandedABISubstitutionHistory(
                                                       elementTypes) + substitutions),
                  function.end < value.endIndex,
                  function.end > index {
            parsed = (function.type, function.end)
            nestedLabels = function.labels
        } else {
            parsed = nil
        }
        guard let parsed, parsed.end > index else { return nil }
        var element = parsed.type
        elementTypes.append(parsed.type)
        index = parsed.end
        for label in nestedLabels {
            identifiers.register(label)
            labels.append(label)
        }
        if index < value.endIndex,
           let label = identifiers.parse(value, start: index) {
            element = "\(label.name): \(element)"
            labels.append(label.name)
            labelCount += 1
            index = label.end
        }
        rendered.append(element)
    }
    return nil
}

/// Reflection typerefs can embed a compact `Dictionary` before a labeled
/// tuple. The dictionary's closing `G` is followed by a length-prefixed
/// label, so recognize the whole tuple before token-by-token fallback lets
/// the parent parser treat the prefix as a complete field type.
private func parseDictionaryLeadingTupleABI(_ value: String) -> String? {
    guard value.hasPrefix("SDy"),
          let dictionary = parseCompactABIContainerPrefix(value),
          dictionary.consumed < value.count else { return nil }
    let suffix = value.index(value.startIndex, offsetBy: dictionary.consumed)
    let rewritten = sourceDictionaryShorthand(dictionary.type) + value[suffix...]
    let tuple = parseTupleABIPrefix(rewritten, start: rewritten.startIndex,
                                    substitutions: expandedABISubstitutionHistory(
                                        [dictionary.type]))
    guard let tuple, tuple.end == rewritten.endIndex else { return nil }
    return tuple.type
}

private func parseTupleABI(_ value: String) -> String? {
    var body = value
    var optional = false
    if body.hasSuffix("Sg") {
        optional = true
        body.removeLast(2)
    }
    guard body.hasSuffix("t"), body.count > 1, !body.hasPrefix("y"),
          !looksLikeSourceFacingNominal(body) else { return nil }
    if let dictionaryTuple = parseDictionaryLeadingTupleABI(body) {
        return dictionaryTuple + (optional ? "?" : "")
    }
    guard let parsed = parseTupleABIPrefix(body, start: body.startIndex),
          parsed.end == body.endIndex else { return nil }
    // Already-readable nominals can end in `t`.
    // Those are not ABI tuples.
    return parsed.type + (optional ? "?" : "")
}

/// Decode identifier word substitutions used by tuple-element labels.
/// For example, after `totalRepayFee` registers `total`, `Repay`, and `Fee`,
/// `0a4BaseC0` expands to `totalBaseFee`.
private struct SwiftABIIdentifierDecoder {
    private var words = [String]()

    mutating func parse(_ value: String, start: String.Index)
        -> (name: String, end: String.Index)? {
        guard start < value.endIndex, value[start].isNumber else { return nil }
        if value[start] != "0" {
            let tail = String(value[start...])
            guard let parsed = parseLengthPrefixedName(tail) else { return nil }
            let end = value.index(start, offsetBy: parsed.consumed)
            registerWords(in: parsed.name)
            return (parsed.name, end)
        }

        var index = value.index(after: start)
        var result = ""
        var sawPart = false
        var finishAfterLiteral = false
        while index < value.endIndex {
            let character = value[index]
            if character.isNumber {
                var digitsEnd = index
                while digitsEnd < value.endIndex, value[digitsEnd].isNumber {
                    digitsEnd = value.index(after: digitsEnd)
                }
                guard let length = Int(value[index..<digitsEnd]), length > 0,
                      let literalEnd = value.index(digitsEnd, offsetBy: length,
                                                   limitedBy: value.endIndex),
                      value.distance(from: digitsEnd, to: literalEnd) == length else {
                    return nil
                }
                result += value[digitsEnd..<literalEnd]
                index = literalEnd
                sawPart = true
                if finishAfterLiteral { break }
                continue
            }
            guard character.isASCII, character.isLetter,
                  let ascii = character.asciiValue else { break }
            let isLastReference = character.isUppercase
            let base = isLastReference ? Character("A").asciiValue! : Character("a").asciiValue!
            let wordIndex = Int(ascii - base)
            guard words.indices.contains(wordIndex) else { return nil }
            result += words[wordIndex]
            index = value.index(after: index)
            sawPart = true
            if isLastReference {
                if index < value.endIndex, value[index] == "0" {
                    index = value.index(after: index)
                    break
                }
                finishAfterLiteral = true
            }
        }
        guard sawPart, !result.isEmpty else { return nil }
        registerWords(in: result)
        return (result, index)
    }

    mutating func register(_ identifier: String) {
        registerWords(in: identifier)
    }

    private mutating func registerWords(in identifier: String) {
        var current = ""
        let characters = Array(identifier)
        func appendCurrent(_ value: inout [String], _ current: inout String) {
            guard !current.isEmpty else { return }
            if !value.contains(current), value.count < 26 { value.append(current) }
            current.removeAll(keepingCapacity: true)
        }
        for (index, character) in characters.enumerated() {
            if character == "_" {
                appendCurrent(&words, &current)
                continue
            }
            if character.isUppercase, index > 0,
               characters[index - 1].isLowercase || characters[index - 1].isNumber {
                appendCurrent(&words, &current)
            }
            if character.isLetter || character.isNumber { current.append(character) }
        }
        appendCurrent(&words, &current)
    }
}

/// Reconstruct the substitution history contributed by already parsed
/// standard-library containers. Their generic arguments and specialization
/// are each eligible substitution entries in the surrounding mangling.
private func expandedABISubstitutionHistory(_ types: [String]) -> [String] {
    types.flatMap { type in
        let body: String
        if type.hasPrefix("Dictionary<"), type.hasSuffix(">") {
            body = String(type.dropFirst("Dictionary<".count).dropLast())
        } else if type.hasPrefix("["), type.hasSuffix("]"), type.contains(":") {
            body = String(type.dropFirst().dropLast())
        } else {
            return [type]
        }
        guard let separator = topLevelTypeSeparator(in: body) else { return [type] }
        let key = body[..<separator].trimmingCharacters(in: .whitespaces)
        let valueStart = body.index(after: separator)
        let value = body[valueStart...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return [type] }
        return [key, value, type]
    }
}

private func topLevelTypeSeparator(in value: String) -> String.Index? {
    var angleDepth = 0
    var bracketDepth = 0
    var parenDepth = 0
    for index in value.indices {
        switch value[index] {
        case "<": angleDepth += 1
        case ">": angleDepth = max(0, angleDepth - 1)
        case "[": bracketDepth += 1
        case "]": bracketDepth = max(0, bracketDepth - 1)
        case "(": parenDepth += 1
        case ")": parenDepth = max(0, parenDepth - 1)
        case ",", ":":
            if angleDepth == 0 && bracketDepth == 0 && parenDepth == 0 {
                return index
            }
        default: break
        }
    }
    return nil
}

/// Decode the compact standard-library container spellings that occur in
/// field metadata without a leading `$s` nominal reference. For example,
/// `SDySo21SectionCSaySo27CellProtocolC_pGG` is
/// `Dictionary<Section, [CellProtocol]>`.
private func parseCompactABIGenericType(_ value: String) -> String? {
    guard var parsed = parseCompactABIContainerPrefix(value) else { return nil }
    var index = value.index(value.startIndex, offsetBy: parsed.consumed)
    while index < value.endIndex, value[index] == "G" {
        index = value.index(after: index)
    }
    if value[index...].hasPrefix("Sg"), !parsed.type.hasSuffix("?") {
        parsed.type += "?"
    }
    return parsed.type
}

private func parseCompactABIContainerPrefix(_ value: String,
                                            substitutions: [String] = [])
    -> (type: String, consumed: Int)? {
    let kind: String
    let expectedCount: Int
    if value.hasPrefix("SDy") {
        kind = "Dictionary"
        expectedCount = 2
    } else if value.hasPrefix("Say") {
        kind = "Array"
        expectedCount = 1
    } else if value.hasPrefix("Shy") {
        kind = "Set"
        expectedCount = 1
    } else {
        return nil
    }
    if kind == "Array", let tupleArray = parseCompactArrayTuplePrefix(value) {
        return tupleArray
    }
    if kind == "Dictionary",
       let tupleDictionary = parseCompactDictionaryTuplePrefix(value) {
        return tupleDictionary
    }
    var index = value.index(value.startIndex, offsetBy: 3)
    var arguments = [String]()
    while arguments.count < expectedCount {
        while index < value.endIndex, value[index] == "_" {
            index = value.index(after: index)
        }
        while !arguments.isEmpty, arguments.count < expectedCount,
              index < value.endIndex, value[index] == "G" {
            index = value.index(after: index)
        }
        if let repeated = parseStdlibRepeatedSubstitution(value, start: index),
           arguments.count + repeated.types.count <= expectedCount {
            arguments.append(contentsOf: repeated.types)
            index = repeated.end
            continue
        }
        let knownTypes = arguments + substitutions
        if kind == "Dictionary", arguments.count == 1,
           value[index...].hasPrefix("AF") {
            // `AF` is the ABI substitution for the first generic argument in
            // a dictionary value, not two independent type tokens.
            arguments.append(arguments[0])
            index = value.index(index, offsetBy: 2)
            continue
        }
        if kind == "Dictionary", arguments.count == expectedCount - 1,
           index < value.endIndex,
           !value[index...].hasPrefix("yp"),
           let function = parseFunctionABIType(
               value, start: index, substitutions: knownTypes),
           function.end > index {
            arguments.append(function.type)
            index = function.end
            continue
        }
        if let substituted = parseFunctionTypeSubstitution(
            value, start: index, previousTypes: knownTypes),
           arguments.count + substituted.types.count <= expectedCount {
            arguments.append(contentsOf: substituted.types)
            index = substituted.end
            continue
        }
        guard index < value.endIndex,
              let argument = parseABITypeToken(
                value, start: index,
                substitutions: knownTypes,
                allowNominalContainerGSg: false),
              argument.end > index else { break }
        let invalidArgument = ["c", "c?", "t", "G", "G?", "Sg", "y", "yc"]
        guard !invalidArgument.contains(argument.type) else { break }
        arguments.append(argument.type)
        index = argument.end
    }
    var inferredOptional = false
    // Untyped dictionaries are `[AnyHashable: Any]`. Reflection often drops
    // the `yp` value, leaving `SDyAnyHashable`, `SDyAnyHashable?`, or a
    // nested `SDySSSDyAnyHashableG`.
    if kind == "Dictionary", arguments.count == 1,
       isUntypedAnyHashableDictionaryKey(arguments[0]),
       isUntypedAnyHashableDictionaryTerminator(value, at: index) {
        if arguments[0].hasSuffix("?") {
            arguments[0] = String(arguments[0].dropLast())
            inferredOptional = true
        }
        arguments.append("Any")
    }
    if arguments.count == expectedCount,
       index < value.endIndex, value[index] != "G",
       value[index] == "A" || value[index...].hasPrefix("SH") {
        while index < value.endIndex, value[index] != "G" {
            index = value.index(after: index)
        }
    }
    var optional = inferredOptional
    if index < value.endIndex, value[index] == "G" {
        index = value.index(after: index)
        // Reflection containers commonly carry one extra generic-context `G`
        // before Optional (`...CGGSg` / `...GGSg`) or at the end (`...GG`).
        if value[index...].hasPrefix("G") {
            let next = value.index(after: index)
            if next == value.endIndex || value[next...].hasPrefix("Sg") {
                index = next
            }
        }
        if value[index...].hasPrefix("Sg") {
            optional = true
            index = value.index(index, offsetBy: 2)
        }
    } else if arguments.count == expectedCount,
              arguments.first == "AnyHashable", arguments.last == "Any" {
        if index < value.endIndex, value[index] == "?" {
            optional = true
            index = value.index(after: index)
        } else if value[index...].hasPrefix("Sg") {
            optional = true
            index = value.index(index, offsetBy: 2)
        }
    } else if arguments.count == expectedCount,
              let last = arguments.last,
              last.hasPrefix("[") || last.contains("<"),
              index == value.endIndex ||
                (index < value.endIndex && value[index] == "?") {
        if index < value.endIndex, value[index] == "?" {
            optional = true
            index = value.index(after: index)
        }
    } else {
        return nil
    }
    let type: String
    switch kind {
    case "Dictionary":
        type = "Dictionary<\(arguments[0]), \(arguments[1])>"
    case "Array":
        type = "[\(arguments[0])]"
    default:
        type = "Set<\(arguments[0])>"
    }
    return (type + (optional ? "?" : ""),
            value.distance(from: value.startIndex, to: index))
}

private func parseCompactArrayTuplePrefix(_ value: String)
    -> (type: String, consumed: Int)? {
    guard value.hasPrefix("Say") else { return nil }
    let start = value.index(value.startIndex, offsetBy: 3)
    guard let tuple = parseTupleABIPrefix(value, start: start),
          tuple.elementTypes.count >= 2,
          tuple.end < value.endIndex, value[tuple.end] == "G" else { return nil }
    var end = value.index(after: tuple.end)
    var optional = false
    if value[end...].hasPrefix("Sg") {
        optional = true
        end = value.index(end, offsetBy: 2)
    }
    return ("[\(tuple.type)]" + (optional ? "?" : ""),
            value.distance(from: value.startIndex, to: end))
}

/// Dictionary tuple values flatten into the generic argument stream. For
/// example `SDyS2S_[Model]tG` means `[String: (String, [Model])]`: `S2S`
/// supplies both the key and the tuple's first element, and `t` closes only
/// the value tuple before the dictionary's `G`.
private func parseCompactDictionaryTuplePrefix(_ value: String)
    -> (type: String, consumed: Int)? {
    guard value.hasPrefix("SDy"),
          let tupleEnd = value.lastIndex(of: "t"),
          let genericEnd = value.firstIndex(of: "G"),
          tupleEnd < genericEnd,
          value.index(after: tupleEnd) < value.endIndex,
          value[value.index(after: tupleEnd)] == "G" else { return nil }
    var index = value.index(value.startIndex, offsetBy: 3)
    var flattened = [String]()
    while index < value.endIndex, value[index] != "t" {
        if value[index] == "_" {
            index = value.index(after: index)
            continue
        }
        if let repeated = parseStdlibRepeatedSubstitution(value, start: index) {
            flattened.append(contentsOf: repeated.types)
            index = repeated.end
            continue
        }
        guard let parsed = parseABITypeToken(value, start: index),
              parsed.end > index else { return nil }
        flattened.append(parsed.type)
        index = parsed.end
    }
    guard flattened.count >= 3, index < value.endIndex, value[index] == "t" else {
        return nil
    }
    index = value.index(after: index)
    guard index < value.endIndex, value[index] == "G" else { return nil }
    index = value.index(after: index)
    var optional = false
    if value[index...].hasPrefix("Sg") {
        optional = true
        index = value.index(index, offsetBy: 2)
    }
    let key = flattened.removeFirst()
    let tuple = "(" + flattened.joined(separator: ", ") + ")"
    return ("Dictionary<\(key), \(tuple)>" + (optional ? "?" : ""),
            value.distance(from: value.startIndex, to: index))
}

/// Replace nominal type references embedded in ABI function/container strings.
/// Field metadata sometimes stores a complete function type, so the nominal
/// reference is not the whole value passed to the demangler. The scanner only
/// consumes tokens whose length prefixes and nominal terminators are valid;
/// unknown or malformed fragments are left untouched.
private func normalizeNestedSwiftABITokens(_ value: String) -> String {
    let characters = Array(value)
    guard !characters.isEmpty else { return value }
    var output = ""
    var index = 0
    while index < characters.count {
        if let container = parseNestedContainerToken(characters, start: index) {
            output += container.name
            index = container.end
            continue
        }
        if let parsed = parseNestedSwiftABIToken(characters, start: index) {
            output += parsed.name
            index = parsed.end
        } else {
            output.append(characters[index])
            index += 1
        }
    }
    return output
}

private func parseNestedContainerToken(_ characters: [Character], start: Int)
    -> (name: String, end: Int)? {
    guard start + 3 < characters.count,
          characters[start] == "S",
          (characters[start + 1] == "a" || characters[start + 1] == "h"),
          characters[start + 2] == "y" else { return nil }
    let isSet = characters[start + 1] == "h"
    let remaining = String(characters[(start + 3)...])
    let element: String
    let consumed: Int
    if remaining.hasPrefix("qd__") {
        // Dependent generic parameters can appear as array elements inside a
        // larger closure/container type without the full `...XX` signature.
        // Their source name is unavailable, so use the same stable placeholder
        // as generic capture records.
        element = "A"
        consumed = 4
    } else if let nominal = parseSwiftNominalTokenWithEnd(remaining) {
        element = nominal.name
        consumed = nominal.end.utf16Offset(in: remaining)
    } else if remaining.hasPrefix("So"),
              let length = parseLengthPrefixedName(String(remaining.dropFirst(2))) {
        // Protocol existential array elements may omit the nominal `C`
        // marker and use `So<N>Name_pG` directly.
        let markerStart = remaining.index(remaining.startIndex,
                                          offsetBy: 2 + length.consumed)
        guard remaining[markerStart...].hasPrefix("_p") else { return nil }
        element = length.name
        consumed = 2 + length.consumed
    } else if let nested = parseNestedSwiftABIToken(Array(remaining), start: 0) {
        element = nested.name
        consumed = nested.end
    } else {
        return nil
    }
    var elementConsumed = consumed
    // Protocol existentials carry the `_p` suffix after the nominal `C`
    // marker (for example `SaySo18HandlerProtocolC_pG`). It belongs to the
    // element token and must be consumed before the array's closing `G`.
    if elementConsumed + 1 < remaining.count,
       remaining[remaining.index(remaining.startIndex, offsetBy: elementConsumed)] == "_",
       remaining[remaining.index(remaining.startIndex, offsetBy: elementConsumed + 1)] == "p" {
        elementConsumed += 2
    }
    guard elementConsumed < remaining.count,
          remaining[remaining.index(remaining.startIndex, offsetBy: elementConsumed)] == "G" else {
        return nil
    }
    var end = start + 3 + elementConsumed + 1
    // Reflection array spellings commonly carry an additional `G` for the
    // nominal context (`...CGG`) before Optional's `Sg` suffix.
    if end < characters.count, characters[end] == "G" {
        end += 1
    }
    var optional = false
    if end + 1 < characters.count,
       characters[end] == "S", characters[end + 1] == "g" {
        optional = true
        end += 2
    }
    let type = isSet ? "Set<\(element)>" : "[\(element)]"
    return (type + (optional ? "?" : ""), end)
}

private func parseNestedSwiftABIToken(_ characters: [Character], start: Int)
    -> (name: String, end: Int)? {
    let cursorStart: Int
    if start + 2 < characters.count,
       characters[start] == "_", characters[start + 1] == "$", characters[start + 2] == "s" {
        cursorStart = start + 3
    } else if start + 1 < characters.count,
              characters[start] == "_", characters[start + 1] == "s" {
        cursorStart = start + 2
    } else if start + 1 < characters.count,
              characters[start] == "$", characters[start + 1] == "s" {
        cursorStart = start + 2
    } else if characters[start] == "s" {
        cursorStart = start + 1
    } else {
        return nil
    }
    var cursor = cursorStart
    var contextPrefix = ""
    if cursor + 1 < characters.count,
       characters[cursor] == "S", characters[cursor + 1] == "S" {
        contextPrefix = "String."
        cursor += 2
    }

    let nominalName: String
    if cursor < characters.count, characters[cursor] == "s" {
        cursor += 1
        guard let direct = parseNestedLengthName(characters, start: cursor) else { return nil }
        nominalName = contextPrefix + direct.name
        cursor = direct.end
    } else if let direct = parseNestedLengthName(characters, start: cursor),
              direct.end < characters.count,
              characters[direct.end] == "C" || characters[direct.end] == "V" ||
              characters[direct.end] == "O" || characters[direct.end] == "P" {
        // Stdlib nominal without a module, e.g. `s11AnyHashableV`.
        nominalName = contextPrefix + direct.name
        cursor = direct.end
    } else {
        guard let module = parseNestedLengthName(characters, start: cursor) else { return nil }
        cursor = module.end
        var usesModuleSubstitution = false
        if cursor + 1 < characters.count,
           characters[cursor] == "0", characters[cursor + 1] == "A" {
            usesModuleSubstitution = true
            cursor += 2
        }
        if cursor < characters.count, characters[cursor] == "E" { cursor += 1 }
        guard let type = parseNestedLengthName(characters, start: cursor) else { return nil }
        cursor = type.end
        let modulePrefix = module.name.hasSuffix("Kit")
            ? String(module.name.dropLast(3))
            : module.name
        let baseName: String
        if usesModuleSubstitution {
            baseName = modulePrefix + type.name
        } else {
            baseName = type.name
        }
        nominalName = contextPrefix + baseName
    }

    // A nominal type is followed by C/V (class/struct), usually with Mn. The
    // generic argument list, when present, follows Mn as y...G.
    // Protocol descriptors use `Mp` instead of the nominal `C/V/O` marker.
    // The following `_p` is the existential marker and is part of this type,
    // rather than a separator for the surrounding container/function.
    if cursor + 1 < characters.count,
       characters[cursor] == "M", characters[cursor + 1] == "p" {
        cursor += 2
        if cursor + 1 < characters.count,
           characters[cursor] == "_", characters[cursor + 1] == "p" {
            cursor += 2
        }
        var name = nominalName
        if cursor + 1 < characters.count,
           characters[cursor] == "S", characters[cursor + 1] == "g" {
            name += "?"
            cursor += 2
        }
        return (name, cursor)
    }
    guard cursor < characters.count,
          characters[cursor] == "C" || characters[cursor] == "V" ||
          characters[cursor] == "O" else { return nil }
    cursor += 1
    if cursor + 1 < characters.count,
       characters[cursor] == "_", characters[cursor + 1] == "p" {
        cursor += 2
    }
    if cursor < characters.count, characters[cursor] == "M" {
        cursor += 1
        if cursor < characters.count, characters[cursor] == "n" { cursor += 1 }
    }

    var name = nominalName
    if cursor < characters.count, characters[cursor] == "y",
       !(cursor + 1 < characters.count && characters[cursor + 1] == "p"),
       let genericEnd = nestedGenericEnd(characters, start: cursor + 1)
            ?? characters.lastIndex(of: "G"),
       genericEnd > cursor {
        let argument = String(characters[(cursor + 1)..<genericEnd])
        let normalizedArguments = parseABITypeArguments(argument)
        if !normalizedArguments.isEmpty {
            name += "<" + normalizedArguments.joined(separator: ", ") + ">"
        }
        cursor = genericEnd + 1
    }
    // In a one-argument closure (`yy...VMncSg`), `c` terminates the function
    // immediately after the nominal argument. It is part of the surrounding
    // function syntax rather than the recovered type name.
    if cursor + 2 < characters.count,
       characters[cursor] == "c", characters[cursor + 1] == "S",
       characters[cursor + 2] == "g" {
        cursor += 1
    }
    if cursor + 1 < characters.count,
       characters[cursor] == "S", characters[cursor + 1] == "g" {
        name += "?"
        cursor += 2
    }
    return (name, cursor)
}

private func parseNestedLengthName(_ characters: [Character], start: Int)
    -> (name: String, end: Int)? {
    guard start < characters.count else { return nil }
    var cursor = start
    while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
    guard cursor > start,
          let length = Int(String(characters[start..<cursor])), length > 0,
          cursor + length <= characters.count else { return nil }
    return (String(characters[cursor..<(cursor + length)]), cursor + length)
}

private func parseFirstABITypeName(_ value: String) -> String? {
    let characters = Array(value)
    if let parsed = parseNestedSwiftABIToken(characters, start: 0) {
        return parsed.name
    }
    if let parsed = parseSwiftNominalTokenWithEnd(value) {
        return parsed.name
    }
    return normalizeKnownSwiftABIType(value) == value ? nil : normalizeKnownSwiftABIType(value)
}

private func nestedGenericEnd(_ characters: [Character], start: Int) -> Int? {
    var cursor = start
    var depth = 0
    while cursor < characters.count {
        switch characters[cursor] {
        case "y":
            // `yp` is the standard substitution for `Any`, not the start of
            // a nested generic argument list.
            if cursor + 1 >= characters.count || characters[cursor + 1] != "p" {
                depth += 1
            }
        case "G":
            if depth == 0 { return cursor }
            depth -= 1
        default: break
        }
        cursor += 1
    }
    return nil
}

private func parseSwiftNominalToken(_ value: String) -> String? {
    parseSwiftNominalTokenWithEnd(value)?.name
}

/// Parse the compact length-prefixed form used for Swift nominal references.
/// This handles both a standard-library spelling such as
/// `ss15ContiguousArrayVMny...` and a module-qualified spelling such as
/// `s8Dispatch0A8WorkItemCMnSg`, without naming either module or type.
private func parseSwiftABIGenericType(_ value: String) -> String? {
    var body = value
    if body.hasPrefix("_$s") { body.removeFirst() }
    if body.hasPrefix("s") { body = "$" + body }
    guard body.hasPrefix("$s") || body.hasPrefix("_s") else { return nil }
    if body.hasPrefix("_s") { body = "$" + String(body.dropFirst()) }
    guard body.hasPrefix("$s") else { return nil }
    body.removeFirst(2)

    // `SS` is the standard substitution for Swift.String in an extension
    // context, as in String.Encoding's Foundation mangling.
    var contextPrefix = ""
    if body.hasPrefix("SS") {
        contextPrefix = "String."
        body.removeFirst(2)
    }

    // `s<N><Name>` is the standard-library module substitution form.
    if body.first == "s", let direct = parseLengthPrefixedName(String(body.dropFirst())) {
        let tail = String(body.dropFirst(1 + direct.consumed))
        if let generic = parseGenericNominalTail(name: contextPrefix + direct.name, tail: tail) {
            return generic
        }
    }

    guard let module = parseLengthPrefixedName(body) else { return nil }
    var tail = String(body.dropFirst(module.consumed))
    // The `0A` substitution denotes the enclosing module in current Swift
    // ABI output; the following length-prefixed name is the nominal type.
    let usesModuleSubstitution = tail.hasPrefix("0A")
    if usesModuleSubstitution { tail.removeFirst(2) }
    if tail.hasPrefix("E") { tail.removeFirst() }
    if usesModuleSubstitution, tail.hasPrefix("0C") {
        let typeName = module.name.hasSuffix("Kit")
            ? String(module.name.dropLast(3))
            : module.name
        let typeTail = String(tail.dropFirst(2))
        return parseGenericNominalTail(name: contextPrefix + module.name + "." + typeName,
                                       tail: "C" + typeTail)
    }
    guard let type = parseLengthPrefixedName(tail) else { return nil }
    let typeTail = String(tail.dropFirst(type.consumed))
    let nominalName: String
    if usesModuleSubstitution {
        let modulePrefix = module.name.hasSuffix("Kit")
            ? String(module.name.dropLast(3))
            : module.name
        nominalName = modulePrefix + type.name
    } else if typeTailHasGeneric(typeTail) {
        nominalName = module.name + "." + type.name
    } else {
        nominalName = type.name
    }
    let parsed = parseGenericNominalTail(name: contextPrefix + nominalName, tail: typeTail)
    return parsed
}

private func parseGenericNominalTail(name: String, tail: String) -> String? {
    if (tail.hasPrefix("C") || tail.hasPrefix("O") || tail.hasPrefix("V")) &&
        !tail.contains("y") {
        return name + (tail.contains("Sg") ? "?" : "")
    }
    guard tail.contains("y") else { return nil }
    guard let start = tail.firstIndex(of: "y"), let end = tail.lastIndex(of: "G"), start < end else {
        return nil
    }
    let args = String(tail[tail.index(after: start)..<end])
    let elements = parseABITypeArguments(args)
    guard !elements.isEmpty else { return nil }
    let optional = tail[end...].contains("Sg")
    return "\(name)<\(elements.joined(separator: ", "))>" + (optional ? "?" : "")
}

/// Parse the concatenated type sequence inside a Swift generic argument list.
/// Uppercase substitutions (A, B, ...) repeat previously parsed arguments;
/// suffixes containing digits or lowercase ABI markers belong to the
/// surrounding nominal signature and are deliberately left out.
private func parseABITypeArguments(_ value: String) -> [String] {
    let characters = Array(value)
    var arguments: [String] = []
    var index = 0
    while index < characters.count {
        if characters[index] == "G" || characters[index] == "t" {
            index += 1
            continue
        }
        if characters[index] == "_", index + 1 < characters.count,
           characters[index + 1] != "s", characters[index + 1] != "$" {
            index += 1
            continue
        }
        let character = characters[index]
        let knownTypes: [(token: String, type: String)] = [
            ("Si", "Int"), ("SS", "String"), ("Sb", "Bool"), ("sb", "Bool"),
            ("Sd", "Double"), ("Sf", "Float"), ("Su", "UInt"),
            ("SO", "ObjectIdentifier"), ("yp", "Any")
        ]
        let remainingValue = String(characters[index...])
        if let repeated = parseStdlibRepeatedSubstitution(
            remainingValue, start: remainingValue.startIndex) {
            arguments.append(contentsOf: repeated.types)
            index += remainingValue.distance(from: remainingValue.startIndex, to: repeated.end)
            continue
        }
        if let known = knownTypes.first(where: { remainingValue.hasPrefix($0.token) }) {
            arguments.append(known.type)
            index += known.token.count
            continue
        }
        if !hasStructuralABITypePrefix(remainingValue),
           !isABISubstitutionSuffix(remainingValue),
           let readable = parsePlainABITypeToken(remainingValue,
                                                 start: remainingValue.startIndex) {
            arguments.append(readable.type)
            index += remainingValue.distance(from: remainingValue.startIndex,
                                             to: readable.end)
            continue
        }
        if character == "S", index + 1 < characters.count,
           characters[index + 1] == "S" {
            arguments.append("String")
            index += 2
            continue
        }
        let startsSubstitution = character >= "A" && character <= "Z" &&
            (index + 1 == characters.count ||
             (characters[index + 1] >= "A" && characters[index + 1] <= "Z"))
        if startsSubstitution {
            var runEnd = index
            while runEnd < characters.count,
                  characters[runEnd] >= "A", characters[runEnd] <= "Z" {
                runEnd += 1
            }
            let substitutions = characters[index..<runEnd]
            if runEnd < characters.count, characters[runEnd] == "y" {
                // SwiftUI result-builder manglings may prefix a nested type
                // with context substitutions such as `AAy`/`ABy`.
                index = runEnd + 1
                continue
            }
            let desiredCount = max(arguments.count, substitutions.count)
            for substitutionCharacter in substitutions where arguments.count < desiredCount {
                let substitution = Int(substitutionCharacter.asciiValue ?? 0) -
                    Int(Character("A").asciiValue ?? 0)
                guard substitution >= 0, substitution < arguments.count else { break }
                arguments.append(arguments[substitution])
            }
            index = runEnd
            continue
        }
        let remaining = Array(characters[index...])
        if let container = parseNestedContainerToken(remaining, start: 0) {
            arguments.append(container.name)
            index += container.end
            continue
        }
        if let parsed = parseNestedSwiftABIToken(remaining, start: 0) {
            arguments.append(parsed.name)
            index += parsed.end
            continue
        }
        let remainingString = String(remaining)
        if let compact = parseCompactABIContainerPrefix(remainingString) {
            arguments.append(compact.type)
            index += compact.consumed
            continue
        }
        if remainingString.hasPrefix("y"),
           let function = parseFunctionABIType(
               remainingString, start: remainingString.startIndex,
               substitutions: arguments) {
            arguments.append(function.type)
            index += remainingString.distance(
                from: remainingString.startIndex, to: function.end)
            continue
        }
        if let associated = parseDependentAssociatedType(remainingString) {
            arguments.append(associated)
            break
        }
        if let parsed = parseSwiftNominalTokenWithEnd(remainingString) {
            arguments.append(parsed.name)
            index += parsed.end.utf16Offset(in: remainingString)
            continue
        }
        break
    }
    return arguments
}

/// Decode dependent associated types retained in reflection metadata.
/// `Qz`/`QZ` refer to generic parameter zero (`A`), while `Qy_` uses INDEX
/// `_` and therefore refers to parameter one (`B`). Source parameter names
/// are not retained here, so stable A/B placeholders avoid business guesses.
private func parseDependentAssociatedType(_ value: String) -> String? {
    guard let associated = parseLengthPrefixedName(value),
          !associated.name.isEmpty else { return nil }
    let suffix = String(value.dropFirst(associated.consumed))
    let parameterIndex: Int
    let markerEnd: String.Index
    if let marker = suffix.range(of: "Qz") ?? suffix.range(of: "QZ") {
        parameterIndex = 0
        markerEnd = marker.upperBound
    } else if let marker = suffix.range(of: "Qy") {
        var cursor = marker.upperBound
        if cursor < suffix.endIndex, suffix[cursor] == "_" {
            parameterIndex = 1
            cursor = suffix.index(after: cursor)
        } else {
            var digits = ""
            while cursor < suffix.endIndex, suffix[cursor].isNumber {
                digits.append(suffix[cursor])
                cursor = suffix.index(after: cursor)
            }
            guard cursor < suffix.endIndex, suffix[cursor] == "_",
                  let encoded = Int(digits) else { return nil }
            parameterIndex = encoded + 2
            cursor = suffix.index(after: cursor)
        }
        markerEnd = cursor
    } else {
        return nil
    }
    guard parameterIndex < 26 else { return nil }
    let parameter = String(UnicodeScalar(65 + parameterIndex)!)
    let optional = suffix[markerEnd...].hasPrefix("Sg")
    return "\(parameter).\(associated.name)" + (optional ? "?" : "")
}

private func typeTailHasGeneric(_ tail: String) -> Bool {
    tail.contains("y") && tail.contains("G")
}

private func parseLengthPrefixedName(_ value: String) -> (name: String, consumed: Int)? {
    var index = value.startIndex
    while index < value.endIndex, value[index].isNumber {
        index = value.index(after: index)
    }
    guard index > value.startIndex,
          let length = Int(value[value.startIndex..<index]), length > 0,
          let end = value.index(index, offsetBy: length, limitedBy: value.endIndex),
          value.distance(from: index, to: end) == length else { return nil }
    return (String(value[index..<end]), value.distance(from: value.startIndex, to: end))
}

private func parseSwiftNominalTokenWithEnd(_ value: String) -> (name: String, end: String.Index)? {
    guard value.hasPrefix("So") else { return nil }
    let digitsStart = value.index(value.startIndex, offsetBy: 2)
    var cursor = digitsStart
    while cursor < value.endIndex, value[cursor].isNumber {
        cursor = value.index(after: cursor)
    }
    // `0A` is the enclosing-module substitution emitted in compact
    // reflection names (`So0A12TypeC`). It is syntax, not part of the length.
    if value[digitsStart..<cursor] == "0",
       value[cursor...].hasPrefix("A") {
        cursor = value.index(after: cursor)
        while cursor < value.endIndex, value[cursor].isNumber {
            cursor = value.index(after: cursor)
        }
    }
    let lengthDigitsStart = value[digitsStart..<cursor].hasPrefix("0A")
        ? value.index(digitsStart, offsetBy: 2) : digitsStart
    guard cursor > lengthDigitsStart,
          let length = Int(value[lengthDigitsStart..<cursor]), length > 0 else { return nil }
    let nameStart = cursor
    let nameEnd = value.index(nameStart, offsetBy: length, limitedBy: value.endIndex) ?? value.endIndex
    guard value.distance(from: nameStart, to: nameEnd) == length else { return nil }
    let name = String(value[nameStart..<nameEnd])
    guard value[nameEnd...].hasPrefix("C") else { return nil }
    return (name, value.index(after: nameEnd))
}

private func replaceGenericTokens(_ value: String, names: [String]) -> String {
    var result = ""
    let chars = Array(value)
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

struct FieldDescriptor {
    let fieldDescriptor: DataStruct
    let mangledTypeName: SwiftName
    let superclass: DataStruct
    let kind: FieldDescriptorKind
    let fieldRecordSize: DataStruct
    let numFields: DataStruct
    let fieldRecords: [FieldRecord]
    
    static func FD(_ binary: Data, offset: Int) -> FieldDescriptor {
        let fieldDescriptor = DataStruct.data(binary, offset: offset, length: 4)
        let newOffset = MachOData.shared.resolveRelativePointer(base: offset, raw: fieldDescriptor.value) ?? binary.count
        
        let mangledTypeName = SwiftName.SN(binary, offset: newOffset, isMangledName: false, isClassName: false)
        let superclass = DataStruct.data(binary, offset: newOffset+4, length: 4)
        let kind = FieldDescriptorKind.FDK(binary, offset: newOffset+8)
        let fieldRecordSize = DataStruct.data(binary, offset: newOffset+10, length: 2)
        let numFields = DataStruct.data(binary, offset: newOffset+12, length: 4)
        var fieldRecords = [FieldRecord]()
        
        let recordSize = fieldRecordSize.value.int16()
        let fieldCount = numFields.value.int16()
        // A field record currently contains three 32-bit words. Reject
        // corrupt descriptors instead of trusting attacker-controlled sizes.
        if newOffset >= 0, newOffset <= binary.count - 16,
           recordSize >= 12, recordSize <= 4096, fieldCount >= 0,
           fieldCount <= (binary.count - min(max(newOffset + 16, 0), binary.count)) / recordSize {
            var fieldStart = newOffset+16
            for _ in 0..<fieldCount {
                fieldRecords.append(FieldRecord.FR(binary, offset: fieldStart))
                fieldStart += recordSize
            }
        }
        
        return FieldDescriptor(fieldDescriptor: fieldDescriptor, mangledTypeName: mangledTypeName, superclass: superclass, kind: kind, fieldRecordSize: fieldRecordSize, numFields: numFields, fieldRecords: fieldRecords)
    }
}
