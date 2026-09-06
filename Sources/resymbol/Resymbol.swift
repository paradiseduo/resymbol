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
    
    @Flag(name: .shortAndLong, help: "Dump Symbol Table. If used with -c maybe slowly.")
    var symbol = false
    
    @Flag(name: .shortAndLong, help: "Dump Class. If used with -s maybe slowly.")
    var `class` = false

    @Flag(name: .long, help: "List architectures in a fat/universal Mach-O and exit.")
    var listArches = false

    @Flag(name: .long, help: "List deterministic symbol-restoration candidates and exit.")
    var candidates = false

    @Flag(name: .long, help: "Show a read-only symbol-restoration plan and exit.")
    var symbolPlan = false

    @Flag(name: .long, help: "Show the validated nlist/string-table rebuild layout and exit.")
    var symbolLayout = false

    @Flag(name: .long, help: "Show the new-file symbol-table patch plan and exit.")
    var symbolPatchPlan = false

    @Option(name: .long, help: "Write a rebuilt symbol table to this new output file.")
    var writeSymbols: String?

    @Option(name: .long, help: "Read extra exact symbols from a JSON array of name/address records.")
    var jsonSymbols: String?

    @Option(name: .long, help: "Architecture to select from a fat/universal Mach-O (default: arm64).")
    var arch: String?
    
    mutating func run() throws {
        if ipa {
            ConsoleIO.writeMessage("IPA input is not supported yet; extract the arm64 Mach-O first.", .error)
            running = false
            return
        } else {
            FileManager.open(machoPath: filePath, backup: false) { data in
                if let binary = data {
                    if MachOFat.isFat(binary) {
                        if writeSymbols != nil {
                            ConsoleIO.writeMessage("Symbol writing currently requires a thin Mach-O input", .error)
                            running = false
                            return
                        }
                        guard let architectures = MachOFat.architectures(in: binary), !architectures.isEmpty else {
                            ConsoleIO.writeMessage("Invalid fat/universal Mach-O structure", .error)
                            running = false
                            return
                        }
                        if listArches {
                            for architecture in architectures {
                                print("\(architecture.name) (offset: \(architecture.offset), size: \(architecture.size))")
                            }
                            running = false
                            return
                        }
                        guard let selected = MachOFat.select(architectures, name: arch) else {
                            ConsoleIO.writeMessage("Requested architecture '\(arch ?? "")' was not found", .error)
                            running = false
                            return
                        }
                        processThin(Data(selected.data))
                    } else {
                        processThin(binary)
                    }
                } else {
                    running = false
                }
            }
        }
    }

    private func processThin(_ binary: Data) {
                    if candidates || symbolPlan || symbolLayout || symbolPatchPlan || writeSymbols != nil || jsonSymbols != nil {
                        guard let file = MachOFile.parse(binary) else {
                            ConsoleIO.writeMessage("Invalid 64-bit Mach-O structure", .error)
                            running = false
                            return
                        }
                        let dynamic = DynamicSymbolModelParser.parse(binary, machOFile: file)
                        let externalCandidates: [RecoveredSymbolCandidate]
                        if let jsonSymbols {
                            guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: jsonSymbols)) else {
                                print("json-symbols: unable to read \(jsonSymbols)")
                                running = false
                                return
                            }
                            externalCandidates = RecoveredSymbolCandidate.externalJSON(jsonData)
                        } else {
                            externalCandidates = []
                        }
                        if let writeSymbols {
                            let sourceURL = URL(fileURLWithPath: filePath).standardizedFileURL
                            let outputURL = URL(fileURLWithPath: writeSymbols).standardizedFileURL
                            guard sourceURL != outputURL,
                                  !FileManager.default.fileExists(atPath: outputURL.path),
                                  let layout = RecoveredSymbolInventory.writeLayout(data: binary, file: file,
                                                                                   dynamicSymbols: dynamic,
                                                                                   externalCandidates: externalCandidates) else {
                                print("symbol-write: unavailable (output must be a new path)")
                                running = false
                                return
                            }
                            do {
                                let rebuilt = try RecoveredSymbolWriter.materialize(data: binary, file: file,
                                                                                      dynamicSymbols: dynamic,
                                                                                      layout: layout)
                                try rebuilt.write(to: outputURL, options: .atomic)
                                if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
                                   let permissions = attributes[.posixPermissions] {
                                    try? FileManager.default.setAttributes([.posixPermissions: permissions],
                                                                            ofItemAtPath: outputURL.path)
                                }
                                print("symbol-write: \(outputURL.path)")
                            } catch {
                                print("symbol-write: failed (\(error))")
                            }
                            running = false
                            return
                        }
                        if symbolPlan {
                            let plan = RecoveredSymbolInventory.plan(data: binary, file: file,
                                                                      dynamicSymbols: dynamic,
                                                                      externalCandidates: externalCandidates)
                            print("candidates: \(plan.candidates.count)")
                            print("existing: \(plan.existingCount)")
                            print("new: \(plan.newCount)")
                            print("export-only: \(plan.exportOnlyCount)")
                            print("estimated-string-bytes: \(plan.estimatedStringBytes)")
                            running = false
                            return
                        }
                        if symbolLayout {
                            guard let layout = RecoveredSymbolInventory.writeLayout(data: binary, file: file,
                                                                                    dynamicSymbols: dynamic,
                                                                                    externalCandidates: externalCandidates) else {
                                print("symbol-layout: unavailable")
                                running = false
                                return
                            }
                            print("entries: \(layout.entries.count)")
                            print("local-range: \(layout.localRange.lowerBound)..<\(layout.localRange.upperBound)")
                            print("external-range: \(layout.externalDefinedRange.lowerBound)..<\(layout.externalDefinedRange.upperBound)")
                            print("undefined-range: \(layout.undefinedRange.lowerBound)..<\(layout.undefinedRange.upperBound)")
                            print("string-bytes: \(layout.stringTable.count)")
                            print("nlist-bytes: \(layout.serializedNListData(byteSwapped: file.isByteSwapped).count)")
                            print("requires-dysymtab-rewrite: \(layout.requiresDynamicSymbolTableRewrite)")
                            running = false
                            return
                        }
                        if symbolPatchPlan {
                            guard let layout = RecoveredSymbolInventory.writeLayout(data: binary, file: file,
                                                                                    dynamicSymbols: dynamic,
                                                                                    externalCandidates: externalCandidates),
                                  let patch = RecoveredSymbolPatchPlan.make(data: binary, file: file,
                                                                              layout: layout) else {
                                print("symbol-patch-plan: unavailable")
                                running = false
                                return
                            }
                            print("symtab-command-offset: \(patch.symbolTableCommandOffset)")
                            print("dysymtab-command-offset: \(patch.dynamicSymbolTableCommandOffset ?? -1)")
                            print("new-symoff: \(patch.symbolTableFileOffset)")
                            print("new-stroff: \(patch.stringTableFileOffset)")
                            print("new-nsyms: \(patch.symbolCount)")
                            print("new-strsize: \(patch.stringTableSize)")
                            print("output-size: \(patch.outputSize)")
                            print("requires-dysymtab-rewrite: \(patch.requiresDynamicSymbolTableRewrite)")
                            running = false
                            return
                        }
                        // Candidate inspection must show the same complete
                        // inventory that the plan/writer use, including
                        // address-proven ObjC runtime metadata discoveries.
                        for candidate in RecoveredSymbolInventory.build(data: binary, file: file,
                                                                         dynamicSymbols: dynamic,
                                                                         includeMetadata: true,
                                                                         externalCandidates: externalCandidates) {
                            let sources = candidate.sources.map(\.rawValue).sorted().joined(separator: ",")
                            print(String(format: "0x%016llx %@ [%@] %@",
                                         candidate.address, candidate.name, sources,
                                         candidate.confidence == .exact ? "exact" : "inferred"))
                        }
                        running = false
                        return
                    }
                    let fh = binary.extract(fat_header.self)
                    BitType.checkType(machoPath: filePath, header: fh) { type, isByteSwapped in
                        if symbol {
                            if `class` {
                                Section.readSection(binary, type: type, isByteSwapped: isByteSwapped, symbol: symbol) { result in
                                    running = false
                                }
                            } else {
                                Section.dumpSymbol(binary, type: type, isByteSwapped: isByteSwapped) { result in
                                    running = false
                                }
                            }
                        } else {
                            Section.readSection(binary, type: type, isByteSwapped: isByteSwapped) { result in
                                running = false
                            }
                        }
                    }
    }
}
