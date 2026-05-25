import Foundation
import CoreGraphics

/// Pure-value row-geometry math for the custom log view. Lives outside
/// `LogScrollDocumentView` so the rect calculations can be unit-tested
/// without spinning up an `NSView`. The view delegates `rowFrame(for:)`,
/// `firstRow(in:)`, `lastRow(in:)`, and document-height computation to
/// instances of this struct.
///
/// One row at a time may be expanded. Rows above an expanded row use
/// the straight `row * baseRowHeight` formula; the expanded row itself
/// gets `baseRowHeight + expandedDelta` of vertical space (the top band
/// is the cell row, the bottom band is owned by an `NSHostingView`
/// rendering `InlineRowDetailView`); rows below the expanded row are
/// shifted down by `expandedDelta`.
struct LogScrollRowGeometry: Equatable {
    let baseRowHeight: CGFloat
    let expandedRow: Int?
    let entryCount: Int
    let width: CGFloat

    /// Extra pixels added to a row's height when it's expanded. Matches
    /// NSLogTableView.drawerHeight so both renderers agree on the
    /// detail-pane footprint.
    static let expandedDelta: CGFloat = 160

    /// Frame of a row in document-view coordinates. For the expanded row,
    /// the frame spans both the cell band and the detail band — callers
    /// that render only the cell portion (the `draw(_:)` loop) should
    /// clip to `baseRowHeight` starting at `frame.minY`.
    func rowFrame(for row: Int) -> NSRect {
        let h = baseRowHeight
        let y: CGFloat
        if let er = expandedRow, er < row {
            y = CGFloat(row) * h + Self.expandedDelta
        } else {
            y = CGFloat(row) * h
        }
        let height = (row == expandedRow) ? h + Self.expandedDelta : h
        return NSRect(x: 0, y: y, width: width, height: height)
    }

    /// First row index whose frame intersects `rect`. Three-region split
    /// when an expansion is active: above the expanded row, within its
    /// band, and below it (where every y is shifted by `expandedDelta`).
    func firstRow(in rect: NSRect) -> Int {
        guard baseRowHeight > 0 else { return 0 }
        let h = baseRowHeight
        guard let er = expandedRow else {
            return max(0, Int(floor(rect.minY / h)))
        }
        let expandedTop = CGFloat(er) * h
        let expandedBottom = expandedTop + h + Self.expandedDelta
        if rect.minY < expandedTop {
            return max(0, Int(floor(rect.minY / h)))
        } else if rect.minY < expandedBottom {
            return er
        } else {
            return max(0, Int(floor((rect.minY - Self.expandedDelta) / h)))
        }
    }

    /// One past the last row index whose frame intersects `rect`. Caller
    /// iterates `firstRow(in:) ..< lastRow(in:)`. Same three-region
    /// split as `firstRow(in:)` with ceil semantics for the upper bound.
    func lastRow(in rect: NSRect) -> Int {
        guard baseRowHeight > 0 else { return 0 }
        let h = baseRowHeight
        guard let er = expandedRow else {
            return min(entryCount, Int(ceil(rect.maxY / h)))
        }
        let expandedTop = CGFloat(er) * h
        let expandedBottom = expandedTop + h + Self.expandedDelta
        let computed: Int
        if rect.maxY <= expandedTop {
            computed = Int(ceil(rect.maxY / h))
        } else if rect.maxY <= expandedBottom {
            computed = er + 1
        } else {
            computed = Int(ceil((rect.maxY - Self.expandedDelta) / h))
        }
        return min(entryCount, computed)
    }

    /// Total virtual document height. Drives `frame.size.height` on the
    /// document view, which in turn drives the scroller knob size.
    func documentHeight() -> CGFloat {
        let base = CGFloat(entryCount) * baseRowHeight
        return base + (expandedRow != nil ? Self.expandedDelta : 0)
    }
}
