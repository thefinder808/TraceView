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

    let bars: [Bar]
    let maxTotal: Int
    let startLabel: String
    let endLabel: String
    let startTime: Date
    let bucketSize: TimeInterval

    /// Time range covered by the given bucket — used by histogram
    /// click-to-navigate to resolve a click position into an entry.
    func timeRange(forBucket index: Int) -> (start: Date, end: Date) {
        let start = startTime.addingTimeInterval(Double(index) * bucketSize)
        let end = start.addingTimeInterval(bucketSize)
        return (start, end)
    }
}
