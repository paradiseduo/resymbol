//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/9/10.
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
    
    func rawValue() -> String {
        return self.map {
            String(format: "%02x", $0)
        }.joined()
    }
    
    func rawValueBig() -> String {
        var arr = Array<String>()
        let _ = self.map {
            let s = String(format: "%02x", $0)
            arr.append(s)
            return s
        }.joined()
        return arr.reversed().joined()
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
        return Int(self.replacingOccurrences(of: "00000001", with: ""), radix: 16) ?? 0
    }
    
    func int16() -> Int {
        return Int(self, radix: 16) ?? 0
    }
    
    func int16RVA() -> Int {
        let rva = (Int("100000000", radix: 16) ?? 0)
        let raw = (Int(self, radix: 16) ?? 0)
        return raw + rva
    }
}

extension Int {
    func string16() -> String {
        return String(format: "%08x", self)
    }
}

extension FileManager {
    static func open(machoPath: String, backup: Bool, handle: (Data?)->()) {
        do {
            if FileManager.default.fileExists(atPath: machoPath) {
                if backup {
                    let backUpPath = "./\(machoPath.components(separatedBy: "/").last!)_back"
                    if FileManager.default.fileExists(atPath: backUpPath) {
                        try FileManager.default.removeItem(atPath: backUpPath)
                    }
                    try FileManager.default.copyItem(atPath: machoPath, toPath: backUpPath)
                    print("Backup machO file \(backUpPath)")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: machoPath))
                handle(data)
            } else {
                print("MachO file not exist !")
                handle(nil)
            }
        } catch let err {
            print(err)
            handle(nil)
        }
    }
}
