//
//  File.swift
//  
//
//  Created by admin on 2022/1/27.
//

import Foundation

class SyncArray<T> {
    private let serialQueue: DispatchQueue
    
    init(_ label: String) {
        serialQueue = DispatchQueue(label: label, attributes: .concurrent)
    }
    
    private var _array = [T]()
    
    var array: [T] {
        get {
            return serialQueue.sync {
                return _array
            }
        }
        set {
            serialQueue.async(flags: .barrier) {
                self._array = newValue
            }
        }
    }
    
    public func append(newElement: T) {
        serialQueue.async {
            self.array.append(newElement)
        }
    }

    public subscript(index: Int) -> T {
        get {
            return serialQueue.sync {
                return array[index]
            }
        }
        set {
            serialQueue.async(flags: .barrier) {
                self.array[index] = newValue
            }
        }
    }
}
