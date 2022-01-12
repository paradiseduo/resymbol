//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

struct FieldRecord {
    let flags: DataStruct
    let mangledTypeName: DataStruct
    let fieldName: DataStruct
}

struct FieldDescriptor {
    let mangledTypeName: DataStruct
    let superclass: DataStruct
    let kind: DataStruct
    let fieldRecordSize: DataStruct
    let numFields: DataStruct
    let fieldRecords: [FieldRecord]
}
