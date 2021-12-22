//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/21.
//

import Foundation

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
    let baseMethod: Methods
    let baseProtocol: Protocols
    let ivars: InstanceVariables
    let weakIvarLayout: DataStruct
    let baseProperties: Properties
    
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
        print("name:\n \tAddress:\(name.0.address)\t Data:\(name.0.data)\t DataString:\(name.0.dataString)\t Value:\(name.0.value)\t Class:\(name.1)")
        print("baseMethod:\n \tAddress:\(baseMethod.baseMethod)\t ElementSize:\(baseMethod.elementSize)\t ElementCount:\(baseMethod.elementCount)\t Method:\(baseMethod.methods)")
        print("baseProtocol:\n \tAddress:\(baseProtocol.baseProtocol)\t Count:\(baseProtocol.count)\t Protocols:\(baseProtocol.protocols)")
        print("ivars:\n \tAddress:\(ivars.ivars)\t ElementSize:\(ivars.elementSize)\t ElementCount:\(ivars.elementCount)\t InstanceVariables:\(ivars.instanceVariables)")
        print("weakIvarLayout:\n \tAddress:\(weakIvarLayout.address)\t Data:\(weakIvarLayout.data)\t DataString:\(weakIvarLayout.dataString)\t Value:\(weakIvarLayout.value)")
        print("baseProperties:\n \tAddress:\(baseProperties.baseProperties)\t ElementSize:\(baseProperties.elementSize)\t ElementCount:\(baseProperties.elementCount)\t InstanceVariables:\(baseProperties.properties)")
        print("\n")
    }
}
