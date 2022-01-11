//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/21.
//

import Foundation

struct ObjcSuperClass {
    let superClass: DataStruct
    let superClassName: String
    
    static func OSC(_ binary: Data, offset: Int) -> ObjcSuperClass {
        let superClass = DataStruct.data(binary, offset: offset, length: 8)
        let superClassName = MachOData.shared.dylbMap.getReplace(address: superClass.address.ltrim("0")) ?? ""
        return ObjcSuperClass(superClass: superClass, superClassName: superClassName)
    }
}

struct ObjcClass {
    let isa: DataStruct
    let superClass: ObjcSuperClass
    let cache: DataStruct
    let cacheMask: DataStruct
    let cacheOccupied: DataStruct
    let classData: DataStruct
    let reserved1: DataStruct
    let reserved2: DataStruct
    let reserved3: DataStruct
    let classRO: ObjcClassRO
    var classMethods: Methods?
    let isSwiftClass: Bool
    
    static func OC(_ binary: Data, offset: Int) -> ObjcClass {
        let isa = DataStruct.data(binary, offset: offset, length: 8)
        let superClass = ObjcSuperClass.OSC(binary, offset: offset+8)
        let cache = DataStruct.data(binary, offset: offset+16, length: 8)
        let cacheMask = DataStruct.data(binary, offset: offset+24, length: 4)
        let cacheOccupied = DataStruct.data(binary, offset: offset+28, length: 4)
        let classData = DataStruct.data(binary, offset: offset+32, length: 8)
        let reserved1 = DataStruct.data(binary, offset: offset+40, length: 8)
        let reserved2 = DataStruct.data(binary, offset: offset+48, length: 8)
        let reserved3 = DataStruct.data(binary, offset: offset+56, length: 8)
        let isSwiftClass = (classData.value.int16Replace()&0x1 != 0)
        
        var offsetCD = classData.value.int16Replace()
        if offsetCD % 4 != 0 {
            offsetCD -= offsetCD%4
        }
        
        let classRO = ObjcClassRO.OCRO(binary, offset: offsetCD, isSwiftClass: isSwiftClass)
                
        return ObjcClass(isa: isa, superClass: superClass, cache: cache, cacheMask: cacheMask, cacheOccupied: cacheOccupied, classData: classData, reserved1: reserved1, reserved2: reserved2, reserved3: reserved3, classRO: classRO, classMethods: nil, isSwiftClass: isSwiftClass)
    }
    
    func write() {
        var result = "@interface \(classRO.name.className.value) \(superClass.superClassName.count > 0 ? ": \(superClass.superClassName)" : "") //0x\(isa.address)\n"
        if let instanceVariables = classRO.ivars.instanceVariables {
            result += "{\n"
            for item in instanceVariables {
                result += "\(item.serialization()) //0x\(item.offset.address)\n"
            }
            result += "}\n"
        }
        if let properties = classRO.baseProperties.properties {
            for item in properties {
                result += "\(item.serialization()) //0x\(item.name.name.address)\n"
            }
            result += "\n"
        }
        if let methods = classMethods?.methods {
            for item in methods {
                result += "\(item.serialization(isClass: true)) //0x\(item.implementation.value)\n"
            }
        }
        if let methods = classRO.baseMethod.methods {
            for item in methods {
                result += "\(item.serialization(isClass: false)) //0x\(item.implementation.value)\n"
            }
        }
        result += "@end\n"
        print(result)
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
    
    static func OCRO(_ binary: Data, offset: Int, isSwiftClass: Bool) -> ObjcClassRO {
        var typeOffset = 0
        let flags = Flags.flags(binary, startOffset: offset)
        let instanceStart = DataStruct.data(binary, offset: offset+4, length: 4)
        let instanceSize = DataStruct.data(binary, offset: offset+8, length: 4)
        let reserved = DataStruct.data(binary, offset: offset+12, length: 4)
        let ivarlayout = DataStruct.data(binary, offset: offset+16, length: 8)
        let name = ClassName.className(binary, startOffset: offset+24)
        
        let baseMethod = Methods.methods(binary, startOffset: offset+32, typeOffSet: &typeOffset)
        let baseProtocol = Protocols.protocols(binary, startOffset: offset+40)
        let ivars = InstanceVariables.instances(binary, startOffset: offset+48)
        let weakIvarLayout = DataStruct.data(binary, offset: offset+56, length: 8)
        let baseProperties = Properties.properties(binary, startOffset: offset+64)
        
        return ObjcClassRO(flags: flags, instanceStart: instanceStart, instanceSize: instanceSize, reserved: reserved, ivarlayout: ivarlayout, name: name, baseMethod: baseMethod, baseProtocol: baseProtocol, ivars: ivars, weakIvarLayout: weakIvarLayout, baseProperties: baseProperties)
    }
}


