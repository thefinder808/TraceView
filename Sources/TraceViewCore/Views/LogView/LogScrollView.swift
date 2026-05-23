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
    let entries: [LogEntry]
    let theme: any AppTheme
    let fontSize: Double
    let showLineNumbers: Bool
    let showTimestamp: Bool
    let showComponent: Bool
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

        // Two notifications drive the runtime:
        //   - frameDidChange on the clip view → width sync (window resize,
        //     scroller fade, pane drag).
        //   - didLiveScroll on the scroll view → scroll-up detection
        //     (drives the "Jump to Bottom" pill when the user scrolls
        //     away from the tail while following).
        container.scrollView.contentView.postsFrameChangedNotifications = true

        // Wire the document-view callback to the binding via the coordinator
        // (a closure captured by the document view can't write `@Binding`
        // directly — SwiftUI bindings need a hop back through the
        // representable's coordinator).
        container.documentView.onSelectionChanged = { [weak coordinator = context.coordinator] entry in
            coordinator?.selectedEntryBinding?.wrappedValue = entry
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

        return container
    }

    func updateNSView(_ container: LogScrollContainerView, context: Context) {
        // Update coordinator's cached bindings/callbacks so the
        // notification-driven paths (scroll observer, selection callback)
        // route through the latest values.
        context.coordinator.selectedEntryBinding = $selectedEntry
        context.coordinator.onScrollUp = onScrollUp

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
            sourceNameForID: sourceNameForID
        )
    }

    // MARK: - Coordinator

    final class Coordinator {
        weak var container: LogScrollContainerView?
        var selectedEntryBinding: Binding<LogEntry?>?
        var onScrollUp: () -> Void = {}

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
                selector: #selector(scrollViewDidScroll(_:)),
                name: NSScrollView.didLiveScrollNotification,
                object: container.scrollView
            )
        }

        /// Clip-view width changed during live-resize. updateNSView won't
        /// fire for these (SwiftUI's representable update cadence isn't
        /// driven by AppKit layout passes), so we sync here too.
        @objc private func clipViewFrameChanged(_ notification: Notification) {
            container?.syncLayout()
        }

        /// User-driven scroll. If they're scrolling above the tail while
        /// follow is on, fire onScrollUp so the parent surfaces the
        /// "Jump to Bottom" pill and pauses Following. Mirrors
        /// NSLogTableView's logic at NSLogTableView.swift:449-469, minus
        /// the sync-scroll suppression window (no scroll-sync until P2.4).
        @objc private func scrollViewDidScroll(_ notification: Notification) {
            guard let container else { return }
            let scrollView = container.scrollView
            let documentView = container.documentView
            let clipView = scrollView.contentView

            let contentHeight = documentView.frame.size.height
            let scrollOffset = clipView.bounds.origin.y
            let visibleHeight = clipView.bounds.height
            let distanceFromBottom = contentHeight - (scrollOffset + visibleHeight)

            if distanceFromBottom > 50, documentView.isFollowing {
                onScrollUp()
            }
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
        entries: [LogEntry],
        theme: any AppTheme,
        fontSize: Double,
        visibility: ColumnVisibility,
        isFollowing: Bool,
        sourceNameForID: @escaping (UUID) -> String?
    ) {
        self.visibility = visibility
        documentView.apply(
            entries: entries,
            theme: theme,
            fontSize: fontSize,
            isFollowing: isFollowing,
            sourceNameForID: sourceNameForID
        )
        syncLayout()
    }

    /// Recompute the column layout for the current clip-view width and
    /// push it to both the header (for hit-testing + title positioning)
    /// and the document view (for per-row column rendering). Called from
    /// `applyState` and from the frame-change observer on live-resize.
    func syncLayout() {
        let clipWidth = scrollView.contentView.frame.width
        if documentView.frame.size.width != clipWidth {
            documentView.setFrameSize(NSSize(
                width: clipWidth,
                height: documentView.frame.size.height
            ))
        }
        guard let theme = documentView.theme else { return }
        let columns = LogScrollColumnLayout.compute(
            boundsWidth: clipWidth,
            visibility: visibility,
            savedWidths: userWidths,
            order: userOrder
        )
        documentView.applyLayout(columns)
        headerView.apply(
            columns: columns,
            theme: theme,
            fontSize: documentView.fontSize
        )
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
