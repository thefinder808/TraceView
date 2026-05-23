import Foundation

// Parses macOS `.diag` diagnostic reports (CPU/disk/memory spin reports,
// LM Studio hangs, VM diagnostics, etc.) found under
// /Library/Logs/DiagnosticReports/.
//
// Format: a readable header block, then a free-form body.
//
//   Date/Time:        2026-04-19 19:54:17.532 -0500
//   End time:         2026-04-19 19:54:37.267 -0500
//   OS Version:       macOS 26.4.1 (Build 25E253)
//   <free-form body>
//
// The header "Date/Time" line carries the base timestamp for the report.
// We parse it once and apply it to every subsequent body line so the
// timestamp column isn't empty while scrolling the diagnostic details.
struct DiagParser: LogParser {
    let name = "Diagnostic Report"
    let supportedExtensions: Set<String> = ["diag"]

    func canParse(sampleLines: [String]) -> Double {
        // Detect by looking for the "Date/Time:" header in the first few
        // lines — very specific to this format.
        for line in sampleLines.prefix(3) {
            if line.hasPrefix("Date/Time:") { return 0.9 }
        }
        return 0
    }

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        // Line-by-line fallback — shouldn't be called since parseFile
        // handles .diag files.
        LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: nil, level: .info,
            message: line, component: nil,
            threadID: nil, source: nil, rawLine: line
        )
    }

    func parseFile(lines: [String], startingEntryID: Int) -> (entries: [LogEntry], nextID: Int)? {
        // Find the Date/Time: line in the header block (usually line 0).
        let headerTimestamp = findDateTime(in: lines.prefix(20))
        guard headerTimestamp != nil else { return nil }

        var entries: [LogEntry] = []
        entries.reserveCapacity(lines.count)
        var nextID = startingEntryID

        for (idx, line) in lines.enumerated() where !line.isEmpty {
            // If a line has its own Date/Time field (rare, but some .diag
            // reports include event-level timestamps in the body), prefer
            // that. Otherwise inherit the header timestamp.
            let ts = extractInlineTimestamp(from: line) ?? headerTimestamp
            let level = detectDiagLevel(line)
            entries.append(LogEntry(
                id: nextID, lineNumber: idx + 1,
                timestamp: ts, level: level,
                message: line, component: nil,
                threadID: nil, source: nil, rawLine: line
            ))
            nextID += 1
        }

        return (entries, nextID)
    }

    // MARK: - Helpers

    private func findDateTime<S: Sequence>(in lines: S) -> Date? where S.Element == String {
        for line in lines where line.hasPrefix("Date/Time:") {
            let value = line.dropFirst("Date/Time:".count).trimmingCharacters(in: .whitespaces)
            if let d = parseTimestamp(value) { return d }
        }
        return nil
    }

    // Some .diag body lines begin with an ISO-ish timestamp — if one is
    // present, use it so the histogram can show time ranges within the
    // report instead of collapsing everything into a single moment.
    private func extractInlineTimestamp(from line: String) -> Date? {
        // Match a leading YYYY-MM-DD HH:MM:SS[.SSS][ TZ] prefix.
        guard line.count >= 19 else { return nil }
        let prefix = String(line.prefix(30))
        let pattern = #"^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:\s*[+-]\d{4})?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let r = Range(match.range(at: 1), in: prefix)
        else { return nil }
        return parseTimestamp(String(prefix[r]))
    }

    // "2026-04-19 19:54:17.532 -0500" and nearby permutations.
    private func parseTimestamp(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for fmt in [
            "yyyy-MM-dd HH:mm:ss.SSS Z",
            "yyyy-MM-dd HH:mm:ss.SS Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss.SS",
            "yyyy-MM-dd HH:mm:ss",
        ] {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    // Light-touch level detection — .diag files don't have structured
    // severity, but certain keywords signal problems worth highlighting.
    private func detectDiagLevel(_ line: String) -> LogLevel {
        let lower = line.lowercased()
        if lower.contains("panic") || lower.contains("fatal") { return .critical }
        if lower.contains("error") || lower.contains("failed") || lower.contains("crash") { return .error }
        if lower.contains("warning") || lower.contains("hang") || lower.contains("stuck") { return .warning }
        return .info
    }
}
