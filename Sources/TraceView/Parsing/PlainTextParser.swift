import Foundation

struct PlainTextParser: LogParser {
    let name = "Plain Text"
    let supportedExtensions: Set<String> = ["log", "txt", ""]

    func canParse(sampleLines: [String]) -> Double {
        // Fallback parser — always matches with low confidence
        0.1
    }

    // Common syslog: "MMM dd HH:mm:ss hostname process[pid]: message"
    // ISO timestamp: "2026-04-06T10:23:01.442Z ..."
    // Simple time: "10:23:01 ..."
    // Bracketed level: "[ERROR] message" or "ERROR: message"

    private static let syslogPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+(\S+)\s+(\S+?)(?:\[\d+\])?:\s*(.*)"#
    )

    // Apple daemon format, common in /var/log/wifi.log and similar:
    //   "Wed Apr 22 00:40:27.253 [airport]/616 @[...] (file:line) message"
    // Captures: timestamp (with day-of-week), component, and the remainder.
    private static let appleDaemonPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\.\d+)\s+\[([^\]]+)\]/\d+\s+(.*)$"#
    )

    private static let isoPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+(.*)"#
    )

    private static let bracketLevelPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\[?(DEBUG|INFO|NOTICE|WARN(?:ING)?|ERROR|CRITICAL|FATAL)\]?\s*:?\s*(.*)"#,
        options: .caseInsensitive
    )

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let syslogFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // "EEE MMM d HH:mm:ss.SSS" — no year; DateFormatter fills in current year.
    private static let appleDaemonFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let nsLine = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        // Try syslog format
        if let regex = Self.syslogPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 5 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let component = nsLine.substring(with: match.range(at: 3))
            let message = nsLine.substring(with: match.range(at: 4))
            let timestamp = Self.syslogFormatter.date(from: timeStr)
            let level = detectLevel(in: message, raw: trimmed)

            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // Try Apple daemon format (wifi.log, airportd, etc.)
        if let regex = Self.appleDaemonPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 4 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let component = nsLine.substring(with: match.range(at: 2))
            let message = nsLine.substring(with: match.range(at: 3))
            let timestamp = Self.appleDaemonFormatter.date(from: timeStr)
            let level = detectLevel(in: message, raw: trimmed)

            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // Try ISO timestamp
        if let regex = Self.isoPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 3 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let rest = nsLine.substring(with: match.range(at: 2))
            let timestamp = Self.isoFormatter.date(from: timeStr)
                ?? parseFlexibleISO(timeStr)
            let (level, message, component) = parseLevelAndComponent(from: rest)

            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // Try bracketed level prefix
        if let regex = Self.bracketLevelPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 3 {
            let levelStr = nsLine.substring(with: match.range(at: 1))
            let message = nsLine.substring(with: match.range(at: 2))
            let level = parseLevel(levelStr)

            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: level,
                message: message, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // Fallback: bare text line
        let level = LevelDetector.detect(in: trimmed)
        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: nil, level: level,
            message: trimmed, component: nil,
            threadID: nil, source: nil, rawLine: line
        )
    }

    // MARK: - Helpers

    private func detectLevel(in message: String, raw: String) -> LogLevel {
        LevelDetector.detect(in: message)
    }

    private func parseLevelAndComponent(from text: String) -> (LogLevel, String, String?) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if let regex = Self.bracketLevelPattern,
           let match = regex.firstMatch(in: text, range: fullRange),
           match.numberOfRanges >= 3 {
            let levelStr = nsText.substring(with: match.range(at: 1))
            let message = nsText.substring(with: match.range(at: 2))
            return (parseLevel(levelStr), message, nil)
        }

        return (LevelDetector.detect(in: text), text, nil)
    }

    private func parseLevel(_ str: String) -> LogLevel {
        switch str.uppercased() {
        case "DEBUG": return .debug
        case "INFO": return .info
        case "NOTICE": return .notice
        case "WARN", "WARNING": return .warning
        case "ERROR": return .error
        case "CRITICAL", "FATAL": return .critical
        default: return .info
        }
    }

    private func parseFlexibleISO(_ str: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Try common variants
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: str) { return date }
        }
        return nil
    }
}
