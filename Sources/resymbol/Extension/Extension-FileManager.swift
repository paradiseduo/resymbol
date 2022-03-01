//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

extension FileManager {
    static func open(machoPath: String, backup: Bool, handle: (Data?)->()) {
        do {
            if FileManager.default.fileExists(atPath: machoPath) {
                if backup {
                    let backUpPath = "./\(machoPath.components(separatedBy: "/").last!)_back"
                    if FileManager.default.fileExists(atPath: backUpPath) {
                        try FileManager.default.removeItem(atPath: backUpPath)
                    }
                    try FileManager.default.copyItem(atPath: machoPath, toPath: backUpPath)
                    ConsoleIO.writeMessage("Backup machO file \(backUpPath)")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: machoPath))
                handle(data)
            } else {
                ConsoleIO.writeMessage("MachO file not exist !", .error)
                handle(nil)
            }
        } catch let err {
            ConsoleIO.writeMessage(err, .error)
            handle(nil)
        }
    }
}
