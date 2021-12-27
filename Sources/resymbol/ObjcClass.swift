//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/21.
//

import Foundation

struct ObjcClass {
    let isa: DataStruct
    let superClass: DataStruct
    let cache: DataStruct
    let cacheMask: DataStruct
    let cacheOccupied: DataStruct
    let classData: DataStruct
    let reserved1: DataStruct
    let reserved2: DataStruct
    let reserved3: DataStruct
    let classRO: ObjcClassRO
    
    static func OC(_ binary: Data, offset: Int) -> ObjcClass {
        let isa = DataStruct.data(binary, offset: offset, length: 8)
        let superClass = DataStruct.data(binary, offset: offset+8, length: 8)
        let cache = DataStruct.data(binary, offset: offset+16, length: 8)
        let cacheMask = DataStruct.data(binary, offset: offset+24, length: 4)
        let cacheOccupied = DataStruct.data(binary, offset: offset+28, length: 4)
        let classData = DataStruct.data(binary, offset: offset+32, length: 8)
        let reserved1 = DataStruct.data(binary, offset: offset+40, length: 8)
        let reserved2 = DataStruct.data(binary, offset: offset+48, length: 8)
        let reserved3 = DataStruct.data(binary, offset: offset+56, length: 8)
        
        var offsetCD = classData.value.int16Replace()
        if offsetCD % 4 != 0 {
            offsetCD -= offsetCD%4
        }
        
        let classRO = ObjcClassRO.OCRO(binary, offset: offsetCD)
        
        return ObjcClass.init(isa: isa, superClass: superClass, cache: cache, cacheMask: cacheMask, cacheOccupied: cacheOccupied, classData: classData, reserved1: reserved1, reserved2: reserved2, reserved3: reserved3, classRO: classRO)
    }
    
    func write() {
        if let s = swift_demangle(classRO.name.className.value) {
            print(isa.address, s)
        } else {
            print(isa.address, classRO.name.className.value)
        }
        print("--------------------------")
        if let properties = classRO.baseProperties.properties {
            for item in properties {
                print("0x\(item.name.name.address) \(item.name.propertyName.value)")
            }
        }
        print("=========================")
        if let methods = classRO.baseMethod.methods {
            for item in methods {
                print("0x\(item.implementation.value) \(item.name.methodName.value)")
            }
        }
        print("\n")
    }
}

struct ObjcClassRO {
    let flags: Flags
    let instanceStart: DataStruct
    let instanceSize: DataStruct
    let reserved: DataStruct
    let ivarlayout: DataStruct
    let name: ClassName
    let baseMethod: Methods
    let baseProtocol: Protocols
    let ivars: InstanceVariables
    let weakIvarLayout: DataStruct
    let baseProperties: Properties
    
    static func OCRO(_ binary: Data, offset: Int) -> ObjcClassRO {
        let flags = Flags.flags(binary, startOffset: offset)
        let instanceStart = DataStruct.data(binary, offset: offset+4, length: 4)
        let instanceSize = DataStruct.data(binary, offset: offset+8, length: 4)
        let reserved = DataStruct.data(binary, offset: offset+12, length: 4)
        let ivarlayout = DataStruct.data(binary, offset: offset+16, length: 8)
        let name = ClassName.className(binary, startOffset: offset+24)

        let baseMethod = Methods.methods(binary, startOffset: offset+32)
        let baseProtocol = Protocols.protocols(binary, startOffset: offset+40)
        let ivars = InstanceVariables.instances(binary, startOffset: offset+48)
        let weakIvarLayout = DataStruct.data(binary, offset: offset+56, length: 8)
        let baseProperties = Properties.properties(binary, startOffset: offset+64)
        
        return ObjcClassRO.init(flags: flags, instanceStart: instanceStart, instanceSize: instanceSize, reserved: reserved, ivarlayout: ivarlayout, name: name, baseMethod: baseMethod, baseProtocol: baseProtocol, ivars: ivars, weakIvarLayout: weakIvarLayout, baseProperties: baseProperties)
    }
}

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
}

struct ObjcCategory {
    let name: ClassName
    let classs: DataStruct
    let instanceMethods: Methods
    let classMethods: Methods
    let protocols: Protocols
    let instanceProperties: Properties
    let v7: DataStruct
    let v8: DataStruct
}
