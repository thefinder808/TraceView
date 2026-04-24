import Foundation

// Parses modern macOS `.ips` crash reports (.ips = "incident prefix script",
// used for User/System/Kernel/Crash reports in ~/Library/Logs/DiagnosticReports
// and /Library/Logs/DiagnosticReports).
//
// Format:
//   Line 1: single-line JSON header with {"timestamp", "app_name", "bug_type",
//           "incident_id", "os_version", ...}.
//   Line 2+: pretty-printed JSON body with the full crash details (stack
//           trace, registers, binary images, etc.), spanning hundreds to
//           thousands of lines.
//
// The timestamp lives in the line-1 JSON, so line-by-line parsing can't
// propagate it to body lines — hence the parseFile hook. All entries share
// the header timestamp (the crash is a single point in time).
struct IPSParser: LogParser {
    let name = "IPS (Crash Report)"
    let supportedExtensions: Set<String> = ["ips"]

    func canParse(sampleLines: [String]) -> Double {
        // Detect by checking the first line: single-line JSON with both
        // "timestamp" and "bug_type" keys. Very specific — no false positives
        // against JSONL or other JSON logs.
        guard let first = sampleLines.first else { return 0 }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}"),
              trimmed.contains("\"timestamp\""),
              trimmed.contains("\"bug_type\"") else { return 0 }
        return 0.95
    }

    // Line-by-line fallback. Not normally called — parseFile handles .ips —
    // but provided for protocol conformance and as a safety net if somehow
    // parseFile returns nil.
    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: nil, level: .info,
            message: line, component: nil,
            threadID: nil, source: nil, rawLine: line
        )
    }

    func parseFile(lines: [String], startingEntryID: Int) -> (entries: [LogEntry], nextID: Int)? {
        guard let headerLine = lines.first,
              let data = headerLine.data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let timestamp = parseTimestamp(header["timestamp"] as? String)
        let appName = header["app_name"] as? String
        let bugType = header["bug_type"] as? String
        let incidentID = header["incident_id"] as? String
        let osVersion = header["os_version"] as? String
        let level = levelFromBugType(bugType)
        let component = appName

        var entries: [LogEntry] = []
        entries.reserveCapacity(lines.count + 4)
        var nextID = startingEntryID

        // Synthesize a summary entry at the top so users see the crash
        // context at a glance instead of having to read the raw JSON header.
        // Its lineNumber is 0 (synthetic) so it sorts before the header.
        let summary = [
            "\(appName ?? "?") — bug_type \(bugType ?? "?")",
            incidentID.map { "incident \($0)" },
            osVersion,
        ].compactMap { $0 }.joined(separator: " · ")
        entries.append(LogEntry(
            id: nextID, lineNumber: 0,
            timestamp: timestamp, level: level,
            message: summary, component: component,
            threadID: nil, source: "header", rawLine: summary
        ))
        nextID += 1

        // Emit every file line (including the JSON header line 1 and the
        // body). Each gets the same timestamp — the crash is a point in
        // time, not a stream. Users can scroll through the JSON body and
        // still see "when" in the timestamp column.
        for (idx, line) in lines.enumerated() where !line.isEmpty {
            entries.append(LogEntry(
                id: nextID, lineNumber: idx + 1,
                timestamp: timestamp, level: .info,
                message: line, component: component,
                threadID: nil, source: nil, rawLine: line
            ))
            nextID += 1
        }

        return (entries, nextID)
    }

    // MARK: - Helpers

    // The header timestamp is typically "YYYY-MM-DD HH:MM:SS.SS -0500" —
    // two-digit fractional seconds and a space-separated TZ.
    private func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        for fmt in [
            "yyyy-MM-dd HH:mm:ss.SS Z",   // "2026-04-16 08:48:56.00 -0500"
            "yyyy-MM-dd HH:mm:ss.SSS Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss.SS",
            "yyyy-MM-dd HH:mm:ss",
        ] {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // Map Apple's bug_type codes to severity. The full taxonomy is long;
    // these cover the common ones. Anything unknown defaults to .error
    // since a crash report exists = something bad happened.
    private func levelFromBugType(_ bugType: String?) -> LogLevel {
        switch bugType {
        case "109", "309":           return .error     // EXC_CRASH, generic crash
        case "110":                  return .critical  // Kernel panic
        case "111", "210", "211":    return .warning   // Hangs / spins
        case "288":                  return .warning   // JetsamEvent (memory pressure kill)
        case "298":                  return .notice    // CPU resource exception
        case "199", "305":           return .error     // Diagnostic / bad access
        case nil:                    return .info
        default:                     return .error
        }
    }
}
