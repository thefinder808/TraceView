import SwiftUI
import Combine

/// Per-pane view model. Owns the filter, find-mode match list, and the
/// filtered entries shown in this specific pane. File I/O, parsing,
/// watching, level counts, and histogram all live on `LogDocument` — so
/// two panes showing the same document share that work.
final class LogDocumentViewModel: ObservableObject {
    let document: LogDocument

    @Published var filter = LogFilter()
    @Published var filteredEntries: FilteredEntries = .empty

    // Find mode — filter hides non-matches; find leaves them visible and
    // produces a navigable match list. Defaults to the global setting.
    @Published var findMode: FindMode = .filter

    // Row indices into `filteredEntries` where the current searchText
    // matches. In filter mode this is always empty (search is part of
    // filtering); in find mode it's rebuilt each time the filter changes.
    @Published private(set) var matches: [Int] = []
    @Published var currentMatchIndex: Int? = nil

    /// Phase 4 PR3 progress signal for the indexed-mode filter pipeline.
    /// 0 ... 1 while a background scan is running; nil when idle or
    /// in-memory mode (which doesn't need a progress UI — its filter is
    /// effectively synchronous). FilterBarView reads this to render the
    /// "Scanning · N%" overlay.
    @Published private(set) var filterScanProgress: Double? = nil

    private var filterTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Phase 4 per-feature gates, surfaced for view binding. Each
    /// forwards to the matching `EntrySource` capability:
    /// - `levelCountsAvailable` drives `SeveritySummaryBar` visibility.
    /// - `histogramAvailable` drives the histogram strip's nil-check.
    /// - `filterAvailable` drives `FilterBarView`'s `.disabled(...)`.
    /// In-memory sources return true for all three. Indexed sources
    /// return: levelCounts=true, histogram=(timestamps captured),
    /// filter=false in PR2 (PR3 lights it up).
    var levelCountsAvailable: Bool { document.entrySource.supportsLevelCounts }
    var histogramAvailable: Bool { document.entrySource.supportsHistogram }
    var filterAvailable: Bool { document.entrySource.supportsFilter }

    init(document: LogDocument) {
        self.document = document
        setupFilterPipeline()
        subscribeToAppends()
        subscribeToLoadComplete()
        // Second pane opened on an already-loaded document: seed the
        // filtered list from the snapshot instead of waiting on didAppend.
        if document.entrySource.count > 0 {
            applyFilter()
        }
    }

    /// Called from the view's `.onAppear`. Load is idempotent on the
    /// document side, so a second pane's call is a no-op.
    func load() {
        document.load()
    }

    // MARK: - Append subscription

    private func subscribeToAppends() {
        // Each pane filters the newly-appended slice independently so
        // per-pane filters (CMTrace-style investigation across panes) show
        // different subsets of the same shared entry stream. `didAppend` is
        // already sent on the main actor, so no scheduler hop needed.
        document.didAppend
            .sink { [weak self] newEntries in
                self?.handleAppend(newEntries)
            }
            .store(in: &cancellables)
    }

    /// Subscribe to load-state transitions. Indexed mode does not fire
    /// `didAppend` post-build (static-after-build invariant), so we need
    /// a separate signal to know when to run the initial filter pass.
    /// `.complete` is the canonical "everything's loaded" signal and
    /// works for both modes — in-memory mode reaches `.complete` after
    /// the last chunk's `handleAppend`, so the rekick re-runs a filter
    /// that's already correct (no behavior change; slight redundant
    /// work).
    private func subscribeToLoadComplete() {
        document.$loadState
            .compactMap { state -> Void? in
                if case .complete = state { return () }
                return nil
            }
            .sink { [weak self] _ in
                self?.applyFilter()
            }
            .store(in: &cancellables)
    }

