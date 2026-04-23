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

    // Line numbers the user has bookmarked for this document. Persisted per
    // file URL; live streams don't persist (no stable identity to key on).
    @Published var bookmarks: Set<Int> = [] {
        didSet { saveBookmarks() }
    }

    // Throttled line count for sidebar display (updated ~1/sec)
    @Published var displayLineCount: Int = 0

    // Smoothed lines/sec for the status bar stream indicator. Updated on the
    // same 1-second tick as displayLineCount using exponential smoothing so
    // brief arrival gaps don't jump the number to zero.
    @Published private(set) var linesPerSecond: Double = 0

    // Ticks with zero arrivals while live → "Stalled" in the UI.
    @Published private(set) var idleTicks: Int = 0

    var lastReadOffset: UInt64 = 0
    var nextEntryID: Int = 0

    private var lineCountTimer: AnyCancellable?
    private var lastCountForRate: Int = 0

    init(source: LogSource, displayName: String) {
        self.source = source
        self.displayName = displayName
        self.bookmarks = Self.loadBookmarks(for: source)

        // Update displayLineCount and stream rate once per second
        lineCountTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let count = self.entries.count
                if count != self.displayLineCount {
                    self.displayLineCount = count
                }

                let delta = count - self.lastCountForRate
                self.lastCountForRate = count

                // EWMA with alpha=0.4 — smooths brief gaps without lagging big bursts.
                let smoothed = 0.6 * self.linesPerSecond + 0.4 * Double(max(delta, 0))
                self.linesPerSecond = smoothed

                self.idleTicks = (delta == 0 && self.isLive) ? self.idleTicks + 1 : 0
            }
    }

    var lineCount: Int { entries.count }

    // MARK: - Bookmark persistence

    // Only file sources persist. Unified-log streams and stdin don't have a
    // stable identity to key UserDefaults on, so their bookmarks live only
    // for the lifetime of the document.
    private static func defaultsKey(for source: LogSource) -> String? {
        switch source {
        case .file(let url): return "traceview.bookmarks.\(url.path)"
        case .unifiedLog, .stdin: return nil
        }
    }

    private static func loadBookmarks(for source: LogSource) -> Set<Int> {
        guard let key = defaultsKey(for: source),
              let array = UserDefaults.standard.array(forKey: key) as? [Int] else {
            return []
        }
        return Set(array)
    }

    private func saveBookmarks() {
        guard let key = Self.defaultsKey(for: source) else { return }
        if bookmarks.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Array(bookmarks).sorted(), forKey: key)
        }
    }
}
