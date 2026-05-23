import Foundation

// Histogram result for the minimap strip. Computed in
// LogDocumentViewModel.recomputeHistogram() and published so HistogramView
// can read it without redoing the O(N) bucketing on every SwiftUI body eval.
struct LogHistogram {
    struct Bar {
        let err: Int
        let warn: Int
        let info: Int
        var total: Int { err + warn + info }
    }

    /// Per-time-window peak preserved across rebucketing rounds, projected
    /// onto a current bucket index. Rendered as a faint ghost behind the
    /// solid bar so a spike that's now absorbed into a wider bucket stays
    /// visible. Only included for buckets where peakCount > bar.total
    /// (i.e. the shadow would visibly extend above the current bar).
    struct Shadow {
        let bucketIndex: Int
        let peakCount: Int
    }

    let bars: [Bar]
    /// Max value the y-axis must accommodate — accounts for shadow heights
    /// in addition to bar totals so a tall ghost doesn't visually exceed
    /// the bar area.
    let maxTotal: Int
    let startLabel: String
    let endLabel: String
    let startTime: Date
    let bucketSize: TimeInterval
    let shadows: [Shadow]

    /// Time range covered by the given bucket — used by histogram
    /// click-to-navigate to resolve a click position into an entry.
    func timeRange(forBucket index: Int) -> (start: Date, end: Date) {
        let start = startTime.addingTimeInterval(Double(index) * bucketSize)
        let end = start.addingTimeInterval(bucketSize)
        return (start, end)
    }
}
