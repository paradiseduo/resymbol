//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/11.
//

import Foundation

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
            if address > RVA {
                add = address - RVA
            }
            self._data[String(add, radix: 16, uppercase: false)] = newValue
        }
    }
}


class ObjcProtocolDic {
    let serialQueue = DispatchQueue(label: "ObjcProtocolDicSyncQueue", attributes: .concurrent)

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

    func get(address: Int) -> String? {
        serialQueue.sync {
            return _data[address]
        }
    }
    
    func set(address: Int, vaule newValue: String) {
        serialQueue.async(flags: .barrier) {
            self._data[address] = newValue
        }
    }
}
