import Foundation

/// Parses structured JSON log files where each line is a JSON object.
/// Looks for common keys: level/severity, message/msg, timestamp/time/ts, logger/component.
struct JSONLogParser: LogParser {
    let name = "JSON Structured"
    let supportedExtensions: Set<String> = ["json", "jsonl", "ndjson"]

    func canParse(sampleLines: [String]) -> Double {
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

        guard jsonCount > 0 else { return 0.0 }
        let ratio = Double(jsonCount) / Double(min(sampleLines.count, 10))

        // High confidence if most lines are JSON with level fields
        if hasLevelField && ratio > 0.7 { return 0.85 }
        if ratio > 0.7 { return 0.6 }
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

        let timestamp = extractTimestamp(from: json)
        let level = extractLevel(from: json)
        let message = extractString(from: json, keys: ["message", "msg", "text", "body"]) ?? trimmed
        let component = extractString(from: json, keys: ["logger", "component", "source", "module", "service", "name"])
        let threadID = extractString(from: json, keys: ["thread", "threadId", "thread_id", "tid"])

        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: timestamp, level: level,
            message: message, component: component,
            threadID: threadID, source: nil, rawLine: line
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func extractTimestamp(from json: [String: Any]) -> Date? {
        guard let str = extractString(from: json, keys: ["timestamp", "time", "ts", "@timestamp", "datetime", "date"]) else {
            return nil
        }

        // Try ISO8601
        if let date = Self.isoFormatter.date(from: str) { return date }

        // Try common formats
        let f = Self.dateFormatter
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss"
        ] {
            f.dateFormat = format
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
