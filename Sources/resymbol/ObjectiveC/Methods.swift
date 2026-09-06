//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

/// Decode an Objective-C metadata record count without allowing malformed or
/// stripped data to turn it into a negative/unbounded loop.  Counts are
/// unsigned in the 64-bit runtime ABI; the file range is the final authority.
func boundedObjCRecordCount(_ raw: String, startOffset: Int, stride: Int,
                            dataCount: Int) -> Int {
    guard stride > 0, startOffset >= 0, startOffset <= dataCount,
          let declared = UInt64(raw, radix: 16) else { return 0 }
    let available = UInt64((dataCount - startOffset) / stride)
    return Int(min(declared, available, UInt64(Int.max)))
}

struct MethodName {
    let name: DataStruct
    let methodName: DataStruct
    
    static func methodName(_ binary: Data, offset: Int) -> MethodName {
        let name = DataStruct.data(binary, offset: offset, length: 8)
        let methodNameOffset = MachOData.shared.resolvePointerWithLegacyFallback(name.value) ?? -1
        let methodName = DataStruct.textData(binary, offset: methodNameOffset)
        return MethodName(name: name, methodName: methodName)
    }
}

struct MethodTypes {
    let types: DataStruct
    let methodTypes: DataStruct
    
    static func methodTypes(_ binary: Data, offset: Int, hasExtendedMethodTypes: Bool = false, typeOffSet: Int = 0) -> MethodTypes {
        let types = DataStruct.data(binary, offset: offset, length: 8)
        let methodTypes: DataStruct
        if hasExtendedMethodTypes {
            methodTypes = DataStruct.textData(binary, offset: typeOffSet)
        } else {
            let typeOffset = MachOData.shared.resolvePointerWithLegacyFallback(types.value) ?? -1
            methodTypes = DataStruct.textData(binary, offset: typeOffset)
        }
        return MethodTypes(types: types, methodTypes: methodTypes)
    }
}

struct Method {
    let name: MethodName
    let types: MethodTypes
    let implementation: DataStruct
    
    static func methods(_ binary: Data, startOffset: Int, count: Int, hasExtendedMethodTypes: Bool = false, typeOffSet: inout Int) -> [Method] {
        var result = [Method]()
        var offSet = startOffset
        var start = 0
        for _ in 0..<count {
            let name = MethodName.methodName(binary, offset: offSet)
            offSet += 8
            if hasExtendedMethodTypes {
                start = MachOData.shared.resolvePointerWithLegacyFallback(DataStruct.data(binary, offset: typeOffSet, length: 8).value) ?? 0
                typeOffSet += 8
            }
            let types = MethodTypes.methodTypes(binary, offset: offSet, hasExtendedMethodTypes: hasExtendedMethodTypes, typeOffSet: start)
            offSet += 8
            let implementation = DataStruct.data(binary, offset: offSet, length: 8)
            offSet += 8
            result.append(Method(name: name, types: types, implementation: implementation))
        }
        return result
    }

    static func relativeMethods(_ binary: Data, startOffset: Int, count: Int,
                                directSelectors: Bool, hasExtendedMethodTypes: Bool,
                                typeOffSet: inout Int) -> [Method] {
        var result = [Method]()
        result.reserveCapacity(count)
        var offset = startOffset
        for _ in 0..<count {
            guard offset >= 0, offset <= binary.count - 12 else { break }
            let nameRelative = DataStruct.data(binary, offset: offset, length: 4)
            // ObjC method metadata stores a signed field-relative offset.
            let nameReference = MachOData.shared.resolveRelativePointer(base: offset, raw: nameRelative.value)
                ?? -1
            let nameOffset: Int
            if directSelectors {
                nameOffset = nameReference
            } else {
                nameOffset = MachOData.shared.resolvePointerWithLegacyFallback(DataStruct.data(binary, offset: nameReference, length: 8).value) ?? -1
            }
            let methodName = MethodName(name: nameRelative,
                                        methodName: DataStruct.textData(binary, offset: nameOffset))

            let typesRelative = DataStruct.data(binary, offset: offset + 4, length: 4)
            // The type reference uses the address of its own 32-bit field.
            var typesOffset = MachOData.shared.resolveRelativePointer(base: offset + 4, raw: typesRelative.value)
                ?? -1
            if hasExtendedMethodTypes {
                typesOffset = MachOData.shared.resolvePointerWithLegacyFallback(DataStruct.data(binary, offset: typeOffSet, length: 8).value) ?? -1
                typeOffSet += 8
            }
            let methodTypes = MethodTypes(types: typesRelative,
                                          methodTypes: DataStruct.textData(binary, offset: typesOffset))
            let implementation = DataStruct.data(binary, offset: offset + 8, length: 4)
            result.append(Method(name: methodName, types: methodTypes, implementation: implementation))
            offset += 12
        }
        return result
    }
    
