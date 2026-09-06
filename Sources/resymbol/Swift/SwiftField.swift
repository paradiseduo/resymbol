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
    let wrappedType: String
    if let accessorType, !accessorType.isEmpty {
        wrappedType = accessorType
    } else if wrapper == "Clamped", let start = fieldType.firstIndex(of: "<"),
              fieldType.hasSuffix(">") {
        // Clamped's single generic argument is also its wrappedValue type;
        // use it only for this known wrapper when accessor indexing was
        // stripped from the binary.
        wrappedType = String(fieldType[fieldType.index(after: start)..<fieldType.index(before: fieldType.endIndex)])
    } else {
        return nil
    }
    return "@\(wrapper) var \(propertyName): \(wrappedType)"
}

/// Resolve a field-record type through the same evidence chain used by class
/// and struct output. Returning nil keeps an unresolved Release-only field
/// honest instead of printing pointer bytes as a source type.
func resolvedSwiftFieldType(_ record: FieldRecord, accessorType: String? = nil,
                            genericNames: [String] = []) -> String? {
    if let accessorType, !accessorType.isEmpty {
        let value = sanitizeRecoveredType(accessorType)
        if !value.isEmpty { return value }
    }
    var raw = record.mangledTypeName.swiftName.value
    if raw.count == 1, let scalar = raw.unicodeScalars.first,
       scalar.value >= 65, scalar.value < 65 + UInt32(genericNames.count) {
        raw = genericNames[Int(scalar.value - 65)]
    }
    if !genericNames.isEmpty {
        raw = replaceGenericTokens(raw, names: genericNames)
    }
    guard !raw.isEmpty, raw != None else { return nil }
    if raw.hasPrefix("0x") {
        let value = sanitizeRecoveredType(fixMangledTypeName(record.mangledTypeName.swiftName))
        return value.isEmpty ? nil : value
    }
    let value = sanitizeRecoveredType(SwiftTypeReferenceParser.parse(raw).description)
    return value.isEmpty ? nil : value
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
