import AppKit
import SwiftUI

/// Static column header for the custom log view. Renders the column titles
/// in a fixed-height bar above the scrolling document. PR #1 of Phase 2 is
/// title-only — drag-resize and drag-reorder hit-testing land in P2.2.
///
/// Lives outside the scrolling `NSScrollView` (in the parent container, as
/// a sibling of the scroll view) so the header stays pinned while rows
/// scroll past underneath. Width tracks the document view's width via the
/// parent container's `layout()` pass.
final class LogScrollHeaderView: NSView {

    static let headerHeight: CGFloat = 22

    private(set) var columns: [ColumnFrame] = []
    private(set) var theme: (any AppTheme)?
    private(set) var fontSize: Double = 12.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Flip so x-positions read left-to-right and y=0 is the top of the
    /// header — consistent with the document view's coordinate system, so
    /// the column-x math from `LogScrollColumnLayout` applies directly.
    override var isFlipped: Bool { true }

    func apply(columns: [ColumnFrame], theme: any AppTheme, fontSize: Double) {
        self.columns = columns
        self.theme = theme
        self.fontSize = fontSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }

        // Header background — slightly distinct from row body. Re-uses
        // statusBarBackground to track theme tints (neon's bright accents,
        // console's terminal greens) without adding a dedicated token.
        NSColor(theme.statusBarBackground).setFill()
        bounds.intersection(dirtyRect).fill()

        // 1px bottom border separating the header band from the rows.
        let borderRect = NSRect(
            x: 0,
            y: bounds.height - 1,
            width: bounds.width,
            height: 1
        ).intersection(dirtyRect)
        if !borderRect.isEmpty {
            NSColor(theme.border).setFill()
            borderRect.fill()
        }

        // Per-column title text. Uses the same paragraph style as cells so
        // hidden overflow ellipsizes consistently.
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let lineHeight = titleFont.ascender - titleFont.descender + titleFont.leading

        for column in columns {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            // Match per-column alignment to the row text so titles sit over
            // the column they label rather than visually drifting.
            paragraph.alignment = alignment(for: column.id)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor(theme.secondaryText),
                .paragraphStyle: paragraph,
            ]

            let textRect = NSRect(
                x: column.x + 4,
                y: (bounds.height - lineHeight) / 2,
                width: max(0, column.width - 8),
                height: lineHeight
            )
            NSAttributedString(string: column.id.title, attributes: attrs)
                .draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    private func alignment(for column: ColumnID) -> NSTextAlignment {
        switch column {
        case .lineNumber: return .right
        case .level:      return .center
        default:          return .left
        }
    }
}
