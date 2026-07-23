import SwiftUI
import AppKit
import Combine

/// SwiftUI wrapper around the custom virtual-scroll log view (Phase 2
/// renderer). API matches `NSLogTableView` one-for-one so `LogDocumentView`
/// can swap between the two by branching on `SettingsManager.useNewLogView`
/// with identical argument lists at both call sites.
///
/// Phase 2 PR #1 carries: rendering, column headers, click selection,
/// live-follow with scroll-up auto-pause. PR #2 (this PR) adds column
/// resize, reorder, and persistence. P2.3 will add keyboard nav,
/// right-click menu, bookmarks, and highlight rules. P2.4 will add
/// scroll-sync, go-to-line, and visible-top reporting.
struct LogScrollView: NSViewRepresentable {
    let entries: FilteredEntries
    let theme: any AppTheme
    let fontSize: Double
    let showLineNumbers: Bool
    let showTimestamp: Bool
    let showComponent: Bool
    let horizontalMessageScroll: Bool
    let isFollowing: Bool
    @Binding var selectedEntry: LogEntry?
    @Binding var expandedEntryID: Int?
    @Binding var pendingGoToLine: Int?
    let bookmarkedLines: Set<Int>
    let highlightRules: [HighlightRule]
    let inlineExpansionEnabled: Bool
    let themeManager: ThemeManager
    var onCopy: (LogEntry) -> Void = { _ in }
    var onFilterToComponent: (LogEntry) -> Void = { _ in }
    var onLookupErrorCode: (String) -> Void = { _ in }
    var onToggleBookmark: (LogEntry) -> Void = { _ in }
    var onScrollUp: () -> Void = {}
    var onVisibleTopChanged: (LogEntry?) -> Void = { _ in }
    var scrollToTimestampSignal: AnyPublisher<Date, Never> = Empty().eraseToAnyPublisher()
    var showSource: Bool = false
    var sourceNameForID: (UUID) -> String? = { _ in nil }
    var onOpenInSourceLog: (LogEntry) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LogScrollContainerView {
        let container = LogScrollContainerView()

        container.scrollView.hasVerticalScroller = true
        container.scrollView.hasHorizontalScroller = false
        container.scrollView.autohidesScrollers = true
        container.scrollView.drawsBackground = false

        // Notifications that drive the runtime:
        //   - frameDidChange on the clip view → width sync (window resize,
        //     scroller fade, pane drag).
        //   - boundsDidChange on the clip view → horizontal-scroll tracking
        //     (keep the header aligned + grow the no-wrap content width as
        //     longer lines scroll into view). Fires for every scroll, live
        //     or programmatic, unlike didLiveScroll.
        //   - didLiveScroll on the scroll view → scroll-up detection
        //     (drives the "Jump to Bottom" pill when the user scrolls
        //     away from the tail while following).
        container.scrollView.contentView.postsFrameChangedNotifications = true
        container.scrollView.contentView.postsBoundsChangedNotifications = true

        // Wire the document-view callback to the binding via the coordinator
        // (a closure captured by the document view can't write `@Binding`
        // directly — SwiftUI bindings need a hop back through the
        // representable's coordinator).
        container.documentView.onSelectionChanged = { [weak coordinator = context.coordinator] entry in
            coordinator?.selectedEntryBinding?.wrappedValue = entry
        }
        // The same indirection covers the right-click menu actions: the
        // closures are reassigned in updateNSView so the latest captured
        // SwiftUI state is reachable on every fire.
        container.documentView.onToggleBookmark = { [weak coordinator = context.coordinator] entry in
            coordinator?.onToggleBookmark(entry)
        }
        container.documentView.onOpenInSourceLog = { [weak coordinator = context.coordinator] entry in
            coordinator?.onOpenInSourceLog(entry)
        }
        container.documentView.onFilterToComponent = { [weak coordinator = context.coordinator] entry in
            coordinator?.onFilterToComponent(entry)
        }
        // Expansion toggle writes back through the binding.
        container.documentView.onExpansionToggled = { [weak coordinator = context.coordinator] id in
            coordinator?.expandedEntryIDBinding?.wrappedValue = id
        }
        // Detail-host builder lives on the coordinator so it sees the
        // latest theme/font/callback state on every build.
        container.documentView.detailViewBuilder = { [weak coordinator = context.coordinator] entry in
            coordinator?.buildDetailHostingView(for: entry) ?? NSView()
        }

        // Restore saved column widths + order on first construction so the
        // initial layout reflects prior sessions. The same UserDefaults
        // keys are used by NSLogTableView's ColumnLayoutStore.apply(to:),
        // so saved state round-trips between the two renderers.
        let savedWidths: [ColumnID: CGFloat] = ColumnLayoutStore.loadWidths()
            .reduce(into: [:]) { acc, kv in
                guard let id = ColumnID(rawValue: kv.key) else { return }
                acc[id] = CGFloat(kv.value)
            }
        let savedOrder: [ColumnID]? = ColumnLayoutStore.loadOrder().flatMap { raw in
            let parsed = raw.compactMap { ColumnID(rawValue: $0) }
            return parsed.isEmpty ? nil : parsed
        }
        container.userWidths = savedWidths
        container.userOrder = savedOrder

        // Persistence — when the header view fires a resize/reorder change,
        // route through the container (which already updates its own
        // state) and into ColumnLayoutStore. Mirrors NSLogTableView's
        // columnDidResize/columnDidMove notification handlers.
        container.onColumnResized = { id, width in
            ColumnLayoutStore.saveWidth(Double(width), for: id.rawValue)
        }
        container.onColumnsReordered = { order in
            ColumnLayoutStore.saveOrder(order.map(\.rawValue))
        }

        context.coordinator.container = container
        context.coordinator.installObservers()
        context.coordinator.installScrollSync(publisher: scrollToTimestampSignal)

        return container
    }

