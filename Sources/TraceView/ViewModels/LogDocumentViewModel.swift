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

    // Cached derived views so SeveritySummaryBar and HistogramView don't
    // iterate all entries on every SwiftUI body evaluation (which fires on
    // every filter keystroke). levelCounts is maintained incrementally on
    // append; histogram is recomputed on load + throttled on append.
    @Published private(set) var levelCounts: [LogLevel: Int] = [:]
    @Published private(set) var histogram: LogHistogram?

    // True while the initial file parse is running on a background task.
    @Published private(set) var isLoading: Bool = false

    private var parser: any LogParser = PlainTextParser()
    private var fileWatcher: FileWatcher?
    private var logStream: UnifiedLogStream?
    private var partialLineBuffer: String = ""
    private var filterTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // Bucket count for the minimap — matches the design handoff.
    private static let histogramBucketCount = 60

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
            Task { @MainActor in await loadFile() }
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

    @MainActor
    private func loadFile() async {
        guard case .file(let url) = document.source else { return }

        parser = ParserRegistry.shared.detectParser(for: url)

        let compressed = GzipDecompressor.isGzipped(url: url)
        document.isCompressed = compressed

        // Gzipped: spawn gunzip off-main to avoid blocking on a few-second
        // decompress. Uncompressed: mmap is cheap enough to do on-main.
        let data: Data?
        if compressed {
            data = await Task.detached(priority: .userInitiated) {
                GzipDecompressor.decompress(url: url)
            }.value
        } else {
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        }

        guard let data, let text = String(data: data, encoding: .utf8) else { return }

        document.fileSize = UInt64(data.count)
        document.lastReadOffset = UInt64(data.count)

        isLoading = true

        // Parse the whole file on a background task. A 100K-line file takes
        // ~1.5s of synchronous parsing; doing it on the main thread froze the
        // UI from the user's first click through to first render.
        let capturedParser = parser
        let startID = document.nextEntryID
        let parsed: (entries: [LogEntry], nextID: Int) = await Task.detached(priority: .userInitiated) {
            let lines = text.components(separatedBy: .newlines)
            var entries: [LogEntry] = []
            entries.reserveCapacity(lines.count)
            var nextID = startID
            for (index, line) in lines.enumerated() {
                guard !line.isEmpty else { continue }
                let entry = capturedParser.parse(line: line, lineNumber: index + 1, entryID: nextID)
                nextID += 1
                entries.append(entry)
            }
            return (entries, nextID)
        }.value

        document.entries = parsed.entries
        document.nextEntryID = parsed.nextID
        updateColumnFlags(scanning: parsed.entries)
        rebuildLevelCounts(from: parsed.entries)
        recomputeHistogram(immediate: true)
        applyFilter()
        isLoading = false

        // Gzipped files are archive snapshots — they don't get appended to,
        // so no file watcher.
        if !compressed {
            startWatching(url: url)
        }
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
        incrementLevelCounts(with: newEntries)
        recomputeHistogram(immediate: false)

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

    // MARK: - Cached derived views

    private func rebuildLevelCounts(from entries: [LogEntry]) {
        var counts: [LogLevel: Int] = [:]
        for entry in entries {
            counts[entry.level, default: 0] += 1
        }
        levelCounts = counts
    }

    private func incrementLevelCounts(with entries: [LogEntry]) {
        var counts = levelCounts
        for entry in entries {
            counts[entry.level, default: 0] += 1
        }
        levelCounts = counts
    }

    // Recomputes the 60-bucket minimap histogram. `immediate` runs it now
    // (used on initial load). Otherwise it schedules a debounced refresh so
    // high-rate log streams don't thrash re-bucketing on every append.
    private func recomputeHistogram(immediate: Bool) {
        histogramTask?.cancel()
        if immediate {
            histogram = Self.computeHistogram(from: document.entries, buckets: Self.histogramBucketCount)
            return
        }
        histogramTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.histogram = Self.computeHistogram(from: self.document.entries, buckets: Self.histogramBucketCount)
        }
    }

    private static let histogramLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func computeHistogram(from entries: [LogEntry], buckets: Int) -> LogHistogram? {
        guard entries.count >= 10 else { return nil }

        let timestamped = entries.compactMap { $0.timestamp }
        guard Double(timestamped.count) / Double(entries.count) >= 0.1,
              let first = timestamped.first,
              let last = timestamped.last,
              last > first else { return nil }

        let total = last.timeIntervalSince(first)
        guard total > 0 else { return nil }

        let bucketSize = total / Double(buckets)
        var bars = Array(repeating: LogHistogram.Bar(err: 0, warn: 0, info: 0), count: buckets)

        for entry in entries {
            guard let ts = entry.timestamp else { continue }
            let offset = ts.timeIntervalSince(first)
            let idx = min(buckets - 1, max(0, Int(offset / bucketSize)))
            let existing = bars[idx]
            switch entry.level {
            case .error, .critical:
                bars[idx] = LogHistogram.Bar(err: existing.err + 1, warn: existing.warn, info: existing.info)
            case .warning:
                bars[idx] = LogHistogram.Bar(err: existing.err, warn: existing.warn + 1, info: existing.info)
            default:
                bars[idx] = LogHistogram.Bar(err: existing.err, warn: existing.warn, info: existing.info + 1)
            }
        }

        let maxTotal = bars.map(\.total).max() ?? 1

        histogramLabelFormatter.dateFormat = total > 86400 ? "MMM d HH:mm" : "HH:mm:ss"

        return LogHistogram(
            bars: bars,
            maxTotal: maxTotal,
            startLabel: histogramLabelFormatter.string(from: first),
            endLabel: histogramLabelFormatter.string(from: last)
        )
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
