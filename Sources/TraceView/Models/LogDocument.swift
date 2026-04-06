import Foundation
import Combine

final class LogDocument: ObservableObject, Identifiable {
    let id = UUID()
    let source: LogSource
    let displayName: String

    @Published var entries: [LogEntry] = []
    @Published var isFollowing: Bool = true
    @Published var isLive: Bool = false
    @Published var fileSize: UInt64 = 0
    @Published var encoding: String.Encoding = .utf8

    var lastReadOffset: UInt64 = 0
    var nextEntryID: Int = 0

    init(source: LogSource, displayName: String) {
        self.source = source
        self.displayName = displayName
    }

    var lineCount: Int { entries.count }
}