    func updateNSView(_ container: LogScrollContainerView, context: Context) {
        // Update coordinator's cached bindings/callbacks so the
        // notification-driven paths (scroll observer, selection callback,
        // detail-host builder) route through the latest values.
        context.coordinator.selectedEntryBinding = $selectedEntry
        context.coordinator.expandedEntryIDBinding = $expandedEntryID
        context.coordinator.pendingGoToLineBinding = $pendingGoToLine
        context.coordinator.onScrollUp = onScrollUp
        context.coordinator.onToggleBookmark = onToggleBookmark
        context.coordinator.onOpenInSourceLog = onOpenInSourceLog
        context.coordinator.onVisibleTopChanged = onVisibleTopChanged
        // Detail-host build state — captured here so newly-constructed
        // hosting subviews use the latest font, theme, and callback set.
        context.coordinator.themeManager = themeManager
        context.coordinator.fontSize = fontSize
        context.coordinator.onCopy = onCopy
        context.coordinator.onFilterToComponent = onFilterToComponent
        context.coordinator.onLookupErrorCode = onLookupErrorCode

        let visibility = ColumnVisibility(
            showLineNumber: showLineNumbers,
            showTimestamp: showTimestamp,
            showComponent: showComponent,
            showSource: showSource
        )

        container.documentView.onScrollUp = onScrollUp
        container.applyState(
            entries: entries,
            theme: theme,
            fontSize: fontSize,
            visibility: visibility,
            isFollowing: isFollowing,
            bookmarkedLines: bookmarkedLines,
            highlightRules: highlightRules,
            expandedEntryID: expandedEntryID,
            inlineExpansionEnabled: inlineExpansionEnabled,
            sourceNameForID: sourceNameForID,
            horizontalMessageScroll: horizontalMessageScroll
        )

        // Go-to-line: if a pending line number is set, scroll + select
        // the row whose lineNumber matches. The coordinator handles the
        // async-clear of the binding so the mutation happens outside this
        // view-update pass (synchronous binding writes during updateNSView
        // trip SwiftUI's "modifying state during view update" warning).
        if let target = pendingGoToLine {
            context.coordinator.handleGoToLine(target)
        }
    }

