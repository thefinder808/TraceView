import AppKit
import SwiftUI

/// Static column header for the custom log view. Renders column titles
/// in a fixed-height bar above the scrolling document and handles the
/// drag-resize + drag-reorder interactions. Persistence is delegated to
/// the parent container via callbacks (`onResizeDrag`, `onResizeCommit`,
/// `onReorderCommit`); this view only owns the in-flight drag state.
///
/// Hit-test invariants:
/// - Each visible non-message column has a 6px-wide divider hit zone
///   centered on its right edge. A click there cursors as
///   `NSCursor.resizeLeftRight` and enters resize mode on mouseDown.
/// - Clicks elsewhere on a non-message column arm a potential reorder;
///   mouseDragged with >4px of movement begins the actual drag.
/// - The message column itself is non-draggable (it autofills the
///   trailing space) and non-resizable (no max width).
final class LogScrollHeaderView: NSView {

    static let headerHeight: CGFloat = 22
    private static let dividerHitRadius: CGFloat = 3      // 6px hit zone
    private static let reorderDragThreshold: CGFloat = 4

    // MARK: - State pushed from the container

    private(set) var columns: [ColumnFrame] = []
    private(set) var theme: (any AppTheme)?
    private(set) var fontSize: Double = 12.0

    /// Horizontal scroll offset of the body, in content coordinates. The
    /// header is a sibling of the scroll view (pinned, never scrolled), so
    /// in no-wrap horizontal-scroll mode it must offset its own content to
    /// stay aligned with the columns below. Column titles draw at
    /// `column.x - contentOffsetX`; mouse hit-testing converts back by
    /// adding it. Zero in normal mode, so everything below is unchanged.
    var contentOffsetX: CGFloat = 0 {
        didSet {
            guard oldValue != contentOffsetX else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    // MARK: - Drag state machine

    /// Live drag state. `idle` is the steady state; `resizing` and
    /// `reordering` cover the two interactions; `preparingReorder` is the
    /// brief window between mouseDown on a column body and the
    /// reorder-drag threshold being crossed.
    private enum DragMode {
        case idle
        case resizing(column: ColumnID, startMouseX: CGFloat, startWidth: CGFloat)
        case preparingReorder(column: ColumnID, startMouseX: CGFloat)
        case reordering(column: ColumnID, mouseX: CGFloat)
    }
    private var dragMode: DragMode = .idle

    // MARK: - Callbacks

    /// Fires continuously while the user drags a divider. The container
    /// clamps the new width into [minWidth, maxWidth] and pushes a fresh
    /// layout to both the header and the document view.
    var onResizeDrag: (ColumnID, CGFloat) -> Void = { _, _ in }

    /// Fires once on mouseUp at the end of a resize drag. The container
    /// persists the clamped final width via ColumnLayoutStore.
    var onResizeCommit: (ColumnID) -> Void = { _ in }

    /// Fires once on mouseUp at the end of a reorder drag. The argument
    /// is the new visible-column order (excluding message, which is
    /// always last by structural invariant). The container merges this
    /// into `userOrder` and persists via ColumnLayoutStore.
    var onReorderCommit: ([ColumnID]) -> Void = { _ in }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(columns: [ColumnFrame], theme: any AppTheme, fontSize: Double) {
        self.columns = columns
        self.theme = theme
        self.fontSize = fontSize
        needsDisplay = true
        // Cursor rects depend on column boundaries; force a refresh so
        // the resize cursor appears at the new divider positions.
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Cursor rects

    override func resetCursorRects() {
        // One resize-left-right cursor rect per non-message column,
        // centered on its right edge. AppKit handles cursor switching
        // automatically as the mouse moves over these rects.
        for column in columns where column.id != .message {
            let dividerX = column.x + column.width - contentOffsetX
            let rect = NSRect(
                x: dividerX - Self.dividerHitRadius,
                y: 0,
                width: Self.dividerHitRadius * 2,
                height: bounds.height
            )
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    // MARK: - Hit-testing

    /// Returns the column whose right-edge divider is within hit radius
    /// of `x`. The message column is excluded — its right edge is the
    /// view's trailing edge and isn't resizable.
    private func dividerHit(at x: CGFloat) -> (column: ColumnID, dividerX: CGFloat)? {
        for column in columns where column.id != .message {
            let dividerX = column.x + column.width
            if abs(x - dividerX) <= Self.dividerHitRadius {
                return (column.id, dividerX)
            }
        }
        return nil
    }

    /// Returns the column whose body contains `x`. Used to identify the
    /// column being clicked for reorder.
    private func columnHit(at x: CGFloat) -> ColumnFrame? {
        for column in columns {
            if x >= column.x && x < column.x + column.width {
                return column
            }
        }
        return nil
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Hit-test and track drags in content coordinates so they stay
        // correct when the table is scrolled horizontally (contentOffsetX).
        let x = p.x + contentOffsetX

        if let hit = dividerHit(at: x) {
            let startWidth = columns.first(where: { $0.id == hit.column })?.width ?? 0
            dragMode = .resizing(
                column: hit.column,
                startMouseX: x,
                startWidth: startWidth
            )
            return
        }

        if let column = columnHit(at: x), column.id != .message {
            // Arm potential reorder. The actual drag only begins once
            // mouseDragged crosses the threshold — that gates against
            // accidental reorders from a click that drifted a pixel.
            dragMode = .preparingReorder(column: column.id, startMouseX: x)
            return
        }

        dragMode = .idle
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let x = p.x + contentOffsetX

        switch dragMode {
        case .idle:
            return

        case let .resizing(column, startMouseX, startWidth):
            let newWidth = startWidth + (x - startMouseX)
            onResizeDrag(column, newWidth)

        case let .preparingReorder(column, startMouseX):
            if abs(x - startMouseX) > Self.reorderDragThreshold {
                dragMode = .reordering(column: column, mouseX: x)
                needsDisplay = true
            }

        case let .reordering(column, _):
            dragMode = .reordering(column: column, mouseX: x)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .idle, .preparingReorder:
            break

        case let .resizing(column, _, _):
            onResizeCommit(column)

        case let .reordering(column, mouseX):
            let newOrder = newOrderAfterReorder(draggedColumn: column, dropX: mouseX)
            onReorderCommit(newOrder)
        }
        dragMode = .idle
        needsDisplay = true
    }

    /// Compute the new visible-column order after dropping `draggedColumn`
    /// at `dropX`. Returns the visible non-message columns in their new
    /// order. Insertion point is determined by which visible non-message
    /// column's midpoint the cursor is left of; past the rightmost
    /// non-message column appends at the end.
    private func newOrderAfterReorder(draggedColumn: ColumnID, dropX: CGFloat) -> [ColumnID] {
        var orderable = columns.filter { $0.id != .message }.map(\.id)
        orderable.removeAll { $0 == draggedColumn }

        var insertIndex = orderable.count
        for (idx, id) in orderable.enumerated() {
            guard let frame = columns.first(where: { $0.id == id }) else { continue }
            let midX = frame.x + frame.width / 2
            if dropX < midX {
                insertIndex = idx
                break
            }
        }
        orderable.insert(draggedColumn, at: insertIndex)
        return orderable
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }

        // Header background.
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

        // Column titles.
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let lineHeight = titleFont.ascender - titleFont.descender + titleFont.leading
        let secondaryColor = NSColor(theme.secondaryText)

        for column in columns {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = alignment(for: column.id)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: secondaryColor,
                .paragraphStyle: paragraph,
            ]
            let textRect = NSRect(
                x: column.x - contentOffsetX + 4,
                y: (bounds.height - lineHeight) / 2,
                width: max(0, column.width - 8),
                height: lineHeight
            )
            NSAttributedString(string: column.id.title, attributes: attrs)
                .draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
        }

        // Drag affordances. Drawn last so they sit over the titles.
        if case let .reordering(draggedColumn, mouseX) = dragMode {
            drawReorderAffordances(
                draggedColumn: draggedColumn,
                mouseX: mouseX,
                titleFont: titleFont,
                titleColor: secondaryColor,
                theme: theme
            )
        }
    }

    /// Translucent proxy of the dragged column's title at the cursor,
    /// plus a 2px vertical drop indicator at the target divider. Mirrors
    /// the affordance NSTableView shows during column drag.
    private func drawReorderAffordances(
        draggedColumn: ColumnID,
        mouseX: CGFloat,
        titleFont: NSFont,
        titleColor: NSColor,
        theme: any AppTheme
    ) {
        // Drop indicator — vertical bar at the boundary the dragged
        // column would land at.
        let orderableExcludingDragged = columns
            .filter { $0.id != .message && $0.id != draggedColumn }
        var dropX: CGFloat = orderableExcludingDragged.last.map { $0.x + $0.width } ?? 0
        for column in orderableExcludingDragged {
            let midX = column.x + column.width / 2
            if mouseX < midX {
                dropX = column.x
                break
            }
        }
        // dropX and mouseX are content coordinates; shift into view space
        // by the horizontal scroll offset for drawing.
        let indicator = NSRect(x: dropX - contentOffsetX - 1, y: 0, width: 2, height: bounds.height)
        NSColor(theme.accentColor).setFill()
        indicator.fill()

        // Translucent proxy of the dragged column's title at the cursor.
        // Constant offset so the cursor appears to "carry" the title.
        let proxyWidth: CGFloat = 80
        let proxyRect = NSRect(
            x: mouseX - contentOffsetX - proxyWidth / 2,
            y: 1,
            width: proxyWidth,
            height: bounds.height - 2
        )
        NSColor(theme.cardBackground).withAlphaComponent(0.85).setFill()
        proxyRect.fill()
        NSColor(theme.border).setStroke()
        proxyRect.frame(withWidth: 1)

        let proxyParagraph = NSMutableParagraphStyle()
        proxyParagraph.alignment = .center
        proxyParagraph.lineBreakMode = .byTruncatingTail
        let proxyAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: proxyParagraph,
        ]
        let lineHeight = titleFont.ascender - titleFont.descender + titleFont.leading
        let proxyTextRect = NSRect(
            x: proxyRect.minX + 4,
            y: (bounds.height - lineHeight) / 2,
            width: proxyRect.width - 8,
            height: lineHeight
        )
        NSAttributedString(string: draggedColumn.title, attributes: proxyAttrs)
            .draw(with: proxyTextRect, options: [.usesLineFragmentOrigin], context: nil)
    }

    private func alignment(for column: ColumnID) -> NSTextAlignment {
        switch column {
        case .lineNumber: return .right
        case .level:      return .center
        default:          return .left
        }
    }
}
