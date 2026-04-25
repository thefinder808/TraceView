import SwiftUI
import Combine

/// Per-pane view model. Owns the filter, find-mode match list, and the
/// filtered entries shown in this specific pane. File I/O, parsing,
/// watching, level counts, and histogram all live on `LogDocument` — so
/// two panes showing the same document share that work.
final class LogDocumentViewModel: ObservableObject {
    let document: LogDocument

    @Published var filter = LogFilter()
    @Published var filteredEntries: [LogEntry] = []

    // Find mode — filter hides non-matches; find leaves them visible and
    // produces a navigable match list. Defaults to the global setting.
    @Published var findMode: FindMode = .filter

    // Row indices into `filteredEntries` where the current searchText
    // matches. In filter mode this is always empty (search is part of
    // filtering); in find mode it's rebuilt each time the filter changes.
    @Published private(set) var matches: [Int] = []
    @Published var currentMatchIndex: Int? = nil

    private var filterTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(document: LogDocument) {
        self.document = document
        setupFilterPipeline()
        subscribeToAppends()
        // Second pane opened on an already-loaded document: seed the
        // filtered list from the snapshot instead of waiting on didAppend.
        if !document.entries.isEmpty {
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
        filteredEntries.append(contentsOf: matching)

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

    /// Awaits any in-flight `applyFilter` task. Used by ⌘G's auto-flip
    /// path so the call site can step matches *after* the rebuild from a
    /// findMode change has populated `matches`.
    @MainActor
    func awaitPendingFilter() async {
        await filterTask?.value
    }

    func applyFilter() {
        filterTask?.cancel()

        let entries = document.entries
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
            self?.filteredEntries = visible
            self?.recomputeMatches()
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
        if filter.isActive {
            return "\(Formatters.formatCount(filteredEntries.count)) of \(Formatters.formatCount(document.entries.count))"
        }
        return Formatters.formatCount(document.entries.count)
    }
}
