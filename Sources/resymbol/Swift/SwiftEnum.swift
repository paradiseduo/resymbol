//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct SwiftEnum {
    let flags: DataStruct
    let parent: DataStruct
    let name: DataStruct
    let accessFunction: DataStruct
    let fieldDescriptor: FieldDescriptor
    let numPayloadCasesAndPayloadSizeOffset: DataStruct
    let numEmptyCases: DataStruct
}
