//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/7.
//

import ArgumentParser
import Foundation
import MachO

let version = "2.0.0"

struct Resymbol: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "resymbol v\(version)",
        discussion: "Parse Objective-C/Swift metadata and restore 64-bit Mach-O symbols",
        version: version)

    @Argument(help: "The 64-bit Mach-O file to parse.")
    var filePath: String

    @Flag(name: .long, help: "Parse Objective-C declarations only.")
    var objc = false

    @Flag(name: .long, help: "Parse Swift declarations only.")
    var swift = false

    @Option(name: .long, help: "Export recovered symbols as a JSON array to this file.")
    var json: String?

    @Flag(name: .long, help: "Restore symbols in place; use --restore-output to write a separate Mach-O.")
    var restoreSymbols = false

    @Option(name: .long, help: "Write restored symbols to this new Mach-O; the input is unchanged and not backed up.")
    var restoreOutput: String?

    @Option(name: .long, help: "Write parsed declarations below this directory instead of stdout.")
    var outputDir: String?

    @Flag(name: .long, help: "Show progress for directory output and symbol restoration.")
    var verbose = false

    mutating func run() throws {
        guard !(objc && swift) else {
            throw ValidationError("--objc and --swift are mutually exclusive")
        }
        let mode: ResymbolParseMode = objc ? .objectiveC : (swift ? .swift : .both)
        let restoreRequested = restoreSymbols
        guard restoreOutput == nil || restoreRequested else {
            throw ValidationError("--restore-output can only be used with --restore-symbols")
        }
        guard let input = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            throw ValidationError("Mach-O file does not exist or cannot be read: \(filePath)")
        }

        if MachOFat.isFat(input) {
            guard let architectures = MachOFat.architectures(in: input),
                  let selected = MachOFat.select(architectures, name: nil) else {
                throw ValidationError("Invalid fat/universal Mach-O")
            }
            if restoreRequested {
                throw ValidationError("Symbol restoration requires a thin Mach-O input")
            }
            try processThin(Data(selected.data), mode: mode, exportJSON: json,
                            restore: false, outputDirectory: outputDir,
                            verbose: verbose)
            return
        }

        try processThin(input, mode: mode, exportJSON: json,
                        restore: restoreRequested, outputDirectory: outputDir,
                        verbose: verbose)
    }

    private func processThin(_ binary: Data, mode: ResymbolParseMode,
                             exportJSON: String?, restore: Bool,
                             outputDirectory: String?, verbose: Bool) throws {
        guard let file = MachOFile.parse(binary) else {
            throw ValidationError("Invalid or unsupported Mach-O; only 64-bit images are supported")
        }
        if file.isEncrypted {
            throw ValidationError("Mach-O contains encrypted data (cryptid \(file.encryptionInfo?.cryptid ?? 0))")
        }

        if restore {
            try restoreSymbols(binary: binary, file: file, requestedOutput: restoreOutput,
                               verbose: verbose)
            return
        }

        if let exportJSON {
            guard outputDirectory == nil else {
                throw ValidationError("--json and --output-dir cannot be combined")
            }
            try exportSymbols(binary: binary, file: file, path: exportJSON)
            return
        }

        let progress = verbose && outputDirectory != nil ? ProgressDisplay() : nil
        try SerializationOutput.begin(directory: outputDirectory.map { URL(fileURLWithPath: $0) },
                                      mode: mode, progress: progress)
        let header = binary.extract(fat_header.self)
        BitType.checkType(machoPath: filePath, header: header) { type, isByteSwapped in
            Section.readSection(binary, type: type, isByteSwapped: isByteSwapped,
                                mode: mode, progress: progress) { result in
                if let outputDirectory {
                    switch SerializationOutput.finish() {
                    case .success(let count): print("output: \(count) files in \(outputDirectory)")
                    case .failure(let error): fputs("Error: unable to write output directory: \(error)\n", stderr)
                    }
                } else {
                    _ = SerializationOutput.finish()
                }
                progress?.finish(success: result)
                running = false
            }
        }
    }

    private struct ExportedSymbol: Encodable {
        let name: String
        let address: String
    }

    private func exportSymbols(binary: Data, file: MachOFile, path: String) throws {
        let dynamic = PerformanceProfile.measure("dynamic-symbol-parse") {
            DynamicSymbolModelParser.parse(binary, machOFile: file)
        }
        let candidates = PerformanceProfile.measure("candidate-discovery") {
            RecoveredSymbolInventory.build(data: binary, file: file,
                                           dynamicSymbols: dynamic,
                                           includeMetadata: true)
        }
        let records = candidates.map {
            ExportedSymbol(name: $0.name, address: String(format: "0x%016llx", $0.address))
        }
        let encoder = JSONEncoder()
        // Candidate ordering is deterministic; sort object keys as well so a
        // repeated export is byte-stable instead of depending on Dictionary's
        // randomized encoding order.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try PerformanceProfile.measureThrowing("json-encode") {
            try encoder.encode(records)
        }
        try PerformanceProfile.measureThrowing("json-write") {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("json: \(path) (\(records.count) symbols)")
        running = false
    }

    private func restoreSymbols(binary: Data, file: MachOFile, requestedOutput: String?,
                                verbose: Bool) throws {
        let progress = ProgressDisplay(enabled: verbose)
        progress.beginPhase("reading symbol model", base: 0.02, span: 0.08)
        guard let dynamic = PerformanceProfile.measure("dynamic-symbol-parse", {
            DynamicSymbolModelParser.parse(binary, machOFile: file)
        }) else {
            progress.finish(success: false)
            throw ValidationError("Unable to read a validated dynamic symbol table")
        }
        progress.completePhase()

        progress.beginPhase("scanning recovery candidates", base: 0.10, span: 0.55)
        guard let layout = PerformanceProfile.measure("symbol-layout", {
            RecoveredSymbolInventory.writeLayout(data: binary, file: file,
                                                 dynamicSymbols: dynamic)
        }) else {
            progress.finish(success: false)
            throw ValidationError("Unable to build a validated symbol-table layout")
        }
        progress.completePhase()

        progress.beginPhase("materializing symbol table", base: 0.65, span: 0.20)
        let rebuilt: Data
        do {
            rebuilt = try PerformanceProfile.measureThrowing("symbol-materialize") {
                try RecoveredSymbolWriter.materialize(data: binary, file: file,
                                                      dynamicSymbols: dynamic,
                                                      layout: layout)
            }
        } catch {
            progress.finish(success: false)
            throw ValidationError("Unable to materialize restored symbols: \(error)")
        }
        progress.completePhase()
        let inputURL = URL(fileURLWithPath: filePath).standardizedFileURL
        let outputURL: URL
        let writesInPlace: Bool
        if let requested = requestedOutput, !requested.isEmpty {
            outputURL = URL(fileURLWithPath: requested).standardizedFileURL
            writesInPlace = false
        } else {
            outputURL = inputURL
            writesInPlace = true
        }
        guard writesInPlace || outputURL != inputURL else {
            progress.finish(success: false)
            throw ValidationError("--restore-output must name a file different from the input")
        }
        guard writesInPlace || !FileManager.default.fileExists(atPath: outputURL.path) else {
            progress.finish(success: false)
            throw ValidationError("Output file already exists: \(outputURL.path)")
        }
        let sourcePermissions = (try? FileManager.default.attributesOfItem(atPath: inputURL.path))?[.posixPermissions]
        progress.beginPhase(writesInPlace ? "writing restored Mach-O in place" : "writing restored Mach-O",
                            base: 0.85, span: 0.15)
        do {
            try rebuilt.write(to: outputURL, options: .atomic)
        } catch {
            progress.finish(success: false)
            throw ValidationError("Unable to write restored Mach-O: \(error)")
        }
        if let sourcePermissions {
            try? FileManager.default.setAttributes([.posixPermissions: sourcePermissions],
                                                    ofItemAtPath: outputURL.path)
        }
        // Let Apple's tool remove the stale signature and its load command.
        // This also truncates the old signature blob and updates mach_header
        // fields exactly as codesign expects before a new signature is added.
        let removeSignature = Process()
        removeSignature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        removeSignature.arguments = ["--remove-signature", outputURL.path]
        removeSignature.standardOutput = FileHandle.nullDevice
        removeSignature.standardError = FileHandle.nullDevice
        do {
            try removeSignature.run()
            removeSignature.waitUntilExit()
            guard removeSignature.terminationStatus == 0 else {
                throw ValidationError("Unable to remove stale code signature")
            }
        } catch let error as ValidationError {
            progress.finish(success: false)
            throw error
        } catch {
            progress.finish(success: false)
            throw ValidationError("Unable to remove stale code signature: \(error)")
        }
        if writesInPlace {
            print("restored in place: \(outputURL.path)")
        } else {
            print("restored: \(outputURL.path)")
        }
        progress.completePhase()
        progress.finish()
        running = false
    }

}
