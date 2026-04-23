import Foundation
import Combine

final class LogDocument: ObservableObject, Identifiable {
    let id = UUID()
    let source: LogSource
    let displayName: String

    // Not @Published — appends happen in tight loops on high-rate streams;
    // a per-append objectWillChange would thrash every @ObservedObject in
    // the view tree. Panes subscribe to `didAppend` for incremental updates.
    var entries: [LogEntry] = []

    // Per-append signal with the newly-appended slice. Pane view models
    // incrementally filter this and append to their own filteredEntries.
    let didAppend = PassthroughSubject<[LogEntry], Never>()

    @Published var isFollowing: Bool = true
    @Published var isLive: Bool = false
    @Published var fileSize: UInt64 = 0
    @Published var encoding: String.Encoding = .utf8
    @Published var isCompressed: Bool = false

    // Derived summary state, computed by the document once per append and
    // read by every pane showing this doc.
    @Published private(set) var histogram: LogHistogram?
    @Published private(set) var levelCounts: [LogLevel: Int] = [:]
    @Published private(set) var hasTimestamps: Bool = false
    @Published private(set) var hasComponents: Bool = false
    @Published private(set) var isLoading: Bool = false

    // Line numbers the user has bookmarked for this document. Persisted per
    // file URL; live streams don't persist (no stable identity to key on).
    @Published var bookmarks: Set<Int> = [] {
        didSet { saveBookmarks() }
    }

    // Throttled line count for sidebar display (updated ~1/sec)
    @Published var displayLineCount: Int = 0

    // Smoothed lines/sec for the status bar stream indicator. Updated on the
    // same 1-second tick as displayLineCount using exponential smoothing so
    // brief arrival gaps don't jump the number to zero.
    @Published private(set) var linesPerSecond: Double = 0

    // Ticks with zero arrivals while live → "Stalled" in the UI.
    @Published private(set) var idleTicks: Int = 0

    var lastReadOffset: UInt64 = 0
    var nextEntryID: Int = 0

    private var lineCountTimer: AnyCancellable?
    private var lastCountForRate: Int = 0

    // File I/O and parsing state — one parser, one watcher, one stream per
    // document, regardless of how many panes show it.
    private var parser: any LogParser = PlainTextParser()
    private var fileWatcher: FileWatcher?
    private var logStream: UnifiedLogStream?
    private var partialLineBuffer: String = ""
    private var histogramTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    // Bucket count for the minimap — matches the design handoff.
    private static let histogramBucketCount = 60

