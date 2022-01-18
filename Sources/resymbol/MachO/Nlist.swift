//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/17.
//

import Foundation

//_OBJC_IVAR_$_
//
//_OBJC_METACLASS_$_
//__OBJC_METACLASS_RO_$_
//
//__OBJC_$_PROP_LIST_
//
//__OBJC_$_CATEGORY_BaseClass_$__CategoryName
//__OBJC_$_CATEGORY_INSTANCE_METHODS_BaseClass_$_CategoryName
//__OBJC_$_CATEGORY_CLASS_METHODS_BaseClass_$_CategoryName
//__OBJC_CATEGORY_PROTOCOLS_$_BaseClass_$_ProtocolName
//
//
//_OBJC_CLASS_$_
//__OBJC_CLASS_RO_$_
//__OBJC_CLASS_PROTOCOLS_$_
//
//__OBJC_$_CLASS_PROP_LIST_
//__OBJC_$_CLASS_METHODS_
//__OBJC_$_INSTANCE_VARIABLES_
//__OBJC_$_INSTANCE_METHODS_
//
//
//__OBJC_PROTOCOL_$_
//__OBJC_LABEL_PROTOCOL_$_
//__OBJC_PROTOCOL_REFERENCE_$_
//
//__OBJC_$_PROTOCOL_REFS_
//__OBJC_$_PROTOCOL_CLASS_METHODS_
//__OBJC_$_PROTOCOL_METHOD_TYPES_
//__OBJC_$_PROTOCOL_INSTANCE_METHODS_
//__OBJC_$_PROTOCOL_INSTANCE_METHODS_OPT_

let symbolPrefix = ["_OBJC_IVAR_$_",
                    "_OBJC_METACLASS_$_",
                    "__OBJC_METACLASS_RO_$_",
                    "__OBJC_$_PROP_LIST_",
                    "_OBJC_CLASS_$_",
                    "__OBJC_CLASS_RO_$_",
                    "__OBJC_CLASS_PROTOCOLS_$_",
                    "__OBJC_$_CLASS_PROP_LIST_",
                    "__OBJC_$_CLASS_METHODS_",
                    "__OBJC_$_INSTANCE_VARIABLES_",
                    "__OBJC_$_INSTANCE_METHODS_",
                    "__OBJC_PROTOCOL_$_",
                    "__OBJC_LABEL_PROTOCOL_$_",
                    "__OBJC_PROTOCOL_REFERENCE_$_",
                    "__OBJC_$_PROTOCOL_REFS_",
                    "__OBJC_$_PROTOCOL_CLASS_METHODS_",
                    "__OBJC_$_PROTOCOL_METHOD_TYPES_",
                    "__OBJC_$_PROTOCOL_INSTANCE_METHODS_OPT_",
                    "__OBJC_$_PROTOCOL_INSTANCE_METHODS_",
                    "__OBJC_$_CATEGORY_INSTANCE_METHODS_",
                    "__OBJC_$_CATEGORY_CLASS_METHODS_",
                    "__OBJC_CATEGORY_PROTOCOLS_$_",
                    "__OBJC_$_CATEGORY_"]


struct Nlist {
    let stringTableIndex: DataStruct
    let type: DataStruct
    let sectionIndex: DataStruct
    let description: DataStruct
    let valueAddress: DataStruct
    var name: String
    
    static func nlist(_ binary: Data, offset: Int) -> Nlist {
        let stringTableIndex = DataStruct.data(binary, offset: offset, length: 4)
        let type = DataStruct.data(binary, offset: offset+4, length: 1)
        let sectionIndex = DataStruct.data(binary, offset: offset+5, length: 1)
        let description = DataStruct.data(binary, offset: offset+6, length: 2)
        let valueAddress = DataStruct.data(binary, offset: offset+8, length: 8)
        let name = (MachOData.shared.stringTable.get(stringTableIndex.value) as? String) ?? ""
        return Nlist(stringTableIndex: stringTableIndex, type: type, sectionIndex: sectionIndex, description: description, valueAddress: valueAddress, name: name)
    }
}


func symbolName(_ name: String) -> String {
    if name.contains("_$_") {
        for item in symbolPrefix {
            if name.hasPrefix(item) {
                return name.replacingOccurrences(of: item, with: "")
            }
        }
    }
    return name
}
