import Foundation

/// View-model-owned snapshot of which entries pass the active filter.
///
/// Two backing modes:
/// - `.materialized([LogEntry])`: filter ran eagerly, the array is the
///   answer. Used for in-memory sources and for find-mode (where every
///   entry passes the level/component filter, so the array is effectively
///   the full entries list).
/// - `.indexed(indices: [Int], source: EntrySource)`: filter ran lazily
///   over an indexed source; we kept only the source-row indices that
///   matched. Subscript calls `source.entry(at: indices[i])` per access.
///
/// Conforms to `RandomAccessCollection<LogEntry>` so the renderer, binary
/// search, and the find-match scanner can `entries[row]`/`entries.count`/
/// `entries.first { … }` regardless of backing.
///
/// Mutation is intentionally NOT free via the protocol — `append(contentsOf:)`
/// would be ambiguous between the two backings. Callers use the explicit
/// `append(matching:sourceIndices:)` and `replace(...)` methods.
struct FilteredEntries: RandomAccessCollection {
    enum Backing {
        case materialized([LogEntry])
        case indexed(indices: [Int], source: EntrySource)
    }

    private(set) var backing: Backing

    init(backing: Backing) {
        self.backing = backing
    }

    static let empty = FilteredEntries(backing: .materialized([]))

    // MARK: - RandomAccessCollection

    var startIndex: Int { 0 }
    var endIndex: Int {
        switch backing {
        case .materialized(let arr): return arr.count
        case .indexed(let idx, _):   return idx.count
        }
    }

    subscript(position: Int) -> LogEntry {
        switch backing {
        case .materialized(let arr):
            return arr[position]
        case .indexed(let idx, let src):
            // Force-unwrap is the right call here: position is in
            // 0..<idx.count, and idx[position] is a known-valid source
            // index by construction (the filter pipeline only inserted
            // valid indices). A nil from entry(at:) is a programmer
            // error, not data.
            return src.entry(at: idx[position])!
        }
    }

    // MARK: - Mutation

    /// Extend the filter result with a batch of newly-matching entries.
    /// For `.materialized`, appends the entries to the backing array.
    /// For `.indexed`, requires `sourceIndices` (the source-row indices
    /// these entries live at) and appends those indices. Passing
    /// `sourceIndices == nil` against an `.indexed` backing is a bug.
    mutating func append(matching entries: [LogEntry], sourceIndices: [Int]? = nil) {
        guard !entries.isEmpty else { return }
        switch backing {
        case .materialized(var arr):
            arr.append(contentsOf: entries)
            backing = .materialized(arr)
        case .indexed(var idx, let src):
            guard let sourceIndices, sourceIndices.count == entries.count else {
                assertionFailure("append on .indexed backing requires sourceIndices matching the entries count")
                return
            }
            idx.append(contentsOf: sourceIndices)
            backing = .indexed(indices: idx, source: src)
        }
    }

    /// Replace the backing with an eager materialized array. Used when the
    /// filter pipeline runs over an in-memory source (or over find-mode,
    /// where everything passes the level/component filter and a flat
    /// array is fine).
    mutating func replace(with entries: [LogEntry]) {
        backing = .materialized(entries)
    }

    /// Replace the backing with an indexed view into the given source.
    /// Used by the Phase 3 indexed-source path where materializing all
    /// entries would defeat lazy loading.
    mutating func replace(indices: [Int], source: EntrySource) {
        backing = .indexed(indices: indices, source: source)
    }
}
