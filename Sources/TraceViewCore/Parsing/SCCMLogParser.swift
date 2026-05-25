import Foundation

/// Parses Microsoft SCCM/ConfigMgr log format (CMTrace format).
/// Format: `<![LOG[message]LOG]!><time="HH:mm:ss.fff+offset" date="MM-DD-YYYY" component="name" context="" type="N" thread="N" file="name">`
/// Type field: 1=Info, 2=Warning, 3=Error
struct SCCMLogParser: LogParser {
    let name = "SCCM (CMTrace)"
    let supportedExtensions: Set<String> = ["log"]
    let isLineStateless = true
    let kind: ParserKind = .sccm

    private static let logPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<!\[LOG\[(.*?)\]LOG\]!><time="([^"]*)" date="([^"]*)" component="([^"]*)" context="[^"]*" type="(\d)" thread="(\d+)" file="([^"]*)">"#,
        options: .dotMatchesLineSeparators
    )

    func canParse(sampleLines: [String]) -> Double {
        var matchCount = 0
        for line in sampleLines.prefix(10) {
            if line.contains("<![LOG[") && line.contains("]LOG]!>") {
                matchCount += 1
            }
        }
        guard matchCount > 0 else { return 0.0 }
        return Double(matchCount) / Double(min(sampleLines.count, 10)) * 0.95
    }

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        guard let regex = Self.logPattern else {
            return fallback(line: line, lineNumber: lineNumber, entryID: entryID)
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        guard let match = regex.firstMatch(in: line, range: fullRange),
              match.numberOfRanges >= 8 else {
            return fallback(line: line, lineNumber: lineNumber, entryID: entryID)
        }

        let message = nsLine.substring(with: match.range(at: 1))
        let timeStr = nsLine.substring(with: match.range(at: 2))
        let dateStr = nsLine.substring(with: match.range(at: 3))
        let component = nsLine.substring(with: match.range(at: 4))
        let typeStr = nsLine.substring(with: match.range(at: 5))
        let threadID = nsLine.substring(with: match.range(at: 6))
        let source = nsLine.substring(with: match.range(at: 7))

        let timestamp = parseDateTime(date: dateStr, time: timeStr)
        let level = parseType(typeStr)

        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: timestamp, level: level,
            message: message, component: component.isEmpty ? nil : component,
            threadID: threadID, source: source.isEmpty ? nil : source,
            rawLine: line
        )
    }

    // Immutable prebuilt formatters — safe to read concurrently (each
    // formatter's `dateFormat` is set once at init). Previously this code
    // mutated `dateFormat` on a shared static, which races under concurrent
    // SCCM-log opens.
    private static let dateFormatters: [DateFormatter] = {
        [
            "MM-dd-yyyy HH:mm:ss.SSS",
            "MM-dd-yyyy HH:mm:ss",
        ].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()

    private func parseDateTime(date: String, time: String) -> Date? {
        // Date: "MM-DD-YYYY", Time: "HH:mm:ss.fff+offset" or "HH:mm:ss.fff"
        // Strip timezone offset: match digits before any +/- timezone suffix
        // e.g., "10:23:01.442+000" -> "10:23:01.442"
        let cleanTime: String
        if let range = time.range(of: #"^[\d:.]+"#, options: .regularExpression) {
            cleanTime = String(time[range])
        } else {
            cleanTime = time
        }

        let combined = "\(date) \(cleanTime)"
        for f in Self.dateFormatters {
            if let date = f.date(from: combined) { return date }
        }
        return nil
    }

    private func parseType(_ type: String) -> LogLevel {
        switch type {
        case "1": return .info
        case "2": return .warning
        case "3": return .error
        default: return .info
        }
    }

    private func fallback(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: nil, level: LevelDetector.detect(in: line),
            message: line, component: nil,
            threadID: nil, source: nil, rawLine: line
        )
    }
}
