//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/22.
//

import Foundation

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
