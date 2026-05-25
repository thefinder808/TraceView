import Foundation
import Combine

/// The data-layer seam for LogDocument's entries. Today there is one
/// conformance — InMemoryEntrySource — wrapping a `[LogEntry]` with the
/// same semantics LogDocument had before. The protocol exists so Phase 3
/// can add IndexedEntrySource (mmap + offset index) behind the same shape
/// without rewriting LogDocument or every entries consumer.
///
/// Phase 1 keeps the `allEntries: [LogEntry]` getter for compatibility —
/// the filter pipeline and histogram compute both snapshot the full array
/// today. Phase 6+ revisits that for indexed sources where materializing
/// 200 M entries is catastrophic.
protocol EntrySource: AnyObject {
    /// Snapshot of every entry currently in the source. For in-memory mode
    /// this is the entries array directly; for indexed mode (Phase 3) this
    /// is documented as "do not call" — synthesizing the full array defeats
    /// the purpose of lazy loading. Use `entry(at:)` for random access and
    /// `count` for sizing.
    var allEntries: [LogEntry] { get }
    var count: Int { get }

    /// Random-access primitive. Returns the entry at the given row index,
    /// or nil only for genuinely out-of-bounds indices. For indexed sources
    /// this may decode and parse a line on demand — implementations are
    /// expected to be fast enough for the AppKit draw loop (~80 visible
    /// rows × 60fps) and should cache recent results to absorb redraw +
    /// binary-search re-lookups. Synchronous because draw callers cannot
    /// await.
    func entry(at index: Int) -> LogEntry?

    /// True iff this source can produce per-level summary counts for the
    /// `SeveritySummaryBar`. In-memory sources iterate `allEntries`; the
    /// indexed source reads its `logIndex.levels` parallel array (always
    /// available, captured during build).
    var supportsLevelCounts: Bool { get }

    /// True iff this source can produce the minimap histogram for
    /// `HistogramView`. In-memory sources walk `allEntries`; the indexed
    /// source reads its `logIndex.timestamps` parallel array, which is
    /// only captured for parser kinds whose timestamps are addressable
    /// from raw bytes (PlainText, SCCM). CSV / unknown formats fall
    /// outside this gate even in indexed mode.
    var supportsHistogram: Bool { get }

    /// True iff this source supports the active filter pipeline (text
    /// search + level + component). In-memory sources can iterate and
    /// filter directly; the indexed source's true value lights up in
    /// Phase 4 PR3 once the background raw-byte scanner lands. PR2
    /// keeps this `false` for indexed sources.
    var supportsFilter: Bool { get }

    /// Fires after each successful append (or replace) with the slice that
    /// was just added (or the full replacement payload). Matches the
    /// pre-refactor `LogDocument.didAppend` shape exactly so existing
    /// subscribers (per-pane filter pipeline, merged-source fan-in) work
    /// unchanged.
    var didAppend: AnyPublisher<[LogEntry], Never> { get }

    func append(_ entries: [LogEntry])
    func reset()
    func replace(with entries: [LogEntry])
}

final class InMemoryEntrySource: EntrySource {
    private(set) var allEntries: [LogEntry] = []
    var count: Int { allEntries.count }
    let supportsLevelCounts = true
    let supportsHistogram = true
    let supportsFilter = true

    private let subject = PassthroughSubject<[LogEntry], Never>()
    var didAppend: AnyPublisher<[LogEntry], Never> { subject.eraseToAnyPublisher() }

    func entry(at index: Int) -> LogEntry? {
        guard index >= 0, index < allEntries.count else { return nil }
        return allEntries[index]
    }

    func append(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        allEntries.append(contentsOf: entries)
        subject.send(entries)
    }

    func reset() {
        allEntries.removeAll()
        // No didAppend — reset is a different signal (matches the
        // pre-refactor LogDocument.reload() which never fired didAppend).
    }

    func replace(with entries: [LogEntry]) {
        allEntries = entries
        subject.send(entries)
    }
}
