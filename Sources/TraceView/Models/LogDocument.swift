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
    /// Per-time-window peaks captured before each rebucket so spikes that
    /// would otherwise shrink as the histogram's time range stretches
    /// stay visible as faint shadows. Reset on reload / loadMerged.
    private var spikePeaks: [SpikePeak] = []
    @Published private(set) var levelCounts: [LogLevel: Int] = [:]
    @Published private(set) var hasTimestamps: Bool = false
    @Published private(set) var hasComponents: Bool = false
    /// Source of truth for the document's initial-load state. Per-chunk
    /// progress lives in the `.streaming(rowsLoaded:)` associated value so
    /// the UI can show a row count while the parse streams.
    @Published private(set) var loadState: LoadState = .idle

    /// Boolean shim for code paths that only care "is something in flight?"
    /// vs the structured `loadState`. Reads only — write `loadState` directly.
    /// Notably, `LogDocumentView`'s spinner-debounce uses this so the grace
    /// period doesn't restart on every chunk's `rowsLoaded` change.
    var isLoading: Bool {
        switch loadState {
        case .idle, .complete: return false
        case .streaming: return true
        }
    }

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
    /// The detached inner task running the chunked parse. Tracked separately
    /// from `loadTask` (the @MainActor outer task) because Task.detached
    /// doesn't inherit cancellation; reload() and deinit must cancel both.
    private var loadParseTask: Task<Void, Never>?

    // For .merged sources: held via the dedicated init so we don't need a
    // global doc lookup. nil for any other source kind. Append-subscriptions
    // live in mergedAppendCancellables so they can be torn down with the doc.
    private var mergedSources: [LogDocument] = []
    private var mergedAppendCancellables = Set<AnyCancellable>()
    /// Source-displayName cache for the Source column. Rebuilt only when
    /// the merged sources list changes (rarely / never post-init).
    private(set) var mergedSourceNames: [UUID: String] = [:]

    // Bucket count for the minimap — matches the design handoff.
    private static let histogramBucketCount = 60
    /// Spike capture is `bar.total > 3 × median(non-zero bar totals) AND >= 5`.
    /// The multiplier filters out random fluctuation; the absolute floor
    /// avoids recording spikes in tiny logs where the median is meaningless.
    private static let spikeThresholdMultiplier = 3.0
    private static let spikeAbsoluteMin = 5
    /// Cap on retained peaks. When over cap, the lowest-count peaks are
    /// dropped first so the visually significant ones survive.
    private static let spikePeakListCap = 100

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

    /// Convenience init for merged-view docs. Holds the source LogDocuments
    /// directly so loadMerged() can subscribe to their didAppend without
    /// going through AppState. Display name is conventionally
    /// "a.log + b.log" — caller decides.
    convenience init(mergedSources: [LogDocument], displayName: String) {
        let ids = mergedSources.map { $0.id }
        self.init(source: .merged(sourceIDs: ids), displayName: displayName)
        self.mergedSources = mergedSources
        self.mergedSourceNames = Dictionary(
            uniqueKeysWithValues: mergedSources.map { ($0.id, $0.displayName) }
        )
        // Live by definition: as long as any source ticks, we tick.
        self.isLive = mergedSources.contains { $0.isLive }
    }

    deinit {
        fileWatcher?.stop()
        logStream?.stop()
        loadTask?.cancel()
        loadParseTask?.cancel()
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
        case .merged:
            guard mergedAppendCancellables.isEmpty else { return }
            // loadMerged is @MainActor; load() callers (LogDocumentView's
            // .onAppear chain) are already on main, but the compiler can't
            // prove it from this nonisolated method, so dispatch explicitly.
            Task { @MainActor [weak self] in self?.loadMerged() }
        }
    }

    /// Clears parsed state and re-runs load. Used by the ⌘R reload path.
    func reload() {
        guard case .file = source else { return }
        fileWatcher?.stop()
        fileWatcher = nil
        loadTask?.cancel()
        loadTask = nil
        loadParseTask?.cancel()
        loadParseTask = nil
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
        loadState = .idle
        spikePeaks.removeAll()
        load()
    }

    @MainActor
    private func loadFile() async {
        guard case .file(let url) = source else { return }

        #if DEBUG
        let timer = LoadPerfTimer(label: displayName)
        #endif

        let compressed = GzipDecompressor.isGzipped(url: url)
        isCompressed = compressed
        // Flip to .streaming first so the UI shows the spinner immediately
        // rather than waiting for the decode + parse round-trip. Initial
        // rowsLoaded is 0; chunk callbacks update it as the stream arrives.
        loadState = .streaming(rowsLoaded: 0)

        #if DEBUG
        timer.mark("gzip-check")
        #endif

        let startID = nextEntryID

        // Cancel any prior inner parse and start a fresh one. `loadTask`
        // (the outer @MainActor task) gates re-entry via load()'s guard,
        // so under normal operation `loadParseTask` should already be nil.
        // The cancel() is belt-and-suspenders for edge cases.
        loadParseTask?.cancel()

        // The inner task runs the entire parse pipeline off-main and calls
        // back into self via `await MainActor.run` at chunk boundaries and
        // at completion. Stored in self.loadParseTask so reload()/deinit
        // can cancel it (Task.detached does NOT inherit cancellation).
        let parseTask = Task.detached(priority: .userInitiated) { [weak self] in
            // I/O + decode + split + parser detection
            let data: Data?
            if compressed {
                data = GzipDecompressor.decompress(url: url)
            } else {
                data = try? Data(contentsOf: url, options: .mappedIfSafe)
            }
            #if DEBUG
            timer.mark("data-load")
            #endif

            guard let data, let text = String(data: data, encoding: .utf8) else {
                await MainActor.run { [weak self] in
                    self?.loadState = .idle
                    #if DEBUG
                    timer.summary()
                    #endif
                }
                return
            }
            #if DEBUG
            timer.mark("decode")
            #endif

            let lines = text.components(separatedBy: .newlines)
            #if DEBUG
            timer.mark("split")
            #endif

            let sampleLines = lines.prefix(50)
                .filter { !$0.isEmpty }
                .map { String($0) }
            let parser = ParserRegistry.shared.detectParser(sampleLines: sampleLines)
            #if DEBUG
            timer.mark("detect")
            #endif

            // Eager fallback for parsers that need cross-line state (IPS,
            // Diag, JSON-pretty). Their parseFile builds entries with
            // file-wide context (e.g. .ips's JSON header carries the
            // timestamp for every body line); chunking would break that.
            // These files are rare and small, so eager is fine.
            if let whole = parser.parseFile(lines: lines, startingEntryID: startID) {
                #if DEBUG
                timer.mark("parse")
                #endif
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.appendChunkFromInitialParse(whole.entries)
                    #if DEBUG
                    timer.mark("apply")
                    #endif
                    self.finalizeLoad(
                        parser: parser,
                        dataCount: data.count,
                        nextID: whole.nextID,
                        url: url,
                        compressed: compressed
                    )
                    #if DEBUG
                    timer.mark("paint")
                    timer.summary()
                    #endif
                }
                return
            }

            // Small-file fast path: chunking has fixed per-chunk overhead
            // (MainActor hop + per-chunk subscriber filter pipeline). For
            // small files that overhead dominates total wall-clock time
            // without any perceived first-paint benefit (small files were
            // already fast — under the ~200ms perceptibility threshold).
            // Eager-parse and emit one chunk.
            //
            // Threshold of 10000 lines chosen empirically:
            //   - api-server.log (1.7K lines): regressed 209ms → 513ms with
            //     chunking; goes eager now → back to 209ms.
            //   - wifi.log (5K lines, Apple-daemon parser): regressed 194ms
            //     → 805ms even with the 3000-line threshold because the
            //     parser's per-line cost is higher; bumping to 10000 puts
            //     it back near baseline.
            //   - install.log (33K lines): chunked path delivers the
            //     perceived first-paint win that dwarfs the +27% total
            //     wall-clock cost.
            //
            // At 10000 lines × ~35us/line for dated-syslog the eager path
            // takes ~350ms — borderline but still under the perceptibility
            // threshold. Bigger files cross into "user notices the wait"
            // and benefit from progressive rendering.
            let eagerLineThreshold = 10000
            if lines.count < eagerLineThreshold {
                var built: [LogEntry] = []
                built.reserveCapacity(lines.count)
                var nextID = startID
                for (index, line) in lines.enumerated() {
                    if Task.isCancelled { return }
                    guard !line.isEmpty else { continue }
                    built.append(parser.parse(line: line, lineNumber: index + 1, entryID: nextID))
                    nextID += 1
                }
                #if DEBUG
                timer.mark("parse")
                #endif
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.appendChunkFromInitialParse(built)
                    #if DEBUG
                    timer.mark("apply")
                    #endif
                    self.finalizeLoad(
                        parser: parser,
                        dataCount: data.count,
                        nextID: nextID,
                        url: url,
                        compressed: compressed
                    )
                    #if DEBUG
                    timer.mark("paint")
                    timer.summary()
                    #endif
                }
                return
            }

            // Chunked path. First chunk is small (500) so first paint
            // happens fast; subsequent chunks are larger (5000) for
            // throughput. Each chunk hops to MainActor exactly once.
            let firstChunkSize = 500
            let subsequentChunkSize = 5000
            var chunkBuffer: [LogEntry] = []
            chunkBuffer.reserveCapacity(firstChunkSize)
            var nextID = startID
            var nextChunkSize = firstChunkSize
            var emittedAny = false

            for (index, line) in lines.enumerated() {
                if Task.isCancelled { return }
                guard !line.isEmpty else { continue }
                chunkBuffer.append(parser.parse(line: line, lineNumber: index + 1, entryID: nextID))
                nextID += 1
                if chunkBuffer.count >= nextChunkSize {
                    let chunkToEmit = chunkBuffer
                    chunkBuffer.removeAll(keepingCapacity: false)
                    chunkBuffer.reserveCapacity(subsequentChunkSize)
                    await MainActor.run { [weak self] in
                        self?.appendChunkFromInitialParse(chunkToEmit)
                    }
                    if !emittedAny {
                        emittedAny = true
                        nextChunkSize = subsequentChunkSize
                    }
                }
            }

            // Final partial chunk.
            if !chunkBuffer.isEmpty {
                let finalChunk = chunkBuffer
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.appendChunkFromInitialParse(finalChunk)
                }
            }
            #if DEBUG
            timer.mark("parse")
            #endif

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                #if DEBUG
                timer.mark("apply")
                #endif
                self.finalizeLoad(
                    parser: parser,
                    dataCount: data.count,
                    nextID: nextID,
                    url: url,
                    compressed: compressed
                )
                #if DEBUG
                timer.mark("paint")
                timer.summary()
                #endif
            }
        }

        loadParseTask = parseTask
        // Don't await parseTask.value — letting it complete in the
        // background allows loadFile() to return immediately, which means
        // the @MainActor task graph isn't blocked on it. The view layer
        // observes loadState changes via @Published and updates as chunks
        // arrive. reload()/deinit cancel via loadParseTask.cancel().
    }

    /// Apply a chunk of newly-parsed entries from the initial chunked load.
    /// Called from the detached parse task via `await MainActor.run`. Updates
    /// loadState's rowsLoaded so the spinner can show progress, then funnels
    /// through the same `didAppend.send` path live-tail uses, which fans out
    /// to per-pane filter pipelines for incremental application.
    @MainActor
    private func appendChunkFromInitialParse(_ chunk: [LogEntry]) {
        guard !chunk.isEmpty else { return }
        entries.append(contentsOf: chunk)
        updateColumnFlags(scanning: chunk)
        incrementLevelCounts(with: chunk)
        // Debounced (300ms) histogram rebuild — multiple chunks landing
        // within the debounce window coalesce into a single recompute,
        // avoiding visible histogram thrash during the stream.
        recomputeHistogram(immediate: false)
        didAppend.send(chunk)

        let priorLoaded: Int
        switch loadState {
        case .streaming(let n): priorLoaded = n
        case .idle, .complete:
            // A late chunk arriving after .complete (race during cancel)
            // shouldn't reset state; just skip the loadState update.
            return
        }
        loadState = .streaming(rowsLoaded: priorLoaded + chunk.count)
    }

    /// Finalize a chunked load after the last chunk has been applied.
    /// Sets fileSize/lastReadOffset/parser/nextEntryID, marks loadState
    /// .complete, kicks off file watching for non-compressed sources.
    @MainActor
    private func finalizeLoad(
        parser: any LogParser,
        dataCount: Int,
        nextID: Int,
        url: URL,
        compressed: Bool
    ) {
        fileSize = UInt64(dataCount)
        lastReadOffset = UInt64(dataCount)
        self.parser = parser
        self.nextEntryID = nextID
        loadState = .complete

        // Gzipped files are archive snapshots — they don't get appended to,
        // so no file watcher.
        if !compressed {
            startWatching(url: url)
        }
    }

    // MARK: - Merged-view loading

    /// Initial merge across all sources, then subscribe to each source's
    /// didAppend so subsequent source appends extend the merged stream.
    ///
    /// **Live append model:** new entries from any source are appended to
    /// the end of the merged entries array, in arrival order — they are
    /// NOT inserted at their timestamp position. This keeps lineNumbers
    /// stable, which matters because pane filteredEntries snapshots and
    /// scroll positions reference them. The trade-off: if source A is
    /// historical (old timestamps) and source B is live-tailing now, B's
    /// new entries still land at the end even though their timestamps
    /// would sort before some of A's existing entries. For the common
    /// merged-view use case (correlating two live streams), source
    /// timestamps stay roughly monotonic together and this is fine.
    @MainActor
    private func loadMerged() {
        guard !mergedSources.isEmpty else { return }
        spikePeaks.removeAll()
        loadState = .streaming(rowsLoaded: 0)

        // 1. Initial merge: pull all current entries from each source,
        //    tag with source identity, drop untimestamped (no place for
        //    them in a chronological merge), sort by timestamp.
        var combined: [LogEntry] = []
        for source in mergedSources {
            for entry in source.entries where entry.timestamp != nil {
                var tagged = entry
                tagged.sourceDocumentID = source.id
                tagged.sourceLineNumber = entry.lineNumber
                combined.append(tagged)
            }
        }
        combined.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }

        // 2. Reassign sequential lineNumbers + entry IDs. Source-line and
        //    source-doc references are preserved on the entry for the
        //    "Open in Source Log" jump.
        var renumbered: [LogEntry] = []
        renumbered.reserveCapacity(combined.count)
        for (i, entry) in combined.enumerated() {
            renumbered.append(LogEntry(
                id: nextEntryID,
                lineNumber: i + 1,
                timestamp: entry.timestamp,
                level: entry.level,
                message: entry.message,
                component: entry.component,
                threadID: entry.threadID,
                source: entry.source,
                rawLine: entry.rawLine,
                sourceDocumentID: entry.sourceDocumentID,
                sourceLineNumber: entry.sourceLineNumber
            ))
            nextEntryID += 1
        }

        entries = renumbered
        updateColumnFlags(scanning: renumbered)
        rebuildLevelCounts(from: renumbered)
        recomputeHistogram(immediate: true)
        didAppend.send(renumbered)
        loadState = .complete

        // 3. Subscribe to each source for live additions.
        for source in mergedSources {
            source.didAppend
                .sink { [weak self, weak source] newEntries in
                    guard let self, let source else { return }
                    self.appendMerged(from: source, newEntries: newEntries)
                }
                .store(in: &mergedAppendCancellables)
        }
    }

    /// Live source append → tag, drop untimestamped, append at end in
    /// arrival order. See loadMerged() doc for why we don't insert at
    /// timestamp position.
    private func appendMerged(from source: LogDocument, newEntries: [LogEntry]) {
        var tagged: [LogEntry] = []
        tagged.reserveCapacity(newEntries.count)
        let startLine = entries.count + 1
        var lineCursor = startLine
        for entry in newEntries where entry.timestamp != nil {
            tagged.append(LogEntry(
                id: nextEntryID,
                lineNumber: lineCursor,
                timestamp: entry.timestamp,
                level: entry.level,
                message: entry.message,
                component: entry.component,
                threadID: entry.threadID,
                source: entry.source,
                rawLine: entry.rawLine,
                sourceDocumentID: source.id,
                sourceLineNumber: entry.lineNumber
            ))
            nextEntryID += 1
            lineCursor += 1
        }
        guard !tagged.isEmpty else { return }

        entries.append(contentsOf: tagged)
        updateColumnFlags(scanning: tagged)
        incrementLevelCounts(with: tagged)
        recomputeHistogram(immediate: false)
        didAppend.send(tagged)
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

    // Recomputes the 60-bucket minimap histogram. `immediate` runs the
    // compute right away (used on initial load); otherwise the compute is
    // debounced 300ms so high-rate log streams don't thrash re-bucketing on
    // every append. Either way the actual `computeHistogram` work runs off
    // main and the result is published back. For 100K-row logs this avoids
    // a multi-100ms main-actor stall after parse completes.
    private func recomputeHistogram(immediate: Bool) {
        histogramTask?.cancel()
        // The outer Task is @MainActor so:
        //   - captureSpikePeaks runs on main (reads @Published histogram,
        //     mutates spikePeaks) AFTER the cancellable debounce sleep,
        //     which preserves the "only surviving task captures" coalescing
        //     that prevents duplicate spike-peak entries during bursts;
        //   - the inner Task.detached runs the actual compute off-main;
        //   - the explicit MainActor.run hops the @Published write back on
        //     main even when Swift's outer @MainActor annotation fails to
        //     resume the continuation on main (a known footgun with
        //     `await Task.detached(...).value` — see the production hang
        //     report; SwiftUI ran the layout pass off-main and deadlocked
        //     against the lineCountTimer's @Published writes on main).
        histogramTask = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.captureSpikePeaksFromCurrentHistogram()
            let snapshotEntries = self.entries
            let snapshotPeaks = self.spikePeaks
            let buckets = Self.histogramBucketCount
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeHistogram(from: snapshotEntries, peaks: snapshotPeaks, buckets: buckets)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.histogram = result
            }
        }
    }

    /// Walks the about-to-be-replaced histogram bars, identifies spikes
    /// (above the threshold), and appends them to `spikePeaks` keyed by
    /// time. No-op on first compute (`histogram == nil`).
    private func captureSpikePeaksFromCurrentHistogram() {
        guard let current = histogram else { return }
        let totals = current.bars.map(\.total).filter { $0 > 0 }
        guard !totals.isEmpty else { return }
        let med = Self.median(of: totals)
        let threshold = max(Double(Self.spikeAbsoluteMin), med * Self.spikeThresholdMultiplier)

        for (i, bar) in current.bars.enumerated() {
            guard Double(bar.total) > threshold else { continue }
            let centerTime = current.startTime.addingTimeInterval(
                Double(i) * current.bucketSize + current.bucketSize / 2
            )
            spikePeaks.append(SpikePeak(time: centerTime, count: bar.total))
        }

        if spikePeaks.count > Self.spikePeakListCap {
            // Keep the top-N by count; the lowest-magnitude entries
            // are the least visually informative to preserve.
            spikePeaks.sort { $0.count > $1.count }
            spikePeaks = Array(spikePeaks.prefix(Self.spikePeakListCap))
        }
    }

    private static func median(of values: [Int]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (Double(sorted[count / 2 - 1]) + Double(sorted[count / 2])) / 2.0
        }
        return Double(sorted[count / 2])
    }

    /// Per-time-window spike record. `time` is the center of the bucket
    /// the peak was captured from; `count` is that bucket's total at
    /// capture time. Stored in `spikePeaks` and reprojected onto current
    /// buckets each recompute.
    private struct SpikePeak {
        let time: Date
        let count: Int
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

    private static func computeHistogram(
        from entries: [LogEntry],
        peaks: [SpikePeak],
        buckets: Int
    ) -> LogHistogram? {
        guard entries.count >= 10 else { return nil }

        // Single pass for min/max + count. Previously used
        // `timestamped.first` / `.last`, which assumes file order matches
        // timestamp order — wrong for merged docs (appendMerged keeps
        // arrival order, not timestamp order, per the live-append model).
        var first: Date?
        var last: Date?
        var timestampedCount = 0
        for entry in entries {
            guard let ts = entry.timestamp else { continue }
            timestampedCount += 1
            if first == nil || ts < first! { first = ts }
            if last == nil || ts > last! { last = ts }
        }
        guard timestampedCount > 0,
              Double(timestampedCount) / Double(entries.count) >= 0.1,
              let first, let last,
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

        // Project peaks onto current buckets. Only include a shadow when
        // its peakCount would visibly extend ABOVE the current bar
        // (otherwise the bar would hide it anyway — saves render work
        // and keeps the shadows array minimal).
        var shadows: [LogHistogram.Shadow] = []
        for bucketIdx in 0..<buckets {
            let bucketStart = first.addingTimeInterval(Double(bucketIdx) * bucketSize)
            let bucketEnd = bucketStart.addingTimeInterval(bucketSize)
            let inRangePeak = peaks
                .filter { $0.time >= bucketStart && $0.time < bucketEnd }
                .map(\.count)
                .max() ?? 0
            if inRangePeak > bars[bucketIdx].total {
                shadows.append(LogHistogram.Shadow(bucketIndex: bucketIdx, peakCount: inRangePeak))
            }
        }

        // maxTotal must include shadow heights so the y-axis stays
        // honest — a tall ghost can legitimately exceed any current bar.
        let visibleShadowMax = shadows.map(\.peakCount).max() ?? 0
        let effectiveMaxTotal = max(maxTotal, visibleShadowMax)

        let formatter = total > 86400 ? histogramLabelFormatterLong : histogramLabelFormatterShort

        return LogHistogram(
            bars: bars,
            maxTotal: effectiveMaxTotal,
            startLabel: formatter.string(from: first),
            endLabel: formatter.string(from: last),
            startTime: first,
            bucketSize: bucketSize,
            shadows: shadows
        )
    }

    // MARK: - Bookmark persistence

    // Only file sources persist. Unified-log streams and stdin don't have a
    // stable identity to key UserDefaults on, so their bookmarks live only
    // for the lifetime of the document.
    private static func defaultsKey(for source: LogSource) -> String? {
        switch source {
        case .file(let url): return "traceview.bookmarks.\(url.path)"
        case .unifiedLog, .stdin, .merged: return nil
        }
    }

    /// True for `.merged` sources — used by views to gate merged-only
    /// affordances (Source column, Open in Source Log, source-filter chips).
    var isMerged: Bool {
        if case .merged = source { return true }
        return false
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
