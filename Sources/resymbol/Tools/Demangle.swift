//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/23.
//

import Foundation


import Darwin

private let demangleCacheLock = NSLock()
private var demangleCache = [String: String]()

@_silgen_name("swift_demangle")
public func _stdlib_demangleImpl(
    mangledName: UnsafePointer<CChar>?,
    mangledNameLength: UInt,
    outputBuffer: UnsafeMutablePointer<CChar>?,
    outputBufferSize: UnsafeMutablePointer<UInt>?,
    flags: UInt32
) -> UnsafeMutablePointer<CChar>?

internal func _stdlib_demangleName(_ mangledName: String) -> String {
    demangleCacheLock.lock()
    if let cached = demangleCache[mangledName] {
        demangleCacheLock.unlock()
        return cached
    }
    demangleCacheLock.unlock()
    guard mangledName.utf8.count <= 4096 else { return mangledName }
    let result: String = mangledName.utf8CString.withUnsafeBufferPointer {
        mangledNameUTF8CStr in

        let demangledNamePtr = _stdlib_demangleImpl(
            mangledName: mangledNameUTF8CStr.baseAddress,
            mangledNameLength: UInt(mangledNameUTF8CStr.count - 1),
            outputBuffer: nil,
            outputBufferSize: nil,
            flags: 0
        )

        if let demangledNamePtr = demangledNamePtr {
            let demangledName = String(cString: demangledNamePtr)
            free(demangledNamePtr)
            return demangledName
        }
        return mangledName
    }
    demangleCacheLock.lock()
    demangleCache[mangledName] = result
    demangleCacheLock.unlock()
    return result
}


func swift_demangle(_ mangled: String) -> String? {
    let result = _stdlib_demangleName(mangled).replacingOccurrences(of: "$s", with: "").replacingOccurrences(of: "__C.", with: "")
    if result.contains("for "), let s = result.components(separatedBy: "for ").last {
        return s
    }
    return fixOptionalTypeName(result)
}


func canDemangleFromRuntime(_ instr: String) -> Bool {
    return instr.hasPrefix("So") || instr.hasPrefix("$So") || instr.hasPrefix("_$So") || instr.hasPrefix("_T")
}

func runtimeGetDemangledName(_ instr: String) -> String {
    var str: String = instr
    if (instr.hasPrefix("$s")) {
        str = instr
    } else if (instr.hasPrefix("So")) {
        str = "$s" + instr
    } else if (instr.hasPrefix("_T")) {
        //
    } else {
        return instr
    }
    
    if let s = swift_demangle(str) {
        return s
    }
    return instr
}

func getTypeFromMangledName(_ str: String) -> String {
    if str.hasSuffix("0x") {
        return str
    }

    // Swift metadata commonly stores type references without the `$` marker
    // and may retain one ABI underscore (`_s...`). Normalize those spellings
    // before asking swift_demangle; prepending `$s` to `_s...` would produce
    // the invalid `$s_s...` form and leak the mangled bytes into output.
    var normalized = str
    if normalized.hasPrefix("_$s") {
        normalized.removeFirst()
    } else if normalized.hasPrefix("_s") {
        normalized = "$" + String(normalized.dropFirst())
    } else if normalized.hasPrefix("s") {
        normalized = "$" + normalized
    }
    if let nominal = partialNominalMetadataTypeName(normalized) {
        return nominal
    }
    if normalized.hasPrefix("$s"), let demangled = strictSwiftDemangle(normalized) {
        return demangled
    }

    if canDemangleFromRuntime(normalized) {
        return runtimeGetDemangledName(normalized)
    }
    //check is ascii string
    if (!str.isAsciiStr()) {
        return str
    }

    // Swift's Objective-C protocol/class references use So<length><name>C.
    // Some SDK/runtime combinations reject the `$sSo...` spelling; recover
    // the readable name directly instead of leaking the mangled token.
    if normalized.hasPrefix("So"), normalized.hasSuffix("C") {
        let body = String(normalized.dropFirst(2).dropLast())
        var digits = ""
        for ch in body where ch.isNumber { digits.append(ch) }
        if let length = Int(digits), length > 0 {
            let nameStart = body.index(body.startIndex, offsetBy: digits.count)
            let name = String(body[nameStart...])
            if name.count >= length { return String(name.prefix(length)) }
        }
    }
    
    // Never ask the Swift runtime to instantiate metadata from bytes read from
    // an arbitrary Mach-O. Invalid or context-dependent names can crash inside
    // swift_getTypeName. swift_demangle is a parser and safely reports failure.
    let candidates = normalized.hasPrefix("$s") || normalized.hasPrefix("_T")
        ? [normalized]
        : ["$s" + normalized, normalized]
    for candidate in candidates {
        let demangled = _stdlib_demangleName(candidate)
        if demangled != candidate {
            return fixOptionalTypeName(demangled
                .replacingOccurrences(of: "__C.", with: ""))
        }
    }
    return str
}

