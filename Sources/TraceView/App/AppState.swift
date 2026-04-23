import SwiftUI
import Combine

final class AppState: ObservableObject {
    @Published var documents: [LogDocument] = []
    @Published var selectedDocumentID: UUID? = nil
    @Published var showErrorLookup: Bool = false
    @Published var showCommandPalette: Bool = false
    @Published var showExport: Bool = false
    @Published var focusSearch: Bool = false
    @Published var showGoToLine: Bool = false

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

    // MARK: - Tab persistence (opt-in via SettingsManager.restoreTabsOnLaunch)

    private func setupTabPersistence() {
        // Save on any change to the open set or the active selection.
        // Live streams are skipped (no stable identity to key on).
        Publishers.CombineLatest($documents, $selectedDocumentID)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveOpenTabsIfEnabled() }
            .store(in: &tabPersistenceCancellables)
    }

    private func saveOpenTabsIfEnabled() {
        guard UserDefaults.standard.bool(forKey: SettingsManager.restoreTabsOnLaunchKey) else { return }

        let paths = documents.compactMap { doc -> String? in
            if case .file(let url) = doc.source { return url.path }
            return nil
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

    var selectedDocument: LogDocument? {
        guard let id = selectedDocumentID else { return documents.first }
        return documents.first { $0.id == id }
    }

    // MARK: - Document Management

    func addDocument(_ document: LogDocument) {
        documents.append(document)
        selectedDocumentID = document.id

        // Forward child changes to trigger UI updates
        let sub = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        documentSubscriptions[document.id] = sub
    }

    func closeDocument(_ document: LogDocument) {
        documentSubscriptions.removeValue(forKey: document.id)
        documents.removeAll { $0.id == document.id }

        if selectedDocumentID == document.id {
            selectedDocumentID = documents.first?.id
        }
    }

    func closeDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        closeDocument(documents[index])
    }

    // MARK: - File Opening

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.log, .plainText, .text, .data]
        panel.message = "Select log files to open"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            openFile(at: url)
        }
    }

    func openFile(at url: URL) {
        // Don't re-open files already open
        if case .file(let existingURL) = documents.first(where: {
            if case .file(let u) = $0.source { return u == url }
            return false
        })?.source {
            selectedDocumentID = documents.first {
                if case .file(let u) = $0.source { return u == existingURL }
                return false
            }?.id
            return
        }

        let doc = LogDocument(
            source: .file(url),
            displayName: url.lastPathComponent
        )
        addDocument(doc)
    }

    // MARK: - Unified Log Streaming

    func startUnifiedLogStream(predicate: String? = nil, label: String = "System Log") {
        let doc = LogDocument(
            source: .unifiedLog(predicate: predicate),
            displayName: label
        )
        doc.isLive = true
        addDocument(doc)
    }

    // MARK: - Navigation

    func selectDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        selectedDocumentID = documents[index].id
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

    func jumpToBottom() {
        selectedDocument?.isFollowing = true
    }

    func reloadCurrentFile() {
        // Handled by LogDocumentViewModel — triggers via notification
        guard let doc = selectedDocument, case .file = doc.source else { return }
        doc.entries.removeAll()
        doc.lastReadOffset = 0
        doc.objectWillChange.send()
    }
}
