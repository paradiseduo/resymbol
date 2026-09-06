//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/11.
//

import Foundation

class SyncDictionary<V: Hashable, T>: Collection {

    private var dictionary = [V: T]()
    private let queue: DispatchQueue
    
    init(_ label: String) {
        queue = DispatchQueue(label: label, attributes: .concurrent)
    }
    
    var startIndex: Dictionary<V, T>.Index {
        queue.sync {
            return dictionary.startIndex
        }
    }

    var endIndex: Dictionary<V, T>.Index {
        queue.sync {
            return dictionary.endIndex
        }
    }

    // this is because it is an apple protocol method
    // swiftlint:disable identifier_name
    func index(after i: Dictionary<V, T>.Index) -> Dictionary<V, T>.Index {
        queue.sync {
            return dictionary.index(after: i)
        }
    }
    // swiftlint:enable identifier_name
    subscript(key: V) -> T? {
        set(newValue) {
            queue.sync(flags: .barrier) {
                dictionary[key] = newValue
            }
        }
        get {
            queue.sync {
                return dictionary[key]
            }
        }
    }

    // has implicity get
    subscript(index: Dictionary<V, T>.Index) -> Dictionary<V, T>.Element {
        queue.sync {
            return dictionary[index]
        }
    }
    
    func removeValue(forKey key: V) {
        _ = queue.sync(flags: .barrier) {
            dictionary.removeValue(forKey: key)
        }
    }

    func removeAll() {
        queue.sync(flags: .barrier) {
            dictionary.removeAll()
        }
    }

    func removeAllSync() {
        queue.sync(flags: .barrier) { dictionary.removeAll() }
    }
    
    func description() {
        ConsoleIO.writeMessage(dictionary, .debug)
    }

    func valuesSnapshot() -> [T] {
        queue.sync { Array(dictionary.values) }
    }

}

extension SyncDictionary where T: Comparable {
    /// Atomically retain a deterministic representative when several parser
    /// workers publish the same logical key concurrently.
    func setDeterministically(_ value: T, forKey key: V) {
        queue.sync(flags: .barrier) {
            guard let existing = dictionary[key] else {
                dictionary[key] = value
                return
            }
            if value < existing { dictionary[key] = value }
        }
    }
}

extension SyncDictionary where T == String {
    /// Keep an exact value only while every producer agrees. An empty value
    /// marks a collided legacy key so consumers can fall back to address-based
    /// evidence instead of choosing a random type.
    func setIfUnambiguous(_ value: String, forKey key: V) {
        guard !value.isEmpty else { return }
        queue.sync(flags: .barrier) {
            guard let existing = dictionary[key] else {
                dictionary[key] = value
                return
            }
            if existing != value { dictionary[key] = "" }
        }
    }
}
