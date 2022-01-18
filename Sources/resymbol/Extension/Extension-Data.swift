//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

extension Data {
    func extract<T>(_ type: T.Type, offset: Int = 0) -> T {
        let data = self[offset..<offset + MemoryLayout<T>.size]
        return data.withUnsafeBytes { dataBytes in
            dataBytes.baseAddress!.assumingMemoryBound(to: UInt8.self).withMemoryRebound(to: T.self, capacity: 1) { (p) -> T in
                return p.pointee
            }
        }
    }
    
    func readValue<Type>(_ offset: Int) -> Type? {
        let val:Type? = self.withUnsafeBytes { (ptr:UnsafeRawBufferPointer) -> Type? in
            return ptr.baseAddress?.advanced(by: offset).load(as: Type.self);
        }
        return val;
    }
    
    func rawValue() -> String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
    
    func rawValueBig() -> String {
        return self.map { String(format: "%02x", $0) }.reversed().joined()
    }
    
    func read_uleb128(index: inout Int, end: Int) -> UInt64 {
        var result: UInt64 = 0
        var bit = 0
        var read_next = true

        var p = self[index]
        repeat {
            let slice = UInt64(p & 0x7f)
            if bit >= 64 {
                assert(false, "uleb128 too big for uint64")
            } else {
                result |= (slice << bit)
                bit += 7
            }
            read_next = (p & 0x80) != 0  // = 128
            index += 1
            p = self[index]
        } while (read_next)
        return result
    }
    
    func read_sleb128(index: inout Int, end: Int) -> Int64 {
        var result: Int64 = 0
        var bit = 0
        var byte: UInt8 = 0

        var p = self[index]
        repeat {
            byte = p
            index += 1
            p = self[index]
            
            result |= (Int64(byte & 0x7F) << bit)
            bit += 7
        } while ((byte & 0x80) != 0)
        
        if (byte & 0x40) != 0 {
            result |= ((-1) << bit)
        }
        
        return result
    }
}
