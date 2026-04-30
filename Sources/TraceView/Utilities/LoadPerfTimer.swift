#if DEBUG
import Foundation
import os.signpost

/// DEBUG-only timer for measuring the open/load path's phase breakdown.
///
/// Created at the top of `LogDocument.loadFile`, marked at each phase
/// boundary, and printed once via `summary()` after first paint. The same
/// phase boundaries are also emitted as `os_signpost` intervals so
/// Instruments' OS Signpost track can render them as a flame-chart-style
/// timeline correlated with CPU samples.
///
/// Subsystem: `com.traceview.app`, category: `load`. Filter Instruments by
/// category to isolate load events.
///
/// **Thread-safety:** `mark()` is called from BOTH the main actor (the
/// outer `loadFile` body) AND the detached parse task (the phases that
/// live inside the closure). An `NSLock` serializes the single-line
/// internal mutations. Lock contention is negligible at the call rate
/// (~8 marks per load).
///
/// **Time semantics:** uses `ProcessInfo.processInfo.systemUptime`, which
/// is monotonic wall-clock time. A phase blocked on I/O looks like time
/// spent in that phase — the right semantic for "time to first paint" but
/// don't compare phases as CPU benchmarks across machines. The signpost
/// track + Time Profiler in Instruments gives CPU/wall correlation when
/// needed.
///
/// **Release safety:** the entire file lives inside `#if DEBUG` so the
/// type does not exist in release binaries. Every call site MUST be
/// wrapped in `#if DEBUG` too — a bare reference outside `#if DEBUG`
/// would fail to compile in release. Verified by `./build.sh release`.
final class LoadPerfTimer: @unchecked Sendable {
    let label: String
    private let signposter: OSSignposter
    private var phases: [(name: String, ms: Double)] = []
    private var lastMark: TimeInterval
    private let started: TimeInterval
    private var activeInterval: (name: String, state: OSSignpostIntervalState)?
    private let lock = NSLock()

    init(label: String) {
        self.label = label
        self.signposter = OSSignposter(subsystem: "com.traceview.app", category: "load")
        let now = ProcessInfo.processInfo.systemUptime
        self.started = now
        self.lastMark = now
    }

    /// Records elapsed since the last `mark` (or `init`) under the given
    /// phase name, then ends the prior signpost interval and begins a new
    /// one keyed on `phase`. Safe to call from any thread.
    func mark(_ phase: String) {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsedMs = (now - lastMark) * 1000.0
        phases.append((name: phase, ms: elapsedMs))
        lastMark = now

        endActiveIntervalLocked()
        let signpostName: StaticString = "phase"
        // self. is required: OSLogMessage is a closure type, and Swift
        // requires explicit self capture for properties referenced inside.
        let state = signposter.beginInterval(signpostName, "phase=\(phase) label=\(self.label)")
        activeInterval = (name: phase, state: state)
    }

    /// Prints a one-line summary of all phases in execution order to stdout
    /// and ends any active signpost interval. Safe to call from any thread.
    ///
    /// Format:
    /// ```
    /// [label]  phase1 12ms · phase2 547ms · phase3 89ms · TOTAL 648ms
    /// ```
    func summary() {
        lock.lock()
        defer { lock.unlock() }

        endActiveIntervalLocked()

        let totalMs = (ProcessInfo.processInfo.systemUptime - started) * 1000.0
        let body = phases
            .map { "\($0.name) \(formatMs($0.ms))" }
            .joined(separator: " · ")
        // Write to stderr (unbuffered by default on Darwin) so the timing
        // line is visible even when launched via `open` or via AppleScript
        // where stdout is redirected/closed and would block-buffer prints
        // until exit (when buffered data is often lost on SIGTERM).
        let line = "[\(label)]  \(body) · TOTAL \(formatMs(totalMs))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func endActiveIntervalLocked() {
        if let active = activeInterval {
            signposter.endInterval("phase", active.state)
            activeInterval = nil
        }
    }

    private func formatMs(_ ms: Double) -> String {
        // Sub-millisecond phases round to 0ms which is fine and readable;
        // larger phases get integer ms with no decimals to keep the line
        // narrow and visually scannable.
        return "\(Int(ms.rounded()))ms"
    }
}
#endif
