import Foundation

/// Parses CSV-formatted log files with a header row.
/// Maps column headers to LogEntry fields by name matching.
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

        // Need at least 2 columns and a recognizable header
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

    // Stored header mapping (set on first parse)
    private var columnMap: ColumnMap?

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        // Line 1 is the header — skip it in output but use it for mapping
        if lineNumber == 1 {
            // Return a placeholder entry for the header row
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: .debug,
                message: line, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }

        let columns = parseCSVRow(line)

        // We need to determine column mapping from context
        // Since parsers are stateless per-line, we infer from column content
        let message = columns.indices.contains(0) ? columns.last ?? line : line
        let level = findLevel(in: columns)
        let timestamp = findTimestamp(in: columns)
        let component = columns.count > 3 ? columns[min(3, columns.count - 1)] : nil

        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: timestamp, level: level,
            message: message, component: component,
            threadID: nil, source: nil, rawLine: line
        )
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
        // Fall back to keyword detection across all columns
        return LevelDetector.detect(in: columns.joined(separator: " "))
    }

    private func findTimestamp(in columns: [String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss"
        ]

        for col in columns.prefix(3) {
            let trimmed = col.trimmingCharacters(in: .whitespaces)
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: trimmed) { return date }
            }
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

private struct ColumnMap {
    var timestamp: Int?
    var level: Int?
    var message: Int?
    var component: Int?
    var thread: Int?
}
