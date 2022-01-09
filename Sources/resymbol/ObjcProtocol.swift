//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/28.
//

import Foundation

struct ObjcProtocol {
    let isa: DataStruct
    let name: ClassName
    let protocols: Protocols
    let instanceMethods: Methods
    let classMethods: Methods
    let optionalInstanceMethods: Methods
    let optionalClassMethods: Methods
    let instanceProperties: Properties
    let size: DataStruct
    let flag: DataStruct
    let extendedMethodTypes: MethodTypes
    
    static func OCPT(_ binary: Data, offset: Int) -> ObjcProtocol {
        let isa = DataStruct.data(binary, offset: offset, length: 8)
        let name = ClassName.className(binary, startOffset: offset+8)
        let protocols = Protocols.protocols(binary, startOffset: offset+16)
        
        let instanceProperties = Properties.properties(binary, startOffset: offset+56)
        let size = DataStruct.data(binary, offset: offset+64, length: 4)
        let flag = DataStruct.data(binary, offset: offset+68, length: 4)
        
        // 这里判断是否具有附加属性
        let hasExtendedMethodTypes = size.value.int16() > (8 * MemoryLayout<UInt64>.size + 2 * MemoryLayout<UInt32>.size)
        let extendedMethodTypes = MethodTypes.methodTypes(binary, offset: offset+72)
        var typeOffset = extendedMethodTypes.types.value.int16Replace()
        
        // 先判断附加属性再生产method的数组，不然要生成两边，浪费时间
        let instanceMethods = Methods.methods(binary, startOffset: offset+24, hasExtendedMethodTypes: hasExtendedMethodTypes, typeOffSet: &typeOffset)
        let classMethods = Methods.methods(binary, startOffset: offset+32, hasExtendedMethodTypes: hasExtendedMethodTypes, typeOffSet: &typeOffset)
        let optionalInstanceMethods = Methods.methods(binary, startOffset: offset+40, hasExtendedMethodTypes: hasExtendedMethodTypes, typeOffSet: &typeOffset)
        let optionalClassMethods = Methods.methods(binary, startOffset: offset+48, hasExtendedMethodTypes: hasExtendedMethodTypes, typeOffSet: &typeOffset)
        
        return ObjcProtocol(isa: isa, name: name, protocols: protocols, instanceMethods: instanceMethods, classMethods: classMethods, optionalInstanceMethods: optionalInstanceMethods, optionalClassMethods: optionalClassMethods, instanceProperties: instanceProperties, size: size, flag: flag, extendedMethodTypes: extendedMethodTypes)
    }
    
    func write() {
        if let s = swift_demangle(name.className.value) {
            print(isa.address, s)
        } else {
            print(isa.address, name.className.value)
        }
        print("----------Properties----------")
        if let properties = instanceProperties.properties {
            for item in properties {
                print("0x\(item.name.name.address) \(item.serialization())")
            }
        }
        print("==========Class Method==========")
        if let methods = classMethods.methods {
            for item in methods {
                print("\(item.serialization(isClass: true))")
            }
        }
        print("==========Optional Class Method==========")
        if let methods = optionalClassMethods.methods {
            for item in methods {
                print("\(item.serialization(isClass: true))")
            }
        }
        print("==========Instance Method==========")
        if let methods = instanceMethods.methods {
            for item in methods {
                print("\(item.serialization(isClass: false))")
            }
        }
        print("==========Optional Instance Method==========")
        if let methods = optionalInstanceMethods.methods {
            for item in methods {
                print("\(item.serialization(isClass: false))")
            }
        }
        print("\n")
    }
}
