//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/26.
//

import Foundation

struct SwiftType {
    let flags: SwiftFlags
    let parent: SwiftParent
    let name: SwiftName
    let accessFunction: DataStruct
    let fieldDescriptor: FieldDescriptor

    var qualifiedName: String {
        let parentName = parent.swiftParent.value
        guard isUsableParent(parentName) else { return name.swiftName.value }
        return "\(parentName).\(name.swiftName.value)"
    }

    var hasUsableName: Bool { isUsableSwiftNominalName(name.swiftName.value) }

    /// Single-letter parents are commonly malformed relative-pointer output
    /// in stripped Release binaries (for example `Q.State`). Keep those from
    /// leaking into source while retaining real nested context descriptors.
    private func isUsableParent(_ value: String) -> Bool {
        guard value.count > 1, value != None, !value.hasPrefix("0x") else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "." || $0 == "_" || $0.isNumber) }
    }
    
    static func ST(_ binary: Data, offset: Int, flags: SwiftFlags) -> SwiftType {
        let parent = SwiftParent.SP(binary, offset: offset)
        let name = SwiftName.SN(binary, offset: offset+4, isMangledName: false, isClassName: true)
        let accessFunction = DataStruct.data(binary, offset: offset+8, length: 4)
        let fieldDescriptor = FieldDescriptor.FD(binary, offset: offset+12)
        
        return SwiftType(flags: flags, parent: parent, name: name, accessFunction: accessFunction, fieldDescriptor: fieldDescriptor)
    }
}

/// Validate names recovered from nominal descriptors before they enter source
/// output or cross-descriptor lookup maps. Descriptor bytes can be stripped or
/// malformed while still looking like a printable hexadecimal placeholder.
func isUsableSwiftNominalName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != None, !trimmed.hasPrefix("0x"),
          !trimmed.contains("first-element-marker") else { return false }
    guard let first = trimmed.first,
          first.isLetter || first == "_" else { return false }
    return trimmed.allSatisfy { character in
        character.isASCII && (character.isLetter || character.isNumber ||
                              character == "_" || character == "." ||
                              character == "<" || character == ">" ||
                              character == "," || character == "`")
    }
}

func isUsableSwiftMemberName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != None, !trimmed.hasPrefix("0x"),
          !trimmed.contains("first-element-marker"), let first = trimmed.first,
          first.isLetter || first == "_" else { return false }
    return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
}
