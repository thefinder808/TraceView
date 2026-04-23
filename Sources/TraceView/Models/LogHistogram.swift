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
}