/// Decode partial nominal metadata references that the runtime demangler does
/// not accept. Both module and type identifiers come from their ABI length
/// prefixes; no framework or application type names are assumed.
private func partialNominalMetadataTypeName(_ value: String) -> String? {
    guard value.hasPrefix("$s") else { return nil }
    let body = String(value.dropFirst(2))

    func identifier(_ text: String, at start: String.Index)
        -> (name: String, end: String.Index)? {
        var cursor = start
        while cursor < text.endIndex, text[cursor].isNumber {
            cursor = text.index(after: cursor)
        }
        guard cursor > start, let length = Int(text[start..<cursor]), length > 0,
              let end = text.index(cursor, offsetBy: length, limitedBy: text.endIndex),
              text.distance(from: cursor, to: end) == length else { return nil }
        return (String(text[cursor..<end]), end)
    }

    guard let module = identifier(body, at: body.startIndex), !module.name.isEmpty,
          let type = identifier(body, at: module.end), type.end < body.endIndex,
          body[type.end] == "C" || body[type.end] == "V" || body[type.end] == "O" else {
        return nil
    }
    var cursor = body.index(after: type.end)
    guard body[cursor...].hasPrefix("Mn") else { return nil }
    cursor = body.index(cursor, offsetBy: 2)
    var result = type.name
    if body[cursor...].hasPrefix("Sg") {
        result += "?"
        cursor = body.index(cursor, offsetBy: 2)
    }
    guard cursor == body.endIndex else { return nil }
    return result
}

/// Unlike `swift_demangle`, this helper distinguishes a successful demangle
/// from the runtime's unchanged fallback string. The public wrapper strips the
/// `$s` prefix for readability, so comparing its result with the input is not
/// sufficient to detect failure.
func strictSwiftDemangle(_ candidate: String) -> String? {
    let raw = _stdlib_demangleName(candidate)
    guard raw != candidate else { return nil }
    return fixOptionalTypeName(raw
        .replacingOccurrences(of: "$s", with: "")
        .replacingOccurrences(of: "__C.", with: ""))
}



func fixOptionalTypeName(_ typeName: String) -> String {
    var result = typeName
    // Demangled Optional can be nested inside another generic, for example
    // `Dictionary<Int, Optional<String>>`. Only remove the balanced
    // `Optional<...>` wrapper; deleting the first `<`/last `>` corrupts the
    // enclosing generic spelling.
    while let optionalStart = result.range(of: "Swift.Optional<") ??
            result.range(of: "Optional<") {
        let open = result.index(before: optionalStart.upperBound)
        var depth = 0
        var cursor = open
        var close: String.Index?
        while cursor < result.endIndex {
            if result[cursor] == "<" {
                depth += 1
            } else if result[cursor] == ">" {
                depth -= 1
                if depth == 0 {
                    close = cursor
                    break
                }
            }
            cursor = result.index(after: cursor)
        }
        guard let close else { break }
        let innerStart = result.index(after: open)
        let inner = String(result[innerStart..<close])
        let replacement = inner + "?"
        result.replaceSubrange(optionalStart.lowerBound...close, with: replacement)
    }
    return result
}