    // MARK: - Coordinator

    final class Coordinator {
        weak var container: LogScrollContainerView?
        var selectedEntryBinding: Binding<LogEntry?>?
        var expandedEntryIDBinding: Binding<Int?>?
        var pendingGoToLineBinding: Binding<Int?>?
        var onScrollUp: () -> Void = {}
        var onToggleBookmark: (LogEntry) -> Void = { _ in }
        var onOpenInSourceLog: (LogEntry) -> Void = { _ in }
        var onVisibleTopChanged: (LogEntry?) -> Void = { _ in }

        // Detail-host construction state. Updated each updateNSView so a
        // hosting view built later in the session captures the latest
        // theme, font, and callback closures (instead of whatever was
        // alive at makeNSView time).
        weak var themeManager: ThemeManager?
        var fontSize: Double = 12.0
        var onCopy: (LogEntry) -> Void = { _ in }
        var onFilterToComponent: (LogEntry) -> Void = { _ in }
        var onLookupErrorCode: (String) -> Void = { _ in }

        /// Build the `NSHostingView` for a row's expanded detail. Called
        /// by `LogScrollDocumentView.syncHostingView()` via the
        /// `detailViewBuilder` closure plumbed in `makeNSView`.
        func buildDetailHostingView(for entry: LogEntry) -> NSView {
            guard let themeManager else { return NSView() }
            let detail = InlineRowDetailView(
                entry: entry,
                fontSize: fontSize,
                onCopy: { [weak self] in self?.onCopy(entry) },
                onFilterToComponent: { [weak self] in self?.onFilterToComponent(entry) },
                onLookupErrorCode: { [weak self] code in self?.onLookupErrorCode(code) }
            )
            .environmentObject(themeManager)
            return NSHostingView(rootView: detail)
        }

        /// Subscription to the inbound `scrollToTimestampSignal` publisher.
        /// Installed once in `installScrollSync(...)` and held for the
        /// coordinator's lifetime — the publisher itself (a PassthroughSubject
        /// on AppState) persists across LogScrollView struct churn.
        private var scrollSyncCancellable: AnyCancellable?

        // MARK: - Pane-sync state (mirrors NSLogTableView.Coordinator)

        /// Throttle window for outbound visible-top reports. Last fire
        /// time + last reported entry ID — only fires when ≥100ms has
        /// passed AND the top entry actually changed.
        private var lastVisibleTopReport: Date = .distantPast
        private var lastReportedEntryID: Int?

