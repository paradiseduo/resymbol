//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/4.
//

import Foundation

// primitive types:
// * gets turned into ^c (i.e. char *)
// T_NAMED_OBJECT w/ _typeName as the name
// @ - id
// { - structure w/ _typeName, members
// ( - union     w/ _typeName, members
// b - bitfield  w/ _bitfieldSize          - can these occur anywhere, or just in structures/unions?
// [ - array     w/ _arraySize, _subtype
// ^ - poiner to _subtype
// C++ template type...

// Primitive types:
// c: char
// i: int
// s: short
// l: long
// q: long long
// C: unsigned char
// I: unsigned int
// S: unsigned short
// L: unsigned long
// Q: unsigned long long
// f: float
// d: double
// D: long double
// B: _Bool // C99 _Bool or C++ bool
// v: void
// #: Class
// :: SEL
// %: NXAtom
// ?: void
//case '?': return @"UNKNOWN" // For easier regression testing.
// j: _Complex - is this a modifier or a primitive type?
//
// modifier (which?) w/ _subtype.  Can we limit these to the top level of the type?
//   - n - in
//   - N - inout
//   - o - out
//   - O - bycopy
//   - R - byref
//   - V - oneway
// const is probably different from the previous modifiers.  You can have const int * const foo, or something like that.
//   - r - const

func grepStructName(_ type: String) -> String {
    if type.hasPrefix("^{") || type.hasPrefix("{") {
        let strArray = Array(type).map { c in
            return String(c)
        }
        var index = 0
        var name = ""
        while index < strArray.count {
            let item = strArray[index]
            if item == "=" || item == "}" {
                return name + "}"
            } else {
                name += item
                index += 1
            }
        }
    }
    return type
}

func primitiveType(_ type: String) -> String {
    if type.count == 0 {
        return "MISSING_TYPE"
    }
    if type == None {
        return "Swift.Type"
    }
    var result = ""
    let grepType = grepStructName(type)
    var strArray = Array(grepType).map { c in
        return String(c)
    }
    // 合并同类项
    if strArray.count > 1 {
        var index = 0
        while index < strArray.count {
            let item = strArray[index]
            index += 1
            if index >= strArray.count {
                break
            }
            if item == "@" || item == "^" {
                if strArray[index] == "?" {
                    strArray[index-1] = String(item)+String(strArray[index])
                    // 空值补位
                    strArray[index] = ""
                }
            }
            if item == "@" {
                if strArray[index] == "\"" {
                    strArray[index] = ""
                    var name = ""
                    index += 1
                    for j in index..<strArray.count {
                        if strArray[j] == "\"" {
                            strArray[j] = ""
                            strArray[index-2] = "@\"" + name + "\""
                            index = j
                            index += 1
                            break
                        } else {
                            name += strArray[j]
                            // 空值补位
                            strArray[j] = ""
                        }
                    }
                }
            }
        }
        // 过滤空值
        strArray = strArray.filter { c in
            return c.count > 0
        }
    }
    
    // 将所有^移动到最后，不然*会跑到前面去[(void *)会变为(* void)]
    var lastNonZeroFoundAt = 0
    for i in 0..<strArray.count {
        if strArray[i] != "^" {
            strArray.swapAt(lastNonZeroFoundAt, i)
            lastNonZeroFoundAt+=1
        }
    }
    
    var index = 0
    while index < strArray.count {
        let item = strArray[index]
        index += 1
        switch item {
        case "{":
            var hasFound = false
            var count = 1
            var name = ""
            for j in index..<strArray.count {
                if strArray[j] == "{" {
                    count += 1
                }
                if strArray[j] == "}" {
                    count -= 1
                    if count == 0 {
                        index = j
                        index += 1
                        break
                    }
                }
                if !hasFound {
                    if strArray[j] == "=" {
                        hasFound = true
                    } else {
                        name += strArray[j]
                    }
                }
            }
            result += "struct" + " " + checkType(name)
        case "@?":
            if strArray.count > 1 {
                var returnType = ""
                var blockType = ""
                var j = index
                while j < strArray.count {
                    if strArray[j] == "<" {
                        j += 1
                        for k in j..<strArray.count {
                            if strArray[k] != "@?" {
                                returnType += checkType(strArray[k]) + " "
                            } else {
                                j = k
                                j += 1
                                returnType = returnType.trimmingCharacters(in: CharacterSet.whitespaces)
                                break
                            }
                        }
                    } else if strArray[j] == ">" {
                        index = j
                        index += 1
                        break
                    } else {
                        blockType += checkType(strArray[j]) + " "
                        j += 1
                    }
                }
                result += returnType + "(^)" + "(\(blockType.trimmingCharacters(in: CharacterSet.whitespaces)))"
            } else {
                result += checkType(item)
            }
        default:
            result += checkType(item)
        }
        result += " "
    }
    result = result.trimmingCharacters(in: CharacterSet.whitespaces)
    return result
}


func checkType(_ item: String) -> String {
    if item.hasPrefix("@\"") && item.hasSuffix("\"") {
        if item.contains("<") && item.contains(">") {
            // 代理属性
            return "id <" + getTypeFromMangledName(item.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")) + "> *"
        } else {
            // 其他属性
            return getTypeFromMangledName(item.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "\"", with: "")) + " *"
        }
    } else {
        switch item {
        case "*":
            return "STR"
        case "@":
            return "id"
        case "{":
            return "struct"
        case "(":
            return "union"
        case "b":
            return "bitfield"
        case "[":
            return "array"
        case "^":
            return "*"
        case "c":
            return"char"
        case "i":
            return "int"
        case "s":
            return "short"
        case "l":
            return "long"
        case "q":
            return "long long"
        case "C":
            return "unsigned char"
        case "I":
            return "unsigned int"
        case "S":
            return "unsigned short"
        case "L":
            return "unsigned long"
        case "Q":
            return "unsigned long long"
        case "f":
            return "float"
        case "d":
            return "double"
        case "D":
            return "long double"
        case "B":
            return "bool"
        case "v":
            return "void"
        case "?":
            return "Void"
        case "#":
            return "Class"
        case ":":
            return "SEL"
        case "%":
            return "NXAtom"
        case "j":
            return "_Complex"
        case "n":
            return "in"
        case "N":
            return "inout"
        case "o":
            return "out"
        case "O":
            return "bycopy"
        case "R":
            return "byref"
        case "V":
            return "oneway"
        case "r":
            return "const"
        case "A":
            return "_Atomic"
        case "@?":
            return "Block"
        case "<":
            return "("
        case ">":
            return ")"
        case "^?":
            return "Pointer"
        default:
            return item
        }
    }
}
