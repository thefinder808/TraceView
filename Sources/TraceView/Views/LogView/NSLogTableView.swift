import SwiftUI
import AppKit
import Combine

struct NSLogTableView: NSViewRepresentable {
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
    var onScrollUp: () -> Void
    /// Fires (throttled ~100ms) when the top-visible entry changes. Used by
    /// pane scroll-sync to broadcast this pane's position to the other.
    var onVisibleTopChanged: (LogEntry?) -> Void = { _ in }
    /// When this publisher fires a Date, scroll to the row with the largest
    /// timestamp <= that Date. Used by pane scroll-sync. AppState gates
    /// whether anything actually fires here, so passing the publisher even
    /// when sync is off is harmless — no Dates arrive.
    var scrollToTimestampSignal: AnyPublisher<Date, Never> = Empty().eraseToAnyPublisher()
    /// Visible only for merged-view docs. Renders the source doc's display
    /// name in the new "Source" column.
    var showSource: Bool = false
    /// Returns the display name for a source doc UUID. Only consulted for
    /// merged-view rendering; for non-merged docs the column is hidden so
    /// this never fires.
    var sourceNameForID: (UUID) -> String? = { _ in nil }
    /// Right-click → "Open in Source Log" handler. Only invoked for entries
    /// that have `sourceDocumentID` populated (merged-view rows).
    var onOpenInSourceLog: (LogEntry) -> Void = { _ in }

    static let baseRowHeight: CGFloat = 24
    static let drawerHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        // Native header gives us the resize cursor on column dividers and
        // drag-to-reorder for free. The system styles it against the window
        // appearance so it tracks light/dark automatically.
        tableView.headerView = NSTableHeaderView()
        tableView.gridStyleMask = []
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        // Only the message column resizes when the window does; user-set
        // widths on the other columns stick.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.rowClicked(_:))
        tableView.doubleAction = nil

        // Right-click context menu — items are rebuilt by the coordinator
        // (NSMenuDelegate) before each appearance so "Open in Source Log"
        // can show only when the clicked row is a merged-view entry.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        // Create columns. Max widths relaxed from earlier (timestamp was
        // capped at 160, component at 200) so users actually have room to
        // drag. lineNumber stays fixed — it's a gutter.
        let lineCol = NSTableColumn(identifier: .lineNumber)
        lineCol.title = "#"
        lineCol.width = 48
        lineCol.minWidth = 48
        lineCol.maxWidth = 80
        tableView.addTableColumn(lineCol)

        let timeCol = NSTableColumn(identifier: .timestamp)
        timeCol.title = "Timestamp"
        timeCol.width = 110
        timeCol.minWidth = 80
        timeCol.maxWidth = 280
        tableView.addTableColumn(timeCol)

        let levelCol = NSTableColumn(identifier: .level)
        levelCol.title = "Level"
        levelCol.width = 52
        levelCol.minWidth = 40
        levelCol.maxWidth = 80
        tableView.addTableColumn(levelCol)

        let compCol = NSTableColumn(identifier: .component)
        compCol.title = "Component"
        compCol.width = 110
        compCol.minWidth = 60
        compCol.maxWidth = 320
        tableView.addTableColumn(compCol)

        // Source column — visible only on merged-view docs (toggled in
        // updateNSView). Sits between component and message because that's
        // the natural read order: timestamp, level, component, source, message.
        let srcCol = NSTableColumn(identifier: .sourceLabel)
        srcCol.title = "Source"
        srcCol.width = 130
        srcCol.minWidth = 80
        srcCol.maxWidth = 240
        srcCol.isHidden = !showSource
        tableView.addTableColumn(srcCol)

        let msgCol = NSTableColumn(identifier: .message)
        msgCol.title = "Message"
        msgCol.minWidth = 200
        tableView.addTableColumn(msgCol)

        // Restore user-set widths and column order from a previous session
        // before any layout happens.
        ColumnLayoutStore.apply(to: tableView)

        // Make message column fill remaining space.
        tableView.sizeLastColumnToFit()

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView

