//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/7.
//

import ArgumentParser
import Foundation
import MachO

let version = "1.0.0"

struct Resymbol: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "resymbol v\(version)", discussion: "Restore symbol", version: version)
    
    @Argument(help: "The machO/IPA to restore symbol.")
    var filePath: String
    
    @Flag(name: .shortAndLong, help: "If restore symbol ipa, please set this flag. Default false mean is machO file path.")
    var ipa = false
    
    mutating func run() throws {

        if ipa {
            
        } else {
            FileManager.open(machoPath: filePath, backup: false) { data in
                if let binary = data {
                    let fh = binary.extract(fat_header.self)
                    BitType.checkType(machoPath: filePath, header: fh) { type, isByteSwapped in
                        Section.readSection(binary, type: type, isByteSwapped: isByteSwapped) { result in
                            for var item in MachOData.shared.objcCategories {
                                item.mapName()
                                item.write()
                            }
                        }
                    }
                }
            }
        }
    }
    
}
