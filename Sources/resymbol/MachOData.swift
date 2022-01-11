//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/30.
//

import Foundation

class MachOData {
    static let shared = MachOData()
    var objcClasses = ObjcClassesDic()
    var dylbMap = DyldDic()
    
    private init() {}
}

class ObjcClassesDic {
    let serialQueue = DispatchQueue(label: "ObjcClassesDicSyncQueue", attributes: .concurrent)

    private var _data = [Int: String]()

    var data: [Int: String] {
        get {
            return serialQueue.sync {
                return _data
            }
        }
        set {
            serialQueue.async(flags: .barrier) {
                self._data = newValue
            }
        }
    }

    func get(address: String) -> String {
        serialQueue.sync {
            return _data[address.int16Replace()] ?? ""
        }
    }
    
    func set(address: Int, vaule newValue: String) {
        serialQueue.async(flags: .barrier) {
            self._data[address] = newValue
        }
    }
}

class DyldDic {
    let serialQueue = DispatchQueue(label: "DyldDicSyncQueue", attributes: .concurrent)

    private var _data = [String: String]()

    var data: [String: String] {
        get {
            return serialQueue.sync {
                return _data
            }
        }
        set {
            serialQueue.async(flags: .barrier) {
                self._data = newValue
            }
        }
    }

    func get(address: String) -> String? {
        serialQueue.sync {
            return _data[address]
        }
    }
    
    func getReplace(address: String) -> String? {
        serialQueue.sync {
            if let s = _data[address] {
                if s.contains("_$_") {
                    let result = s.components(separatedBy: "_$_").last!
                    if let swift = swift_demangle(result) {
                        return swift
                    }
                    return result
                }
                return s
            }
            return nil
        }
    }
    
    func set(address: UInt64, vaule newValue: String) {
        serialQueue.async(flags: .barrier) {
            var add = address
            if address > 0x100000000 {
                add = address - 0x100000000
            }
            self._data[String(add, radix: 16, uppercase: false)] = newValue
        }
    }
}
