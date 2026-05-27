import Foundation

/// Wraps the macOS `log stream` command to capture real-time unified log output as JSON.
/// Batches incoming lines and flushes to the callback on a 100ms timer to avoid
/// overwhelming SwiftUI with per-chunk updates.
final class UnifiedLogStream {
    private var process: Process?
    private var outputPipe: Pipe?
    private var stderrPipe: Pipe?
    private let bufferQueue = DispatchQueue(label: "com.traceview.logstream.buffer")
    private var pendingLines: [String] = []
    private var flushTimer: DispatchSourceTimer?
    /// Set true when `stop()` is called so the terminationHandler doesn't
    /// surface a fake error for a clean user-initiated quit.
    private var stoppedExplicitly = false

    var onNewLines: (([String]) -> Void)?
    /// Fired when `/usr/bin/log stream` can't start or exits early with a
    /// non-zero status. Argument is a user-readable message — typically
    /// the captured stderr text plus the exit code. Called on an
    /// arbitrary thread; caller is responsible for hopping to the main
    /// queue before touching UI state.
    var onError: ((String) -> Void)?

    func start(predicate: String? = nil, level: String = "default") {
        stop()
        stoppedExplicitly = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")

        // `ndjson` emits one complete JSON object per line, which is what
        // UnifiedLogParser.parse(line:) expects. Plain `json` style on
        // recent macOS pretty-prints each entry across many lines, so the
        // parser would see {"source":null,\n  "formatString":"...",\n ...}
        // as separate lines and fall through to the plain-text path —
        // visible symptom: "All System" shows thousands of INFO entries
        // with no timestamps and each line is one field fragment.
        var args = ["stream", "--style", "ndjson", "--level", level]
        if let predicate {
            args += ["--predicate", predicate]
        }
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        // Capture stderr instead of discarding to /dev/null so we can
        // surface the real reason when `log` rejects the invocation —
        // e.g. on a managed work Mac where the user lacks the
        // entitlement to read system-wide events with a predicate.
        let stderr = Pipe()
        proc.standardError = stderr
        outputPipe = pipe
        stderrPipe = stderr

        // Start batch flush timer (100ms interval)
        let timer = DispatchSource.makeTimerSource(queue: bufferQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.flushPendingLines()
        }
        timer.resume()
        flushTimer = timer

        var lineBuffer = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self, bufferQueue] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            bufferQueue.sync {
                lineBuffer += text
                var lines = lineBuffer.components(separatedBy: .newlines)
                lineBuffer = lines.removeLast()

                let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                self?.pendingLines.append(contentsOf: nonEmpty)
            }
        }

        // Detect early exit / non-zero status. `log stream` is supposed
        // to run forever — any termination we didn't request via stop()
        // is a failure to surface. We snapshot status + stderr off the
        // handler's arbitrary thread, then hop to main to read
        // `stoppedExplicitly` — start()/stop() both run on main, so
        // serializing the check there avoids a race against a
        // simultaneous user-initiated stop.
        proc.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let stderrText = (try? stderr.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self, !self.stoppedExplicitly else { return }
                self.onError?(Self.formatExitError(status: status, stderr: stderrText))
            }
        }

        process = proc

        do {
            try proc.run()
        } catch {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            stderrPipe = nil
            flushTimer?.cancel()
            flushTimer = nil
            process = nil
            // Clear the termination handler so it doesn't fire later
            // and double-report against a process that never ran.
            proc.terminationHandler = nil
            onError?("Failed to launch /usr/bin/log: \(error.localizedDescription)")
        }
    }

    private static func formatExitError(status: Int32, stderr: String) -> String {
        if stderr.isEmpty {
            return "log stream exited unexpectedly (status \(status))"
        }
        return "log stream failed (status \(status)): \(stderr)"
    }

    private func flushPendingLines() {
        // Already on bufferQueue
        guard !pendingLines.isEmpty else { return }
        let batch = pendingLines
        pendingLines.removeAll(keepingCapacity: true)

        DispatchQueue.main.async { [weak self] in
            self?.onNewLines?(batch)
        }
    }

    func stop() {
        stoppedExplicitly = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        flushTimer?.cancel()
        flushTimer = nil
        // Detach the handler first so a clean terminate() doesn't trip
        // the unexpected-exit path against our own teardown.
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
        stderrPipe = nil
        pendingLines.removeAll()
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    deinit {
        stop()
    }
}
