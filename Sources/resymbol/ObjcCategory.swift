//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/27.
//

import Foundation

struct ObjcCategory {
    let name: ClassName
    let classs: DataStruct
    let instanceMethods: Methods
    let classMethods: Methods
    let protocols: Protocols
    let instanceProperties: Properties
    let v7: DataStruct
    let v8: DataStruct
    
    static func OCCG(_ binary: Data, offset: Int) -> ObjcCategory {
        let name = ClassName.className(binary, startOffset: offset)
        let classs = DataStruct.data(binary, offset: offset+8, length: 8)
        let instanceMethods = Methods.methods(binary, startOffset: offset+16)
        let classMethods = Methods.methods(binary, startOffset: offset+24)
        let protocols = Protocols.protocols(binary, startOffset: offset+32)
        let instanceProperties = Properties.properties(binary, startOffset: offset+40)
        let v7 = DataStruct.data(binary, offset: offset+48, length: 8)
        let v8 = DataStruct.data(binary, offset: offset+56, length: 8)
        
        return ObjcCategory(name: name, classs: classs, instanceMethods: instanceMethods, classMethods: classMethods, protocols: protocols, instanceProperties: instanceProperties, v7: v7, v8: v8)
    }
    
    func write() {
        if let s = swift_demangle(name.className.value) {
            print(name.name.address, s)
        } else {
            print(name.name.address, name.className.value)
        }
        print("----------Properties----------")
        if let properties = instanceProperties.properties {
            for item in properties {
                print("0x\(item.name.name.address) \(item.name.propertyName.value)")
            }
        }
        print("==========Instance Method==========")
        if let methods = instanceMethods.methods {
            for item in methods {
                print("0x\(item.implementation.value) \(item.name.methodName.value)")
            }
        }
        print("==========Class Method==========")
        if let methods = classMethods.methods {
            for item in methods {
                print("0x\(item.implementation.value) \(item.name.methodName.value)")
            }
        }
        print("==========Protocols==========")
        if let methods = protocols.protocols {
            for item in methods {
                print("0x\(item.pointer.address) \(item.pointer.value)")
            }
        }
        print("\n")
    }
}