        /// After a sync-driven scroll lands, suppress outbound reports
        /// for this long so the resulting scrollViewDidScroll doesn't
        /// ricochet a "I just moved!" event back to the pane that drove
        /// us here. Load-bearing per PR #33 review #1 — do not simplify.
        private var suppressReportsUntil: Date = .distantPast

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func installObservers() {
            guard let container else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewFrameChanged(_:)),
                name: NSView.frameDidChangeNotification,
                object: container.scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: container.scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidScroll(_:)),
                name: NSScrollView.didLiveScrollNotification,
                object: container.scrollView
            )
            // willStart / didEnd flank the entire live-scroll session —
            // gesture, momentum, and rubber-band bounce. We use these to
            // gate frame.size.height growth on the document view, so
            // streaming entries don't shift the bounce target mid-flight.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(willStartLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: container.scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didEndLiveScroll(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: container.scrollView
            )
        }

        /// Subscribe to inbound sync-driven scrolls. Called from
        /// `makeNSView` so the subscription is set up exactly once.
        func installScrollSync(publisher: AnyPublisher<Date, Never>) {
            scrollSyncCancellable = publisher.sink { [weak self] target in
                self?.scrollToTimestamp(target)
            }
        }

        /// Clip-view width changed during live-resize. updateNSView won't
        /// fire for these (SwiftUI's representable update cadence isn't
        /// driven by AppKit layout passes), so we sync here too.
        @objc private func clipViewFrameChanged(_ notification: Notification) {
            container?.syncLayout()
        }

        /// Clip-view bounds origin changed — the user (or code) scrolled.
        /// Keep the header's horizontal offset aligned with the body and, in
        /// no-wrap mode, grow the message content width as longer lines
        /// scroll into view (widening the document + horizontal scroller).
        /// Vertical-only scrolls leave the horizontal offset untouched (the
        /// header setter no-ops on an unchanged value).
        @objc private func clipViewBoundsChanged(_ notification: Notification) {
            guard let container else { return }
            container.syncHeaderHorizontalOffset()
            if container.horizontalMessageScroll,
               container.documentView.updateMessageContentWidth() {
                container.syncLayout()
            }
        }

        @objc private func willStartLiveScroll(_ notification: Notification) {
            container?.documentView.isLiveScrolling = true
        }

        @objc private func didEndLiveScroll(_ notification: Notification) {
            container?.documentView.isLiveScrolling = false
        }

        /// User-driven scroll OR sync-driven scroll lands. Distinguishes
        /// via the suppression window: during a sync-driven scroll, the
        /// resulting scrollViewDidScroll is gated out of scroll-up auto-
        /// pause and out of outbound visible-top reporting, so we don't
        /// ricochet back to the source pane. Mirrors NSLogTableView's
        /// logic at NSLogTableView.swift:449-472.
        @objc private func scrollViewDidScroll(_ notification: Notification) {
            guard let container else { return }
            let scrollView = container.scrollView
            let documentView = container.documentView
            let clipView = scrollView.contentView

            let contentHeight = documentView.frame.size.height
            let scrollOffset = clipView.bounds.origin.y
            let visibleHeight = clipView.bounds.height
            let distanceFromBottom = contentHeight - (scrollOffset + visibleHeight)

            let inSyncScroll = Date() < suppressReportsUntil

            if distanceFromBottom > 50, documentView.isFollowing, !inSyncScroll {
                onScrollUp()
            }

            reportVisibleTopIfChanged()
        }

        /// Inbound sync-driven scroll. Find the row whose timestamp is the
        /// largest one ≤ `target`, scroll to it, arm the suppression
        /// window. Matches NSLogTableView.swift:495-500.
        private func scrollToTimestamp(_ target: Date) {
            guard let container, let row = nearestRow(forTimestamp: target) else { return }
            suppressReportsUntil = Date().addingTimeInterval(0.25)
            container.documentView.scrollRowToVisible(row)
        }

        /// Compute and fire the visible-top report if the top entry
        /// changed and we're past both the throttle gate and the
        /// suppression window. ~10Hz max fire rate.
        private func reportVisibleTopIfChanged() {
            let now = Date()
            if now < suppressReportsUntil { return }
            if now.timeIntervalSince(lastVisibleTopReport) < 0.1 { return }
            guard let container else { return }
            let documentView = container.documentView
            let visibleRect = container.scrollView.contentView.documentVisibleRect
            let topRow = documentView.firstRow(in: visibleRect)
            guard topRow >= 0, topRow < documentView.entries.count else { return }
            let topEntry = documentView.entries[topRow]
            if topEntry.id == lastReportedEntryID { return }
            lastReportedEntryID = topEntry.id
            lastVisibleTopReport = now
            onVisibleTopChanged(topEntry)
        }

        /// Largest index whose entry has `timestamp ≤ target`. Wrapper
        /// around the pure helper `findNearestRow(in:forTimestamp:)`.
        private func nearestRow(forTimestamp target: Date) -> Int? {
            guard let container else { return nil }
            return Self.findNearestRow(in: container.documentView.entries, forTimestamp: target)
        }

        /// Largest index of `entries` whose `timestamp ≤ target`. Returns
        /// nil if the array is empty or no entry has a timestamp.
        ///
        /// Upper-bound bisect — O(log n) on sorted arrays. Single-source
        /// logs are timestamp-sorted by construction; merged-view logs
        /// interleave by timestamp at merge time (per upstream CLAUDE.md
        /// invariants), so the merged result is globally sorted too.
        /// Pathological cases (logs with wildly out-of-order timestamps)
        /// fall through to the nil-fallback path; scroll-sync UX cares
        /// about smoothness, not exact row targeting.
        ///
        /// If no entry has a timestamp ≤ target (target is before all
        /// timestamps), falls back to the first timestamped entry —
        /// matches the pre-bisect linear-scan behavior.
        static func findNearestRow<C: RandomAccessCollection>(in entries: C, forTimestamp target: Date) -> Int? where C.Element == LogEntry, C.Index == Int {
            guard !entries.isEmpty else { return nil }

            // Upper-bound bisect: smallest index where the predicate
            // "timestamp ≤ target" first becomes false. The largest
            // qualifying index is then `lo - 1`.
            var lo = 0
            var hi = entries.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if let ts = entries[mid].timestamp, ts <= target {
                    lo = mid + 1
                } else {
                    // ts > target, or ts is nil. For nil-timestamp
                    // entries interleaved in an otherwise-sorted array,
                    // biasing left is a heuristic — the nil-fallback at
                    // the end catches the pathological case where the
                    // bisect missed all qualifying entries.
                    hi = mid
                }
            }

            let candidate = lo - 1
            if candidate >= 0, entries[candidate].timestamp != nil {
                return candidate
            }
            // Cap the nil-fallback scan. The naive
            // `entries.firstIndex(where: { $0.timestamp != nil })`
            // walks until it finds a timestamped entry — on an indexed
            // source with all-nil-timestamp prefix that would re-parse
            // every line via DateFormatter, the same kind of main-
            // thread hang that bit go-to-line. Scroll-sync UX is fine
            // with "couldn't find one"; 256 entries is enough to find a
            // timestamp in any reasonable log file.
            let fallbackCap = 256
            let scanEnd = Swift.min(entries.count, fallbackCap)
            for i in 0..<scanEnd where entries[i].timestamp != nil {
                return i
            }
            return nil
        }

        /// Find the row whose `lineNumber` matches `target`, scroll +
        /// select. Sticky-on-miss: if the entries array doesn't contain
        /// the target yet (e.g. async filter still running), leave the
        /// binding set so a later updateNSView retries. Async-clear via
        /// the main queue to avoid SwiftUI's "mutating state during view
        /// update" warning. Matches NSLogTableView.swift:314-327.
        func handleGoToLine(_ target: Int) {
            guard let container else { return }
            let documentView = container.documentView
            // Use the O(1) lineNumber → position helper. The naive
            // `firstIndex(where: { $0.lineNumber == target })` walks
            // every entry up to the match, which on an indexed source
            // parses every visited line (DateFormatter is the hot
            // syscall) — a 25M-line jump hung the main thread for >37s
            // before the OS spilled a crash report.
            guard let row = documentView.entries.position(forLineNumber: target) else {
                // Sticky on miss — leave binding alone.
                return
            }
            documentView.scrollAndSelect(row: row)
            // Pause Following so the landing spot sticks. Dispatched
            // async so the @Published mutation fires outside this view
            // update pass.
            let scrollUp = onScrollUp
            DispatchQueue.main.async { scrollUp() }
            // Clear the binding on the next runloop tick so subsequent
            // updateNSView passes don't keep re-scrolling.
            let binding = pendingGoToLineBinding
            DispatchQueue.main.async { binding?.wrappedValue = nil }
        }
    }
}

