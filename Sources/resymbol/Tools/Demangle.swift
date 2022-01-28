//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/23.
//

import Foundation


import Darwin

typealias Swift_Demangle = @convention(c) (_ mangledName: UnsafePointer<UInt8>?,
                                           _ mangledNameLength: Int,
                                           _ outputBuffer: UnsafeMutablePointer<UInt8>?,
                                           _ outputBufferSize: UnsafeMutablePointer<Int>?,
                                           _ flags: UInt32) -> UnsafeMutablePointer<Int8>?

func swift_demangle(_ mangled: String) -> String? {
    let RTLD_DEFAULT = dlopen(nil, RTLD_NOW)
    if let sym = dlsym(RTLD_DEFAULT, "swift_demangle") {
        let f = unsafeBitCast(sym, to: Swift_Demangle.self)
        if let cString = f(mangled, mangled.count, nil, nil, 0) {
            defer { cString.deallocate() }
            let result = String(cString: cString).replacingOccurrences(of: "$s", with: "").replacingOccurrences(of: "__C.", with: "")
            return fixOptionalTypeName(result)
        }
    }
    return nil
}


@_silgen_name("swift_getTypeByMangledNameInContext")
public func _getTypeByMangledNameInContext(_ name: UnsafePointer<UInt8>,
                                           _ nameLength: Int,
                                           genericContext: UnsafeRawPointer?,
                                           genericArguments: UnsafeRawPointer?) -> Any.Type?

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
    
    guard let ptr = str.toPointer() else {
        return str
    }
    
    var useCnt:Int = str.count
    if str.contains("_pG") {
        useCnt = useCnt - str.components(separatedBy: "_pG").first!.count
    }
        
    guard let typeRet: Any.Type = _getTypeByMangledNameInContext(ptr, useCnt, genericContext: nil, genericArguments: nil) else {
        return str
    }
    
    return fixOptionalTypeName(String(describing: typeRet))
}


func fixOptionalTypeName(_ typeName: String) -> String {
    if typeName.contains("Optional") {
        let result = typeName.replacingOccurrences(of: "Swift.Optional", with: "").replacingOccurrences(of: "Optional", with: "")
        if result.contains("->") {
            return result.replacingOccurrences(of: "<", with: "(").replacingOccurrences(of: ">", with: ")").replacingOccurrences(of: "-)", with: "->") + "?"
        } else {
            return result.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "") + "?"
        }
    }
    return typeName
}

func fixArrayTypeName(_ typeName: String) -> String {
    if typeName.contains("Swift.Array") {
        return typeName.replacingOccurrences(of: "Swift.Array", with: "").replacingOccurrences(of: "<", with: "[").replacingOccurrences(of: ">", with: "]")
    }
    return typeName
}
