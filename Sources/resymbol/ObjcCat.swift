//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/27.
//

import Foundation

struct ObjcCatData {
    let name: ClassName
    let _class: DataStruct
    let instanceMethods: Methods
    let classMethods: Methods
    let protocols: Protocols
    let instanceProperties: Properties
    
    func write() {
        if let s = swift_demangle(name.className.value) {
            print(name.name.address, s)
        } else {
            print(name.name.address, name.className.value)
        }
        print("--------------------------")
        if let properties = instanceProperties.properties {
            for item in properties {
                print("0x\(item.name.name.address) \(item.name.propertyName.value)")
            }
        }
        print("=========================")
        if let methods = instanceMethods.methods {
            for item in methods {
                print("0x\(item.implementation.value) \(item.name.methodName.value)")
            }
        }
        print("=========================")
        if let methods = classMethods.methods {
            for item in methods {
                print("0x\(item.implementation.value) \(item.name.methodName.value)")
            }
        }
        print("=========================")
        if let methods = protocols.protocols {
            for item in methods {
                print("0x\(item.pointer.address) \(item.pointer.value)")
            }
        }
        print("\n")
    }
}
