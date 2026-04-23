import SwiftUI
import AppKit

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
    let inlineExpansionEnabled: Bool
    let themeManager: ThemeManager
    var onCopy: (LogEntry) -> Void = { _ in }
    var onFilterToComponent: (LogEntry) -> Void = { _ in }
    var onLookupErrorCode: (String) -> Void = { _ in }
    var onToggleBookmark: (LogEntry) -> Void = { _ in }
    var onScrollUp: () -> Void

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
        tableView.headerView = nil // We use our own SwiftUI header
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = false
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.rowClicked(_:))
        tableView.doubleAction = nil

        // Right-click → "Toggle Bookmark" on the clicked row.
        let menu = NSMenu()
        let bookmarkItem = NSMenuItem(
            title: "Toggle Bookmark",
            action: #selector(Coordinator.toggleBookmarkMenuAction(_:)),
            keyEquivalent: "d"
        )
        bookmarkItem.keyEquivalentModifierMask = .command
        bookmarkItem.target = context.coordinator
        menu.addItem(bookmarkItem)
        tableView.menu = menu

        // Create columns
        let lineCol = NSTableColumn(identifier: .lineNumber)
        lineCol.title = "#"
        lineCol.width = 48
        lineCol.minWidth = 48
        lineCol.maxWidth = 48
        tableView.addTableColumn(lineCol)

        let timeCol = NSTableColumn(identifier: .timestamp)
        timeCol.title = "Timestamp"
        timeCol.width = 110
        timeCol.minWidth = 80
        timeCol.maxWidth = 160
        tableView.addTableColumn(timeCol)

        let levelCol = NSTableColumn(identifier: .level)
        levelCol.title = "Level"
        levelCol.width = 52
        levelCol.minWidth = 40
        levelCol.maxWidth = 60
        tableView.addTableColumn(levelCol)

        let compCol = NSTableColumn(identifier: .component)
        compCol.title = "Component"
        compCol.width = 110
        compCol.minWidth = 60
        compCol.maxWidth = 200
        tableView.addTableColumn(compCol)

        let msgCol = NSTableColumn(identifier: .message)
        msgCol.title = "Message"
        msgCol.minWidth = 200
        tableView.addTableColumn(msgCol)

        // Make message column fill remaining space
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

        // Follow timer
        context.coordinator.startFollowTimer()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let tableView = coordinator.tableView!

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

        // Track expansion state. If mode flipped to bottomPane, force collapse.
        let desiredExpanded = inlineExpansionEnabled ? expandedEntryID : nil
        let heightChanged = coordinator.currentExpandedID != desiredExpanded
        coordinator.currentExpandedID = desiredExpanded

        // Update column visibility
        tableView.tableColumn(withIdentifier: .lineNumber)?.isHidden = !showLineNumbers
        tableView.tableColumn(withIdentifier: .timestamp)?.isHidden = !showTimestamp
        tableView.tableColumn(withIdentifier: .component)?.isHidden = !showComponent

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

        if themeChanged {
            tableView.reloadData()
        } else if newCount > oldCount && oldCount > 0 {
            // Incremental append — insert only new rows
            tableView.beginUpdates()
            let indexSet = IndexSet( oldCount..<newCount)
            tableView.insertRows(at: indexSet, withAnimation: [])
            tableView.endUpdates()
        } else if newCount != oldCount {
            // Full data change (filter applied, file reloaded, etc.)
            tableView.reloadData()
        }

        // Go-to-line: scroll to the row whose lineNumber matches, then clear
        // the pending binding on the next tick so subsequent updateNSView
        // passes don't keep re-scrolling to the same spot. onScrollUp
        // signals the parent to pause following so the landing spot sticks.
        if let target = pendingGoToLine {
            if let row = entries.firstIndex(where: { $0.lineNumber == target }) {
                tableView.scrollRowToVisible(row)
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                onScrollUp()
            }
            let binding = $pendingGoToLine
            DispatchQueue.main.async { binding.wrappedValue = nil }
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

        // Auto-follow: handled by the coordinator's timer
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
        var bookmarkedLines: Set<Int> = []
        var currentExpandedID: Int?
        var previousExpandedID: Int?
        var previousEntryCount = 0
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private var followTimer: Timer?
        private var userScrolling = false

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

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let scrollView, let tableView else { return }

            // Check if user scrolled away from the bottom
            let clipView = scrollView.contentView
            let contentHeight = tableView.frame.height
            let scrollOffset = clipView.bounds.origin.y
            let visibleHeight = clipView.bounds.height

            let distanceFromBottom = contentHeight - (scrollOffset + visibleHeight)

            // If user scrolled more than 2 rows away from bottom, pause following
            if distanceFromBottom > 50 && isFollowing {
                onScrollUp()
            }
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
        // Fires from the right-click menu. NSTableView exposes the clicked
        // row via .clickedRow (-1 if the click was on blank table area).
        @objc func toggleBookmarkMenuAction(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < entries.count else { return }
            onToggleBookmark(entries[row])
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
    static let message = NSUserInterfaceItemIdentifier("message")
}
