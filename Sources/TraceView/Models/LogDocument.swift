import Foundation
import Combine

final class LogDocument: ObservableObject, Identifiable {
    let id = UUID()
    let source: LogSource
    let displayName: String

    // Not @Published — mutations don't trigger view updates directly.
    // The ViewModel manages its own @Published filteredEntries.
    var entries: [LogEntry] = []

    @Published var isFollowing: Bool = true
    @Published var isLive: Bool = false
    @Published var fileSize: UInt64 = 0
    @Published var encoding: String.Encoding = .utf8

    // Throttled line count for sidebar display (updated ~1/sec)
    @Published var displayLineCount: Int = 0

    var lastReadOffset: UInt64 = 0
    var nextEntryID: Int = 0

    private var lineCountTimer: AnyCancellable?

    init(source: LogSource, displayName: String) {
        self.source = source
        self.displayName = displayName

        // Update displayLineCount once per second
        lineCountTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let count = self.entries.count
                if count != self.displayLineCount {
                    self.displayLineCount = count
                }
            }
    }

    var lineCount: Int { entries.count }
}
