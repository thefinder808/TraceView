import SwiftUI
import Combine

final class LogDocumentViewModel: ObservableObject {
    let document: LogDocument

    @Published var filter = LogFilter()
    @Published var filteredEntries: [LogEntry] = []

    // Auto-hide hints for the table — flips true the first time any entry
    // lands with a parsed timestamp / component, stays true thereafter.
    // The log table combines these with the user's showTimestamp /
    // showComponent settings so an unparseable file doesn't render two
    // dead columns full of em-dashes.
    @Published private(set) var hasTimestamps = false
    @Published private(set) var hasComponents = false

    private var parser: any LogParser = PlainTextParser()
    private var fileWatcher: FileWatcher?
    private var logStream: UnifiedLogStream?
    private var partialLineBuffer: String = ""
    private var filterTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(document: LogDocument) {
        self.document = document
        setupFilterPipeline()
    }

    deinit {
        fileWatcher?.stop()
        logStream?.stop()
    }

    // MARK: - Loading

    func load() {
        switch document.source {
        case .file:
            loadFile()
        case .unifiedLog(let predicate):
            startLogStream(predicate: predicate)
        case .stdin:
            break
        }
    }

    private func startLogStream(predicate: String?) {
        parser = UnifiedLogParser()
        let stream = UnifiedLogStream()
        stream.onNewLines = { [weak self] lines in
            self?.appendLines(lines)
        }
        stream.start(predicate: predicate)
        logStream = stream
        document.isLive = true
    }

    func stopStream() {
        logStream?.stop()
        logStream = nil
        document.isLive = false
    }

    private func loadFile() {
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
        updateColumnFlags(scanning: entries)
        applyFilter()

        // Start watching for changes
        startWatching(url: url)
    }

    private func updateColumnFlags(scanning entries: [LogEntry]) {
        // contains(where:) short-circuits on first match — constant cost
        // once either flag has flipped true.
        if !hasTimestamps, entries.contains(where: { $0.timestamp != nil }) {
            hasTimestamps = true
        }
        if !hasComponents, entries.contains(where: { $0.component != nil }) {
            hasComponents = true
        }
    }

    // MARK: - File Watching

    private func startWatching(url: URL) {
        let watcher = FileWatcher()
        watcher.onFileChanged = { [weak self] in
            self?.readNewContent(from: url)
        }
        watcher.watch(url: url)
        fileWatcher = watcher
        document.isLive = true
    }

    func stopWatching() {
        fileWatcher?.stop()
        fileWatcher = nil
        document.isLive = false
    }

    private func readNewContent(from url: URL) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
        defer { handle.closeFile() }

        // Check if file was truncated/rotated (new size < last offset)
        let fileSize = handle.seekToEndOfFile()
        if fileSize < document.lastReadOffset {
            // File was truncated — re-read from beginning
            handle.seek(toFileOffset: 0)
            document.lastReadOffset = 0
        } else if fileSize == document.lastReadOffset {
            // No new data
            return
        } else {
            handle.seek(toFileOffset: document.lastReadOffset)
        }

        let newData = handle.readDataToEndOfFile()
        document.lastReadOffset = handle.offsetInFile
        document.fileSize = fileSize

        guard let text = String(data: newData, encoding: .utf8) else { return }

        // Prepend any buffered partial line from last read
        let fullText = partialLineBuffer + text
        partialLineBuffer = ""

        var lines = fullText.components(separatedBy: .newlines)

        // If the text doesn't end with a newline, the last "line" is partial — buffer it
        if !fullText.hasSuffix("\n") && !fullText.hasSuffix("\r\n") && !lines.isEmpty {
            partialLineBuffer = lines.removeLast()
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return }

        appendLines(nonEmptyLines)
    }

    /// Append new lines from file watcher or other sources.
    /// Parsing happens inline (fast), filtering is async if active.
    func appendLines(_ lines: [String]) {
        var newEntries: [LogEntry] = []
        newEntries.reserveCapacity(lines.count)
        let startLine = document.entries.count + 1

        for (offset, line) in lines.enumerated() {
            let entry = parser.parse(
                line: line,
                lineNumber: startLine + offset,
                entryID: document.nextEntryID
            )
            document.nextEntryID += 1
            newEntries.append(entry)
        }

        document.entries.append(contentsOf: newEntries)
        updateColumnFlags(scanning: newEntries)

        // Incremental filter: dispatch to background if filter is active
        if filter.isActive {
            let currentFilter = filter
            Task { @MainActor [weak self] in
                let matching = await Task.detached(priority: .userInitiated) {
                    var f = currentFilter
                    return newEntries.filter { f.matches($0) }
                }.value
                guard !matching.isEmpty else { return }
                self?.filteredEntries.append(contentsOf: matching)
            }
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
            var f = currentFilter
            let result = await Task.detached(priority: .userInitiated) {
                entries.filter { f.matches($0) }
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
