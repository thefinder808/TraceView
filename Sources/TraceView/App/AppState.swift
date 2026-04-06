import SwiftUI
import Combine

final class AppState: ObservableObject {
    @Published var documents: [LogDocument] = []
    @Published var selectedDocumentID: UUID? = nil
    @Published var showSettings: Bool = false
    @Published var showErrorLookup: Bool = false
    @Published var showCommandPalette: Bool = false
    @Published var focusSearch: Bool = false

    private var documentSubscriptions: [UUID: AnyCancellable] = [:]

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

    // MARK: - Navigation

    func selectDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        selectedDocumentID = documents[index].id
    }

    func toggleFollowing() {
        selectedDocument?.isFollowing.toggle()
    }

    func jumpToBottom() {
        selectedDocument?.isFollowing = true
    }
}