    private func handleAppend(_ newEntries: [LogEntry]) {
        // Filter-mode: apply the active filter to the new slice. Find-mode:
        // all level-and-component-matching entries are visible; search-text
        // hits get appended incrementally as new match positions.
        let mode = findMode
        let currentFilter = filter
        let matching: [LogEntry]
        if mode == .find {
            matching = newEntries.filter { currentFilter.matchesLevelAndComponent($0) }
        } else if currentFilter.isActive {
            var f = currentFilter
            matching = newEntries.filter { f.matches($0) }
        } else {
            matching = newEntries
        }

        guard !matching.isEmpty else { return }

        let baseIndex = filteredEntries.count
        // In-memory mode: pass nil sourceIndices, the FilteredEntries
        // materialized backing stores the LogEntry values directly. Phase 3
        // indexed mode will route through a different append path because
        // IndexedEntrySource is a static-after-build source — handleAppend
        // is in-memory-only by construction.
        filteredEntries.append(matching: matching)

        // Incrementally extend the match list with any hits inside the new
        // slice — O(batch), not O(filteredEntries). A full rescan is only
        // needed when the filter/mode changes (handled in applyFilter).
        if mode == .find, !filter.searchText.isEmpty {
            var f = filter
            for (i, entry) in matching.enumerated() where f.matchesSearchText(entry) {
                matches.append(baseIndex + i)
            }
            if currentMatchIndex == nil, !matches.isEmpty {
                currentMatchIndex = 0
            }
        }
    }

    // MARK: - Filtering

    private func setupFilterPipeline() {
        $filter
            // Drop Combine's initial-value emission. With streaming first-paint
            // (PR #52), loadFile no longer blocks the main actor for the whole
            // parse — so the 150ms-debounced initial-value sink can fire BEFORE
            // the first chunk's didAppend has populated entries[]. applyFilter
            // would snapshot empty entries, then later overwrite the chunk's
            // contributions to filteredEntries with that empty result, leaving
            // the table body blank despite entries being loaded.
            //
            // The initial value is the default empty `LogFilter` — applyFilter
            // on it is wasted work anyway. Init handles the pre-populated-doc
            // case explicitly via the entries-not-empty applyFilter() call.
            // Any user change to filter still flows through normally.
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyFilter()
            }
            .store(in: &cancellables)

