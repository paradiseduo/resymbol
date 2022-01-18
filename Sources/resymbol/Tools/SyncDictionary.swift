//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/11.
//

import Foundation

class SyncDictionary {
    let serialQueue: DispatchQueue
    
    init(_ label: String) {
        serialQueue = DispatchQueue(label: label, attributes: .concurrent)
    }
    
    private var _data = [AnyHashable: Any]()
    
    var data: [AnyHashable: Any] {
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
    
    func get(_ key: AnyHashable) -> Any? {
        serialQueue.sync {
            return _data[key]
        }
    }
    
    func set(key: AnyHashable, vaule newValue: Any) {
        serialQueue.async(flags: .barrier) {
            self._data[key] = newValue
        }
    }
}

extension SyncDictionary {
    func getReplace(address: String) -> String? {
        serialQueue.sync {
            if let s = _data[address] as? String {
                let result = symbolName(s)
                if let swift = swift_demangle(result) {
                    return swift
                }
                return result
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
