import Foundation

struct LogEntry: Identifiable {
    let id: Int
    let lineNumber: Int
    let timestamp: Date?
    let level: LogLevel
    let message: String
    let component: String?
    let threadID: String?
    let source: String?
    let rawLine: String
}
