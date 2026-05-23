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
    var allEntries: [LogEntry] { get }
    var count: Int { get }

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

    private let subject = PassthroughSubject<[LogEntry], Never>()
    var didAppend: AnyPublisher<[LogEntry], Never> { subject.eraseToAnyPublisher() }

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
