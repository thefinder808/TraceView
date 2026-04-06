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
    var onScrollUp: () -> Void

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
        tableView.doubleAction = nil

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

        // Update data
        coordinator.entries = entries
        coordinator.theme = theme
        coordinator.fontSize = fontSize
        coordinator.onScrollUp = onScrollUp
        coordinator.isFollowing = isFollowing
        coordinator.selectedEntryBinding = $selectedEntry

        // Update column visibility
        tableView.tableColumn(withIdentifier: .lineNumber)?.isHidden = !showLineNumbers
        tableView.tableColumn(withIdentifier: .timestamp)?.isHidden = !showTimestamp
        tableView.tableColumn(withIdentifier: .component)?.isHidden = !showComponent

        // Update rows
        let oldCount = coordinator.previousEntryCount
        let newCount = entries.count

        if newCount > oldCount && oldCount > 0 {
            // Incremental append — insert only new rows
            tableView.beginUpdates()
            let indexSet = IndexSet( oldCount..<newCount)
            tableView.insertRows(at: indexSet, withAnimation: [])
            tableView.endUpdates()
        } else if newCount != oldCount {
            // Full data change (filter applied, file reloaded, etc.)
            tableView.reloadData()
        }

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
            return rowView
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            24
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

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else {
            super.draw(dirtyRect)
            return
        }

        // Draw level-based background
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

        // Draw selection on top
        if isSelected {
            NSColor(theme.accentColor).withAlphaComponent(0.2).setFill()
            dirtyRect.fill()
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
