import Foundation

/// Parses JSON output from `log show --style ndjson` / `log stream --style ndjson`.
/// Each line is one JSON object with keys: timestamp, messageType, processImagePath,
/// category, subsystem, eventMessage, etc. `--style json` pretty-prints entries
/// across many lines and does NOT work with this parser.
struct UnifiedLogParser: LogParser {
    let name = "Unified Log (JSON)"
    let supportedExtensions: Set<String> = ["json"]

    func canParse(sampleLines: [String]) -> Double {
        // Search the full sample window — `log show --style json` pretty-
        // prints with a fixed key order where `messageType` is near the
        // top of each entry but `eventMessage` is ~20 lines later. An
        // early-lines-only check would miss pretty exports entirely (the
        // file would then fall through to PlainTextParser and render as
        // fragmented JSON).
        let joined = sampleLines.joined(separator: " ")

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
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: .info,
                message: line, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }
        return parseUnifiedEntry(json, lineNumber: lineNumber, entryID: entryID, rawLine: line)
    }

    /// Handles pretty-printed `log show --style json` exports, which are
    /// one big JSON array that can't be parsed line-by-line. Returns nil
    /// for NDJSON-per-line (handled by `parse(line:)`).
    func parseFile(lines: [String], startingEntryID: Int) -> (entries: [LogEntry], nextID: Int)? {
        let joined = lines.joined(separator: "\n")
        guard let data = joined.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [[String: Any]] else {
            return nil
        }

        var entries: [LogEntry] = []
        entries.reserveCapacity(array.count)
        var nextID = startingEntryID
        for (i, obj) in array.enumerated() {
            let raw = (try? String(data: JSONSerialization.data(withJSONObject: obj, options: []), encoding: .utf8)) ?? ""
            entries.append(parseUnifiedEntry(obj, lineNumber: i + 1, entryID: nextID, rawLine: raw))
            nextID += 1
        }
        return (entries, nextID)
    }

    private func parseUnifiedEntry(_ json: [String: Any], lineNumber: Int, entryID: Int, rawLine: String) -> LogEntry {
        let timestamp = parseTimestamp(json["timestamp"] as? String)
        let level = parseMessageType(json["messageType"] as? String)
        let message = (json["eventMessage"] as? String) ?? ""
        let process = (json["processImagePath"] as? String)
            .map { ($0 as NSString).lastPathComponent }
        let subsystem = json["subsystem"] as? String
        let category = json["category"] as? String
        let threadID = (json["threadID"] as? Int).map { String($0) }

        // subsystem:category when present, else process name
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
            threadID: threadID, source: nil, rawLine: rawLine
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
