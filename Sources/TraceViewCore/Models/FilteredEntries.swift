import Foundation

/// View-model-owned snapshot of which entries pass the active filter.
///
/// Three backing modes:
/// - `.materialized([LogEntry])`: filter ran eagerly, the array is the
///   answer. Used for in-memory sources and for find-mode (where every
///   entry passes the level/component filter, so the array is effectively
///   the full entries list).
/// - `.identity(source:)`: indexed source with no active filter. count
///   and subscript forward directly to the source — avoids materializing
///   a `[Int]` of size N (288 MB for a 36 M-row file). Used in Phase 3
///   where filter/find are disabled for indexed mode.
/// - `.indexed(indices: [Int], source: EntrySource)`: filter ran lazily
///   over an indexed source; we kept only the source-row indices that
///   matched. Subscript calls `source.entry(at: indices[i])` per access.
///   Reserved for Phase 4+ when filter support over indexed sources lands.
///
/// Conforms to `RandomAccessCollection<LogEntry>` so the renderer, binary
/// search, and the find-match scanner can `entries[row]`/`entries.count`/
/// `entries.first { … }` regardless of backing.
///
/// Mutation is intentionally NOT free via the protocol — `append(contentsOf:)`
/// would be ambiguous across backings. Callers use the explicit
/// `append(matching:sourceIndices:)` and `replace(...)` methods.
struct FilteredEntries: RandomAccessCollection {
    enum Backing {
        case materialized([LogEntry])
        case identity(source: EntrySource)
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
        case .identity(let src):     return src.count
        case .indexed(let idx, _):   return idx.count
        }
    }

    subscript(position: Int) -> LogEntry {
        switch backing {
        case .materialized(let arr):
            return arr[position]
        case .identity(let src):
            // Direct passthrough — position is 0..<src.count by
            // construction. Force-unwrap because nil here means the
            // source's count and entry(at:) disagree, which is a bug.
            return src.entry(at: position)!
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
    /// these entries live at) and appends those indices. `.identity`
    /// does not support append — its count tracks the source directly,
    /// so there's nothing for the caller to extend.
    mutating func append(matching entries: [LogEntry], sourceIndices: [Int]? = nil) {
        guard !entries.isEmpty else { return }
        switch backing {
        case .materialized(var arr):
            arr.append(contentsOf: entries)
            backing = .materialized(arr)
        case .identity:
            assertionFailure(".identity backing's count tracks the source — append is not meaningful")
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
    /// Reserved for Phase 4+ — Phase 3 disables filter in indexed mode.
    mutating func replace(indices: [Int], source: EntrySource) {
        backing = .indexed(indices: indices, source: source)
    }

    /// Replace the backing with the identity view over the given source.
    /// Used by Phase 3's indexed-mode wire-up (filter disabled, all rows
    /// addressed lazily).
    mutating func replace(identity source: EntrySource) {
        backing = .identity(source: source)
    }

    // MARK: - Fast lookups

    /// O(1) (or O(log N) for filtered) lookup for backings with a
    /// stable line-number → source-row mapping. `.identity` over an
    /// `IndexedEntrySource` is O(1) (the source sets `LogEntry.lineNumber
    /// = position + 1`). `.indexed` over an indexed source becomes
    /// O(log N) via a bisect on the sorted indices array (the scanner
    /// always emits in source-row order). Falls back to a linear scan
    /// for `.materialized`.
    ///
    /// Used by go-to-line — a `firstIndex(where: { $0.lineNumber == target })`
    /// over a `.identity` or `.indexed` backing would parse every line
    /// up to the target on the main thread. For a 25 M-line jump that's
    /// 25 M DateFormatter calls and a multi-minute hang.
    func position(forLineNumber lineNumber: Int) -> Int? {
        switch backing {
        case .identity(let src):
            let candidate = lineNumber - 1
            return (candidate >= 0 && candidate < src.count) ? candidate : nil
        case .indexed(let indices, _):
            // lineNumber → source index conversion holds for
            // IndexedEntrySource (id == position == source index).
            let target = lineNumber - 1
            return binarySearchPosition(in: indices, for: target)
        case .materialized:
            return firstIndex(where: { $0.lineNumber == lineNumber })
        }
    }

    /// O(1) (or O(log N) for filtered) lookup for backings with a
    /// stable entry-id → source-row mapping. `.identity` is O(1);
    /// `.indexed` is O(log N) via the same bisect as
    /// `position(forLineNumber:)`. Falls back to a linear scan
    /// otherwise.
    ///
    /// Used by the renderer's expanded-row resolution. Without the
    /// shortcut, expanding any row in indexed mode triggers the same
    /// parse storm as the go-to-line bug — every apply() pass walks
    /// from row 0 until the expanded id is found.
    func position(forEntryID id: Int) -> Int? {
        switch backing {
        case .identity(let src):
            return (id >= 0 && id < src.count) ? id : nil
        case .indexed(let indices, _):
            return binarySearchPosition(in: indices, for: id)
        case .materialized:
            return firstIndex(where: { $0.id == id })
        }
    }

    /// Binary search for `target` in a sorted `indices` array. Returns
    /// the position of the match or nil if `target` is not present.
    /// The `IndexedFilterScanner.scan` always emits indices in
    /// monotonically-increasing order, which is what makes this bisect
    /// correct.
    private func binarySearchPosition(in indices: [Int], for target: Int) -> Int? {
        guard !indices.isEmpty, target >= indices.first!, target <= indices.last! else {
            return nil
        }
        var lo = 0
        var hi = indices.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let v = indices[mid]
            if v == target { return mid }
            if v < target { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }
}
