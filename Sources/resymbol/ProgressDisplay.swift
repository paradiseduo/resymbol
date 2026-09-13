import Foundation

/// Progress is deliberately written to stderr so declaration output and JSON
/// remain machine-readable on stdout/files. The timer keeps long metadata
/// scans visibly active even when a parser stage cannot expose safe sub-counts.
final class ProgressDisplay {
    private let enabled: Bool
    private let lock = NSLock()
    private let startedAt = Date()
    private var phaseName = "Starting"
    private var fraction = 0.0
    private var phaseCompleted = 0
    private var phaseTotal = 0
    private var phaseBase = 0.0
    private var phaseSpan = 1.0
    private var lastRender = Date.distantPast
    private var finished = false
    private var timer: DispatchSourceTimer?

    init(enabled: Bool = true) {
        self.enabled = enabled
        guard enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.render(force: true) }
        self.timer = timer
        timer.resume()
        render(force: true)
    }

    func beginPhase(_ name: String, completed: Int = 0, total: Int = 0,
                    base: Double, span: Double) {
        guard enabled else { return }
        lock.lock()
        phaseName = name
        phaseCompleted = max(0, completed)
        phaseTotal = max(0, total)
        phaseBase = min(1, max(0, base))
        phaseSpan = min(1 - phaseBase, max(0, span))
        fraction = phaseTotal > 0
            ? phaseBase + phaseSpan * min(1, Double(phaseCompleted) / Double(phaseTotal))
            : phaseBase
        lock.unlock()
        render(force: true)
    }

    func advance(_ count: Int = 1) {
        guard enabled else { return }
        lock.lock()
        phaseCompleted = min(phaseTotal, phaseCompleted + max(0, count))
        if phaseTotal > 0 {
            fraction = phaseBase + phaseSpan * min(1, Double(phaseCompleted) / Double(phaseTotal))
        }
        lock.unlock()
        render(force: false)
    }

    func completePhase() {
        guard enabled else { return }
        lock.lock()
        if phaseTotal > 0 {
            phaseCompleted = phaseTotal
            fraction = phaseBase + phaseSpan
        } else {
            fraction = phaseBase + phaseSpan
        }
        lock.unlock()
        render(force: true)
    }

    func finish(success: Bool = true) {
        guard enabled else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        fraction = success ? 1 : fraction
        let elapsed = Date().timeIntervalSince(startedAt)
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        let state = success ? "done" : "failed"
        writeMessage("\r\u{001B}[K[\(state)] 100% elapsed \(formatDuration(elapsed))\n")
    }

    private func render(force: Bool) {
        guard enabled else { return }
        lock.lock()
        if finished { lock.unlock(); return }
        let now = Date()
        if !force && now.timeIntervalSince(lastRender) < 0.15 {
            lock.unlock()
            return
        }
        lastRender = now
        let currentFraction = fraction
        let name = phaseName
        let completed = phaseCompleted
        let total = phaseTotal
        let elapsed = now.timeIntervalSince(startedAt)
        let eta: String
        if total > 0, currentFraction > 0.001, currentFraction < 0.999 {
            eta = " ETA \(formatDuration(elapsed * (1 - currentFraction) / currentFraction))"
        } else {
            eta = ""
        }
        lock.unlock()
        let count = total > 0 ? " \(completed)/\(total)" : (completed > 0 ? " \(completed) items" : "")
        let percent = String(format: "%3d", Int32(currentFraction * 100))
        writeMessage("\r\u{001B}[K[progress] \(percent)% \(name)\(count) elapsed \(formatDuration(elapsed))\(eta)")
    }

    private func writeMessage(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "\(value)s" }
        return "\(value / 60)m\(value % 60)s"
    }
}
