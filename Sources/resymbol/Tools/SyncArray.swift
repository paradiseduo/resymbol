//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/27.
//

import Foundation

/// A thread-safe array.
public actor SyncArray<Element> {
    fileprivate var array = [Element]()
}
 
// MARK: - Properties
public extension SyncArray {
 
    var first: Element? {
        return self.array.first
    }
 
    var last: Element? {
        return self.array.last
    }
 
    var count: Int {
        return self.array.count
    }

    var isEmpty: Bool {
        return self.array.isEmpty
    }
    
    var description: String {
        return self.array.description
    }
}
 
// MARK: - 读操作
public extension SyncArray {
    func first(where predicate: (Element) -> Bool) -> Element? {
        return self.array.first(where: predicate)
    }
    
    func filter(_ isIncluded: (Element) -> Bool) -> [Element] {
        return self.array.filter(isIncluded)
    }
    
    func index(where predicate: (Element) -> Bool) -> Int? {
        return self.array.firstIndex(where: predicate)
    }
    
    func sorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        return self.array.sorted(by: areInIncreasingOrder)
    }
    
    func flatMap<ElementOfResult>(_ transform: (Element) -> ElementOfResult?) -> [ElementOfResult] {
        return self.array.compactMap(transform)
    }
 
    func forEach(_ body: (Element) -> Void) {
        self.array.forEach(body)
    }
    
    func contains(where predicate: (Element) -> Bool) -> Bool {
        return self.array.contains(where: predicate)
    }
}
 
// MARK: - 写操作
public extension SyncArray {
 
    func append( _ element: Element) {
        self.array.append(element)
    }
 
    func append( _ elements: [Element]) {
        self.array += elements
    }
 
    func insert( _ element: Element, at index: Int) {
        self.array.insert(element, at: index)
    }
 
    func remove(at index: Int, completion: ((Element) -> Void)? = nil) {
        let element = self.array.remove(at: index)
        DispatchQueue.main.async {
            completion?(element)
        }
    }
    
    func remove(where predicate: @escaping (Element) -> Bool, completion: ((Element) -> Void)? = nil) {
        guard let index = self.array.firstIndex(where: predicate) else { return }
        let element = self.array.remove(at: index)
        
        DispatchQueue.main.async {
            completion?(element)
        }
    }
 
    func removeAll(completion: (([Element]) -> Void)? = nil) {
        let elements = self.array
        self.array.removeAll()
        
        DispatchQueue.main.async {
            completion?(elements)
        }
    }
}
 
public extension SyncArray {

    subscript(index: Int) -> Element? {
        get {
            guard self.array.startIndex..<self.array.endIndex ~= index else { return nil }
            return self.array[index]
        }
        set {
            guard let newValue = newValue else { return }
            self.array[index] = newValue
        }
    }
}
 
 
// MARK: - Equatable
public extension SyncArray where Element: Equatable {

    func contains(_ element: Element) -> Bool {
        return self.array.contains(element)
    }
}
