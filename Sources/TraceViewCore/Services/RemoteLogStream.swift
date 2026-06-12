import Foundation

/// Streams a remote log by spawning `/usr/bin/ssh` and reading the stdout of
/// a remote follow command (`tail -F`, `journalctl -f`, …). Mirrors
/// `UnifiedLogStream`'s shape — `onNewLines` callback, 100ms batch flush,
/// `start`/`stop`/`deinit` — and adds connection-state reporting plus
/// auto-reconnect with exponential backoff so a deploy/reboot doesn't
/// silently kill the tail.
///
/// Auth rides entirely on the OS ssh client: `~/.ssh` keys, ssh-agent,
/// `known_hosts`, `~/.ssh/config`. We pass `BatchMode=yes` so a missing key
/// fails fast instead of hanging on a password prompt, and we never disable
/// `StrictHostKeyChecking` — an untrusted host fails with an actionable
/// message rather than opening a MITM window.
final class RemoteLogStream {
    private let bufferQueue = DispatchQueue(label: "com.traceview.remotestream.buffer")

    private var connection: RemoteConnection?
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var flushTimer: DispatchSourceTimer?

    private var pendingLines: [String] = []
    private var lineBuffer = ""
    private var stderrBuffer = ""

    /// Bumped on every (re)launch and on stop(). Stale termination handlers
    /// and delayed callbacks compare against it and bail if it moved.
    private var generation = 0
    private var isStopped = false
    /// True once the CURRENT attempt has confirmed a session.
    private var hasConnected = false
    /// True once ANY attempt in this start() session has connected. Gates
    /// follow-only reconnects (no backlog replay) and disables the initial-
    /// connect attempt cap (an established connection retries indefinitely).
    private var everConnected = false
    private var reconnectAttempt = 0

    /// Give up on a NEVER-connected target after this many failed attempts
    /// so a typo'd/unreachable host that doesn't emit a recognized fatal
    /// error can't spin forever. Once connected, reconnects are unbounded.
    private static let maxInitialConnectAttempts = 6

    var onNewLines: (([String]) -> Void)?
    var onStateChange: ((RemoteConnectionState) -> Void)?

    // MARK: - Lifecycle

    func start(connection: RemoteConnection) {
        stop()
        bufferQueue.async { [weak self] in
            guard let self else { return }
            self.connection = connection
            self.isStopped = false
            self.everConnected = false
            self.reconnectAttempt = 0
            self.launch()
        }
    }

