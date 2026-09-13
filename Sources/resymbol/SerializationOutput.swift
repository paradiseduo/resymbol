import Foundation

enum ResymbolParseMode {
    case objectiveC
    case swift
    case both

    var includesObjectiveC: Bool { self != .swift }
    var includesSwift: Bool { self != .objectiveC }
}

enum SerializationOutputKind {
    case objectiveCClass
    case objectiveCProtocol
    case objectiveCExtension
    case swiftClass
    case swiftStruct
    case swiftEnum
    case swiftProtocol
    case swiftExtension
    case swiftBlock
    case swiftBuiltin
    case swiftOther

    var languageDirectory: String {
        switch self {
        case .objectiveCClass, .objectiveCProtocol, .objectiveCExtension: return "OC"
        default: return "Swift"
        }
    }

    var typeDirectory: String {
        switch self {
        case .objectiveCClass, .swiftClass: return "class"
        case .objectiveCProtocol, .swiftProtocol: return "protocol"
        case .objectiveCExtension, .swiftExtension: return "Extension"
        case .swiftStruct: return "struct"
        case .swiftEnum: return "enum"
        case .swiftBlock: return "block"
        case .swiftBuiltin: return "builtin"
        case .swiftOther: return "other"
        }
    }

    var fileExtension: String {
        languageDirectory == "OC" ? "h" : "swift"
    }
}

/// Routes serialized declarations either to stdout or to one file per type.
/// Parsing can call serializers concurrently, so collection is synchronized.
enum SerializationOutput {
    private static let lock = NSLock()
    private static var directory: URL?
    private static var mode: ResymbolParseMode = .both
    private static var progress: ProgressDisplay?
    private static var files = [String: String]()
    private static var stdoutBuffer = String()
    private static var stdoutBatching = false

    static func begin(directory: URL?, mode: ResymbolParseMode = .both,
                      progress: ProgressDisplay? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        self.directory = directory
        self.mode = mode
        self.progress = progress
        files.removeAll(keepingCapacity: true)
        stdoutBuffer.removeAll(keepingCapacity: true)
        stdoutBatching = false
        if let directory {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        }
    }

    static func emit(_ text: String, kind: SerializationOutputKind, name: String) {
        if stdoutBatching, directory == nil {
            stdoutBuffer.append(text)
            stdoutBuffer.append("\n")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if kind.languageDirectory == "OC" && !mode.includesObjectiveC { return }
        if kind.languageDirectory == "Swift" && !mode.includesSwift { return }
        guard let directory else {
            // `print(text)` historically added one separator newline after
            // each declaration; preserve that exact output while avoiding
            // one stdout syscall per Swift type.
            stdoutBuffer.append(text)
            stdoutBuffer.append("\n")
            return
        }

        let safe = safeFileName(name)
        let relative = "\(kind.languageDirectory)/\(kind.typeDirectory)/\(safe).\(kind.fileExtension)"
        // A descriptor and a compatibility record can describe the same type.
        // Prefer the richer declaration if both target one output file.
        if let old = files[relative], old.count >= text.count { return }
        files[relative] = text
        progress?.advance()
        _ = directory
    }

    /// Swift declarations are serialized after all parser workers have
    /// joined. Allow that single-threaded phase to append directly to the
    /// stdout buffer instead of taking one lock per declaration.
    static func beginStdoutBatch() {
        lock.lock()
        stdoutBatching = directory == nil
        lock.unlock()
    }

    static func endStdoutBatch() {
        lock.lock()
        stdoutBatching = false
        lock.unlock()
    }

    /// Flushes the collected declarations. Returns the number of files written.
    static func finish() -> Result<Int, Error> {
        lock.lock()
        let root = directory
        let pending = files
        let output = stdoutBuffer
        directory = nil
        progress = nil
        files.removeAll(keepingCapacity: true)
        stdoutBuffer.removeAll(keepingCapacity: true)
        stdoutBatching = false
        lock.unlock()

        guard let root else {
            if !output.isEmpty { FileHandle.standardOutput.write(Data(output.utf8)) }
            return .success(0)
        }
        do {
            for (relative, text) in pending {
                let url = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            return .success(pending.count)
        } catch {
            return .failure(error)
        }
    }

    private static func safeFileName(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let allowed = (v >= 48 && v <= 57) ||
                (v >= 65 && v <= 90) ||
                (v >= 97 && v <= 122) ||
                v == 46 || v == 95 || v == 45 || v == 43
            return allowed ? Character(scalar) : "_"
        }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "unnamed" : result
    }
}
