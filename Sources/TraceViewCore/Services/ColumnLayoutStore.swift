import Foundation

// Persists column widths and column order for the log table to UserDefaults.
// Keyed by column identifier (lineNumber, timestamp, level, component,
// source, message) so the layout survives across launches.
//
// Read by `LogScrollView.makeNSView` on first construction and written by
// `LogScrollContainerView`'s onColumnResized / onColumnsReordered
// callbacks when the user drags a header divider or column title.
//
// Message column is deliberately skipped from saved widths — it
// autoresizes to fill the remaining space, so any saved width would fight
// `LogScrollColumnLayout.compute`'s "fill remainder" math on the next
// window resize.
enum ColumnLayoutStore {
    private static let widthsKey = "traceview.columnWidths"
    private static let orderKey = "traceview.columnOrder"
    private static let messageIdentifier = "message"

    static func loadWidths() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
    }

    static func saveWidth(_ width: Double, for identifier: String) {
        guard identifier != messageIdentifier else { return }
        var widths = loadWidths()
        widths[identifier] = width
        UserDefaults.standard.set(widths, forKey: widthsKey)
    }

    static func loadOrder() -> [String]? {
        UserDefaults.standard.stringArray(forKey: orderKey)
    }

    static func saveOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: orderKey)
    }
}