    func stop() {
        bufferQueue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.generation &+= 1
            self.teardownProcess()
            self.pendingLines.removeAll()
            self.lineBuffer = ""
            self.stderrBuffer = ""
        }
    }

    var isRunning: Bool { process?.isRunning ?? false }

    deinit {
        // deinit can't safely bounce through the async queue; tear down directly.
        flushTimer?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
    }

    // MARK: - Launch (runs on bufferQueue)

    private func launch() {
        guard let connection, case .ssh(let cfg) = connection.kind else { return }
        teardownProcess()
        hasConnected = false
        lineBuffer = ""
        stderrBuffer = ""
        generation &+= 1
        let gen = generation

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = Self.sshArguments(for: cfg, followOnly: everConnected)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        outputPipe = outPipe
        errorPipe = errPipe

        let timer = DispatchSource.makeTimerSource(queue: bufferQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.flushPendingLines() }
        timer.resume()
        flushTimer = timer

        outPipe.fileHandleForReading.readabilityHandler = { [weak self, bufferQueue] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            bufferQueue.async {
                guard let self, self.generation == gen else { return }
                self.lineBuffer += text
                var lines = self.lineBuffer.components(separatedBy: .newlines)
                self.lineBuffer = lines.removeLast()
                let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                self.pendingLines.append(contentsOf: nonEmpty)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self, bufferQueue] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            bufferQueue.async {
                guard let self, self.generation == gen else { return }
                self.stderrBuffer += text
            }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.bufferQueue.async {
                guard self.generation == gen, !self.isStopped else { return }
                self.handleTermination()
            }
        }

        process = proc
        emitState(.connecting)

        do {
            try proc.run()
        } catch {
            teardownProcess()
            emitState(.failed("Could not launch ssh: \(error.localizedDescription)"))
            return
        }

        // Treat the session as connected once it has stayed up briefly without
        // a fatal exit — auth succeeded even if the log is currently silent.
        bufferQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.generation == gen, !self.isStopped else { return }
            if self.process?.isRunning == true, !self.hasConnected {
                self.markConnected()
            }
        }
    }

    private func handleTermination() {
        // Drain any stderr still buffered in the pipe BEFORE teardown. The
        // stderr readabilityHandler delivers asynchronously and has no
        // ordering guarantee against this termination handler, so the final
        // chunk (e.g. "Permission denied") that decides fatal-vs-transient
        // may not have arrived yet. Without this drain, a permanent auth /
        // host-key failure can be misclassified as transient and reconnect
        // forever. The child's stderr write end is closed (it has exited),
        // so this read returns immediately.
        if let errFH = errorPipe?.fileHandleForReading {
            errFH.readabilityHandler = nil
            let remaining = errFH.readDataToEndOfFile()
            if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
                stderrBuffer += text
            }
        }
        flushPendingLines()
        let stderr = stderrBuffer
        teardownProcess()

        if let fatal = Self.fatalMessage(from: stderr) {
            emitState(.failed(fatal))
            return
        }

        reconnectAttempt += 1

        // A target that has never connected and isn't emitting a recognized
        // fatal error (e.g. an unreachable IP that just times out) gives up
        // after a bounded number of tries instead of spinning forever. An
        // already-established connection is exempt — it reconnects unbounded.
        if !everConnected && reconnectAttempt > Self.maxInitialConnectAttempts {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            emitState(.failed(detail.isEmpty
                ? "Could not connect after several attempts. Check the host, path, and that your key is loaded (ssh-add)."
                : detail))
            return
        }

        // Transient (network blip, sshd restart, reboot). Reconnect with backoff.
        let delay = Self.backoffDelay(attempt: reconnectAttempt)
        emitState(.reconnecting)
        let gen = generation
        bufferQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == gen, !self.isStopped else { return }
            self.launch()
        }
    }

    private func markConnected() {
        hasConnected = true
        everConnected = true
        reconnectAttempt = 0
        emitState(.connected)
    }

    private func teardownProcess() {
        flushTimer?.cancel()
        flushTimer = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        outputPipe = nil
        errorPipe = nil
    }

    // MARK: - Flush (runs on bufferQueue)

    private func flushPendingLines() {
        guard !pendingLines.isEmpty else { return }
        let batch = pendingLines
        pendingLines.removeAll(keepingCapacity: true)
        if !hasConnected { markConnected() }
        DispatchQueue.main.async { [weak self] in
            self?.onNewLines?(batch)
        }
    }

    private func emitState(_ state: RemoteConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    // MARK: - SSH argv + error classification

    static func sshArguments(for cfg: SSHConfig, followOnly: Bool = false) -> [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-T",
        ]
        if let port = cfg.port {
            args += ["-p", String(port)]
        }
        args.append(cfg.target)
        args.append(cfg.effectiveRemoteCommand(followOnly: followOnly))
        return args
    }

    /// Returns an actionable message for errors that retrying won't fix, or
    /// nil if the failure looks transient (so the caller should reconnect).
    static func fatalMessage(from stderr: String) -> String? {
        let s = stderr.lowercased()
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") {
            return "Host not trusted. Connect once in Terminal (ssh \u{2026}) to add it to known_hosts, then retry."
        }
        if s.contains("permission denied") {
            return "Authentication failed. Add your key with `ssh-add`, or check the username/host."
        }
        if s.contains("could not resolve hostname") || s.contains("name or service not known") {
            return "Could not resolve host. Check the target (and ~/.ssh/config)."
        }
        if s.contains("bad configuration") || (s.contains("no such file or directory") && s.contains("identityfile")) {
            return "SSH configuration error:\n\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return nil
    }

    static func backoffDelay(attempt: Int) -> TimeInterval {
        let capped = min(max(attempt, 1), 6)         // 2^5 = 32 → clamped to 30 below
        return min(30, pow(2.0, Double(capped - 1))) // 1, 2, 4, 8, 16, 30, 30…
    }
}
