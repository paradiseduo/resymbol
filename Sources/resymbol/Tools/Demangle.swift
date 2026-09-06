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
    if (canDemangleFromRuntime(str)) {
        return runtimeGetDemangledName(str)
    }
    //check is ascii string
    if (!str.isAsciiStr()) {
        return str
    }

    // Swift's Objective-C protocol/class references use So<length><name>C.
    // Some SDK/runtime combinations reject the `$sSo...` spelling; recover
    // the readable name directly instead of leaking the mangled token.
    if str.hasPrefix("So"), str.hasSuffix("C") {
        let body = String(str.dropFirst(2).dropLast())
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
    let candidates = str.hasPrefix("$s") || str.hasPrefix("_T")
        ? [str]
        : ["$s" + str, str]
    for candidate in candidates {
        let demangled = _stdlib_demangleName(candidate)
        if demangled != candidate {
            return fixOptionalTypeName(demangled
                .replacingOccurrences(of: "__C.", with: ""))
        }
    }
    return str
}



func fixOptionalTypeName(_ typeName: String) -> String {
    if typeName.contains("Optional") {
        var result = typeName.replacingOccurrences(of: "Swift.Optional", with: "").replacingOccurrences(of: "Optional", with: "")
        if let s = result.firstIndex(of: "<") {
            result.remove(at: s)
            if let e = result.lastIndex(of: ">") {
                result.remove(at: e)
            }
        }
        return result + "?"
    }
    return typeName
}

func fixMangledTypeName(_ dataStruct: DataStruct) -> String {
    if !dataStruct.value.contains("0x") {
        return dataStruct.value
    }
    let hexName: String = dataStruct.value.removingPrefix("0x")
    let data = hexName.hexData
    let startAddress = dataStruct.address.int16()
    guard data.count >= 4 else { return dataStruct.value }
    
    var mangledName: String = ""
    var i: Int = 0
    let maxOutputLength = 256
    
    while i < data.count, mangledName.utf8.count < maxOutputLength {
        let val = data[i]
        if (val == 0x01) {
            //find
            let fromIdx: Int = i + 1 // ignore 0x01
            let toIdx: Int = i + 5 // 4 bytes
            guard toIdx <= data.count else { return dataStruct.value }
            let subData = data[fromIdx..<toIdx]
            let fieldOffset = startAddress.addingReportingOverflow(fromIdx).overflow ? -1 : startAddress + fromIdx
            let address = MachOData.shared.resolveRelativePointer(base: fieldOffset,
                                                                    raw: subData.rawValueBig()) ?? -1
            guard address >= 0, address < MachOData.shared.binary.count else {
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
                      address < MachOData.shared.binary.count {
                result = DataStruct.textSwiftData(MachOData.shared.binary, offset: address,
                                                  isMangledName: true, isClassName: false).value
            } else if let range = MachOData.shared.swiftReflectionStringRange,
                      range.contains(address),
                      address < MachOData.shared.binary.count {
                result = DataStruct.textData(MachOData.shared.binary, offset: address,
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
            let address = MachOData.shared.resolveRelativePointer(base: fieldOffset,
                                                                    raw: subData.rawValueBig()) ?? -1
            guard address >= 0, address <= MachOData.shared.binary.count - 4 else {
                i = toIdx + 1
                continue
            }
            let newDataStruct = DataStruct.data(MachOData.shared.binary, offset: address, length: 4)
            let indirectTarget = MachOData.shared.resolveRelativePointer(base: address,
                                                                           raw: newDataStruct.value) ?? -1
            var result = ""
            if let s = MachOData.shared.mangledNameMap[dataStruct.value] {
                result = s
            } else if let s = MachOData.shared.nominalOffsetMap[indirectTarget] {
                result = s
            } else if let s = MachOData.shared.dylbMap[String(indirectTarget, radix: 16, uppercase: false)] {
                result = s
            } else if let s = MachOData.shared.nominalOffsetMap[newDataStruct.value.int16()] {
                result = s
            } else if let s = MachOData.shared.dylbMap[String(newDataStruct.address.int16(), radix: 16, uppercase: false)] {
                result = s
            } else if let s = MachOData.shared.swiftProtocols[newDataStruct.value.int16()] {
                result = s
            } else if let range = MachOData.shared.swiftTypeRefRange,
                      range.contains(indirectTarget),
                      indirectTarget < MachOData.shared.binary.count {
                result = DataStruct.textSwiftData(MachOData.shared.binary,
                                                  offset: indirectTarget,
                                                  isMangledName: true, isClassName: false).value
            } else if let range = MachOData.shared.swiftReflectionStringRange,
                      range.contains(indirectTarget),
                      indirectTarget < MachOData.shared.binary.count {
                result = DataStruct.textData(MachOData.shared.binary, offset: indirectTarget,
                                              demangle: true).value
            }
            if (i == 0 && toIdx >= data.count) {
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