        // Observe scroll to detect user scroll-up
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        // Persist column width / order changes.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: tableView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification,
            object: tableView
        )

        // Follow timer
        context.coordinator.startFollowTimer()

        // Subscribe to sync-driven scroll commands. The publisher delivers
        // a target Date; we find the nearest entry with timestamp <= that
        // and scroll to it, suppressing our own visible-top reports for a
        // short window so the inbound scroll doesn't bounce back.
        context.coordinator.scrollSyncCancellable = scrollToTimestampSignal.sink {
            [weak coordinator = context.coordinator] target in
            coordinator?.scrollToTimestamp(target)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }

        // Detect theme swap. Cached NSTextField cells keep their old textColor,
        // so a plain theme reassignment leaves already-visible rows looking
        // stale until the user scrolls. A full reloadData rebuilds every
        // rendered cell with the new theme while preserving the scroll offset.
        let themeChanged = coordinator.theme.name != theme.name

        // Update data
        coordinator.entries = entries
        coordinator.theme = theme
        coordinator.fontSize = fontSize
        coordinator.onScrollUp = onScrollUp
        coordinator.onVisibleTopChanged = onVisibleTopChanged
        coordinator.isFollowing = isFollowing
        coordinator.selectedEntryBinding = $selectedEntry
        coordinator.expandedEntryIDBinding = $expandedEntryID
        coordinator.inlineExpansionEnabled = inlineExpansionEnabled
        coordinator.themeManager = themeManager
        coordinator.onCopy = onCopy
        coordinator.onFilterToComponent = onFilterToComponent
        coordinator.onLookupErrorCode = onLookupErrorCode
        coordinator.onToggleBookmark = onToggleBookmark
        let bookmarksChanged = coordinator.bookmarkedLines != bookmarkedLines
        coordinator.bookmarkedLines = bookmarkedLines

        // Highlight rules change less often than the data does, so we only
        // recompile the regex cache when the rule set actually differs.
        let rulesChanged = coordinator.highlightRules != highlightRules
        if rulesChanged {
            coordinator.highlightRules = highlightRules
            coordinator.rebuildHighlightRegexes()
        }

        // Track expansion state. If mode flipped to bottomPane, force collapse.
        let desiredExpanded = inlineExpansionEnabled ? expandedEntryID : nil
        let heightChanged = coordinator.currentExpandedID != desiredExpanded
        coordinator.currentExpandedID = desiredExpanded

        // Update column visibility
        tableView.tableColumn(withIdentifier: .lineNumber)?.isHidden = !showLineNumbers
        tableView.tableColumn(withIdentifier: .timestamp)?.isHidden = !showTimestamp
        tableView.tableColumn(withIdentifier: .component)?.isHidden = !showComponent
        tableView.tableColumn(withIdentifier: .sourceLabel)?.isHidden = !showSource

        // Forward callbacks the coordinator needs at notification time
        // (NSMenu rebuilds, etc).
        coordinator.sourceNameForID = sourceNameForID
        coordinator.onOpenInSourceLog = onOpenInSourceLog

        // Update rows
        let oldCount = coordinator.previousEntryCount
        let newCount = entries.count

        // Bookmarks change in place via row view redraws — no full reload.
        if bookmarksChanged {
            tableView.enumerateAvailableRowViews { view, row in
                guard row < entries.count, let rv = view as? LogTableRowView else { return }
                let want = bookmarkedLines.contains(entries[row].lineNumber)
                if rv.isBookmarked != want {
                    rv.isBookmarked = want
                    rv.needsDisplay = true
                }
            }
        }

        // Detect whether a count growth is a clean trailing append (live-
        // tail, the common path) or a non-trailing insertion (re-enabling
        // a hidden source in a merged view interleaves entries by
        // timestamp — count grows but the new rows aren't all at the end).
        // Compare the entry now at the previous trailing index against
        // what WAS the trailing entry; if they match, the prefix is
        // unchanged and `insertRows(at: oldCount..<newCount)` is correct.
        // Otherwise the insertions land in the middle and the cheap path
        // would leave stale rows visible until scroll forces re-query.
        let isTrailingAppend: Bool = {
            guard oldCount > 0,
                  newCount > oldCount,
                  oldCount - 1 < entries.count,
                  let lastLine = coordinator.previousLastEntryLine else { return false }
            return entries[oldCount - 1].lineNumber == lastLine
        }()

        if themeChanged || rulesChanged {
            tableView.reloadData()
        } else if isTrailingAppend {
            // Incremental append — insert only new rows
            tableView.beginUpdates()
            let indexSet = IndexSet(oldCount..<newCount)
            tableView.insertRows(at: indexSet, withAnimation: [])
            tableView.endUpdates()
        } else if newCount != oldCount {
            // Full data change (filter applied, file reloaded, source
            // toggle in merged view, etc.)
            tableView.reloadData()
        }

        // Go-to-line: scroll to the row whose lineNumber matches, then clear
        // the pending binding on the next tick so subsequent updateNSView
        // passes don't keep re-scrolling to the same spot. onScrollUp
        // signals the parent to pause following so the landing spot sticks —
        // dispatched async so the @Published mutation it performs happens
        // OUTSIDE this view-update pass. Mutating ObservableObject state
        // synchronously inside updateNSView triggers SwiftUI's "mutating
        // during view update" warning, and each warning generates a dyld
        // backtrace that can hang the main thread for seconds when the
        // mutation fans out via observer chains.
        if let target = pendingGoToLine {
            if let row = entries.firstIndex(where: { $0.lineNumber == target }) {
                tableView.scrollRowToVisible(row)
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                DispatchQueue.main.async { [onScrollUp] in onScrollUp() }
                // Only clear the pending value once we've actually landed
                // on a row. Sticky on lookup miss so that a goToLine fired
                // before the new pane's filteredEntries finished its first
                // async build (e.g. sidebar bookmark click that just
                // swapped tabs) still lands once entries arrive.
                let binding = $pendingGoToLine
                DispatchQueue.main.async { binding.wrappedValue = nil }
            }
        }

        // Height-only change: refresh affected rows so the drawer opens/closes.
        // noteHeightOfRows resizes rows in place but does NOT re-invoke
        // rowViewForRow, so the detail view must be attached/detached on the
        // already-visible row view directly.
        if heightChanged && newCount == oldCount {
            let affected = IndexSet(entries.indices.filter {
                entries[$0].id == desiredExpanded || entries[$0].id == coordinator.previousExpandedID
            })
            if !affected.isEmpty {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    tableView.noteHeightOfRows(withIndexesChanged: affected)
                }
                for idx in affected {
                    coordinator.syncDetailView(forRow: idx)
                }
            }
        }
        coordinator.previousExpandedID = desiredExpanded

        coordinator.previousEntryCount = newCount
        coordinator.previousLastEntryLine = entries.last?.lineNumber

        // Auto-follow: handled by the coordinator's timer
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: NSLogTableView
        var entries: [LogEntry] = []
        var theme: any AppTheme
        var fontSize: Double = 12
        var isFollowing: Bool = true
        var onScrollUp: () -> Void = {}
        var selectedEntryBinding: Binding<LogEntry?>?
        var expandedEntryIDBinding: Binding<Int?>?
        var inlineExpansionEnabled: Bool = true
        var themeManager: ThemeManager?
        var onCopy: (LogEntry) -> Void = { _ in }
        var onFilterToComponent: (LogEntry) -> Void = { _ in }
        var onLookupErrorCode: (String) -> Void = { _ in }
        var onToggleBookmark: (LogEntry) -> Void = { _ in }
        var sourceNameForID: (UUID) -> String? = { _ in nil }
        var onOpenInSourceLog: (LogEntry) -> Void = { _ in }
        var bookmarkedLines: Set<Int> = []
        var highlightRules: [HighlightRule] = []
        // Compiled regex per enabled rule, in the same display order as
        // `highlightRules`. Rebuilt via rebuildHighlightRegexes() whenever
        // the source rules change.
        private var compiledHighlights: [(rule: HighlightRule, regex: NSRegularExpression)] = []
        var currentExpandedID: Int?
        var previousExpandedID: Int?
        var previousEntryCount = 0
        /// `lineNumber` of the entry that was last in the array on the
        /// previous updateNSView pass. Used to detect whether a count
        /// growth is a clean trailing append (live-tail) or an insertion-
        /// in-the-middle (e.g. re-enabling a hidden source in a merged
        /// view, which interleaves entries by timestamp). Trailing
        /// appends can use the cheap `insertRows(at:)` path; non-trailing
        /// insertions need a full reloadData or rows render stale until
        /// the table re-queries on scroll.
        var previousLastEntryLine: Int?
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private var followTimer: Timer?
        private var userScrolling = false
        var onVisibleTopChanged: (LogEntry?) -> Void = { _ in }
        var scrollSyncCancellable: AnyCancellable?
        // Throttle window for outbound visible-top reports. ~10 Hz max.
        private var lastVisibleTopReport: Date = .distantPast
        private var lastReportedEntryID: Int?
        // After a sync-driven scroll lands, suppress outbound reports for
        // this long so the resulting scrollViewDidScroll doesn't ricochet
        // a "I just moved!" event back to the pane that drove us here.
        private var suppressReportsUntil: Date = .distantPast

        init(parent: NSLogTableView) {
            self.parent = parent
            self.entries = parent.entries
            self.theme = parent.theme
            self.fontSize = parent.fontSize
            self.isFollowing = parent.isFollowing
            self.inlineExpansionEnabled = parent.inlineExpansionEnabled
            self.themeManager = parent.themeManager
            super.init()
        }

        deinit {
            followTimer?.invalidate()
            // Coordinator registers as an observer for scroll / column
            // notifications in makeNSView. NotificationCenter holds an
            // unowned ref, so leaving these in place after dealloc crashes
            // on the next matching notification.
            NotificationCenter.default.removeObserver(self)
        }

        func startFollowTimer() {
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                self?.followTick()
            }
        }

        private func followTick() {
            guard isFollowing, let tableView, entries.count > 0 else { return }
            let lastRow = entries.count - 1
            tableView.scrollRowToVisible(lastRow)
        }

        @objc func columnDidResize(_ notification: Notification) {
            guard let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            ColumnLayoutStore.saveWidth(Double(col.width), for: col.identifier.rawValue)
        }

        @objc func columnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            let order = tableView.tableColumns.map { $0.identifier.rawValue }
            ColumnLayoutStore.saveOrder(order)
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let scrollView, let tableView else { return }

            // Check if user scrolled away from the bottom
            let clipView = scrollView.contentView
            let contentHeight = tableView.frame.height
            let scrollOffset = clipView.bounds.origin.y
            let visibleHeight = clipView.bounds.height

            let distanceFromBottom = contentHeight - (scrollOffset + visibleHeight)

            // During the sync-driven-scroll suppression window this scroll
            // event came from pane sync, not the user — don't pause Following
            // or fan out a visible-top report. Without this gate, a sync-
            // driven landing >50pt from the bottom looks like a user scroll
            // and trips auto-pause on both panes (see PR #33 review #1).
            let inSyncScroll = Date() < suppressReportsUntil

            if distanceFromBottom > 50 && isFollowing && !inSyncScroll {
                onScrollUp()
            }

            reportVisibleTopIfChanged()
        }

        /// Computes the top-visible row's entry and fires onVisibleTopChanged
        /// if changed, throttled to ~10 Hz. Suppressed for a short window
        /// after a sync-driven scroll to break the bounce-back loop.
        private func reportVisibleTopIfChanged() {
            let now = Date()
            if now < suppressReportsUntil { return }
            if now.timeIntervalSince(lastVisibleTopReport) < 0.1 { return }
            guard let scrollView, let tableView else { return }
            let visibleRows = tableView.rows(in: scrollView.contentView.documentVisibleRect)
            guard visibleRows.location >= 0,
                  visibleRows.location < entries.count else { return }
            let topEntry = entries[visibleRows.location]
            if topEntry.id == lastReportedEntryID { return }
            lastReportedEntryID = topEntry.id
            lastVisibleTopReport = now
            onVisibleTopChanged(topEntry)
        }

        /// Sync-driven scroll: find the row whose timestamp is closest but
        /// not later than `target`, scroll there, and arm the suppression
        /// window so the resulting scroll notification doesn't echo back.
        func scrollToTimestamp(_ target: Date) {
            guard let tableView else { return }
            guard let row = nearestRow(forTimestamp: target) else { return }
            suppressReportsUntil = Date().addingTimeInterval(0.25)
            tableView.scrollRowToVisible(row)
        }

        /// Largest index whose entry has `timestamp <= target`. If no entry
        /// qualifies (target is before any timestamped row), returns the
        /// first row that has any timestamp. Returns nil if no entry has a
        /// timestamp at all.
        private func nearestRow(forTimestamp target: Date) -> Int? {
            var bestIndex: Int?
            var bestTimestamp: Date?
            for (i, entry) in entries.enumerated() {
                guard let ts = entry.timestamp, ts <= target else { continue }
                if bestTimestamp == nil || ts > bestTimestamp! {
                    bestIndex = i
                    bestTimestamp = ts
                }
            }
            if bestIndex == nil {
                bestIndex = entries.firstIndex(where: { $0.timestamp != nil })
            }
            return bestIndex
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < entries.count, let column = tableColumn else { return nil }
            let entry = entries[row]

            let cellID = NSUserInterfaceItemIdentifier("LogCell_\(column.identifier.rawValue)")
            let cell: NSTextField
            if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField {
                cell = existing
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = cellID
                cell.isEditable = false
                cell.isBordered = false
                cell.drawsBackground = false
                cell.lineBreakMode = .byTruncatingTail
                cell.maximumNumberOfLines = 1
            }

            let monoFont = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
            let smallFont = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize - 1), weight: .regular)
            let badgeFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

            switch column.identifier {
            case .lineNumber:
                cell.stringValue = "\(entry.lineNumber)"
                cell.font = smallFont
                cell.textColor = NSColor(theme.tertiaryText)
                cell.alignment = .right

            case .timestamp:
                cell.stringValue = entry.timestamp.map { Formatters.formatTimestamp($0) } ?? "—"
                cell.font = monoFont
                cell.textColor = NSColor(theme.timestampText)
                cell.alignment = .left

            case .level:
                cell.stringValue = entry.level.shortName
                cell.font = badgeFont
                cell.textColor = NSColor(theme.badgeText(for: entry.level))
                cell.alignment = .center

            case .component:
                cell.stringValue = entry.component ?? "—"
                cell.font = monoFont
                cell.textColor = NSColor(theme.componentText)
                cell.alignment = .left

            case .sourceLabel:
                if let id = entry.sourceDocumentID,
                   let name = sourceNameForID(id) {
                    cell.stringValue = name
                } else {
                    cell.stringValue = "—"
                }
                cell.font = smallFont
                cell.textColor = NSColor(theme.componentText)
                cell.alignment = .left

            case .message:
                cell.stringValue = entry.message
                cell.font = monoFont
                cell.textColor = NSColor(messageColor(for: entry.level))
                cell.alignment = .left

            default:
                break
            }

            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row < entries.count else { return nil }
            let entry = entries[row]
            let rowView = LogTableRowView()
            rowView.entryLevel = entry.level
            rowView.theme = theme
            rowView.baseRowHeight = NSLogTableView.baseRowHeight
            rowView.isBookmarked = bookmarkedLines.contains(entry.lineNumber)
            rowView.customHighlightColor = highlightColor(for: entry)

            if inlineExpansionEnabled, entry.id == currentExpandedID {
                attachDetailView(to: rowView, entry: entry)
            }
            return rowView
        }

        // Called from updateNSView after an expansion toggle to sync the
        // detail view of an already-visible row (rowViewForRow is not
        // re-invoked by noteHeightOfRows).
        func syncDetailView(forRow row: Int) {
            guard row >= 0, row < entries.count, let tableView else { return }
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? LogTableRowView else { return }
            let entry = entries[row]
            if inlineExpansionEnabled, entry.id == currentExpandedID {
                attachDetailView(to: rowView, entry: entry)
            } else {
                rowView.removeDetailView()
            }
        }

        private func attachDetailView(to rowView: LogTableRowView, entry: LogEntry) {
            guard let themeManager else { return }
            let detail = InlineRowDetailView(
                entry: entry,
                onCopy: { [weak self] in self?.onCopy(entry) },
                onFilterToComponent: { [weak self] in self?.onFilterToComponent(entry) },
                onLookupErrorCode: { [weak self] code in self?.onLookupErrorCode(code) }
            )
            .environmentObject(themeManager)

            let hosting = NSHostingView(rootView: detail)
            rowView.attachDetailView(hosting)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < entries.count else { return NSLogTableView.baseRowHeight }
            if inlineExpansionEnabled, entries[row].id == currentExpandedID {
                return NSLogTableView.baseRowHeight + NSLogTableView.drawerHeight
            }
            return NSLogTableView.baseRowHeight
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            if row >= 0 && row < entries.count {
                selectedEntryBinding?.wrappedValue = entries[row]
            } else {
                selectedEntryBinding?.wrappedValue = nil
            }
        }

        // Fires on every click — including re-click of the already-selected
        // row, which is how a user collapses the drawer. selectionDidChange
        // alone misses the re-click case because selection hasn't changed.
        // Rebuilds the cached regex list. Disabled rules and rules whose
        // patterns fail to compile are silently skipped; the Settings row
        // surfaces the invalid-regex state visually.
        func rebuildHighlightRegexes() {
            compiledHighlights = highlightRules.compactMap { rule in
                guard rule.isEnabled,
                      !rule.pattern.isEmpty,
                      let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
                return (rule, regex)
            }
        }

        // First matching rule wins. Per-row cost is small — each regex
        // runs against the message once. Rendered rows only (~40 visible),
        // so this is cheap even with many rules.
        func highlightColor(for entry: LogEntry) -> NSColor? {
            guard !compiledHighlights.isEmpty else { return nil }
            let range = NSRange(entry.message.startIndex..., in: entry.message)
            for (rule, regex) in compiledHighlights {
                if regex.firstMatch(in: entry.message, range: range) != nil {
                    return NSColor(rule.color)
                }
            }
            return nil
        }

        // Fires from the right-click menu. NSTableView exposes the clicked
        // row via .clickedRow (-1 if the click was on blank table area).
        @objc func toggleBookmarkMenuAction(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < entries.count else { return }
            onToggleBookmark(entries[row])
        }

        @objc func openInSourceLogMenuAction(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < entries.count else { return }
            onOpenInSourceLog(entries[row])
        }

        // MARK: - NSMenuDelegate

        // Rebuild the right-click menu items right before each appearance.
        // Lets us conditionally include "Open in Source Log" only when the
        // clicked row is a merged-view entry (has a sourceDocumentID).
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let row = tableView.clickedRow
            let entry: LogEntry? = (row >= 0 && row < entries.count) ? entries[row] : nil

            let bookmarkItem = NSMenuItem(
                title: "Toggle Bookmark",
                action: #selector(toggleBookmarkMenuAction(_:)),
                keyEquivalent: "d"
            )
            bookmarkItem.keyEquivalentModifierMask = .command
            bookmarkItem.target = self
            menu.addItem(bookmarkItem)

            if let entry, entry.sourceDocumentID != nil {
                menu.addItem(NSMenuItem.separator())
                let sourceLabel: String
                if let id = entry.sourceDocumentID, let name = sourceNameForID(id) {
                    sourceLabel = "Open in \(name)"
                } else {
                    sourceLabel = "Open in Source Log"
                }
                let sourceItem = NSMenuItem(
                    title: sourceLabel,
                    action: #selector(openInSourceLogMenuAction(_:)),
                    keyEquivalent: ""
                )
                sourceItem.target = self
                menu.addItem(sourceItem)
            }
        }

        @objc func rowClicked(_ sender: Any?) {
            guard inlineExpansionEnabled, let tableView else { return }
            let row = tableView.clickedRow
            guard row >= 0, row < entries.count else { return }
            let entry = entries[row]
            if currentExpandedID == entry.id {
                expandedEntryIDBinding?.wrappedValue = nil
            } else {
                expandedEntryIDBinding?.wrappedValue = entry.id
            }
        }

        private func messageColor(for level: LogLevel) -> Color {
            switch level {
            case .critical, .error: return theme.errorText
            case .warning: return theme.warningText
            case .debug: return theme.debugText
            default: return theme.primaryText
            }
        }
    }
}

