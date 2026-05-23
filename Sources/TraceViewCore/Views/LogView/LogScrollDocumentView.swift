import AppKit
import SwiftUI

/// Custom virtual-scroll log document view that bypasses NSTableView. The
/// view's `frame.height` reflects the full virtual document height
/// (`entries.count * rowHeight`), so the enclosing `NSScrollView`'s
/// scroller knob is accurate, but `draw(_:)` only renders rows that
/// intersect `dirtyRect` — AppKit clips the dirty rect to the visible
/// viewport plus a small responsive-scrolling pre-render window, so the
/// per-frame cost is proportional to *visible* rows, not total rows.
///
/// This is the production view backing PR #1 of Phase 2; the rendering
/// pipeline is the one proved out at 36M rows in the traceview-spike.
/// PR #1 is render-only: no selection, hover, keyboard, scroll-sync,
/// follow, or expansion. Subsequent PRs layer those on top.
///
/// The variable-row-height accessors (`rowFrame(for:)`, `firstRow(in:)`,
/// `lastRow(in:)`) are present so future inline-expansion work doesn't
/// reshape the rect math — for now they take the constant-height fast
/// path.
final class LogScrollDocumentView: NSView {

    // MARK: - State

    private(set) var entries: [LogEntry] = []
    private(set) var theme: (any AppTheme)?
    private(set) var fontSize: Double = 12.0
    private(set) var visibility = ColumnVisibility(
        showLineNumber: true,
        showTimestamp: true,
        showComponent: true,
        showSource: false
    )
    private var sourceNameForID: (UUID) -> String? = { _ in nil }

    /// True while the table should pin to the last row. Mirrors the
    /// `LogDocument.isFollowing` flag fed through `LogScrollView`. The
    /// follow timer reads this on every tick; setting it to false stops
    /// auto-scroll without invalidating anything.
    var isFollowing: Bool = false

    /// Fires when the user scrolls more than 50pt away from the bottom
    /// while `isFollowing` was true. The parent uses this to flip
    /// `AppState.setFollowing(pane:, false)`, which surfaces the "Jump to
    /// Bottom" pill in the UI.
    var onScrollUp: () -> Void = {}

    /// Index of the selected row, or nil. Click-to-select wires this in
    /// `mouseDown`; keyboard nav (P2.3) will add ↑/↓/PgUp/PgDn handlers.
    private(set) var selectedRow: Int?

    /// Fires when the selected entry changes. Parent writes through to
    /// the `selectedEntry` binding so the bottom detail pane updates and
    /// `AppState.activePane` tracks which pane the user is reading.
    var onSelectionChanged: (LogEntry?) -> Void = { _ in }

    private var followTimer: Timer?

    // MARK: - Caches

    private var cachedLayout: [ColumnFrame] = []
    private var cachedLayoutWidth: CGFloat = -1
    private var cachedLayoutVisibility: ColumnVisibility?

