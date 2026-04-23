import SwiftUI
import Combine

/// Which split pane something targets. Tabs are per-pane even though the
/// underlying `LogDocument`s are window-scoped shared resources.
enum Pane { case primary, secondary }

final class AppState: ObservableObject {
    /// All open documents keyed by UUID — the single source of truth.
    /// Tab bars index into this via `primaryTabOrder` / `secondaryTabOrder`.
    /// A doc can legitimately appear in both orders (same file visible in
    /// both panes) without duplicating I/O.
    @Published var documents: [LogDocument] = []

    /// Ordered doc IDs shown as tabs in the primary (left) pane.
    @Published var primaryTabOrder: [UUID] = []

    /// Ordered doc IDs shown as tabs in the secondary (right) pane.
    /// Empty = split view is closed.
    @Published var secondaryTabOrder: [UUID] = []

    @Published var selectedDocumentID: UUID? = nil
    @Published var secondarySelectedDocumentID: UUID? = nil

    @Published var showErrorLookup: Bool = false
    @Published var showCommandPalette: Bool = false
    @Published var showExport: Bool = false
    @Published var showGoToLine: Bool = false

    /// Fires ⌘F / Find menu. FilterBarView observes this and focuses its
    /// search field. Tick instead of bool so repeated ⌘F presses re-focus
    /// even when the field is already in the window (e.g. after a click-
    /// away).
    @Published var focusSearchTick: Int = 0
    func focusSearchField() { focusSearchTick += 1 }

    // Set by callers that want to open the error lookup panel with a
    // pre-filled query (e.g. the inline-row "Lookup 0x…" pill). Consumed
    // by ErrorLookupPanel which clears it after populating the search.
    @Published var pendingErrorLookupCode: String? = nil

    // Set by the Go-To-Line sheet; NSLogTableView observes this and scrolls
    // to the matching row, then clears it.
    @Published var pendingGoToLine: Int? = nil

    let logBrowser = LogBrowserService()
    private var documentSubscriptions: [UUID: AnyCancellable] = [:]
    private var tabPersistenceCancellables = Set<AnyCancellable>()

    // Exposed for SettingsManager to clear when the user toggles
    // restoreTabsOnLaunch off, so opting out doesn't leak saved state.
    static let savedOpenTabsKey = "traceview.savedOpenTabs"
    static let savedSelectedTabKey = "traceview.savedSelectedTab"

    init() {
        setupTabPersistence()
        restoreTabsIfEnabled()
    }

    // MARK: - Derived pane collections

    var primaryDocuments: [LogDocument] {
        primaryTabOrder.compactMap { id in documents.first { $0.id == id } }
    }

    var secondaryDocuments: [LogDocument] {
        secondaryTabOrder.compactMap { id in documents.first { $0.id == id } }
    }

    var selectedDocument: LogDocument? {
        guard let id = selectedDocumentID else { return primaryDocuments.first }
        return documents.first { $0.id == id }
    }

    var secondaryDocument: LogDocument? {
        guard let id = secondarySelectedDocumentID else { return nil }
        return documents.first { $0.id == id }
    }

    var isSplitView: Bool { !secondaryTabOrder.isEmpty }

    func tabOrder(in pane: Pane) -> [UUID] {
        pane == .primary ? primaryTabOrder : secondaryTabOrder
    }

    func documents(in pane: Pane) -> [LogDocument] {
        pane == .primary ? primaryDocuments : secondaryDocuments
    }

    func selectedID(in pane: Pane) -> UUID? {
        pane == .primary ? selectedDocumentID : secondarySelectedDocumentID
    }

    // MARK: - Tab persistence (opt-in via SettingsManager.restoreTabsOnLaunch)