    init(source: LogSource, displayName: String) {
        self.source = source
        self.displayName = displayName
        self.bookmarks = Self.loadBookmarks(for: source)

        // Update displayLineCount and stream rate once per second
        lineCountTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let count = self.entries.count
                if count != self.displayLineCount {
                    self.displayLineCount = count
                }

                let delta = count - self.lastCountForRate
                self.lastCountForRate = count

                // EWMA with alpha=0.4 — smooths brief gaps without lagging big bursts.
                let smoothed = 0.6 * self.linesPerSecond + 0.4 * Double(max(delta, 0))
                self.linesPerSecond = smoothed

                self.idleTicks = (delta == 0 && self.isLive) ? self.idleTicks + 1 : 0
            }
    }

    deinit {
        fileWatcher?.stop()
        logStream?.stop()
        loadTask?.cancel()
        histogramTask?.cancel()
    }

    var lineCount: Int { entries.count }

    // MARK: - Loading

    /// Idempotent — safe to call from every pane's `.onAppear`. The first
    /// caller kicks off the load; subsequent calls are no-ops.
    func load() {
        switch source {
        case .file:
            guard loadTask == nil, !isLoading, entries.isEmpty else { return }
            loadTask = Task { @MainActor [weak self] in
                await self?.loadFile()
                self?.loadTask = nil
            }
        case .unifiedLog(let predicate):
            guard logStream == nil else { return }
            startLogStream(predicate: predicate)
        case .stdin:
            break
        }
    }

    /// Clears parsed state and re-runs load. Used by the ⌘R reload path.
    func reload() {
        guard case .file = source else { return }
        fileWatcher?.stop()
        fileWatcher = nil
        loadTask?.cancel()
        loadTask = nil
        histogramTask?.cancel()
        histogramTask = nil
        entries.removeAll()
        nextEntryID = 0
        lastReadOffset = 0
        partialLineBuffer = ""
        histogram = nil
        levelCounts = [:]
        hasTimestamps = false
        hasComponents = false
        isLoading = false
        load()
    }

    @MainActor
    private func loadFile() async {
        guard case .file(let url) = source else { return }

        parser = ParserRegistry.shared.detectParser(for: url)

        let compressed = GzipDecompressor.isGzipped(url: url)
        isCompressed = compressed

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

        fileSize = UInt64(data.count)
        lastReadOffset = UInt64(data.count)

        isLoading = true

        // Parse the whole file on a background task. A 100K-line file takes
        // ~1.5s of synchronous parsing; doing it on the main thread froze the
        // UI from the user's first click through to first render.
        let capturedParser = parser
        let startID = nextEntryID
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

        entries = parsed.entries
        nextEntryID = parsed.nextID
        updateColumnFlags(scanning: parsed.entries)
        rebuildLevelCounts(from: parsed.entries)
        recomputeHistogram(immediate: true)
        didAppend.send(parsed.entries)
        isLoading = false

        // Gzipped files are archive snapshots — they don't get appended to,
        // so no file watcher.
        if !compressed {
            startWatching(url: url)
        }
    }

    // MARK: - Unified log stream

    private func startLogStream(predicate: String?) {
        parser = UnifiedLogParser()
        let stream = UnifiedLogStream()
        stream.onNewLines = { [weak self] lines in
            self?.appendLines(lines)
        }
        stream.start(predicate: predicate)
        logStream = stream
        isLive = true
    }

    func stopStream() {
        logStream?.stop()
        logStream = nil
        isLive = false
    }

    // MARK: - File watching

    private func startWatching(url: URL) {
        let watcher = FileWatcher()
        watcher.onFileChanged = { [weak self] in
            self?.readNewContent(from: url)
        }
        watcher.watch(url: url)
        fileWatcher = watcher
        isLive = true
    }

    func stopWatching() {
        fileWatcher?.stop()
        fileWatcher = nil
        isLive = false
    }

    private func readNewContent(from url: URL) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
        defer { handle.closeFile() }

        // Check if file was truncated/rotated (new size < last offset)
        let size = handle.seekToEndOfFile()
        if size < lastReadOffset {
            handle.seek(toFileOffset: 0)
            lastReadOffset = 0
        } else if size == lastReadOffset {
            return
        } else {
            handle.seek(toFileOffset: lastReadOffset)
        }

        let newData = handle.readDataToEndOfFile()
        lastReadOffset = handle.offsetInFile
        fileSize = size

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

    /// Append new lines from file watcher or unified-log stream. Parses
    /// inline (cheap), updates derived state, then fanned out to panes via
    /// `didAppend` so each pane runs its own filter on the new slice.
    private func appendLines(_ lines: [String]) {
        var newEntries: [LogEntry] = []
        newEntries.reserveCapacity(lines.count)
        let startLine = entries.count + 1

        for (offset, line) in lines.enumerated() {
            let entry = parser.parse(
                line: line,
                lineNumber: startLine + offset,
                entryID: nextEntryID
            )
            nextEntryID += 1
            newEntries.append(entry)
        }

        entries.append(contentsOf: newEntries)
        updateColumnFlags(scanning: newEntries)
        incrementLevelCounts(with: newEntries)
        recomputeHistogram(immediate: false)
        didAppend.send(newEntries)
    }

    // MARK: - Derived summaries

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
            histogram = Self.computeHistogram(from: entries, buckets: Self.histogramBucketCount)
            return
        }
        histogramTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.histogram = Self.computeHistogram(from: self.entries, buckets: Self.histogramBucketCount)
        }
    }

    // Two static formatters — previous code mutated a single shared
    // formatter's dateFormat on every recompute. Avoids a (cheap but
    // pointless) property write in the hot path.
    private static let histogramLabelFormatterShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let histogramLabelFormatterLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
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

        let formatter = total > 86400 ? histogramLabelFormatterLong : histogramLabelFormatterShort

        return LogHistogram(
            bars: bars,
            maxTotal: maxTotal,
            startLabel: formatter.string(from: first),
            endLabel: formatter.string(from: last)
        )
    }

    // MARK: - Bookmark persistence

    // Only file sources persist. Unified-log streams and stdin don't have a
    // stable identity to key UserDefaults on, so their bookmarks live only
    // for the lifetime of the document.
    private static func defaultsKey(for source: LogSource) -> String? {
        switch source {
        case .file(let url): return "traceview.bookmarks.\(url.path)"
        case .unifiedLog, .stdin: return nil
        }
    }

    private static func loadBookmarks(for source: LogSource) -> Set<Int> {
        guard let key = defaultsKey(for: source),
              let array = UserDefaults.standard.array(forKey: key) as? [Int] else {
            return []
        }
        return Set(array)
    }

    private func saveBookmarks() {
        guard let key = Self.defaultsKey(for: source) else { return }
        if bookmarks.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Array(bookmarks).sorted(), forKey: key)
        }
    }
}
