//
//  ConsleIO.swift
//  converter
//
//  Created by paradiseduo on 2021/11/26.
//

import Foundation

let DEBUG_FLAG = false

enum OutputType {
    case error
    case standard
    case debug
}

struct ConsoleIO {
    static func writeMessage(_ message: Any, _ to: OutputType = .standard) {
        switch to {
            case .standard:
                print(message)
            case .debug:
                debugPrintf(message)
            case .error:
                fputs("Error: \(message)\n", stderr)
                exit(-10)
        }
    }
    
    static func debugPrintf(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        if DEBUG_FLAG {
            var i = 0
            let j = items.count
            for item in items {
                debugPrint(item, terminator: i == j ? terminator: separator)
                i += 1
            }
            debugPrint()
        }
    }
}
