import SwiftUI
import AppKit
import Combine

/// SwiftUI wrapper around the custom virtual-scroll log view (Phase 2
/// renderer). API matches `NSLogTableView` one-for-one so `LogDocumentView`
/// can swap between the two by branching on `SettingsManager.useNewLogView`
/// with identical argument lists at both call sites.
///
/// PR #1 carries: rendering, column headers (title only, no resize), click
/// selection, live-follow with scroll-up auto-pause. The remaining inputs
/// (expansion, go-to-line, bookmarks, highlight rules, scroll-sync,
/// keyboard nav, right-click menu) are accepted but ignored — they land in
/// P2.2–P2.4. Keeping the signature aligned avoids churning the call site
/// each PR.
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

        // Push state to the document view first — this updates its
        // visibility/theme/fontSize, which `syncWidth` then reads to
        // recompute the column layout for the header.
        container.documentView.onScrollUp = onScrollUp
        container.documentView.apply(
            entries: entries,
            theme: theme,
            fontSize: fontSize,
            visibility: visibility,
            isFollowing: isFollowing,
            sourceNameForID: sourceNameForID
        )

        container.syncWidth()
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
            container?.syncWidth()
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
/// so it stays pinned while rows scroll. Width sync — keeping the header,
/// the scroll view, and the document view all at the same width — runs
/// through `syncWidth()` on every meaningful state change.
final class LogScrollContainerView: NSView {
    let headerView: LogScrollHeaderView
    let scrollView: NSScrollView
    let documentView: LogScrollDocumentView

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

    /// Recompute the column layout for the current clip-view width and
    /// push it to both the header and (implicitly, via setFrameSize) the
    /// document view's redraw. Called from `updateNSView` for state
    /// changes and from the frame-change observer for live-resize.
    func syncWidth() {
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
            visibility: documentView.visibility
        )
        headerView.apply(columns: columns, theme: theme, fontSize: documentView.fontSize)
    }
}