/// Parent view that arranges the static column header above the scrolling
/// document. The header is a sibling of the scroll view (not inside it),
/// so it stays pinned while rows scroll. The container owns the layout
/// state — visibility, user-modified widths, user-modified order — and
/// computes the [ColumnFrame] array that both the header and the
/// document view render against. Single source of truth means resize
/// hit-testing in the header can't drift from the column boundaries the
/// document view draws.
final class LogScrollContainerView: NSView {
    let headerView: LogScrollHeaderView
    let scrollView: NSScrollView
    let documentView: LogScrollDocumentView

    // MARK: - Layout state

    private(set) var visibility = ColumnVisibility(
        showLineNumber: true,
        showTimestamp: true,
        showComponent: true,
        showSource: false
    )

    /// User-modified column widths, keyed by ColumnID. Loaded from
    /// `ColumnLayoutStore` on init, updated as the user drags column
    /// dividers, persisted via the `onColumnResized` callback.
    var userWidths: [ColumnID: CGFloat] = [:]

    /// User-modified column order. Nil means "use default order".
    /// Loaded from `ColumnLayoutStore` on init, updated when the user
    /// drags a column to a new position, persisted via the
    /// `onColumnsReordered` callback.
    var userOrder: [ColumnID]?

    /// No-wrap horizontal-scroll mode for the message column. Mirrors
    /// `SettingsManager.horizontalMessageScroll`; drives the horizontal
    /// scroller, the message-column width, and the document frame width.
    private(set) var horizontalMessageScroll = false

