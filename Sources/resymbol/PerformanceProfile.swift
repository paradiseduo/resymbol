import Foundation

enum PerformanceProfile {
    static let enabled = ProcessInfo.processInfo.environment["RESYMBOL_PROFILE"] == "1"

    static func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        fputs("[profile] \(name): \(String(format: "%.3f", elapsed))s\n", stderr)
        return value
    }

    static func measureThrowing<T>(_ name: String, _ body: () throws -> T) throws -> T {
        guard enabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        fputs("[profile] \(name): \(String(format: "%.3f", elapsed))s\n", stderr)
        return value
    }

    static func report(_ name: String, start: UInt64, count: Int) {
        guard enabled else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        fputs("[profile] \(name): \(String(format: "%.3f", elapsed))s (\(count) items)\n", stderr)
    }
}
