import SwiftUI
import Combine

final class LogDocumentViewModel: ObservableObject {
    let document: LogDocument

    @Published var filter = LogFilter()
    @Published var filteredEntries: [LogEntry] = []
    @Published var isAtBottom: Bool = true

    private var parser: any LogParser
    private var filterTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(document: LogDocument) {
        self.document = document
        self.parser = PlainTextParser()
        setupFilterPipeline()
    }

    // MARK: - Loading

    func loadFile() {
        guard case .file(let url) = document.source else { return }

        // Detect parser
        parser = ParserRegistry.shared.detectParser(for: url)

        // Read file
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return }

        document.fileSize = UInt64(data.count)
        document.lastReadOffset = UInt64(data.count)

        // Parse all lines
        let lines = text.components(separatedBy: .newlines)
        var entries: [LogEntry] = []
        entries.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let entry = parser.parse(line: line, lineNumber: index + 1, entryID: document.nextEntryID)
            document.nextEntryID += 1
            entries.append(entry)
        }

        document.entries = entries
        applyFilter()
    }

    /// Append new lines (used by FileWatcher in Phase 3)
    func appendLines(_ lines: [String]) {
        var newEntries: [LogEntry] = []
        let startLine = document.entries.count + 1

        for (offset, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let entry = parser.parse(
                line: line,
                lineNumber: startLine + offset,
                entryID: document.nextEntryID
            )
            document.nextEntryID += 1
            newEntries.append(entry)
        }

        document.entries.append(contentsOf: newEntries)

        // Incremental filter: only test new entries
        if filter.isActive {
            let matching = newEntries.filter { filter.matches($0) }
            filteredEntries.append(contentsOf: matching)
        } else {
            filteredEntries.append(contentsOf: newEntries)
        }
    }

    // MARK: - Filtering

    private func setupFilterPipeline() {
        $filter
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyFilter()
            }
            .store(in: &cancellables)
    }

    func applyFilter() {
        filterTask?.cancel()

        let entries = document.entries
        let currentFilter = filter

        if !currentFilter.isActive {
            filteredEntries = entries
            return
        }

        filterTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                entries.filter { currentFilter.matches($0) }
            }.value
            guard !Task.isCancelled else { return }
            self?.filteredEntries = result
        }
    }

    // MARK: - Computed

    var matchCountText: String {
        if filter.isActive {
            return "\(Formatters.formatCount(filteredEntries.count)) of \(Formatters.formatCount(document.entries.count))"
        }
        return Formatters.formatCount(document.entries.count)
    }

    var uniqueComponents: [String] {
        let components = Set(document.entries.compactMap(\.component))
        return components.sorted()
    }
}
