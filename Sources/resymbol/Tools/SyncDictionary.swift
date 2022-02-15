//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/11.
//

import Foundation

actor SyncDictionary<V: Hashable, T> {

    private var dictionary = [V: T]()
    
    var startIndex: Dictionary<V, T>.Index {
        return dictionary.startIndex
    }

    var endIndex: Dictionary<V, T>.Index {
        return dictionary.endIndex
    }

    // this is because it is an apple protocol method
    // swiftlint:disable identifier_name
    func index(after i: Dictionary<V, T>.Index) -> Dictionary<V, T>.Index {
        return dictionary.index(after: i)
    }
    // swiftlint:enable identifier_name
    func set(_ key: V, _ value: T) {
        dictionary[key] = value
    }
    
    func get(_ key: V) -> T? {
        return dictionary[key]
    }

    // has implicity get
    subscript(index: Dictionary<V, T>.Index) -> Dictionary<V, T>.Element {
        return dictionary[index]
    }
    
    func removeValue(forKey key: V) {
        dictionary.removeValue(forKey: key)
    }

    func removeAll() {
        dictionary.removeAll()
    }
    
    func description() {
        print(dictionary)
    }

}