    func serialization(isClass: Bool) -> String {
        let replaceType = types.methodTypes.value.replacingOccurrences(of: "@0:8", with: "")
        let strArray = Array(replaceType).map { c in
            return String(c)
        }
        var typeArray = [String]()
        var index = 0
        while index < strArray.count {
            var type = ""
            // 史上最恶心的结构体 ^{kinfo_proc={extern_proc=(?={?=^{proc}^{proc}}{timeval=qi})^{vmspace}^{sigacts}iciii*^viiIiI^v*II{itimerval={timeval=qi}{timeval=qi}}{timeval=qi}QQQi^{vnode}i^{vnode}iIIICCc[17c]^{pgrp}^{user}SS^{rusage}}{eproc=^{proc}^{session}{_pcred=[72c]^{ucred}IIIIi}{_ucred=iIs[16I]}{vmspace=i*[5i][3*]}iisii^{session}[8c]isssi[12c][4i]}}
            var count = 0 //用于引号和括号配对
            var count1 = 0 //用于{}配对
            var count2 = 0 //用于[]配对
            for j in index..<strArray.count {
                if strArray[j].rangeOfCharacter(from: CharacterSet.decimalDigits) != nil && count % 2 == 0 && count1 == 0 && count2 == 0 {
                    index = j
                    if type.count > 0 {
                        typeArray.append(type)
                    }
                    break
                } else {
                    type += strArray[j]
                    if strArray[j] == "\"" {
                        count += 1
                    }
                    if strArray[j] == "{" {
                        count1 += 1
                    }
                    if strArray[j] == "}" {
                        count1 -= 1
                    }
                    if strArray[j] == "[" {
                        count2 += 1
                    }
                    if strArray[j] == "]" {
                        count2 -= 1
                    }
                }
            }
            index += 1
        }
        var result = ""
        if isClass {
            if typeArray.count > 0 {
                result += "+" + "(\(primitiveType(typeArray[0])))"
            } else {
                return "+" + "(MISSING_TYPE *)" + name.methodName.value + ";"
            }
        } else {
            if typeArray.count > 0 {
                result += "-" + "(\(primitiveType(typeArray[0])))"
            } else {
                return "-" + "(MISSING_TYPE *)" + name.methodName.value + ";"
            }
        }
        let names = name.methodName.value.components(separatedBy: ":").filter { s in
            s.count > 0
        }
        if !name.methodName.value.contains(":") && names.count == 1 {
            result += names[0]+";"
        } else {
            for i in 0..<names.count {
                if i+1 >= typeArray.count {
                    result +=  names[i] + ":(MISSING_TYPE *)" + "arg\(i+1) "
                } else {
                    result +=  names[i] + ":(\(primitiveType(typeArray[i+1])))" + "arg\(i+1) "
                }

            }
            result = result.trimmingCharacters(in: CharacterSet.whitespaces) + ";"
        }
        return result
    }
}

struct Methods {
    let baseMethod: DataStruct
    let elementSize: DataStruct?
    let elementCount: DataStruct?
    let methods: [Method]?
    
    static func methods(_ binary: Data, startOffset: Int, hasExtendedMethodTypes: Bool = false, typeOffSet: inout Int) -> Methods {
        let baseMethod = DataStruct.data(binary, offset: startOffset, length: 8)
        let offSetMD = MachOData.shared.resolvePointerWithLegacyFallback(baseMethod.value) ?? -1
        if offSetMD > 0 {
            let elementSize = DataStruct.data(binary, offset: offSetMD, length: 4)
            let elementCount = DataStruct.data(binary, offset: offSetMD+4, length: 4)
            let header = UInt32(elementSize.value, radix: 16) ?? 0
            let isRelative = header & 0x8000_0000 != 0
            let directSelectors = header & 0x4000_0000 != 0
            let entrySize = isRelative ? 12 : 24
            let count = boundedObjCRecordCount(elementCount.value,
                                               startOffset: offSetMD + 8,
                                               stride: entrySize,
                                               dataCount: binary.count)
            let methods: [Method]
            if isRelative {
                methods = Method.relativeMethods(binary, startOffset: offSetMD+8, count: count,
                                                directSelectors: directSelectors,
                                                hasExtendedMethodTypes: hasExtendedMethodTypes,
                                                typeOffSet: &typeOffSet)
            } else {
                methods = Method.methods(binary, startOffset: offSetMD+8, count: count,
                                         hasExtendedMethodTypes: hasExtendedMethodTypes,
                                         typeOffSet: &typeOffSet)
            }
            return Methods(baseMethod: baseMethod, elementSize: elementSize, elementCount: elementCount, methods: methods)
        } else {
            return Methods(baseMethod: baseMethod, elementSize: nil, elementCount: nil, methods: nil)
        }
    }
}
