//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

extension String {
    init(rawCString: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) {
        var rawCString = rawCString
        let rawCStringSize = MemoryLayout.size(ofValue: rawCString)
        let string = withUnsafePointer(to: &rawCString) { (pointer) -> String in
            return pointer.withMemoryRebound(to: UInt8.self, capacity: rawCStringSize, {
                return String(cString: $0)
            })
        }
        self.init(string)
    }
    
    init(rawCChar: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) {
        var rawCString = rawCChar
        let rawCStringSize = MemoryLayout.size(ofValue: rawCString)
        let string = withUnsafePointer(to: &rawCString) { (pointer) -> String in
            return pointer.withMemoryRebound(to: CChar.self, capacity: rawCStringSize, {
                return String(cString: $0)
            })
        }
        self.init(string)
    }
    
    init(data: Data, offset: Int, commandSize: Int, loadCommandString: lc_str) {
        let loadCommandStringOffset = Int(loadCommandString.offset)
        let stringOffset = offset + loadCommandStringOffset
        let length = commandSize - loadCommandStringOffset
        self = String(data: data[stringOffset..<(stringOffset + length)], encoding: .utf8)!.trimmingCharacters(in: .controlCharacters)
    }
    
    func int16Replace() -> Int {
        return Int((UInt64(self, radix: 16) ?? 0) & ~RVA)
    }
    
    func int16() -> Int {
        if self.hasPrefix("ff") {
            return int16Subtraction()
        }
        return Int(self, radix: 16) ?? 0
    }
    
    func int16Subtraction() -> Int {
        if let i = Int(self, radix: 16) {
            if self.starts(with: "0") {
                return i
            } else {
                return i | ~0xFFFFFFFF
            }
        }
        return 0
    }
    
    func int16RVA() -> Int {
        let rva = (Int("100000000", radix: 16) ?? 0)
        let raw = (Int(self, radix: 16) ?? 0)
        return raw + rva
    }
    
    func ltrim(_ chars: String) -> String {
        if let index = self.firstIndex(where: {!chars.contains($0)}) {
            return String(self[index..<self.endIndex])
        } else {
            return self
        }
    }
    
    func rtrim(_ chars: String) -> String {
        if let index = self.lastIndex(where: {!chars.contains($0)}) {
            return String(self[self.startIndex...index])
        } else {
            return self
        }
    }
}

extension String {
    subscript(_ indexs: ClosedRange<Int>) -> String {
        let beginIndex = index(startIndex, offsetBy: indexs.lowerBound)
        let endIndex = index(startIndex, offsetBy: indexs.upperBound)
        return String(self[beginIndex...endIndex])
    }
    
    subscript(_ indexs: Range<Int>) -> String {
        let beginIndex = index(startIndex, offsetBy: indexs.lowerBound)
        let endIndex = index(startIndex, offsetBy: indexs.upperBound)
        return String(self[beginIndex..<endIndex])
    }
    
    subscript(_ indexs: PartialRangeThrough<Int>) -> String {
        let endIndex = index(startIndex, offsetBy: indexs.upperBound)
        return String(self[startIndex...endIndex])
    }
    
    subscript(_ indexs: PartialRangeFrom<Int>) -> String {
        let beginIndex = index(startIndex, offsetBy: indexs.lowerBound)
        return String(self[beginIndex..<endIndex])
    }
    
    subscript(_ indexs: PartialRangeUpTo<Int>) -> String {
        let endIndex = index(startIndex, offsetBy: indexs.upperBound)
        return String(self[startIndex..<endIndex])
    }
}
