import SwiftUI
import Combine
import AppKit

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

    /// Pane the user most recently interacted with. Drives where menu
    /// shortcuts ⌘F / ⌘G / ⇧⌘G / ⌘D land when split is open. Updated on
    /// row selection, tab tap, and filter-bar focus. Resets to .primary
    /// when the split closes so a stale .secondary doesn't no-op the
    /// next shortcut.
    @Published var activePane: Pane = .primary

    @Published var isSidebarVisible: Bool = true
    @Published var showErrorLookup: Bool = false
    @Published var showCommandPalette: Bool = false
    /// Drives the "New Remote Connection" sheet (File menu + sidebar button).
    @Published var showNewConnectionSheet: Bool = false
    /// Pane-targeted export request. Each LogDocumentView attaches a sheet
    /// that only presents when this matches its own pane, so the active
    /// pane's filtered entries get exported and the inactive pane stays put.
    /// nil = no sheet open. Replaced the global `showExport: Bool` because
    /// in split view both panes used to attach the same boolean and race.
    @Published var exportRequest: ExportRequest? = nil
    @Published var showGoToLine: Bool = false

    struct ExportRequest: Identifiable, Equatable {
        let id = UUID()
        let pane: Pane
    }

    func requestExport(in pane: Pane) {
        exportRequest = ExportRequest(pane: pane)
    }

    func toggleSidebarVisibility() {
        isSidebarVisible.toggle()
    }

    /// Scroll-sync between split panes. When on, scrolling one pane drives
    /// the other to the entry with the closest timestamp. No-op when split
    /// is closed or the driving pane has no parsed timestamps.
    @Published var paneScrollSyncEnabled: Bool = false

    /// Timestamps published by the secondary pane, consumed by the primary
    /// to scroll itself. Cross-wired on purpose: each pane publishes its
    /// own scroll position to the OPPOSITE subject so subscribers don't
    /// need to filter by source.
    let primaryScrollSyncSignal = PassthroughSubject<Date, Never>()
    let secondaryScrollSyncSignal = PassthroughSubject<Date, Never>()

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

    // Per-pane "scroll to this lineNumber" signals. Set by Go-To-Line,
    // sidebar bookmarks, find-step, histogram-click, and the merged-view's
    // "Open in Source Log" jump. NSLogTableView in each pane observes its
    // own and scrolls when set, then clears.
    //
    // Pane-scoped because merged docs use sequential lineNumbers that can
    // collide with their source docs' lineNumbers — a global binding would
    // make the merged view mis-scroll any time we navigated the source.
    @Published var pendingPrimaryGoToLine: Int? = nil
    @Published var pendingSecondaryGoToLine: Int? = nil

    /// Route a go-to-line to a specific pane. Use this from any code path
    /// that knows which pane it's acting in.
    func goToLine(_ line: Int, in pane: Pane) {
        switch pane {
        case .primary: pendingPrimaryGoToLine = line
        case .secondary: pendingSecondaryGoToLine = line
        }
    }

    /// Navigate to a line in a specific document, switching the right
    /// pane's selected tab to the doc first if needed. Used by sidebar
    /// bookmark clicks where the doc may not be the currently-selected
    /// tab in either pane. Routing prefers primary when the doc is in
    /// both pane orders.
    func goToLine(_ line: Int, in document: LogDocument) {
        let docID = document.id
        let targetPane: Pane
        if primaryTabOrder.contains(docID) {
            selectedDocumentID = docID
            targetPane = .primary
        } else if secondaryTabOrder.contains(docID) {
            secondarySelectedDocumentID = docID
            targetPane = .secondary
        } else {
            // Doc has bookmarks but isn't in either pane (e.g. a merged-
            // source doc that was hidden when its merged view took over).
            // Reopen it in primary as a defensive fallback.
            primaryTabOrder.append(docID)
            selectedDocumentID = docID
            targetPane = .primary
        }
        activePane = targetPane
        // The tab-swap above may swap out a LogDocumentView, so let the
        // new view mount before firing the scroll signal — otherwise the
        // freshly-subscribed NSLogTableView misses the published value.
        DispatchQueue.main.async { [weak self] in
            self?.goToLine(line, in: targetPane)
        }
    }

    let logBrowser = LogBrowserService()
    private var documentSubscriptions: [UUID: AnyCancellable] = [:]
    private var tabPersistenceCancellables = Set<AnyCancellable>()

    // While any NSMenu is being tracked (the macOS menu bar's File/Edit/View
    // dropdowns, SwiftUI .contextMenu, etc.), suppress forwarded publishes.
    // Otherwise the App scene's body re-evaluates on every document tick and
    // SwiftUI replaces the menu bar's NSMenu, cancelling the user's open
    // tracking session — items appear briefly then vanish. The next document
    // tick after the menu closes refreshes views naturally.
    private var isMenuTracking = false

    // Exposed for SettingsManager to clear when the user toggles
    // restoreTabsOnLaunch off, so opting out doesn't leak saved state.
    static let savedOpenTabsKey = "traceview.savedOpenTabs"
    static let savedSelectedTabKey = "traceview.savedSelectedTab"

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuStartedTracking),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuEndedTracking),
            name: NSMenu.didEndTrackingNotification, object: nil)

        setupTabPersistence()
        restoreTabsIfEnabled()
    }

    @objc private func menuStartedTracking(_ note: Notification) {
        isMenuTracking = true
    }

    @objc private func menuEndedTracking(_ note: Notification) {
        isMenuTracking = false
    }

    // MARK: - Derived pane collections

    var primaryDocuments: [LogDocument] {
        primaryTabOrder.compactMap { id in documents.first { $0.id == id } }
    }

    /// Docs the sidebar shows under "Open Files". Hides source docs that
    /// are only alive because a merged view holds them — those are
    /// considered "internal" to the merged view and surface via the
    /// merged row's right-click "Open in <source>" instead of as a
    /// top-level Open Files entry.
    var visibleDocuments: [LogDocument] {
        documents.filter { doc in
            primaryTabOrder.contains(doc.id)
                || secondaryTabOrder.contains(doc.id)
                || !isReferencedByMergedView(documentID: doc.id)
        }
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

    func selectedDocument(in pane: Pane) -> LogDocument? {
        pane == .primary ? selectedDocument : secondaryDocument
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
        activePane = .primary
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

        // Forward child changes to trigger UI updates, except while a menu
        // is being tracked (see isMenuTracking above).
        let sub = document.objectWillChange.sink { [weak self] _ in
            guard let self, !self.isMenuTracking else { return }
            self.objectWillChange.send()
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

        // If the secondary pane was closed tab-by-tab, the split is now
        // gone — clear activePane so subsequent ⌘G/⇧⌘G/⌘D/⌘F don't no-op
        // against a pane that no longer exists. Guarded against no-op
        // writes because closeTab is called in a tight loop from
        // createMergedView (closing source tabs); spurious @Published
        // fires there cascaded through SwiftUI and broke the freshly-
        // mounted merged view's first filteredEntries build.
        if !isSplitView && activePane != .primary {
            activePane = .primary
        }

        // Tear down anything that's now unreachable. The sweep, not just an
        // inline check on `documentID`, is what handles the merged-view
        // close case: closing a merged doc orphans its sources (now in no
        // tab order, no longer referenced by any merged view), and the
        // sweep collects them in the same pass.
        reapOrphanedDocuments()
    }

    private func isReferencedByMergedView(documentID: UUID) -> Bool {
        documents.contains { doc in
            if case .merged(let ids) = doc.source {
                return ids.contains(documentID)
            }
            return false
        }
    }

    /// Removes any docs that are no longer reachable: not in either pane's
    /// tab order, and not held as a source by any still-open merged doc.
    /// Runs after a tab close so a merged-view teardown also cleans up any
    /// sources it was the last reference to.
    ///
    /// Iterative because removing a merged doc can orphan its sources,
    /// which a single-pass filter wouldn't see (the merged doc was still
    /// `present` at filter time, so its sources were marked referenced).
    /// Each iteration removes at least one doc; loop terminates in at
    /// most documents.count rounds.
    private func reapOrphanedDocuments() {
        while true {
            let orphans = documents.filter { doc in
                !primaryTabOrder.contains(doc.id)
                    && !secondaryTabOrder.contains(doc.id)
                    && !isReferencedByMergedView(documentID: doc.id)
            }
            if orphans.isEmpty { return }
            for orphan in orphans {
                documentSubscriptions.removeValue(forKey: orphan.id)
            }
            let orphanIDs = Set(orphans.map(\.id))
            documents.removeAll { orphanIDs.contains($0.id) }
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
    /// Order matters: add to the target FIRST so the doc has a live pane
    /// reference throughout, then close in the source. If we closed first,
    /// `closeTab`'s teardown check would see zero references and destroy
    /// the document before we could re-attach it.
    func moveTabToOtherPane(documentID: UUID, from source: Pane) {
        let target: Pane = source == .primary ? .secondary : .primary
        switch target {
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
        closeTab(documentID: documentID, in: source)
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

    // MARK: - Remote connections

    /// Open (or focus) a saved remote connection in the given pane. Dedupes
    /// on the connection's id so opening the same connection twice just
    /// re-activates the existing tab instead of spawning a second ssh.
    func openRemoteConnection(_ connection: RemoteConnection, into pane: Pane = .primary) {
        if let existing = documents.first(where: {
            if case .remote(let c) = $0.source { return c.id == connection.id }
            return false
        }) {
            addTab(documentID: existing.id, to: pane)
            return
        }

        let doc = LogDocument(
            source: .remote(connection),
            displayName: connection.displayName
        )
        doc.isLive = true
        addDocument(doc, to: pane)
    }

    // MARK: - Navigation

    /// ⌘1…⌘9 — selects the Nth primary tab.
    func selectDocument(at index: Int) {
        guard primaryTabOrder.indices.contains(index) else { return }
        selectedDocumentID = primaryTabOrder[index]
    }

    func toggleFollowing(in pane: Pane) {
        guard let current = selectedDocument(in: pane)?.isFollowing else { return }
        setFollowing(pane: pane, following: !current)
    }

    /// Open the error lookup panel pre-filled with `code`.
    func lookupErrorCode(_ code: String) {
        pendingErrorLookupCode = code
        showErrorLookup = true
    }

    /// Fires the main-menu ⌘D shortcut. LogDocumentView observes this tick
    /// and toggles a bookmark on its currently-selected row.
    @Published var pendingBookmarkToggleTick: Int = 0
    func toggleBookmarkOnSelection() {
        pendingBookmarkToggleTick += 1
    }

    /// Fires ⌘⌥R. Active pane's LogDocumentView observes the tick and
    /// flips its viewModel.filter.isRegex. Lives on AppState so the Filter
    /// menu (which is global) can reach the per-pane VM via the same
    /// active-pane gating used by ⌘D / ⌘G.
    @Published var pendingRegexToggleTick: Int = 0
    func toggleRegex() {
        pendingRegexToggleTick += 1
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

    func jumpToBottom(in pane: Pane) {
        setFollowing(pane: pane, following: true)
    }

    func reloadFile(in pane: Pane) {
        guard let doc = selectedDocument(in: pane), case .file = doc.source else { return }
        doc.reload()
    }

    // MARK: - Pane scroll sync

    /// Called by each pane when its top-visible entry changes. Routes the
    /// timestamp to the OTHER pane's signal so that pane can self-scroll.
    func reportPaneScroll(pane: Pane, entry: LogEntry?) {
        guard paneScrollSyncEnabled, isSplitView,
              let timestamp = entry?.timestamp else { return }
        switch pane {
        case .primary:   secondaryScrollSyncSignal.send(timestamp)
        case .secondary: primaryScrollSyncSignal.send(timestamp)
        }
    }

    func togglePaneScrollSync() {
        paneScrollSyncEnabled.toggle()
    }

    // MARK: - Merged views

    /// Tracks which merged view should show its create-sheet next time it's
    /// visible. Boolean toggle that the Tools menu sets and the sheet
    /// observes. Kept here (not as @State on a view) because the trigger is
    /// menu-driven and the sheet attaches to ContentView.
    @Published var showCreateMergedView: Bool = false

    /// Build a merged-view document over `sources` and open it in the
    /// primary pane. Display name is "a + b" (or "a + b + 2 more" when
    /// there are 4+ sources). Caller is responsible for ensuring at least
    /// 2 sources are passed.
    ///
    /// Source tabs are closed in BOTH panes after the merged view opens.
    /// The source LogDocuments are NOT torn down — closeTab now skips
    /// teardown when a merged doc holds the source — so source content
    /// stays alive, the sidebar still lists them under Open Files, and
    /// "Open in Source Log" can re-tab them on demand.
    func createMergedView(from sources: [LogDocument]) {
        guard sources.count >= 2 else { return }
        let displayName = mergedDisplayName(for: sources)
        let merged = LogDocument(mergedSources: sources, displayName: displayName)
        addDocument(merged, to: .primary)
        for src in sources {
            if primaryTabOrder.contains(src.id) {
                closeTab(documentID: src.id, in: .primary)
            }
            if secondaryTabOrder.contains(src.id) {
                closeTab(documentID: src.id, in: .secondary)
            }
        }
    }

    private func mergedDisplayName(for sources: [LogDocument]) -> String {
        let names = sources.map(\.displayName)
        if names.count <= 3 {
            return names.joined(separator: " + ")
        }
        let head = names.prefix(2).joined(separator: " + ")
        return "\(head) + \(names.count - 2) more"
    }

    /// "Open in Source Log" from a merged-view row. Opens the source doc
    /// in the secondary pane (entering split if needed) and queues a
    /// scroll to the source's original lineNumber via the secondary
    /// pane's go-to-line channel.
    func openInSourceLog(documentID: UUID, lineNumber: Int) {
        guard let doc = documents.first(where: { $0.id == documentID }) else { return }
        addTab(documentID: doc.id, to: .secondary)
        // Set after addTab so the new (or focused) secondary view picks
        // it up on its next render. The Published binding on the
        // secondary's NSLogTableView will fire and scroll into place.
        pendingSecondaryGoToLine = lineNumber
    }

    /// Set the follow state for a pane's active document. When sync is on
    /// and the split is open, the other pane mirrors the change so a pause
    /// or resume in one pane affects both.
    ///
    /// Idempotent on purpose: if isFollowing already equals `following`,
    /// we skip the write so we don't fire @Published/objectWillChange for
    /// no reason. Re-entrant callers (pendingGoToLine + onScrollUp pathway,
    /// scroll observers re-arming after a programmatic scroll) would
    /// otherwise cascade observer updates that SwiftUI flags as "mutation
    /// during view update" with expensive backtrace logging.
    func setFollowing(pane: Pane, following: Bool) {
        let target = pane == .primary ? selectedDocument : secondaryDocument
        if let target, target.isFollowing != following {
            target.isFollowing = following
        }

        if paneScrollSyncEnabled, isSplitView {
            let other = pane == .primary ? secondaryDocument : selectedDocument
            if let other, other.isFollowing != following {
                other.isFollowing = following
            }
        }
    }
}
