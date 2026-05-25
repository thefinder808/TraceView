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

    private(set) var entries: FilteredEntries = .empty
    private(set) var theme: (any AppTheme)?
    private(set) var fontSize: Double = 12.0

    /// `lineNumber` of the entry that was last in the array on the
    /// previous `apply(...)`. Used to detect whether a count growth is a
    /// clean trailing append (live-tail, the common path on streaming
    /// logs) or a non-trailing insertion (filter applied, source toggled
    /// in merged view). Trailing appends can invalidate only the new
    /// rows' rect instead of the whole view — critical for streaming
    /// logs under active user scroll, where unconditional whole-view
    /// invalidation causes visible jitter mid-rubber-band and mid-sync.
    private var previousLastEntryLine: Int?

    /// True while AppKit reports a live-scroll session is in flight
    /// (gesture, momentum, or rubber-band bounce). Set from the
    /// coordinator's willStart/didEnd notification handlers. While set,
    /// `apply(...)` defers `frame.size.height` growth for pure trailing
    /// appends — changing the document height mid-bounce makes AppKit
    /// re-evaluate the bounce target every entry, producing visible
    /// jitter. The deferred height flushes on `didEndLiveScroll`.
    var isLiveScrolling: Bool = false {
        didSet {
            guard oldValue != isLiveScrolling, !isLiveScrolling else { return }
            if let pending = pendingFrameHeight {
                setFrameSize(NSSize(width: frame.size.width, height: pending))
                pendingFrameHeight = nil
                // Ensure the newly-revealed bottom region paints on the
                // next runloop pass. Without this, AppKit can leave a
                // briefly-blank strip until something else triggers a
                // dirty-rect pass.
                needsDisplay = true
            }
        }
    }
    private var pendingFrameHeight: CGFloat?
    /// Visible columns in display order. Computed by
    /// `LogScrollContainerView.syncLayout()` from
    /// `(boundsWidth, visibility, userWidths, userOrder)` and pushed via
    /// `applyLayout(_:)`. The document view never computes layout itself
    /// — keeping all layout math in the container means the header view
    /// and the document view can never drift, which matters for resize
    /// hit-testing where pixel-exact divider positions decide whether a
    /// click lands on the resize cursor or the column body.
    private(set) var columns: [ColumnFrame] = []
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

    /// Line numbers that should render a 3px accent stripe on the left
    /// edge. Set by `LogDocument.bookmarks` via the apply chain.
    private(set) var bookmarkedLines: Set<Int> = []

    /// Highlight rules (regex → tint color). Compiled on apply into
    /// `compiledHighlights`; the draw loop iterates the compiled cache
    /// once per row, first-match-wins, matching NSLogTableView semantics.
    private(set) var highlightRules: [HighlightRule] = []
    private var compiledHighlights: [(rule: HighlightRule, regex: NSRegularExpression)] = []

    /// Right-click handlers. Wired from LogScrollView.
    var onToggleBookmark: (LogEntry) -> Void = { _ in }
    var onOpenInSourceLog: (LogEntry) -> Void = { _ in }
    var onFilterToComponent: (LogEntry) -> Void = { _ in }

    /// Entry the right-click context menu was built for. NSMenu doesn't
    /// pass the originating event into the menu-item action, so we cache
    /// the entry between `menu(for:)` and the @objc action selectors.
    private var contextMenuEntry: LogEntry?

    // MARK: - Inline expansion

    /// Pixel-height delta a row gains when expanded. Matches
    /// NSLogTableView.drawerHeight so the new and legacy renderers look
    /// identical when the user toggles between them. Re-exposes the
    /// constant from `LogScrollRowGeometry` for callers that haven't
    /// gotten a geometry value yet (e.g., `syncHostingView`).
    static let expandedDelta: CGFloat = LogScrollRowGeometry.expandedDelta

    /// Whether clicking a row toggles expansion. Bound to
    /// `SettingsManager.detailDisplayMode == .inline`. When false, click
    /// just selects without expanding (selection still populates the
    /// bottom detail pane).
    var inlineExpansionEnabled: Bool = false

    /// Entry currently expanded, or nil. Bound to the `expandedEntryID`
    /// SwiftUI state on `LogDocumentView`. Single-row-at-a-time —
    /// expanding a new row collapses the previous one.
    private(set) var expandedEntryID: Int?

    /// Resolved row index of `expandedEntryID` against the current
    /// `entries` array. Cached on every `apply(...)` so the
    /// rect-math accessors don't re-scan entries on every paint.
    private var expandedRow: Int?

    /// Fires when the user clicks to toggle expansion. The parent
    /// writes through to the `expandedEntryID` binding.
    var onExpansionToggled: (Int?) -> Void = { _ in }

    /// Builder closure for the SwiftUI detail view embedded below an
    /// expanded row. Supplied by `LogScrollView` so the SwiftUI
    /// environment (`themeManager`, callback closures) is captured at
    /// the right layer. Called lazily — once per expansion toggle, not
    /// on every layout pass.
    var detailViewBuilder: ((LogEntry) -> NSView)?

    /// The currently-attached SwiftUI host view (`NSHostingView` wrapping
    /// `InlineRowDetailView`). Lifecycle is tied to `expandedRow`:
    /// attached when an expansion becomes active, repositioned on layout
    /// passes, detached on collapse.
    private var hostingSubview: NSView?

    /// Entry ID the current `hostingSubview` was built for. Used to
    /// decide whether to rebuild (different entry expanded) vs reuse
    /// (same entry, just reposition) on layout changes.
    private var hostingSubviewEntryID: Int?

    private var followTimer: Timer?

    // MARK: - Caches

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

    // MARK: - Row geometry (one row may be expanded)

    /// Base row height — the height every row has when not expanded.
    var baseRowHeight: CGFloat {
        ceil(CGFloat(fontSize) * 2)
    }

    /// Compatibility shim: the old constant-height accessor. Returns
    /// `baseRowHeight`. New code should use `baseRowHeight` directly or
    /// `rowFrame(for:).height` when the expanded row matters.
    var rowHeight: CGFloat { baseRowHeight }

    /// Pure-value geometry helper for testability. Same logic the view
    /// applies, but factored out so unit tests don't have to construct
    /// a full NSView + apply() chain just to verify rect math.
    private var geometry: LogScrollRowGeometry {
        LogScrollRowGeometry(
            baseRowHeight: baseRowHeight,
            expandedRow: expandedRow,
            entryCount: entries.count,
            width: bounds.width
        )
    }

    func rowFrame(for row: Int) -> NSRect { geometry.rowFrame(for: row) }
    func firstRow(in rect: NSRect) -> Int { geometry.firstRow(in: rect) }
    func lastRow(in rect: NSRect) -> Int { geometry.lastRow(in: rect) }

    /// Total virtual document height: `entries.count * baseRowHeight`
    /// plus an extra `expandedDelta` if any row is currently expanded.
    private func computeDocumentHeight() -> CGFloat {
        geometry.documentHeight()
    }

    // MARK: - State application

    /// Single entry point from the SwiftUI wrapper. Diff-applies the new
    /// state and invalidates only the caches that actually need rebuilding.
    /// Whole-view `needsDisplay = true` is cheap — the dirty rect clips to
    /// the visible viewport, so the redraw cost is proportional to visible
    /// rows regardless of how many entries the document has.
    func apply(
        entries: FilteredEntries,
        theme: any AppTheme,
        fontSize: Double,
        isFollowing: Bool,
        bookmarkedLines: Set<Int>,
        highlightRules: [HighlightRule],
        expandedEntryID: Int?,
        inlineExpansionEnabled: Bool,
        sourceNameForID: @escaping (UUID) -> String?
    ) {
        self.isFollowing = isFollowing
        let oldCount = self.entries.count
        let oldLastLine = previousLastEntryLine
        let oldExpandedRow = expandedRow
        let fontSizeChanged = self.fontSize != fontSize
        let themeChanged = (self.theme?.name ?? "") != theme.name
        let countChanged = oldCount != entries.count
        let bookmarksChanged = self.bookmarkedLines != bookmarkedLines
        let rulesChanged = self.highlightRules != highlightRules

        self.entries = entries
        self.theme = theme
        self.fontSize = fontSize
        self.bookmarkedLines = bookmarkedLines
        if rulesChanged {
            self.highlightRules = highlightRules
            rebuildHighlightRegexes()
        }
        self.sourceNameForID = sourceNameForID

        // Inline-expansion state. The desired expansion clears if the
        // mode is off OR the previously-expanded entry is no longer in
        // `entries` (filtered out, file reloaded, merged source toggled).
        // Resolves via the O(1) entry-id → position helper so apply()
        // doesn't parse every line up to the expanded row on indexed
        // sources — same hot bug as handleGoToLine.
        self.inlineExpansionEnabled = inlineExpansionEnabled
        let desiredExpandedID: Int? = inlineExpansionEnabled ? expandedEntryID : nil
        self.expandedEntryID = desiredExpandedID
        let resolvedExpandedRow: Int? = desiredExpandedID.flatMap { id in
            entries.position(forEntryID: id)
        }
        self.expandedRow = resolvedExpandedRow
        let expandedRowChanged = oldExpandedRow != resolvedExpandedRow

        // Detect trailing-append shape — same logic NSLogTableView uses to
        // decide between `insertRows` and `reloadData` (NSLogTableView.swift:275-281).
        // If the entry now at the previous trailing index matches the
        // previous trailing entry's lineNumber, the prefix is unchanged
        // and the count growth is a pure append we can invalidate
        // surgically.
        let isTrailingAppend: Bool = {
            guard oldCount > 0,
                  entries.count > oldCount,
                  oldCount - 1 < entries.count,
                  let oldLastLine else { return false }
            return entries[oldCount - 1].lineNumber == oldLastLine
        }()
        previousLastEntryLine = entries.last?.lineNumber

        // Invalidate BEFORE marking dirty so the next draw rebuilds the
        // cache against the new keying tuple. Order matters: if needsDisplay
        // ran with the stale cache still in place we'd paint one frame of
        // wrong colors / fonts after a theme switch.
        if fontSizeChanged || themeChanged {
            attrCache = nil
        }

        // Document height grows/shrinks with entry count, font size, and
        // expansion state. Setting frame.size *before* marking dirty
        // keeps the scroller knob accurate the moment we ask AppKit to
        // redraw — otherwise the overlay scroller's fade-in is driven by
        // a stale document height for one frame.
        //
        // Exception: during a live-scroll session, pure trailing appends
        // defer the height growth until the scroll settles. Mid-bounce
        // height changes cause AppKit to recompute the rubber-band
        // target on every entry, producing visible jitter. Font-size
        // changes, non-trailing count changes, and expansion toggles all
        // apply immediately because those genuinely change visible
        // content (and expansion is a deliberate user gesture that
        // should reflect immediately).
        if countChanged || fontSizeChanged || expandedRowChanged {
            let canDefer = isLiveScrolling && isTrailingAppend
                && !fontSizeChanged && !expandedRowChanged
            if canDefer {
                pendingFrameHeight = computeDocumentHeight()
            } else {
                updateFrameHeight()
                pendingFrameHeight = nil
            }
        }

        // Attach / detach / reposition the SwiftUI detail host whenever
        // expansion changes. The hosting view's lifecycle is tied to
        // `expandedRow`, not to the apply pass — `syncHostingView` builds
        // or removes the subview based on current state.
        if expandedRowChanged {
            syncHostingView()
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

        // Surgical invalidation. Whole-view repaints mid-scroll cause
        // visible jitter on streaming logs (UnifiedLogStream feeds
        // entries at ~10-20 Hz) — every append used to repaint the
        // entire visible viewport, disturbing rubber-band bounce
        // animations and ping-ponging during pane scroll-sync. The
        // cases below cover each axis of change:
        let visibleStateChanged = fontSizeChanged || themeChanged
            || bookmarksChanged || rulesChanged
        if visibleStateChanged || expandedRowChanged {
            // Theme/font/bookmark-set/highlight-rule changes can affect
            // any visible row — repaint everything. Expansion toggles
            // shift every row below the expanded one, so the whole view
            // needs paint as well.
            needsDisplay = true
        } else if isTrailingAppend {
            // Pure append: existing rows are pixel-identical. Only the
            // newly-appended rows (almost always off-screen) need
            // paint. AppKit's responsive-scrolling pre-render handles
            // the off-screen ones when their dirty rect comes into the
            // pre-render window. Visible content stays undisturbed,
            // which is what lets rubber-band bounce and scroll-sync
            // stay smooth.
            //
            // Use rowFrame(for:) for the start-of-new-rows y position so
            // an active expansion shifts the rect correctly.
            let startY = rowFrame(for: oldCount).minY
            let newRowsRect = NSRect(
                x: 0,
                y: startY,
                width: bounds.width,
                height: CGFloat(entries.count - oldCount) * baseRowHeight
            )
            setNeedsDisplay(newRowsRect)
        } else if countChanged {
            // Non-trailing change (filter shrink, file reload, merged-view
            // toggle, reorder). Visible content changes — repaint.
            needsDisplay = true
        }
        // If nothing changed, no invalidation needed. Updates that only
        // tweak `isFollowing` or `sourceNameForID` fall through here and
        // correctly don't trigger a redraw.
    }

    /// Recompile the enabled highlight rules into a regex cache. Invalid
    /// patterns (compilation failure) are silently dropped; the Settings
    /// row shows the "invalid regex" indicator so the user already sees
    /// the failure surface in the UI. Matches NSLogTableView semantics at
    /// NSLogTableView.swift:673-680.
    private func rebuildHighlightRegexes() {
        compiledHighlights = highlightRules.compactMap { rule in
            guard rule.isEnabled,
                  !rule.pattern.isEmpty,
                  let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
            return (rule, regex)
        }
    }

    /// First-match-wins color lookup for a row's message text. Returns
    /// nil when no rule applies; the draw loop only paints an overlay
    /// when a color comes back.
    private func highlightColor(for entry: LogEntry) -> NSColor? {
        guard !compiledHighlights.isEmpty else { return nil }
        let range = NSRange(entry.message.startIndex..., in: entry.message)
        for (rule, regex) in compiledHighlights {
            if regex.firstMatch(in: entry.message, range: range) != nil {
                return NSColor(rule.color)
            }
        }
        return nil
    }

    /// Push a fresh column layout. Called by the container whenever
    /// width, visibility, saved widths, or column order changes. The
    /// document view doesn't compute layout itself — see the doc comment
    /// on `columns`.
    func applyLayout(_ newColumns: [ColumnFrame]) {
        self.columns = newColumns
        needsDisplay = true
    }

    private func updateFrameHeight() {
        let newHeight = computeDocumentHeight()
        if frame.size.height != newHeight {
            setFrameSize(NSSize(width: frame.size.width, height: newHeight))
        }
    }

    // MARK: - SwiftUI detail-host lifecycle

    /// Reconcile the attached `NSHostingView` against the current
    /// `expandedRow`. Three cases:
    /// - No expansion → remove existing host.
    /// - Expansion to the same entry as the current host → reposition.
    /// - Expansion to a new entry → rebuild via `detailViewBuilder`.
    /// Called from `apply(...)` when expansion changes and from
    /// `setFrameSize(_:)` when width changes.
    private func syncHostingView() {
        guard let er = expandedRow, er < entries.count,
              let builder = detailViewBuilder else {
            removeHostingView()
            return
        }
        let entry = entries[er]

        if hostingSubviewEntryID != entry.id {
            removeHostingView()
            let view = builder(entry)
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
            hostingSubview = view
            hostingSubviewEntryID = entry.id
        }

        guard let view = hostingSubview else { return }
        let rowRect = rowFrame(for: er)
        view.frame = NSRect(
            x: 0,
            y: rowRect.minY + baseRowHeight,
            width: bounds.width,
            height: Self.expandedDelta
        )
    }

    private func removeHostingView() {
        hostingSubview?.removeFromSuperview()
        hostingSubview = nil
        hostingSubviewEntryID = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged {
            // Width changes shift column boundaries (message column
            // auto-resizes); the layout cache lives on the container
            // and is refreshed via syncLayout when the clip view's
            // frameDidChange fires. Here we just need to reposition the
            // host view (its width tracks the document's).
            syncHostingView()
        }
    }

    // MARK: - Selection (click only — keyboard nav + right-click menu land in P2.3)

    /// Accept first responder so the right-click menu (P2.3) can route to
    /// us via the responder chain, and keyboard nav (also P2.3) can attach.
    /// Click events fire regardless of first-responder state.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let row = rowAtPoint(location) else {
            // Click on blank area below the last row — clear selection
            // (and collapse any open expansion). Don't pause follow:
            // an accidental click outside any row shouldn't disrupt
            // live tailing.
            updateSelection(to: nil)
            if inlineExpansionEnabled, expandedEntryID != nil {
                onExpansionToggled(nil)
            }
            return
        }

        // A row click is investigative — pause live-follow so the row
        // stays put while the user reads it. Idempotent if follow was
        // already paused; the AppState gate makes the call a no-op.
        onScrollUp()

        // Re-click of the currently-selected row is special. In inline
        // mode the existing rowClicked logic toggles expansion (handled
        // below); in bottom-pane mode we now clear selection so the
        // bottom detail pane closes, matching the inline "re-click
        // collapses the detail" semantics.
        let isReclick = (selectedRow == row)

        if inlineExpansionEnabled {
            updateSelection(to: row)
            let entry = entries[row]
            let newID: Int? = (expandedEntryID == entry.id) ? nil : entry.id
            onExpansionToggled(newID)
        } else {
            updateSelection(to: isReclick ? nil : row)
        }

        // Take first-responder so keyboard nav lands here.
        window?.makeFirstResponder(self)
    }

    /// Resolve a point in document-view coordinates to a row index.
    /// Honors active expansion via `firstRow(in:)`. Returns nil when the
    /// point is below the last row (clicks on blank trailing space).
    private func rowAtPoint(_ point: NSPoint) -> Int? {
        guard baseRowHeight > 0 else { return nil }
        let probe = NSRect(x: 0, y: point.y, width: 1, height: 0.1)
        let row = firstRow(in: probe)
        guard row >= 0, row < entries.count else { return nil }
        // Verify the point actually falls inside the row's frame (the
        // expanded-row case has a tall band; a click in the detail-host
        // region should NOT count as a click on the row — that area is
        // owned by the SwiftUI subview, which handles its own clicks).
        let frame = rowFrame(for: row)
        guard point.y < frame.minY + baseRowHeight else {
            // Inside the expanded row's detail band. The hosting subview
            // catches its own clicks; we just no-op the document-view
            // selection logic so the user's click on a button inside
            // InlineRowDetailView doesn't also re-trigger expansion.
            return nil
        }
        return row
    }

    /// Scroll the given row into view and mark it selected. Used by the
    /// coordinator's go-to-line handler and (later) by ⌘F find-match
    /// navigation. Distinct from `updateSelection` because go-to-line
    /// always wants to scroll-into-view, whereas a mouse click is
    /// already in view by definition.
    func scrollAndSelect(row: Int) {
        guard row >= 0, row < entries.count else { return }
        updateSelection(to: row)
        scrollToVisible(rowFrame(for: row))
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

    // MARK: - Keyboard navigation

    override func keyDown(with event: NSEvent) {
        guard !entries.isEmpty else {
            super.keyDown(with: event)
            return
        }
        let pageStep = max(1, visibleRowCount() - 1)
        let current = selectedRow ?? -1
        let lastIndex = entries.count - 1
        let newRow: Int

        switch event.specialKey {
        case .upArrow:
            newRow = max(0, current - 1)
        case .downArrow:
            // From no-selection (-1), arrow-down lands on row 0.
            newRow = min(lastIndex, current + 1)
        case .pageUp:
            newRow = max(0, (current >= 0 ? current : lastIndex) - pageStep)
        case .pageDown:
            newRow = min(lastIndex, (current >= 0 ? current : 0) + pageStep)
        case .home:
            newRow = 0
        case .end:
            newRow = lastIndex
        default:
            super.keyDown(with: event)
            return
        }

        guard newRow != selectedRow else { return }
        // Keyboard nav is also investigative — pause follow before
        // moving the selection, same as click selection.
        onScrollUp()
        updateSelection(to: newRow)
        scrollToVisible(rowFrame(for: newRow))
    }

    /// How many full rows fit in the visible viewport. Used for PgUp/PgDn
    /// step size. Falls back to 10 if we can't reach the enclosing scroll
    /// view (shouldn't happen in practice — the view is always inside a
    /// LogScrollContainerView's NSScrollView).
    private func visibleRowCount() -> Int {
        guard let clip = enclosingScrollView?.contentView, rowHeight > 0 else { return 10 }
        return max(1, Int(clip.bounds.height / rowHeight))
    }

    // MARK: - Right-click context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let row = rowAtPoint(p) else { return nil }

        // Cache the clicked entry so the @objc action methods (which
        // can't carry payload through NSMenuItem.target/action) can read
        // it. Also select the clicked row so a subsequent ⌘D keyboard
        // shortcut operates on the same entry as the visible context.
        contextMenuEntry = entries[row]
        updateSelection(to: row)

        let menu = NSMenu()
        let bookmarkItem = NSMenuItem(
            title: "Toggle Bookmark",
            action: #selector(toggleBookmarkAction(_:)),
            keyEquivalent: "d"
        )
        bookmarkItem.keyEquivalentModifierMask = .command
        bookmarkItem.target = self
        menu.addItem(bookmarkItem)

        // Phase 4.5 PR2: "Filter to Component" is shown when the
        // clicked row has a component value AND no component filter is
        // currently pinned. The inline detail pill still works as
        // before; this just makes the action discoverable from a
        // right-click without expanding the row first.
        if let entry = contextMenuEntry, let component = entry.component, !component.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let filterItem = NSMenuItem(
                title: "Filter to Component: \(component)",
                action: #selector(filterToComponentAction(_:)),
                keyEquivalent: ""
            )
            filterItem.target = self
            menu.addItem(filterItem)
        }

        if let entry = contextMenuEntry, entry.sourceDocumentID != nil {
            menu.addItem(NSMenuItem.separator())
            let label: String = {
                guard let id = entry.sourceDocumentID,
                      let name = sourceNameForID(id) else { return "Open in Source Log" }
                return "Open in \(name)"
            }()
            let sourceItem = NSMenuItem(
                title: label,
                action: #selector(openInSourceLogAction(_:)),
                keyEquivalent: ""
            )
            sourceItem.target = self
            menu.addItem(sourceItem)
        }
        return menu
    }

    @objc private func toggleBookmarkAction(_ sender: Any?) {
        guard let entry = contextMenuEntry else { return }
        onToggleBookmark(entry)
    }

    @objc private func openInSourceLogAction(_ sender: Any?) {
        guard let entry = contextMenuEntry else { return }
        onOpenInSourceLog(entry)
    }

    @objc private func filterToComponentAction(_ sender: Any?) {
        guard let entry = contextMenuEntry else { return }
        onFilterToComponent(entry)
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
        let rowH = baseRowHeight
        guard rowH > 0 else { return }

        let start = firstRow(in: dirtyRect)
        let end = lastRow(in: dirtyRect)
        guard start < end else { return }

        let layout = columns

        for row in start..<end {
            let entry = entries[row]
            // Cell-band rect for this row. For the expanded row we draw
            // only the top `baseRowHeight` band — the detail host
            // (NSHostingView) owns the bottom portion. So even for an
            // expanded row, rowRect here is just the top band.
            let rowY = rowFrame(for: row).minY
            let rowRect = NSRect(x: 0, y: rowY, width: bounds.width, height: rowH)

            // Severity background — full row width. Restrict to dirtyRect
            // intersection so partial-row redraws (e.g. scrolling a few
            // pixels) don't repaint outside the dirty band.
            severityColor(for: entry.level, theme: theme).setFill()
            rowRect.intersection(dirtyRect).fill()

            // Highlight rule overlay — 0.22-alpha tint over the message
            // column's band only. Composed over the severity background
            // so an "ERROR with ratelimit" row reads as red with an
            // amber overlay on the message text. Matches
            // NSLogTableView's behavior at NSLogTableView.swift:854-868.
            if let highlightColor = highlightColor(for: entry),
               let messageColumn = layout.first(where: { $0.id == .message }) {
                let messageBand = NSRect(
                    x: messageColumn.x,
                    y: rowY,
                    width: messageColumn.width,
                    height: rowH
                ).intersection(dirtyRect)
                if !messageBand.isEmpty {
                    highlightColor.withAlphaComponent(0.22).setFill()
                    messageBand.fill()
                }
            }

            // Selection band — accent color at 0.20 alpha, composed over
            // the severity background. Matches NSLogTableView's selection
            // styling at NSLogTableView.swift:870-882.
            if row == selectedRow {
                NSColor(theme.accentColor).withAlphaComponent(0.2).setFill()
                rowRect.intersection(dirtyRect).fill()
            }

            // Bookmark stripe — 3px accent-colored band along the left
            // edge of the row. Visible over the level tint without being
            // loud. Matches NSLogTableView.swift:884-897.
            if bookmarkedLines.contains(entry.lineNumber) {
                let stripe = NSRect(
                    x: 0,
                    y: rowY,
                    width: 3,
                    height: rowH
                ).intersection(dirtyRect)
                if !stripe.isEmpty {
                    NSColor(theme.accentColor).setFill()
                    stripe.fill()
                }
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