func fixMangledTypeName(_ dataStruct: DataStruct) -> String {
    if !dataStruct.value.contains("0x") {
        return dataStruct.value
    }
    // Reuse one binary snapshot for the complete fixup walk. The old code
    // fetched MachOData.shared.binary for every marker and range check,
    // paying a concurrent-queue synchronization cost repeatedly per field.
    let binary = MachOData.shared.binary
    let resolver = MachOData.shared.addressResolver()
    let hexName: String = dataStruct.value.removingPrefix("0x")
    let data = hexName.hexData
    let startAddress = dataStruct.address.int16()
    guard data.count >= 4 else { return dataStruct.value }
    
    var mangledName: String = ""
    var i: Int = 0
    // SwiftUI result-builder types can contain deeply nested generic
    // arguments and routinely exceed 256 characters. Keep a generous output
    // bound while the input byte buffer remains the authoritative loop limit.
    let maxOutputLength = 2048
    
    while i < data.count, mangledName.utf8.count < maxOutputLength {
        let val = data[i]
        if (val == 0x01) {
            //find
            let fromIdx: Int = i + 1 // ignore 0x01
            let toIdx: Int = i + 5 // 4 bytes
            guard toIdx <= data.count else { return dataStruct.value }
            let subData = data[fromIdx..<toIdx]
            let fieldOffset = startAddress.addingReportingOverflow(fromIdx).overflow ? -1 : startAddress + fromIdx
            let resolvedAddress: Int?
            if let resolver {
                resolvedAddress = resolver.resolveRelativePointer(fieldOffset: fieldOffset,
                                                                  rawHex: subData.rawValueBig())
            } else {
                resolvedAddress = MachOData.shared.resolveRelativePointer(base: fieldOffset,
                                                                           raw: subData.rawValueBig())
            }
            let address = resolvedAddress ?? -1
            guard address >= 0, address < binary.count else {
                i += 5
                continue
            }
            var result = ""
            if let s = MachOData.shared.mangledNameMap[dataStruct.value] {
                result = s
            } else if let s = MachOData.shared.nominalOffsetMap[address] {
                result = s
            } else if let s = MachOData.shared.dylbMap[String(address, radix: 16, uppercase: false)] {
                result = s
            } else if let s = MachOData.shared.swiftProtocols[address] {
                result = s
            } else if let range = MachOData.shared.swiftTypeRefRange,
                      range.contains(address),
                      address < binary.count {
                result = DataStruct.textSwiftData(binary, offset: address,
                                                  isMangledName: true, isClassName: false).value
            } else if let range = MachOData.shared.swiftReflectionStringRange,
                      range.contains(address),
                      address < binary.count {
                result = DataStruct.textData(binary, offset: address,
                                              demangle: true).value
            }
            if (i == 0 && toIdx >= data.count) {
            mangledName = String((mangledName + result).prefix(maxOutputLength)) // use original result
            } else {
                let fixName = makeDemangledTypeName(result, header: "")
                mangledName = String((mangledName + fixName).prefix(maxOutputLength))
            }
            i += 5
        } else if (val == 0x02) {
            //indirectly
            let fromIdx: Int = i + 1 // ignore 0x02
            let toIdx: Int = i + 5 // 4-byte relative offset
            guard toIdx <= data.count else { return dataStruct.value }
            let subData = data[fromIdx..<toIdx]
            let fieldOffset = startAddress.addingReportingOverflow(fromIdx).overflow ? -1 : startAddress + fromIdx
            // Chained-fixup imports retain their symbol name in the fixup
            // slot. Resolve that name before interpreting the slot contents
            // as another relative pointer; arm64e authenticated imports do
            // not reliably decode as plain 32-bit offsets.
            let pointerOffset: Int?
            if let resolver {
                pointerOffset = resolver.resolveRelativePointer(fieldOffset: fieldOffset,
                                                                  rawHex: subData.rawValueBig())
            } else {
                pointerOffset = MachOData.shared.resolveRelativePointer(base: fieldOffset,
                                                                          raw: subData.rawValueBig())
            }
            let boundName = pointerOffset.flatMap { boundSymbolName(atFileOffset: $0, resolver: resolver) }
            let newDataStruct = pointerOffset.map { DataStruct.data(binary, offset: $0, length: 4) }
            let resolvedIndirectTarget: Int?
            if boundName != nil {
                resolvedIndirectTarget = nil
            } else if let pointerOffset {
                // Marker 0x02 denotes an indirect reference. The slot is a
                // pointer-sized value, commonly an arm64e-authenticated VM
                // address. Resolve it before trying legacy 32-bit forms.
                if let resolver, pointerOffset <= binary.count - 8 {
                    let rawPointer = binary[pointerOffset..<pointerOffset + 8].enumerated()
                        .reduce(UInt64(0)) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
                    resolvedIndirectTarget = resolver.resolveAbsolutePointer(
                        rawPointer, format: .arm64eAuthenticated)
                        ?? resolver.resolveRelativePointer(
                            fieldOffset: pointerOffset,
                            raw: UInt32(newDataStruct?.value ?? "00000000", radix: 16) ?? 0)
                } else {
                    resolvedIndirectTarget = pointerOffset
                }
            } else {
                resolvedIndirectTarget = nil
            }
            let indirectTarget = resolvedIndirectTarget ?? -1
            var result = ""
            if let boundName {
                // Chained imports may omit the ABI marker when spliced into a
                // typeref; normalize the symbol prefix before demangling.
                result = boundName.hasPrefix("_$s")
                    ? "_" + String(boundName.dropFirst(2))
                    : boundName.hasPrefix("$s")
                        ? "_" + String(boundName.dropFirst(1))
                        : boundName
            } else if let s = MachOData.shared.mangledNameMap[dataStruct.value] {
                result = s
            } else if let s = MachOData.shared.objcClassMetadataNames[indirectTarget] {
                // Hybrid Swift/ObjC metadata may expose the context
                // descriptor directly. Prefer the runtime class identity over
                // attempting to parse stripped descriptor name bytes.
                result = s
            } else if let descriptorName = indirectTarget >= 0
                        ? swiftNominalDescriptorName(binary, offset: indirectTarget)
                        : nil {
                result = descriptorName
            } else if let s = MachOData.shared.objcClasses[indirectTarget] {
                // Indirect typerefs for Swift classes may point directly at
                // an ObjC runtime class object. The class-list index provides
                // its source-facing name without any business-type lookup.
                result = s
            } else if let s = MachOData.shared.nominalOffsetMap[indirectTarget] {
                result = s
            } else if let s = MachOData.shared.dylbMap[String(indirectTarget, radix: 16, uppercase: false)] {
                result = s
            } else if let newDataStruct,
                      let s = MachOData.shared.nominalOffsetMap[newDataStruct.value.int16()] {
                result = s
            } else if let newDataStruct,
                      let s = MachOData.shared.dylbMap[String(newDataStruct.address.int16(), radix: 16, uppercase: false)] {
                result = s
            } else if let newDataStruct,
                      let s = MachOData.shared.swiftProtocols[newDataStruct.value.int16()] {
                result = s
            } else if let range = MachOData.shared.swiftTypeRefRange,
                      range.contains(indirectTarget),
                      indirectTarget < binary.count {
                result = DataStruct.textSwiftData(binary,
                                                  offset: indirectTarget,
                                                  isMangledName: true, isClassName: false).value
            } else if let range = MachOData.shared.swiftReflectionStringRange,
                      range.contains(indirectTarget),
                      indirectTarget < binary.count {
                result = DataStruct.textData(binary, offset: indirectTarget,
                                              demangle: true).value
            }
            if boundName != nil {
                mangledName = String((mangledName + result).prefix(maxOutputLength))
            } else if (i == 0 && toIdx >= data.count) {
                mangledName = String((mangledName + result).prefix(maxOutputLength))
            } else {
                let fixName = makeDemangledTypeName(result, header: mangledName)
                mangledName = String((mangledName + fixName).prefix(maxOutputLength))
            }
            i = toIdx
        } else {
            //check next
            mangledName.append(String(format: "%c", val))
            i += 1
        }
    }
    if mangledName.utf8.count >= maxOutputLength {
        return mangledName
    }
    if mangledName.hasSuffix("_p") {
        return mangledName.replacingOccurrences(of: "_p", with: "")
    } else if mangledName.hasSuffix("_pSgXw") {
        return mangledName.replacingOccurrences(of: "_pSgXw", with: "?")
    }
    if mangledName == "" {
        return ""
    }
    let result: String = getTypeFromMangledName(mangledName)
    if (result == mangledName) {
        if mangledName.contains("$s") {
            if let s = swift_demangle(mangledName) {
                return s
            }
        } else {
            if let s = swift_demangle("$s" + mangledName) {
                return s
            }
        }
    }
    return sanitizeRecoveredType(result)
}

