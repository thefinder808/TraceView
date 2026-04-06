import Foundation

/// Parses Microsoft SCCM/ConfigMgr log format (CMTrace format).
/// Format: `<![LOG[message]LOG]!><time="HH:mm:ss.fff+offset" date="MM-DD-YYYY" component="name" context="" type="N" thread="N" file="name">`
/// Type field: 1=Info, 2=Warning, 3=Error
struct SCCMLogParser: LogParser {
    let name = "SCCM (CMTrace)"
    let supportedExtensions: Set<String> = ["log"]

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

    private func parseDateTime(date: String, time: String) -> Date? {
        // Date: "MM-DD-YYYY", Time: "HH:mm:ss.fff+offset" or "HH:mm:ss.fff"
        let cleanTime = time.components(separatedBy: "+").first?
            .components(separatedBy: "-").first ?? time

        let combined = "\(date) \(cleanTime)"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in [
            "MM-dd-yyyy HH:mm:ss.SSS",
            "MM-dd-yyyy HH:mm:ss"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: combined) { return date }
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
