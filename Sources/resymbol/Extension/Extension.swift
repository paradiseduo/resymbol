//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/9/10.
//

import Foundation

public func printf(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    if DEBUG_FLAG {
        var i = 0
        let j = items.count
        for item in items {
            print(item, terminator: i == j ? terminator: separator)
            i += 1
        }
        print()
    }
}