    private func setupTabPersistence() {
        // Save on any change to the open set, either pane order, or the
        // primary selection. Split state is intentionally not persisted —
        // restored sessions always start with the split closed and every
        // doc in the primary pane.
        Publishers.CombineLatest4($documents, $primaryTabOrder, $secondaryTabOrder, $selectedDocumentID)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveOpenTabsIfEnabled() }
            .store(in: &tabPersistenceCancellables)
    }

    private func saveOpenTabsIfEnabled() {
        guard UserDefaults.standard.bool(forKey: SettingsManager.restoreTabsOnLaunchKey) else { return }

        // Union of both panes' tab orders, deduped, preserving primary order
        // first. Secondary-only tabs get appended after.
        var seen = Set<UUID>()
        var orderedIDs: [UUID] = []
        for id in primaryTabOrder + secondaryTabOrder where seen.insert(id).inserted {
            orderedIDs.append(id)
        }
        let paths = orderedIDs.compactMap { id -> String? in
            guard let doc = documents.first(where: { $0.id == id }),
                  case .file(let url) = doc.source else { return nil }
            return url.path
        }
        UserDefaults.standard.set(paths, forKey: Self.savedOpenTabsKey)

        if let id = selectedDocumentID,
           let doc = documents.first(where: { $0.id == id }),
           case .file(let url) = doc.source {
            UserDefaults.standard.set(url.path, forKey: Self.savedSelectedTabKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedSelectedTabKey)
        }
    }

    private func restoreTabsIfEnabled() {
        guard UserDefaults.standard.bool(forKey: SettingsManager.restoreTabsOnLaunchKey),
              let paths = UserDefaults.standard.stringArray(forKey: Self.savedOpenTabsKey)
        else { return }

        let fm = FileManager.default
        for path in paths where fm.fileExists(atPath: path) {
            openFile(at: URL(fileURLWithPath: path))
        }

        if let selectedPath = UserDefaults.standard.string(forKey: Self.savedSelectedTabKey),
           let doc = documents.first(where: {
               if case .file(let u) = $0.source { return u.path == selectedPath }
               return false
           }) {
            selectedDocumentID = doc.id
        }
    }

    // MARK: - Split view

    /// Toggle split mode. Opens with the primary's current active doc
    /// duplicated into the secondary pane. Closing merges the secondary
    /// tabs back into primary (preserving any that weren't already there).
    func toggleSplitView() {
        if isSplitView {
            mergeSecondaryIntoPrimary()
        } else if let primary = selectedDocument {
            secondaryTabOrder = [primary.id]
            secondarySelectedDocumentID = primary.id
        }
    }

    /// Send a specific document to the secondary pane (enters split mode
    /// if needed). Called from the tab bar context menu.
    func openInSplit(_ document: LogDocument) {
        addTab(documentID: document.id, to: .secondary)
    }

    /// Add an existing doc to a pane's tab order (if not already there)
    /// and activate it. No-op if the doc isn't in `documents` — caller is
    /// responsible for having added it via `addDocument`.
    func addTab(documentID: UUID, to pane: Pane) {
        guard documents.contains(where: { $0.id == documentID }) else { return }
        switch pane {
        case .primary:
            if !primaryTabOrder.contains(documentID) {
                primaryTabOrder.append(documentID)
            }
            selectedDocumentID = documentID
        case .secondary:
            if !secondaryTabOrder.contains(documentID) {
                secondaryTabOrder.append(documentID)
            }
            secondarySelectedDocumentID = documentID
        }
    }

    func closeSplitView() {
        mergeSecondaryIntoPrimary()
    }

    private func mergeSecondaryIntoPrimary() {
        // Merge any secondary-only tabs back into primary so the doc set
        // is preserved when split closes. Primary order is kept first.
        for id in secondaryTabOrder where !primaryTabOrder.contains(id) {
            primaryTabOrder.append(id)
        }
        secondaryTabOrder = []
        secondarySelectedDocumentID = nil
    }

    // MARK: - Document management

    /// Open a new document into the primary pane (default route).
    func addDocument(_ document: LogDocument) {
        addDocument(document, to: .primary)
    }

    /// Open a new document into a specific pane.
    func addDocument(_ document: LogDocument, to pane: Pane) {
        documents.append(document)
        switch pane {
        case .primary:
            primaryTabOrder.append(document.id)
            selectedDocumentID = document.id
        case .secondary:
            secondaryTabOrder.append(document.id)
            secondarySelectedDocumentID = document.id
        }

        // Forward child changes to trigger UI updates
        let sub = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        documentSubscriptions[document.id] = sub
    }

    /// Close a tab in the given pane. If the document isn't referenced by
    /// the other pane either, the document is fully closed (removed from
    /// `documents` and its subscription torn down).
    func closeTab(documentID: UUID, in pane: Pane) {
        switch pane {
        case .primary:
            primaryTabOrder.removeAll { $0 == documentID }
            if selectedDocumentID == documentID {
                selectedDocumentID = primaryTabOrder.first
            }
        case .secondary:
            secondaryTabOrder.removeAll { $0 == documentID }
            if secondarySelectedDocumentID == documentID {
                secondarySelectedDocumentID = secondaryTabOrder.first
            }
        }

        // If nothing references this doc anymore, tear it down fully.
        if !primaryTabOrder.contains(documentID) && !secondaryTabOrder.contains(documentID) {
            documentSubscriptions.removeValue(forKey: documentID)
            documents.removeAll { $0.id == documentID }
        }
    }

    /// Close a document wherever it appears (both panes if in both). Used
    /// by the sidebar "Open Files" row's × button — the sidebar is window-
    /// level, so closing from there releases the doc entirely.
    func closeDocumentEverywhere(_ document: LogDocument) {
        if primaryTabOrder.contains(document.id) {
            closeTab(documentID: document.id, in: .primary)
        }
        if secondaryTabOrder.contains(document.id) {
            closeTab(documentID: document.id, in: .secondary)
        }
    }

    /// Move a tab from one pane to the other. Opens split if needed.
    func moveTabToOtherPane(documentID: UUID, from source: Pane) {
        let target: Pane = source == .primary ? .secondary : .primary
        closeTab(documentID: documentID, in: source)
        // closeTab might have fully closed the doc if the other pane
        // already had it — but since we're moving to the other pane, the
        // target's order doesn't have it yet (moves should only happen
        // from tabs that aren't already in both panes). Verify the doc
        // still exists; if it somehow got torn down, bail.
        guard documents.contains(where: { $0.id == documentID }) else { return }
        switch target {
        case .primary:
            primaryTabOrder.append(documentID)
            selectedDocumentID = documentID
        case .secondary:
            secondaryTabOrder.append(documentID)
            secondarySelectedDocumentID = documentID
        }
    }

    // MARK: - File opening

    func openFile() { openFile(into: .primary) }

    /// Shows the standard open panel and routes results to the given pane.
    func openFile(into pane: Pane) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.log, .plainText, .text, .data]
        panel.message = pane == .primary
            ? "Select log files to open"
            : "Select log files to open in the right pane"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            openFile(at: url, into: pane)
        }
    }

    func openFile(at url: URL) { openFile(at: url, into: .primary) }

    /// Open (or focus) `url` in the given pane. If the doc is already open
    /// but not in the target pane's tab order, add it to that pane without
    /// re-loading.
    func openFile(at url: URL, into pane: Pane) {
        if let existing = documents.first(where: {
            if case .file(let u) = $0.source { return u == url }
            return false
        }) {
            // Already open — make sure the target pane has it in its tab order
            let order = pane == .primary ? primaryTabOrder : secondaryTabOrder
            if !order.contains(existing.id) {
                switch pane {
                case .primary: primaryTabOrder.append(existing.id)
                case .secondary: secondaryTabOrder.append(existing.id)
                }
            }
            switch pane {
            case .primary: selectedDocumentID = existing.id
            case .secondary: secondarySelectedDocumentID = existing.id
            }
            return
        }

        let doc = LogDocument(source: .file(url), displayName: url.lastPathComponent)
        addDocument(doc, to: pane)
    }

    // MARK: - Unified log streaming

    func startUnifiedLogStream(predicate: String? = nil, label: String = "System Log") {
        let doc = LogDocument(
            source: .unifiedLog(predicate: predicate),
            displayName: label
        )
        doc.isLive = true
        addDocument(doc)
    }

    // MARK: - Navigation

    /// ⌘1…⌘9 — selects the Nth primary tab.
    func selectDocument(at index: Int) {
        guard primaryTabOrder.indices.contains(index) else { return }
        selectedDocumentID = primaryTabOrder[index]
    }

    func toggleFollowing() {
        selectedDocument?.isFollowing.toggle()
    }

    /// Open the error lookup panel pre-filled with `code`.
    func lookupErrorCode(_ code: String) {
        pendingErrorLookupCode = code
        showErrorLookup = true
    }

    /// Toggle a bookmark on the given line of the selected document.
    func toggleBookmark(lineNumber: Int) {
        guard let doc = selectedDocument else { return }
        if doc.bookmarks.contains(lineNumber) {
            doc.bookmarks.remove(lineNumber)
        } else {
            doc.bookmarks.insert(lineNumber)
        }
    }

    /// Fires the main-menu ⌘D shortcut. LogDocumentView observes this tick
    /// and toggles a bookmark on its currently-selected row.
    @Published var pendingBookmarkToggleTick: Int = 0
    func toggleBookmarkOnSelection() {
        pendingBookmarkToggleTick += 1
    }

    /// Fires ⌘G / ⌘⇧G. LogDocumentView observes the tick and asks its VM
    /// to step matches by `pendingFindStepDirection` (+1 / -1), then
    /// routes the landing line through pendingGoToLine.
    @Published var pendingFindStepTick: Int = 0
    var pendingFindStepDirection: Int = 1
    func stepFindMatch(by delta: Int) {
        pendingFindStepDirection = delta
        pendingFindStepTick += 1
    }

    func jumpToBottom() {
        selectedDocument?.isFollowing = true
    }

    func reloadCurrentFile() {
        guard let doc = selectedDocument, case .file = doc.source else { return }
        doc.reload()
    }
}
