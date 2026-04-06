import Foundation

/// Wraps the macOS `log stream` command to capture real-time unified log output as JSON.
final class UnifiedLogStream {
    private var process: Process?
    private var outputPipe: Pipe?
    private let bufferQueue = DispatchQueue(label: "com.traceview.logstream.buffer")

    var onNewLines: (([String]) -> Void)?

    /// Start streaming unified log output.
    /// - Parameters:
    ///   - predicate: Optional NSPredicate-style filter (e.g., "subsystem == 'com.apple.bluetooth'")
    ///   - level: Minimum log level: "debug", "info", "default", "error", "fault"
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

        var lineBuffer = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self, bufferQueue] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            bufferQueue.sync {
                lineBuffer += text
                var lines = lineBuffer.components(separatedBy: .newlines)
                lineBuffer = lines.removeLast()

                let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !nonEmpty.isEmpty else { return }

                DispatchQueue.main.async {
                    self?.onNewLines?(nonEmpty)
                }
            }
        }

        process = proc

        do {
            try proc.run()
        } catch {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            process = nil
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    deinit {
        stop()
    }
}