// MARK: - Custom Row View (for background highlighting)

class LogTableRowView: NSTableRowView {
    var entryLevel: LogLevel = .info
    var theme: (any AppTheme)?
    var baseRowHeight: CGFloat = 24
    var isBookmarked: Bool = false
    var customHighlightColor: NSColor?
    private(set) var detailView: NSView?
    private var detailConstraints: [NSLayoutConstraint] = []

    // Pin the detail view below the cell band via AutoLayout. Frame-based
    // positioning doesn't play nicely with NSHostingView — its SwiftUI
    // content is sized via layout constraints, and without a constraint on
    // the host's size the content renders at zero.
    func attachDetailView(_ view: NSView) {
        detailView?.removeFromSuperview()
        NSLayoutConstraint.deactivate(detailConstraints)
        detailConstraints = []

        detailView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)

        detailConstraints = [
            view.topAnchor.constraint(equalTo: topAnchor, constant: baseRowHeight),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(detailConstraints)
        needsLayout = true
    }

    func removeDetailView() {
        NSLayoutConstraint.deactivate(detailConstraints)
        detailConstraints = []
        detailView?.removeFromSuperview()
        detailView = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        removeDetailView()
    }

    override func layout() {
        super.layout()
        // Pin cells to the top `baseRowHeight` band. Without this, a tall
        // expanded row would stretch the cells themselves. Detail view
        // positioning is handled via AutoLayout (attachDetailView).
        for sub in subviews where sub is NSTableCellView {
            var f = sub.frame
            f.origin.y = 0
            f.size.height = baseRowHeight
            sub.frame = f
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else {
            super.draw(dirtyRect)
            return
        }

        // Draw level-based background across the whole (possibly expanded) row.
        let bgColor: NSColor
        switch entryLevel {
        case .critical:
            bgColor = NSColor(theme.criticalHighlight)
        case .error:
            bgColor = NSColor(theme.errorHighlight)
        case .warning:
            bgColor = NSColor(theme.warningHighlight)
        default:
            bgColor = NSColor(theme.tableBackground)
        }

        bgColor.setFill()
        dirtyRect.fill()

        // Custom highlight rule tint, composed over the level background.
        // Kept low alpha so severity still reads through — a "ratelimit"
        // rule still lets an ERROR row look red, with an amber tint on top.
        if let custom = customHighlightColor {
            let band = NSRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: min(baseRowHeight, bounds.height)
            ).intersection(dirtyRect)
            if !band.isEmpty {
                custom.withAlphaComponent(0.22).setFill()
                band.fill()
            }
        }

        // Selection highlight applies only to the cell-row band, not the drawer.
        if isSelected {
            let selectionRect = NSRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: min(baseRowHeight, bounds.height)
            ).intersection(dirtyRect)
            if !selectionRect.isEmpty {
                NSColor(theme.accentColor).withAlphaComponent(0.2).setFill()
                selectionRect.fill()
            }
        }

        // Bookmark marker — a 3px accent-colored stripe along the left edge
        // of the row. Visible over the level tint without being loud.
        if isBookmarked {
            let stripe = NSRect(
                x: 0,
                y: 0,
                width: 3,
                height: min(baseRowHeight, bounds.height)
            ).intersection(dirtyRect)
            if !stripe.isEmpty {
                NSColor(theme.accentColor).setFill()
                stripe.fill()
            }
        }
    }
}

// MARK: - Column Identifiers

extension NSUserInterfaceItemIdentifier {
    static let lineNumber = NSUserInterfaceItemIdentifier("lineNumber")
    static let timestamp = NSUserInterfaceItemIdentifier("timestamp")
    static let level = NSUserInterfaceItemIdentifier("level")
    static let component = NSUserInterfaceItemIdentifier("component")
    static let sourceLabel = NSUserInterfaceItemIdentifier("sourceLabel")
    static let message = NSUserInterfaceItemIdentifier("message")
}