    // MARK: - Persistence callbacks

    var onColumnResized: (ColumnID, CGFloat) -> Void = { _, _ in }
    var onColumnsReordered: ([ColumnID]) -> Void = { _ in }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        self.headerView = LogScrollHeaderView(frame: .zero)
        self.scrollView = NSScrollView()
        self.documentView = LogScrollDocumentView(frame: .zero)
        super.init(frame: frameRect)
        scrollView.documentView = documentView
        addSubview(headerView)
        addSubview(scrollView)
        autoresizesSubviews = false
        translatesAutoresizingMaskIntoConstraints = true

        // Header sends user-driven layout edits back to the container so
        // the container can update state, push fresh layout to both
        // children, and forward to the persistence callbacks.
        headerView.onResizeDrag = { [weak self] id, newWidth in
            self?.handleResize(id: id, newWidth: newWidth)
        }
        headerView.onResizeCommit = { [weak self] id in
            guard let self, let width = self.currentWidth(for: id) else { return }
            self.onColumnResized(id, width)
        }
        headerView.onReorderCommit = { [weak self] newOrder in
            self?.handleReorderCommit(newOrder)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Flip the container so the header at (x: 0, y: 0) sits at the top —
    /// matches the document view's flipped coordinate system, so column
    /// x-positions read the same on both sides.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        let h = LogScrollHeaderView.headerHeight
        headerView.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
        scrollView.frame = NSRect(x: 0, y: h, width: b.width, height: max(0, b.height - h))
    }

    // MARK: - State application

