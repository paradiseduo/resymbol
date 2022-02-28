//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

extension Int {
    func string16() -> String {
        return String(format: "%08x", self)
    }
    
    func alignment() -> Int {
        if self % 4 != 0 {
            return self - self%4
        }
        return self
    }
}
