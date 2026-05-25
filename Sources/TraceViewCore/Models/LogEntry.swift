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

    // Populated only on entries that came from a merged-view source. Lets
    // the merged view show the origin doc and supports "Open in Source Log"
    // (right-click a row to open the source doc + scroll to its line).
    var sourceDocumentID: UUID? = nil
    var sourceLineNumber: Int? = nil
}