/// Read a nominal type name from a descriptor reached through an indirect
/// typeref. This also covers descriptors from imported Swift modules that are
/// not present in this image's `__swift5_types` section.
private func swiftNominalDescriptorName(_ binary: Data, offset: Int) -> String? {
    guard offset >= 0, offset <= binary.count - 12 else { return nil }
    let name = SwiftName.SN(binary, offset: offset + 8,
                             isMangledName: false, isClassName: true).swiftName.value
    guard isUsableSwiftNominalName(name) else { return nil }
    let parent = SwiftParent.SP(binary, offset: offset + 4).swiftParent.value
    if isUsableSwiftNominalName(parent) {
        return "(parent).(name)"
    }
    return name
}

private func boundSymbolName(atFileOffset offset: Int,
                             resolver: MachOAddressResolver?) -> String? {
    guard let resolver,
          let vmAddress = resolver.vmAddress(forFileOffset: offset),
          let imageOffset = resolver.imageOffset(forVMAddress: vmAddress) else {
        return nil
    }
    let key = String(imageOffset, radix: 16)
    return MachOData.shared.boundSymbols[key]?.name
        ?? MachOData.shared.dylbMap[key]
}

/// Reject values produced by unresolved relative pointers or by scanning
/// arbitrary bytes as if they were Swift type metadata.
func sanitizeRecoveredType(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == None || trimmed.hasPrefix("0x") ||
        trimmed.contains("first-element-marker") ||
        trimmed.contains("nominal type descriptor") {
        return ""
    }
    return trimmed
}

func makeDemangledTypeName(_ type: String, header: String) -> String {
    // Empty type name means the address-based lookup missed every name map.
    // Synthesizing "So0C" produces a meaningless placeholder that survives to
    // the output as a fake type (e.g. `field: So0C` / `field: So0CyytG`).
    // Return the accumulated header instead so the slot stays honestly empty.
    if type.isEmpty {
        return header
    }
    if type.hasPrefix("_$") {
        return header + type.replacingOccurrences(of: "_$", with: "_")
    }
    let isArray: Bool = header.contains("Say") || header.contains("SDy")
    let suffix: String = isArray ? "G" : ""
    let fixName = "So\(type.count)\(type)C" + suffix
    return fixName
}
