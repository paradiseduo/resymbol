//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/30.
//

import Foundation

class MachOData {
    static let shared = MachOData()
    var binary = Data()
    var dylbMap = [String: String]()
    
    private init() {}
}