    /// Single entry point from LogScrollView.updateNSView. Updates
    /// non-layout state on the document view, then recomputes layout for
    /// the current clip-view width and pushes it to both children.
    func applyState(
        entries: FilteredEntries,
        theme: any AppTheme,
        fontSize: Double,
        visibility: ColumnVisibility,
        isFollowing: Bool,
        bookmarkedLines: Set<Int>,
        highlightRules: [HighlightRule],
        expandedEntryID: Int?,
        inlineExpansionEnabled: Bool,
        sourceNameForID: @escaping (UUID) -> String?,
        horizontalMessageScroll: Bool
    ) {
        let wasHorizontalMessageScroll = self.horizontalMessageScroll
        self.visibility = visibility
        self.horizontalMessageScroll = horizontalMessageScroll
        // Enabling the scroller lets AppKit show the horizontal bar when the
        // document outgrows the clip; autohide keeps it invisible otherwise.
        scrollView.hasHorizontalScroller = horizontalMessageScroll

        // Leaving no-wrap mode: the document is about to shrink back to the
        // clip width and the scroller disappears. Snap the horizontal scroll
        // back to the left explicitly so a previously scrolled-right view
        // (and the header offset that tracks it) can't be left stranded
        // shifted with no scroller to correct it.
        if wasHorizontalMessageScroll && !horizontalMessageScroll {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }

        documentView.apply(
            entries: entries,
            theme: theme,
            fontSize: fontSize,
            isFollowing: isFollowing,
            bookmarkedLines: bookmarkedLines,
            highlightRules: highlightRules,
            expandedEntryID: expandedEntryID,
            inlineExpansionEnabled: inlineExpansionEnabled,
            sourceNameForID: sourceNameForID,
            horizontalScrollEnabled: horizontalMessageScroll
        )
        syncLayout()
    }

    /// Recompute the column layout for the current clip-view width and
    /// push it to both the header (for hit-testing + title positioning)
    /// and the document view (for per-row column rendering). Called from
    /// `applyState` and from the frame-change observer on live-resize.
    func syncLayout() {
        let clipWidth = scrollView.contentView.frame.width

        // No-wrap mode: measure the visible messages so the column can grow
        // to fit them; nil in normal mode (message fills the remainder and
        // truncates).
        let messageContentWidth: CGFloat?
        if horizontalMessageScroll {
            documentView.updateMessageContentWidth()
            messageContentWidth = documentView.messageContentWidth
        } else {
            messageContentWidth = nil
        }

        let columns = LogScrollColumnLayout.compute(
            boundsWidth: clipWidth,
            visibility: visibility,
            savedWidths: userWidths,
            order: userOrder,
            messageContentWidth: messageContentWidth
        )

        // Document width: the clip width normally, or the full column extent
        // when no-wrap mode pushes the message column past the viewport.
        let totalWidth = columns.last.map { $0.x + $0.width } ?? clipWidth
        let docWidth = horizontalMessageScroll ? max(clipWidth, totalWidth) : clipWidth
        if documentView.frame.size.width != docWidth {
            documentView.setFrameSize(NSSize(
                width: docWidth,
                height: documentView.frame.size.height
            ))
        }

        documentView.applyLayout(columns)
        syncHeaderHorizontalOffset()

        guard let theme = documentView.theme else { return }
        headerView.apply(
            columns: columns,
            theme: theme,
            fontSize: documentView.fontSize
        )
    }

    /// Keep the header's horizontal content offset in lockstep with the body
    /// so column titles stay above their columns when the table is scrolled
    /// horizontally in no-wrap mode. A no-op (offset 0) in normal mode where
    /// the document never scrolls horizontally.
    func syncHeaderHorizontalOffset() {
        headerView.contentOffsetX = scrollView.contentView.bounds.origin.x
    }

    // MARK: - Mouse-driven layout edits (from header)

    private func handleResize(id: ColumnID, newWidth: CGFloat) {
        // Clamp into the column's [minWidth, maxWidth] band. Message
        // column doesn't participate in resize (it autofills the
        // remainder), but the header view already filters it out before
        // calling here.
        let clamped: CGFloat
        if let maxW = id.maxWidth {
            clamped = max(id.minWidth, min(maxW, newWidth))
        } else {
            clamped = max(id.minWidth, newWidth)
        }
        userWidths[id] = clamped
        syncLayout()
    }

    private func handleReorderCommit(_ newOrder: [ColumnID]) {
        userOrder = newOrder
        syncLayout()
        onColumnsReordered(newOrder)
    }

    /// Current rendered width of a column. Used by `onResizeCommit` to
    /// persist the clamped width rather than the raw drag value.
    private func currentWidth(for id: ColumnID) -> CGFloat? {
        documentView.columns.first(where: { $0.id == id })?.width
    }
}
