//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/19.
//

import Foundation

struct Dyld {
    static func binding(_ binary: Data, vmAddress:[UInt64], start: Int, end: Int, isLazy: Bool = false) async {
        var done = false
        var symbolName = ""
        var libraryOrdinal: Int32 = 0
        var symbolFlags: Int32 = 0
        var type: Int32 = 0
        var addend: Int64 = 0
        var segmentIndex: Int32 = 0
        let ptrSize = UInt64(MemoryLayout<UInt64>.size)
        var bindCount: UInt64 = 0
        
        var index = start
        var address = vmAddress[0]
        var cccccc = 0
        while index < end && !done {
            let item = Int32(binary[index])
            let immediate = item & BIND_IMMEDIATE_MASK
            let opcode = item & BIND_OPCODE_MASK
            index += 1
            cccccc += 1
            switch opcode {
            case BIND_OPCODE_DONE:
                printf("BIND_OPCODE: DONE")
                if !isLazy {
                    done = true
                }
                break
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
                libraryOrdinal = immediate
                printf("BIND_OPCODE: SET_DYLIB_ORDINAL_IMM,          libraryOrdinal = \(libraryOrdinal)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
                libraryOrdinal = Int32(binary.read_uleb128(index: &index, end: end))
                printf("BIND_OPCODE: SET_DYLIB_ORDINAL_ULEB,         libraryOrdinal = \(libraryOrdinal)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
                if immediate == 0 {
                    libraryOrdinal = 0
                } else {
                    libraryOrdinal = immediate | BIND_OPCODE_MASK
                }
                printf("BIND_OPCODE: SET_DYLIB_SPECIAL_IMM,          libraryOrdinal = \(libraryOrdinal)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                var strData = Data()
                while binary[index] != 0 {
                    strData.append(contentsOf: [binary[index]])
                    index += 1
                }
                index += 1
                symbolName = String(data: strData, encoding: String.Encoding.utf8) ?? ""
                symbolFlags = immediate
                printf("BIND_OPCODE: SET_SYMBOL_TRAILING_FLAGS_IMM,  flags: \(String(format: "%02x", symbolFlags)), str = \(symbolName)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_TYPE_IMM:
                type = immediate
                printf("BIND_OPCODE: SET_TYPE_IMM,                   type = \(type) \(BindType.description(immediate))   index: \(cccccc)")
                break
            case BIND_OPCODE_SET_ADDEND_SLEB:
                addend = binary.read_sleb128(index: &index, end: end)
                printf("BIND_OPCODE: SET_ADDEND_SLEB,                addend = \(addend)  index: \(cccccc)")
                break
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                segmentIndex = immediate
                let r = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: SET_SEGMENT_AND_OFFSET_ULEB,    segmentIndex: \(segmentIndex), offset: \(String(format: "0x%016llx", r))  index: \(cccccc)")
                address = (vmAddress[Int(segmentIndex)] &+ r)
                printf("    address = \(String(format: "0x%016llx", address))")
                break
            case BIND_OPCODE_ADD_ADDR_ULEB:
                let r = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: ADD_ADDR_ULEB,                  \(address) += \(String(format: "0x%016llx", r))  index: \(cccccc)")
                address &+= r
                break
            case BIND_OPCODE_DO_BIND:
                printf("BIND_OPCODE: DO_BIND")
                await set(address: address, vaule: symbolName)
                bindCount += 1
                address &+= ptrSize
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
                let r = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: DO_BIND_ADD_ADDR_ULEB,          \(address) += \(ptrSize) + \(String(format: "%016llx", r))  index: \(cccccc)")
                await set(address: address, vaule: symbolName)
                bindCount += 1
                address &+= (ptrSize &+ r)
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
                printf("BIND_OPCODE: DO_BIND_ADD_ADDR_IMM_SCALED,    \(address) += \(ptrSize) * \((ptrSize * UInt64(immediate)))  index: \(cccccc)")
                await set(address: address, vaule: symbolName)
                bindCount += 1
                address &+= (ptrSize &+ (ptrSize * UInt64(immediate)))
                break
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
                let count = binary.read_uleb128(index: &index, end: end)
                let skip = binary.read_uleb128(index: &index, end: end)
                printf("BIND_OPCODE: DO_BIND_ULEB_TIMES_SKIPPING_ULEB, count: \(String(format: "%016llx", count)), skip: \(String(format: "%016llx", skip))  index: \(cccccc)")
                for _ in 0 ..< count {
                    await set(address: address, vaule: symbolName)
                    address &+= (ptrSize &+ skip)
                }
                bindCount += count
                break
            default:
                break
            }
        }
    }
    
    private static func set(address: UInt64, vaule newValue: String) async {
        var add = address
        if address > RVA {
            add = address - RVA
        }
        await MachOData.shared.dylbMap.set(String(add, radix: 16, uppercase: false), newValue)
    }
}
