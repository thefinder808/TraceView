import Foundation

/// Parses CSV-formatted log files with a header row.
/// Maps column headers to LogEntry fields by name matching.
/// Note: Since LogParser.parse() is stateless per-line, we detect the header
/// on line 1 and encode the column mapping into each subsequent parse call
/// by re-parsing the header. For efficiency, the registry should cache parsers.
struct CSVLogParser: LogParser {
    let name = "CSV"
    let supportedExtensions: Set<String> = ["csv"]

    private static let timestampHeaders = Set(["timestamp", "time", "datetime", "date", "ts", "@timestamp"])
    private static let levelHeaders = Set(["level", "severity", "loglevel", "log_level", "priority"])
    private static let messageHeaders = Set(["message", "msg", "text", "body", "description", "log"])
    private static let componentHeaders = Set(["component", "source", "logger", "module", "service", "process", "category"])
    private static let threadHeaders = Set(["thread", "threadid", "thread_id", "tid"])

    func canParse(sampleLines: [String]) -> Double {
        guard sampleLines.count >= 2 else { return 0.0 }

        let header = sampleLines[0]
        let columns = parseCSVRow(header)

        guard columns.count >= 2 else { return 0.0 }

        let lowerHeaders = Set(columns.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })

        let hasMessage = !lowerHeaders.isDisjoint(with: Self.messageHeaders)
        let hasLevel = !lowerHeaders.isDisjoint(with: Self.levelHeaders)
        let hasTimestamp = !lowerHeaders.isDisjoint(with: Self.timestampHeaders)

        // Verify second line has same column count
        let secondRow = parseCSVRow(sampleLines[1])
        guard secondRow.count == columns.count else { return 0.0 }

        if hasMessage && (hasLevel || hasTimestamp) { return 0.8 }
        if hasMessage { return 0.5 }
        return 0.0
    }

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        // Line 1 is the header — return it as a debug entry
        if lineNumber == 1 {
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: .debug,
                message: "CSV Header: \(line)", component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }

        let columns = parseCSVRow(line)
        guard !columns.isEmpty else {
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: .info,
                message: line, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // Heuristic column extraction
        let timestamp = findTimestamp(in: columns)
        let level = findLevel(in: columns)
        let component = findComponent(in: columns)
        // Message is typically the last or longest column
        let message = findMessage(in: columns)

        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: timestamp, level: level,
            message: message, component: component,
            threadID: nil, source: nil, rawLine: line
        )
    }

    private func findMessage(in columns: [String]) -> String {
        // The message is usually the last column or the longest one
        guard columns.count > 1 else { return columns.first ?? "" }
        // Pick the longest column (most likely the message)
        return columns.max(by: { $0.count < $1.count }) ?? columns.last ?? ""
    }

    private func findComponent(in columns: [String]) -> String? {
        // Component is usually a short identifier, not the first (timestamp) or last (message)
        guard columns.count > 3 else { return nil }
        // Skip first (likely timestamp) and last (likely message), pick a short middle column
        let middle = columns.dropFirst().dropLast()
        return middle.first { $0.count > 0 && $0.count < 50 && !isTimestamp($0) && !isLevel($0) }
    }

    private func findLevel(in columns: [String]) -> LogLevel {
        for col in columns {
            let trimmed = col.trimmingCharacters(in: .whitespaces).lowercased()
            switch trimmed {
            case "debug", "trace": return .debug
            case "info", "information": return .info
            case "notice": return .notice
            case "warn", "warning": return .warning
            case "error", "err": return .error
            case "fatal", "critical": return .critical
            default: continue
            }
        }
        return LevelDetector.detect(in: columns.joined(separator: " "))
    }

    private func findTimestamp(in columns: [String]) -> Date? {
        for col in columns.prefix(3) {
            let trimmed = col.trimmingCharacters(in: .whitespaces)
            if let date = parseDate(trimmed) { return date }
        }
        return nil
    }

    private func isTimestamp(_ str: String) -> Bool {
        parseDate(str.trimmingCharacters(in: .whitespaces)) != nil
    }

    private func isLevel(_ str: String) -> Bool {
        let lower = str.trimmingCharacters(in: .whitespaces).lowercased()
        return ["debug", "trace", "info", "notice", "warn", "warning", "error", "fatal", "critical"].contains(lower)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func parseDate(_ str: String) -> Date? {
        let f = Self.dateFormatter
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss"
        ] {
            f.dateFormat = format
            if let date = f.date(from: str) { return date }
        }
        return nil
    }

    private func parseCSVRow(_ line: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                columns.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        columns.append(current)
        return columns
    }
}
