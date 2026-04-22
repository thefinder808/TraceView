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
}
