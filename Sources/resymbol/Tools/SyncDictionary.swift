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
