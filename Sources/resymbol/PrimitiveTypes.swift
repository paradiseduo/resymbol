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
//case '?': return @"UNKNOWN"; // For easier regression testing.
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

func primitiveType(_ type: String) -> String {
    switch type {
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
        return "char"
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
    case "v", "?":
        return "void"
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
    case "^?":
        return "Pointer"
    default:
        return ""
    }
}
