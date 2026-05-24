import Foundation
import Combine

/// EntrySource backed by a memory-mapped file + offset index. Built once
/// from a file URL; rows are decoded and parsed on demand via the
/// supplied `LogParser` and cached in an LRU so repeated accesses (draw
/// loop redraws, bisect probes, selection re-lookups) only parse once
/// per viewport-warm window.
///
/// Phase 3 constraints:
/// - The parser MUST be line-stateless (`parser.isLineStateless == true`).
///   `LogDocument.loadFile` enforces this before constructing the source.
///   PlainText, SCCM, CSV qualify; IPS, Diag, UnifiedLog, JSONLog don't.
/// - The source is static after build — no live tail, no live append.
///   `append` and `replace` assertionFailure in debug.
/// - `supportsDerivedStats == false` — the histogram + level-counts
///   pipeline must skip indexed sources. The view binds a status-bar
///   note off this flag in PR3.
final class IndexedEntrySource: EntrySource {
    let logIndex: LogIndex
    let parser: any LogParser

    /// LRU of recently-parsed entries keyed by row index. 512 covers ~2
    /// viewport-windows worth of rows plus log₂(36M) bisect probes plus
    /// selection / scroll-sync re-lookups, all without thrashing. Per-
    /// entry cost ~200 B → cache itself ~100 KB.
    private let cache = LRUCache<Int, LogEntry>(capacity: 512)

    private let subject = PassthroughSubject<[LogEntry], Never>()
    var didAppend: AnyPublisher<[LogEntry], Never> { subject.eraseToAnyPublisher() }

    var count: Int { logIndex.lineCount }
    let supportsDerivedStats = false

    /// Documented "do not use" — synthesizing the full array defeats lazy
    /// loading. Returns []. Callers that need to iterate every entry in
    /// indexed mode should bail on `supportsDerivedStats == false`
    /// instead. Phase 3's status-bar note surfaces this state in the UI.
    var allEntries: [LogEntry] { [] }

    init(fileURL: URL, parser: any LogParser) throws {
        precondition(
            parser.isLineStateless,
            "IndexedEntrySource requires a line-stateless parser; got \(parser.name)"
        )
        self.parser = parser
        self.logIndex = try LogIndex.build(fileURL: fileURL)
    }

    func entry(at index: Int) -> LogEntry? {
        guard index >= 0, index < logIndex.lineCount else { return nil }
        if let cached = cache.get(index) {
            return cached
        }
        guard let raw = logIndex.line(at: index) else { return nil }
        // entryID == index gives stable identity across repeat calls,
        // which matters for the renderer's last-reported-entry-id change
        // detection and for the inline-detail-host's "same entry?" check.
        // lineNumber is 1-based by existing convention.
        let entry = parser.parse(line: raw, lineNumber: index + 1, entryID: index)
        cache.put(index, entry)
        return entry
    }

    func append(_ entries: [LogEntry]) {
        assertionFailure("IndexedEntrySource is static after build — append() is invalid")
    }

    func replace(with entries: [LogEntry]) {
        assertionFailure("IndexedEntrySource is static after build — replace() is invalid")
    }

    func reset() {
        // The underlying mmap'd Data is held by LogIndex's `let data` and
        // released when this source is deallocated. The only resettable
        // state is the parsed-entry cache.
        cache.removeAll()
    }
}
