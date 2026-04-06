import Foundation

/// Wraps the macOS `log stream` command to capture real-time unified log output as JSON.
/// Batches incoming lines and flushes to the callback on a 100ms timer to avoid
/// overwhelming SwiftUI with per-chunk updates.
final class UnifiedLogStream {
    private var process: Process?
    private var outputPipe: Pipe?
    private let bufferQueue = DispatchQueue(label: "com.traceview.logstream.buffer")
    private var pendingLines: [String] = []
    private var flushTimer: DispatchSourceTimer?

    var onNewLines: (([String]) -> Void)?

    func start(predicate: String? = nil, level: String = "default") {
        stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")

        var args = ["stream", "--style", "json", "--level", level]
        if let predicate {
            args += ["--predicate", predicate]
        }
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        outputPipe = pipe

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

        process = proc

        do {
            try proc.run()
        } catch {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            flushTimer?.cancel()
            flushTimer = nil
            process = nil
        }
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
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        flushTimer?.cancel()
        flushTimer = nil
        process?.terminate()
        process = nil
        outputPipe = nil
        pendingLines.removeAll()
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    deinit {
        stop()
    }
}
