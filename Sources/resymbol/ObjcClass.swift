//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/21.
//

import Foundation

struct DataStruct {
    let address: String
    let data: Data
    let dataString: String
    let value: String
    
    static func data(_ binary: Data, offset: Int, length: Int) -> DataStruct {
        let b = binary.subdata(in: Range<Data.Index>(NSRange(location: offset, length: length))!)
        return DataStruct(address: String(format: "%08x", offset), data: b, dataString: b.rawValue(), value: b.rawValueBig())
    }
}

struct ObjcClassData {
    let isa: DataStruct
    let superClass: DataStruct
    let cache: DataStruct
    let cacheMask: DataStruct
    let cacheOccupied: DataStruct
    let classData: DataStruct
    let flags: (DataStruct, [RO])
    let instanceStart: DataStruct
    let instanceSize: DataStruct
    let reserved: DataStruct
    let ivarlayout: DataStruct
    let name: (DataStruct, DataStruct)
    let baseMethod: DataStruct
    let baseProtocol: DataStruct
    let ivars: DataStruct
    let weakIvarLayout: DataStruct
    let baseProperties: DataStruct
    
    func description() {
        print("isa:\n\t Address:\(isa.address)\t Data:\(isa.data)\t DataString:\(isa.dataString)\t Value:\(isa.value)")
        print("superClass:\n\t Address:\(superClass.address)\t Data:\(superClass.data)\t DataString:\(superClass.dataString)\t Value:\(superClass.value)")
        print("cache:\n\t Address:\(cache.address)\t Data:\(cache.data)\t DataString:\(cache.dataString)\t Value:\(cache.value)")
        print("cacheMask:\n \tAddress:\(cacheMask.address)\t Data:\(cacheMask.data)\t DataString:\(cacheMask.dataString)\t Value:\(cacheMask.value)")
        print("cacheOccupied:\n \tAddress:\(cacheOccupied.address)\t Data:\(cacheOccupied.data)\t DataString:\(cacheOccupied.dataString)\t Value:\(cacheOccupied.value)")
        print("classData:\n \tAddress:\(classData.address)\t Data:\(classData.data)\t DataString:\(classData.dataString)\t Value:\(classData.value)")
        print("flags:\n \tAddress:\(flags.0.address)\t Data:\(flags.0.data)\t DataString:\(flags.0.dataString)\t Value:\(flags.0.value)\t RO:\(flags.1)")
        print("instanceStart:\n \tAddress:\(instanceStart.address)\t Data:\(instanceStart.data)\t DataString:\(instanceStart.dataString)\t Value:\(instanceStart.value)")
        print("instanceSize:\n \tAddress:\(instanceSize.address)\t Data:\(instanceSize.data)\t DataString:\(instanceSize.dataString)\t Value:\(instanceSize.value)")
        print("reserved:\n \tAddress:\(reserved.address)\t Data:\(reserved.data)\t DataString:\(reserved.dataString)\t Value:\(reserved.value)")
        print("ivarlayout:\n \tAddress:\(ivarlayout.address)\t Data:\(ivarlayout.data)\t DataString:\(ivarlayout.dataString)\t Value:\(ivarlayout.value)")
        print("name:\n \tAddress:\(name.0.address)\t Data:\(name.0.data)\t DataString:\(name.0.dataString)\t Value:\(name.0.value)\t ClassAddress:\(name.1.address)\t ClassData:\(name.1.data)\t ClassDataString:\(name.1.dataString)\t ClassValue:\(name.1.value)")
        print("baseMethod:\n \tAddress:\(baseMethod.address)\t Data:\(baseMethod.data)\t DataString:\(baseMethod.dataString)\t Value:\(baseMethod.value)")
        print("baseProtocol:\n \tAddress:\(baseProtocol.address)\t Data:\(baseProtocol.data)\t DataString:\(baseProtocol.dataString)\t Value:\(baseProtocol.value)")
        print("ivars:\n \tAddress:\(ivars.address)\t Data:\(ivars.data)\t DataString:\(ivars.dataString)\t Value:\(ivars.value)")
        print("weakIvarLayout:\n \tAddress:\(weakIvarLayout.address)\t Data:\(weakIvarLayout.data)\t DataString:\(weakIvarLayout.dataString)\t Value:\(weakIvarLayout.value)")
        print("baseProperties:\n \tAddress:\(baseProperties.address)\t Data:\(baseProperties.data)\t DataString:\(baseProperties.dataString)\t Value:\(baseProperties.value)")
        print("\n")
    }
}


struct RO {
    let rawValue : UInt8

    static let _META   = RO(rawValue: 1 << 0)
    static let _ROOT  = RO(rawValue: 1 << 1)
    static let _HAS_CXX_STRUCTORS  = RO(rawValue: 1 << 2)
    static let _HAS_LOAD_METHOD = RO(rawValue: 1 << 3)
    static let _HIDDEN = RO(rawValue: 1 << 4)
    static let _EXCEPTION = RO(rawValue: 1 << 5)
    static let _HAS_SWIFT_INITIALIZER = RO(rawValue: 1 << 6)
    static let _IS_ARC = RO(rawValue: 1 << 7)
    static let _HAS_CXX_DTOR_ONLY = RO(rawValue: 1 << 8)
    static let _HAS_WEAK_WITHOUT_ARC = RO(rawValue: 1 << 9)
    static let _FORBIDS_ASSOCIATED_OBJECTS = RO(rawValue: 1 << 10)
    static let _FROM_BUNDLE = RO(rawValue: 1 << 29)
    static let _FUTURE = RO(rawValue: 1 << 30)
    static let _REALIZED = RO(rawValue: 1 << 31)
    
    static func flags(_ data: Int) -> [RO] {
        var ro = [RO]()
        let er = String(data, radix: 2)
        for (i, item) in er.reversed().enumerated() {
            if item == "1" {
                switch i {
                case 0:
                    ro.append(_META)
                case 1:
                    ro.append(_ROOT)
                case 2:
                    ro.append(_HAS_CXX_STRUCTORS)
                case 3:
                    ro.append(_HAS_LOAD_METHOD)
                case 4:
                    ro.append(_HIDDEN)
                case 5:
                    ro.append(_EXCEPTION)
                case 6:
                    ro.append(_HAS_SWIFT_INITIALIZER)
                case 7:
                    ro.append(_IS_ARC)
                case 8:
                    ro.append(_HAS_CXX_DTOR_ONLY)
                case 9:
                    ro.append(_HAS_WEAK_WITHOUT_ARC)
                case 10:
                    ro.append(_FORBIDS_ASSOCIATED_OBJECTS)
                case 29:
                    ro.append(_FROM_BUNDLE)
                case 30:
                    ro.append(_FUTURE)
                case 31:
                    ro.append(_REALIZED)
                default:
                    continue
                }
            }
        }
        return ro
    }
}
