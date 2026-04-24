import Foundation

/// Parses structured JSON log files where each line is a JSON object.
/// Looks for common keys: level/severity, message/msg, timestamp/time/ts, logger/component.
struct JSONLogParser: LogParser {
    let name = "JSON Structured"
    let supportedExtensions: Set<String> = ["json", "jsonl", "ndjson"]

    func canParse(sampleLines: [String]) -> Double {
        // NDJSON / JSONL path: each line parses as a JSON object.
        var jsonCount = 0
        var hasLevelField = false

        for line in sampleLines.prefix(10) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            jsonCount += 1

            let keys = Set(json.keys.map { $0.lowercased() })
            if keys.contains("level") || keys.contains("severity") || keys.contains("loglevel") {
                hasLevelField = true
            }
        }

        if jsonCount > 0 {
            let ratio = Double(jsonCount) / Double(min(sampleLines.count, 10))
            if hasLevelField && ratio > 0.7 { return 0.85 }
            if ratio > 0.7 { return 0.6 }
        }

        // Whole-file JSON array path: first non-whitespace char in the
        // sample is `[`, and the sample contains log-shaped keys. Use the
        // full sample window (not just the first N lines) — pretty-
        // printed exports put keys like `timestamp`, `message`, and
        // `eventMessage` deep in each entry's key block, well past a
        // 20-line cutoff.
        let joined = sampleLines.joined(separator: " ")
        let lead = joined.trimmingCharacters(in: .whitespaces).first
        if lead == "[" {
            let hasLogKeys = joined.contains("\"timestamp\"") ||
                             joined.contains("\"level\"") ||
                             joined.contains("\"message\"") ||
                             joined.contains("\"severity\"") ||
                             joined.contains("\"eventMessage\"") ||
                             joined.contains("\"messageType\"")
            if hasLogKeys { return 0.75 }
        }

        return 0.0
    }

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: LevelDetector.detect(in: line),
                message: line, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }
        return parseObject(json, lineNumber: lineNumber, entryID: entryID, rawLine: line)
    }

    /// Handles whole-file JSON arrays and top-level objects whose `events`/
    /// `logs`/`records`/`entries` array holds the log entries — e.g. pretty-
    /// printed arrays from `log show --style json` exports or custom
    /// envelope formats like `{"events": [...]}`. Returns nil for NDJSON
    /// (handled by the line-by-line `parse(line:)` fallback).
    func parseFile(lines: [String], startingEntryID: Int) -> (entries: [LogEntry], nextID: Int)? {
        let joined = lines.joined(separator: "\n")
        guard let data = joined.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let array = extractEntryArray(from: object)
        guard let array else { return nil }

        var entries: [LogEntry] = []
        entries.reserveCapacity(array.count)
        var nextID = startingEntryID
        for (i, obj) in array.enumerated() {
            // Synthetic rawLine — the original pretty JSON doesn't map 1:1
            // to a single file line, so we re-serialize as a compact JSON
            // snippet for the "Raw" detail pane and copy path.
            let raw = (try? String(data: JSONSerialization.data(withJSONObject: obj, options: []), encoding: .utf8)) ?? ""
            entries.append(parseObject(obj, lineNumber: i + 1, entryID: nextID, rawLine: raw))
            nextID += 1
        }
        return (entries, nextID)
    }

    private func extractEntryArray(from object: Any) -> [[String: Any]]? {
        if let array = object as? [[String: Any]] { return array }
        if let obj = object as? [String: Any] {
            for key in ["events", "logs", "records", "entries", "messages"] {
                if let array = obj[key] as? [[String: Any]] { return array }
            }
        }
        return nil
    }

    private func parseObject(_ json: [String: Any], lineNumber: Int, entryID: Int, rawLine: String) -> LogEntry {
        let timestamp = extractTimestamp(from: json)
        let level = extractLevel(from: json)
        let message = extractString(from: json, keys: ["message", "msg", "text", "body"]) ?? rawLine
        let component = extractString(from: json, keys: ["logger", "component", "source", "module", "service", "name"])
        let threadID = extractString(from: json, keys: ["thread", "threadId", "thread_id", "tid"])

        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: timestamp, level: level,
            message: message, component: component,
            threadID: threadID, source: nil, rawLine: rawLine
        )
    }

    private func extractString(from json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            // Try exact match first, then case-insensitive
            if let val = json[key] { return "\(val)" }
            for (k, v) in json {
                if k.lowercased() == key.lowercased() { return "\(v)" }
            }
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Immutable formatter array — each has its `dateFormat` set once at
    // init and is never mutated afterward. Reading `.date(from:)` on an
    // immutable DateFormatter is thread-safe on macOS 10.9+. Previously
    // this code mutated `dateFormat` on a shared static formatter inside
    // `extractTimestamp`, which races under concurrent parse tasks
    // (multiple files opened simultaneously) and can produce wrong dates.
    private static let dateFormatters: [DateFormatter] = {
        [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
        ].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()

    private func extractTimestamp(from json: [String: Any]) -> Date? {
        guard let str = extractString(from: json, keys: ["timestamp", "time", "ts", "@timestamp", "datetime", "date"]) else {
            return nil
        }

        // Try ISO8601
        if let date = Self.isoFormatter.date(from: str) { return date }

        // Try common formats
        for f in Self.dateFormatters {
            if let date = f.date(from: str) { return date }
        }

        // Try epoch seconds/millis
        if let num = Double(str) {
            if num > 1_000_000_000_000 { return Date(timeIntervalSince1970: num / 1000) }
            if num > 1_000_000_000 { return Date(timeIntervalSince1970: num) }
        }

        return nil
    }

    private func extractLevel(from json: [String: Any]) -> LogLevel {
        guard let str = extractString(from: json, keys: ["level", "severity", "loglevel", "log_level", "lvl"]) else {
            // Fall back to keyword detection in message
            let msg = extractString(from: json, keys: ["message", "msg"]) ?? ""
            return LevelDetector.detect(in: msg)
        }

        switch str.lowercased() {
        case "trace", "verbose", "debug": return .debug
        case "info", "information": return .info
        case "notice": return .notice
        case "warn", "warning": return .warning
        case "error", "err": return .error
        case "fatal", "critical", "emergency", "alert": return .critical
        default: return .info
        }
    }
}