        // Mode flips change what searchText means — rerun the pipeline.
        $findMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyFilter()
            }
            .store(in: &cancellables)
    }

    func applyFilter() {
        filterTask?.cancel()

        // Sources that genuinely can't filter (no current case — Phase 4
        // PR3 enabled indexed sources — but kept as defense-in-depth
        // for any future source type added behind this flag).
        if !document.entrySource.supportsFilter {
            filteredEntries = FilteredEntries(backing: .identity(source: document.entrySource))
            matches = []
            currentMatchIndex = nil
            filterScanProgress = nil
            return
        }

        if let indexed = document.entrySource as? IndexedEntrySource {
            applyFilterIndexed(source: indexed)
        } else {
            applyFilterInMemory()
        }
    }

    /// Phase 4 PR3: indexed-mode filter dispatches a `Task.detached`
    /// scan via `IndexedFilterScanner`. The scanner walks the mmap'd
    /// data line-by-line — level check against `logIndex.levels`, text
    /// check via `memmem`-style byte loop over the line range. Returns
    /// `[Int]` of source-row indices for `FilteredEntries.indexed`
    /// (filter mode) or for the `matches` list (find mode).
    ///
    /// Cancellation propagates because `filterTask` IS the detached
    /// task; calling `.cancel()` on it sets `Task.isCancelled == true`
    /// inside the scan loop, which polls every 65 K rows.
    private func applyFilterIndexed(source: IndexedEntrySource) {
        // Inactive filter: no scan needed, just publish the identity
        // view. Avoids both the wasted ~2 s scan AND the
        // `.indexed`-backing scroll-to-line parse storm — position
        // helpers fast-path on `.identity` because lineNumber ==
        // position + 1 by IndexedEntrySource invariant. Filter mode
        // only — find mode reaches the scan path even with an empty
        // filter to populate the matches list.
        if !filter.isActive && findMode != .find {
            filteredEntries = FilteredEntries(backing: .identity(source: source))
            matches = []
            currentMatchIndex = nil
            filterScanProgress = nil
            return
        }

        let currentFilter = filter
        let mode = findMode
        filterScanProgress = 0

        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = IndexedFilterScanner.scan(
                source: source,
                filter: currentFilter
            ) { p in
                // Coalesce per-tick progress onto main. The scanner
                // throttles to 1% boundaries (~100 calls per scan) so
                // the micro-task overhead is bounded.
                Task { @MainActor [weak self] in
                    self?.filterScanProgress = p
                }
            }

            // nil from scan == cancelled mid-scan. Leave state alone so
            // the next applyFilter call can overwrite cleanly.
            guard let indices = result else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                // Bail if the source was swapped (a new file opened
                // mid-scan, etc.). Identity comparison: both branches
                // hold the same reference iff no swap occurred.
                guard self.document.entrySource === source else { return }

                if mode == .find {
                    // Find mode: don't hide rows; populate matches.
                    // For .identity backing, position == source index
                    // (per IndexedEntrySource's id/lineNumber
                    // invariants), so the scan output IS the matches
                    // list. Known divergence from in-memory find mode:
                    // level filter doesn't hide rows in indexed find
                    // mode — it narrows the matches list instead.
                    self.filteredEntries = FilteredEntries(backing: .identity(source: source))
                    self.matches = indices
                    self.currentMatchIndex = indices.isEmpty ? nil : 0
                } else {
                    self.filteredEntries = FilteredEntries(backing: .indexed(indices: indices, source: source))
                    self.matches = []
                    self.currentMatchIndex = nil
                }
                self.filterScanProgress = nil
            }
        }
    }

    private func applyFilterInMemory() {
        let entries = document.entries
        let snapshotCount = entries.count
        let snapshotLastID = entries.last?.id
        let currentFilter = filter
        let mode = findMode

        filterTask = Task { @MainActor [weak self] in
            // Find mode applies level + component only; search is for
            // match-marking, not hiding. Filter mode applies everything.
            let visible = await Task.detached(priority: .userInitiated) {
                var f = currentFilter
                if mode == .find {
                    return entries.filter { f.matchesLevelAndComponent($0) }
                }
                guard currentFilter.isActive else { return entries }
                return entries.filter { f.matches($0) }
            }.value
            guard !Task.isCancelled else { return }
            // Explicit MainActor.run because the @MainActor outer Task does
            // not reliably resume on main after `await Task.detached(...).value`
            // — same footgun that hung LogDocument.recomputeHistogram in
            // production. Without this the @Published filteredEntries write
            // can land off-main, triggering SwiftUI layout on the cooperative
            // pool and deadlocking against the lineCountTimer.
            await MainActor.run {
                guard let self else { return }
                if self.document.entries.count != snapshotCount
                    || self.document.entries.last?.id != snapshotLastID {
                    self.applyFilter()
                    return
                }
                self.filteredEntries = FilteredEntries(backing: .materialized(visible))
                self.recomputeMatches()
            }
        }
    }

    // MARK: - Find-mode match navigation

    private func recomputeMatches() {
        guard findMode == .find, !filter.searchText.isEmpty else {
            matches = []
            currentMatchIndex = nil
            return
        }

        var f = filter
        let hits = filteredEntries.indices.filter { idx in
            f.matchesSearchText(filteredEntries[idx])
        }
        matches = hits

        // Preserve the current match if it's still valid, otherwise land
        // on the first match (or nil if none).
        if let current = currentMatchIndex, current < hits.count {
            // keep
        } else {
            currentMatchIndex = hits.isEmpty ? nil : 0
        }
    }

    func advanceMatch(by delta: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        let next = ((currentMatchIndex ?? -delta) + delta + matches.count) % matches.count
        currentMatchIndex = next
        return filteredEntries[matches[next]].lineNumber
    }

    // MARK: - Computed

    var matchCountText: String {
        // Use entrySource.count so indexed mode reports the true line
        // count instead of zero (allEntries returns [] for indexed).
        let total = document.entrySource.count
        if filter.isActive {
            return "\(Formatters.formatCount(filteredEntries.count)) of \(Formatters.formatCount(total))"
        }
        return Formatters.formatCount(total)
    }
}
