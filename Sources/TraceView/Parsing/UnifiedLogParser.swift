import Foundation

/// Parses JSON output from `log show --style json` and `log stream --style json`.
/// Each entry is a JSON object with keys: timestamp, messageType, processImagePath,
/// category, subsystem, eventMessage, etc.
struct UnifiedLogParser: LogParser {
    let name = "Unified Log (JSON)"
    let supportedExtensions: Set<String> = ["json"]

    func canParse(sampleLines: [String]) -> Double {
        // Check if it looks like unified log JSON output
        // Could be an array wrapper or individual JSON objects
        let joined = sampleLines.prefix(5).joined()

        // Look for key unified log fields
        if joined.contains("messageType") && joined.contains("eventMessage") {
            return 0.9
        }
        if joined.contains("processImagePath") && joined.contains("subsystem") {
            return 0.85
        }
        return 0.0
    }

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[],"))

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: treat as plain text
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: .info,
                message: line, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }

        let timestamp = parseTimestamp(json["timestamp"] as? String)
        let level = parseMessageType(json["messageType"] as? String)
        let message = (json["eventMessage"] as? String) ?? ""
        let process = (json["processImagePath"] as? String)
            .map { ($0 as NSString).lastPathComponent }
        let subsystem = json["subsystem"] as? String
        let category = json["category"] as? String
        let threadID = (json["threadID"] as? Int).map { String($0) }

        // Use subsystem:category as component if available, otherwise process
        let component: String?
        if let sub = subsystem, !sub.isEmpty {
            if let cat = category, !cat.isEmpty {
                component = "\(sub):\(cat)"
            } else {
                component = sub
            }
        } else {
            component = process
        }

        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: timestamp, level: level,
            message: message, component: component,
            threadID: threadID, source: nil, rawLine: line
        )
    }

    // Cached per-format parsers. The previous per-call DateFormatter
    // allocation was the dominant cost in bulk-parsing unified log files —
    // 100K allocations for a 100K-line export.
    private static let timestampFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss.SSSSSSZ",
         "yyyy-MM-dd HH:mm:ss.SSSZ",
         "yyyy-MM-dd HH:mm:ssZ",
         "yyyy-MM-dd HH:mm:ss.SSSSSS",
         "yyyy-MM-dd HH:mm:ss"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    private func parseTimestamp(_ str: String?) -> Date? {
        guard let str else { return nil }
        // Unified log timestamp format: "2026-04-06 10:23:01.442000-0700"
        for formatter in Self.timestampFormatters {
            if let date = formatter.date(from: str) { return date }
        }
        return nil
    }

    private func parseMessageType(_ type: String?) -> LogLevel {
        switch type?.lowercased() {
        case "fault": return .critical
        case "error": return .error
        case "default": return .notice
        case "info": return .info
        case "debug": return .debug
        default: return .info
        }
    }
}
