import AppKit

// Persists column widths and column order for the log table to UserDefaults.
// Keyed by column identifier (lineNumber, timestamp, level, component,
// message) so the layout survives across launches.
//
// Message column is deliberately skipped — it autoresizes to fill the
// remaining space, so any saved width would fight sizeLastColumnToFit /
// lastColumnOnlyAutoresizingStyle on the next window resize.
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

    // Apply both the saved order and the saved widths to an already-configured
    // table. Call after columns are added but before the table is displayed.
    static func apply(to tableView: NSTableView) {
        // Reorder first — column indices after move are stable for width edits.
        if let savedOrder = loadOrder() {
            for (desiredIndex, identifier) in savedOrder.enumerated() {
                let currentIndex = tableView.tableColumns.firstIndex {
                    $0.identifier.rawValue == identifier
                }
                guard let currentIndex, currentIndex != desiredIndex else { continue }
                tableView.moveColumn(currentIndex, toColumn: desiredIndex)
            }
        }

        let widths = loadWidths()
        for column in tableView.tableColumns {
            guard let width = widths[column.identifier.rawValue] else { continue }
            column.width = CGFloat(width)
        }
    }
}