    /// Per-(fontSize, theme.name) attribute lookup. Flat by design — each
    /// column's drawing context is one indirection away. Rebuilt only when
    /// the keying tuple changes; theme switches and font-size steps both
    /// invalidate it.
    private struct AttributeCache {
        let fontSize: Double
        let themeName: String
        let bodyLineHeight: CGFloat
        let smallLineHeight: CGFloat
        let badgeLineHeight: CGFloat
        let lineNumber: [NSAttributedString.Key: Any]
        let timestamp: [NSAttributedString.Key: Any]
        let component: [NSAttributedString.Key: Any]
        let sourceLabel: [NSAttributedString.Key: Any]
        let levelBadge: [LogLevel: [NSAttributedString.Key: Any]]
        let message: [LogLevel: [NSAttributedString.Key: Any]]
    }
    private var attrCache: AttributeCache?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
        startFollowTimer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        followTimer?.invalidate()
    }

    /// 150ms tick — matches `NSLogTableView.startFollowTimer` so live-tail
    /// cadence is identical between the two renderers. The tick is a no-op
    /// when `isFollowing` is false, so leaving the timer permanently armed
    /// is cheap and avoids a start/stop dance on every flag change.
    private func startFollowTimer() {
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.followTick()
        }
    }

    private func followTick() {
        guard isFollowing, !entries.isEmpty else { return }
        let lastRow = entries.count - 1
        scrollToVisible(rowFrame(for: lastRow))
    }

    /// `isFlipped = true` puts the origin at the top-left so row 0 is at
    /// y = 0 and rows grow downward. NSScrollView is happy either way, but
    /// flipped is more natural for top-down log indexing.
    override var isFlipped: Bool { true }

    // MARK: - Row geometry (variable-height-ready API, constant-height impl)

    /// Current row height. Constant in Phase 2; deferred inline-expansion
    /// phase will introduce a sparse expansion map behind these accessors
    /// without changing the API.
    var rowHeight: CGFloat {
        ceil(CGFloat(fontSize) * 2)
    }

    func rowFrame(for row: Int) -> NSRect {
        let h = rowHeight
        return NSRect(x: 0, y: CGFloat(row) * h, width: bounds.width, height: h)
    }

    /// First row index whose frame intersects `rect`.
    func firstRow(in rect: NSRect) -> Int {
        guard rowHeight > 0 else { return 0 }
        return max(0, Int(floor(rect.minY / rowHeight)))
    }

    /// One past the last row index whose frame intersects `rect`. Caller
    /// should iterate `firstRow(in:) ..< lastRow(in:)`.
    func lastRow(in rect: NSRect) -> Int {
        guard rowHeight > 0 else { return 0 }
        return min(entries.count, Int(ceil(rect.maxY / rowHeight)))
    }

    // MARK: - State application

    /// Single entry point from the SwiftUI wrapper. Diff-applies the new
    /// state and invalidates only the caches that actually need rebuilding.
    /// Whole-view `needsDisplay = true` is cheap — the dirty rect clips to
    /// the visible viewport, so the redraw cost is proportional to visible
    /// rows regardless of how many entries the document has.
    func apply(
        entries: [LogEntry],
        theme: any AppTheme,
        fontSize: Double,
        visibility: ColumnVisibility,
        isFollowing: Bool,
        sourceNameForID: @escaping (UUID) -> String?
    ) {
        self.isFollowing = isFollowing
        let fontSizeChanged = self.fontSize != fontSize
        let themeChanged = (self.theme?.name ?? "") != theme.name
        let visibilityChanged = self.visibility != visibility
        let countChanged = self.entries.count != entries.count

        self.entries = entries
        self.theme = theme
        self.fontSize = fontSize
        self.visibility = visibility
        self.sourceNameForID = sourceNameForID

        // Invalidate BEFORE marking dirty so the next draw rebuilds the
        // cache against the new keying tuple. Order matters: if needsDisplay
        // ran with the stale cache still in place we'd paint one frame of
        // wrong colors / fonts after a theme switch.
        if fontSizeChanged || themeChanged {
            attrCache = nil
        }
        if fontSizeChanged || visibilityChanged {
            invalidateLayoutCache()
        }

        // Document height grows/shrinks with entry count and font size.
        // Setting frame.size *before* marking dirty keeps the scroller knob
        // accurate the moment we ask AppKit to redraw — otherwise the
        // overlay scroller's fade-in is driven by a stale document height
        // for one frame.
        if countChanged || fontSizeChanged {
            updateFrameHeight()
        }

        // Selection follows the entries array: if the previously-selected
        // row is now out of range (filter shrank the list, file reloaded,
        // merged-view source toggled off), clear it. P2.3 will upgrade to
        // selection-by-entry-id so the highlight survives filter churn,
        // but PR #1 keeps the simpler index-based model.
        if let row = selectedRow, row >= entries.count {
            selectedRow = nil
            onSelectionChanged(nil)
        }

        needsDisplay = true
    }

    private func updateFrameHeight() {
        let newHeight = CGFloat(entries.count) * rowHeight
        if frame.size.height != newHeight {
            setFrameSize(NSSize(width: frame.size.width, height: newHeight))
        }
    }

    // MARK: - Selection (click only — keyboard nav + right-click menu land in P2.3)

    /// Accept first responder so the right-click menu (P2.3) can route to
    /// us via the responder chain, and keyboard nav (also P2.3) can attach.
    /// Click events fire regardless of first-responder state.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard rowHeight > 0 else { return }
        let row = Int(floor(location.y / rowHeight))
        guard row >= 0, row < entries.count else {
            // Click on blank area below the last row — clear selection.
            updateSelection(to: nil)
            return
        }
        updateSelection(to: row)
        // Take first-responder so future keyboard nav (P2.3) lands here.
        window?.makeFirstResponder(self)
    }

    private func updateSelection(to newRow: Int?) {
        guard newRow != selectedRow else { return }
        let oldRow = selectedRow
        selectedRow = newRow

        // Repaint only the old + new row bands. Whole-view invalidation
        // would also work but costs us a redraw of every visible row for
        // a one-pixel-strip change.
        if let oldRow, oldRow < entries.count {
            setNeedsDisplay(rowFrame(for: oldRow))
        }
        if let newRow {
            setNeedsDisplay(rowFrame(for: newRow))
        }

        let entry: LogEntry? = newRow.flatMap { $0 < entries.count ? entries[$0] : nil }
        onSelectionChanged(entry)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged {
            // Width drives the message column's autoresizing width, so any
            // change invalidates the cached layout. The whole view repaints
            // because every visible row's message column shifts.
            invalidateLayoutCache()
            needsDisplay = true
        }
    }

    // MARK: - Layout cache

    private func invalidateLayoutCache() {
        cachedLayoutWidth = -1
        cachedLayoutVisibility = nil
    }

    private func currentLayout() -> [ColumnFrame] {
        if cachedLayoutWidth == bounds.width, cachedLayoutVisibility == visibility {
            return cachedLayout
        }
        let layout = LogScrollColumnLayout.compute(
            boundsWidth: bounds.width,
            visibility: visibility
        )
        cachedLayout = layout
        cachedLayoutWidth = bounds.width
        cachedLayoutVisibility = visibility
        return layout
    }

    // MARK: - Attribute cache

    private func currentAttrs() -> AttributeCache? {
        guard let theme else { return nil }
        if let cache = attrCache,
           cache.fontSize == fontSize,
           cache.themeName == theme.name {
            return cache
        }
        let cache = buildAttributeCache(theme: theme)
        attrCache = cache
        return cache
    }

    private func buildAttributeCache(theme: any AppTheme) -> AttributeCache {
        let monoFont = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        // Floored at 10pt so the gutter stays legible when the user dials
        // all the way down to 9pt — 8pt mono is too small.
        let smallFont = NSFont.monospacedSystemFont(
            ofSize: CGFloat(max(10, fontSize - 1)),
            weight: .regular
        )
        let badgeFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

        let bodyLine: CGFloat = monoFont.ascender - monoFont.descender + monoFont.leading
        let smallLine: CGFloat = smallFont.ascender - smallFont.descender + smallFont.leading
        let badgeLine: CGFloat = badgeFont.ascender - badgeFont.descender + badgeFont.leading

        func attrs(
            font: NSFont,
            color: NSColor,
            alignment: NSTextAlignment
        ) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = alignment
            return [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        }

        let lineNumberAttrs = attrs(
            font: smallFont,
            color: NSColor(theme.tertiaryText),
            alignment: .right
        )
        let timestampAttrs = attrs(
            font: monoFont,
            color: NSColor(theme.timestampText),
            alignment: .left
        )
        let componentAttrs = attrs(
            font: monoFont,
            color: NSColor(theme.componentText),
            alignment: .left
        )
        let sourceLabelAttrs = attrs(
            font: smallFont,
            color: NSColor(theme.componentText),
            alignment: .left
        )

        var levelBadge: [LogLevel: [NSAttributedString.Key: Any]] = [:]
        var message: [LogLevel: [NSAttributedString.Key: Any]] = [:]
        for level in [LogLevel.debug, .info, .notice, .warning, .error, .critical] {
            levelBadge[level] = attrs(
                font: badgeFont,
                color: NSColor(theme.badgeText(for: level)),
                alignment: .center
            )
            message[level] = attrs(
                font: monoFont,
                color: NSColor(messageColor(for: level, theme: theme)),
                alignment: .left
            )
        }

        return AttributeCache(
            fontSize: fontSize,
            themeName: theme.name,
            bodyLineHeight: bodyLine,
            smallLineHeight: smallLine,
            badgeLineHeight: badgeLine,
            lineNumber: lineNumberAttrs,
            timestamp: timestampAttrs,
            component: componentAttrs,
            sourceLabel: sourceLabelAttrs,
            levelBadge: levelBadge,
            message: message
        )
    }

    /// Mirrors `NSLogTableView.Coordinator.messageColor(for:)` so the new
    /// renderer's per-level text colors match the existing view exactly.
    private func messageColor(for level: LogLevel, theme: any AppTheme) -> Color {
        switch level {
        case .critical, .error: return theme.errorText
        case .warning: return theme.warningText
        case .debug: return theme.debugText
        default: return theme.primaryText
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let cache = currentAttrs() else { return }
        let rowH = rowHeight
        guard rowH > 0 else { return }

        let start = firstRow(in: dirtyRect)
        let end = lastRow(in: dirtyRect)
        guard start < end else { return }

        let layout = currentLayout()

        for row in start..<end {
            let entry = entries[row]
            let rowY = CGFloat(row) * rowH
            let rowRect = NSRect(x: 0, y: rowY, width: bounds.width, height: rowH)

            // Severity background — full row width. Restrict to dirtyRect
            // intersection so partial-row redraws (e.g. scrolling a few
            // pixels) don't repaint outside the dirty band.
            severityColor(for: entry.level, theme: theme).setFill()
            rowRect.intersection(dirtyRect).fill()

            // Selection band — accent color at 0.20 alpha, composed over
            // the severity background. Matches NSLogTableView's selection
            // styling at NSLogTableView.swift:870-882.
            if row == selectedRow {
                NSColor(theme.accentColor).withAlphaComponent(0.2).setFill()
                rowRect.intersection(dirtyRect).fill()
            }

            // Per-column text. Vertically centered via a band rect sized
            // to the column's font line-height; ellipsis truncation via
            // NSAttributedString.draw(with:options:) + paragraph style.
            for column in layout {
                let value = stringValue(for: column.id, entry: entry)
                let (columnAttrs, lineHeight) = attributes(
                    for: column.id,
                    level: entry.level,
                    cache: cache
                )
                let textRect = NSRect(
                    x: column.x + 4,
                    y: rowY + (rowH - lineHeight) / 2,
                    width: max(0, column.width - 8),
                    height: lineHeight
                )
                NSAttributedString(string: value, attributes: columnAttrs)
                    .draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
            }
        }
    }

    private func severityColor(for level: LogLevel, theme: any AppTheme) -> NSColor {
        switch level {
        case .critical: return NSColor(theme.criticalHighlight)
        case .error:    return NSColor(theme.errorHighlight)
        case .warning:  return NSColor(theme.warningHighlight)
        default:        return NSColor(theme.tableBackground)
        }
    }

    private func attributes(
        for column: ColumnID,
        level: LogLevel,
        cache: AttributeCache
    ) -> ([NSAttributedString.Key: Any], CGFloat) {
        switch column {
        case .lineNumber:
            return (cache.lineNumber, cache.smallLineHeight)
        case .timestamp:
            return (cache.timestamp, cache.bodyLineHeight)
        case .level:
            return (cache.levelBadge[level] ?? cache.component, cache.badgeLineHeight)
        case .component:
            return (cache.component, cache.bodyLineHeight)
        case .sourceLabel:
            return (cache.sourceLabel, cache.smallLineHeight)
        case .message:
            return (cache.message[level] ?? cache.component, cache.bodyLineHeight)
        }
    }

    private func stringValue(for column: ColumnID, entry: LogEntry) -> String {
        switch column {
        case .lineNumber:
            return "\(entry.lineNumber)"
        case .timestamp:
            return entry.timestamp.map { Formatters.formatTimestamp($0) } ?? "—"
        case .level:
            return entry.level.shortName
        case .component:
            return entry.component ?? "—"
        case .sourceLabel:
            if let id = entry.sourceDocumentID, let name = sourceNameForID(id) {
                return name
            }
            return "—"
        case .message:
            return entry.message
        }
    }
}
