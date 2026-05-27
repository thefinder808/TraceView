import Darwin
import Foundation

/// Memory-mapped log file + offset index for lazy random-access row reads.
///
/// The file is mmapped via `Data(contentsOf:options:.mappedIfSafe)`, which
/// gives the kernel control over which pages are actually resident.
/// Reading individual lines via `line(at:)` materializes only the bytes
/// for that line as a Swift String. Scrolling the table touches only the
/// visible rows, so resident memory stays bounded regardless of total
/// file size — a 5 GB file with a 290 MB offsets array plus a few hundred
/// MB of resident pages, not a 5 GB copy.
///
/// Phase 4 captures two parallel arrays during the same build pass:
/// `levels: [UInt8]` (always; ~36 MB on 5 GB) and `timestamps: [Double]?`
/// (PlainText / SCCM only; ~292 MB on 5 GB). These power severity chips,
/// histogram, and level-filter in indexed mode without touching the
/// parser or materializing entries. See `FastLineScanner` for the
/// equivalence boundary with `parser.parse(line:)`.
///
/// Build cost is one full pass over the file scanning for 0x0A. On
/// M-series the scan runs at memory bandwidth so a 5 GB file indexes in
/// 1-2 s once the pages page in. The warm pass that follows touches one
/// byte per 16 KB page so subsequent row reads from the AppKit draw loop
/// don't page-fault on the main thread.
///
/// Re-implementation of the spike at
/// `/Users/thefinder808/Development/traceview-spike/Sources/TraceViewSpike/LogIndex.swift`
/// against TraceView types. The boundary-condition logic for files with
/// vs without a trailing `\n` is preserved verbatim — the spike's version
/// was verified correct during planning.
final class LogIndex {
    let fileURL: URL
    let data: Data                  // memory-mapped, kernel-managed paging
    let offsets: [UInt64]           // byte offset of the start of each line
    let levels: [UInt8]             // FastLevelScanner output per line
    let timestamps: [Double]?       // FastTimestampScanner output, or nil
    /// Phase 4.5 PR2 component capture. `componentIndex[i]` is an index
    /// into `uniqueComponents` for row i. `uniqueComponents[0]` is the
    /// sentinel empty string ("no component captured"). Populated when
    /// `parserKind` is PlainText or SCCM; nil otherwise.
    let componentIndex: [UInt16]?
    let uniqueComponents: [String]?
    /// Source-row indices in timestamp order, populated only when the
    /// build pass detected non-monotonic timestamps (e.g. install.log
    /// written by multiple concurrent daemons). Nil for the common
    /// monotonic case so the bisect in `IndexedEntrySource` stays on
    /// the zero-allocation fast path. When present, sort key is
    /// `(timestamp, sourceIndex)` with NaN entries placed at the head
    /// via the predicate in `build()`. The bisect predicate then
    /// treats NaN as "less than start" and walks past them naturally.
    let sortedByTimestamp: [Int]?
    let parserKind: ParserKind
    let indexElapsed: TimeInterval
    let warmElapsed: TimeInterval
    /// Time to build `sortedByTimestamp`. Zero when monotonic (no
    /// sort happened) AND zero on the cache-hit path (the sort
    /// happened on the original build whose timing was recorded
    /// then). Treat `buildElapsed` accordingly when comparing
    /// fresh-build vs cache-load timings.
    let sortedSortElapsed: TimeInterval
    var buildElapsed: TimeInterval { indexElapsed + warmElapsed + sortedSortElapsed }

    var lineCount: Int { offsets.count }
    var totalBytes: Int { data.count }

    private init(
        fileURL: URL,
        data: Data,
        offsets: [UInt64],
        levels: [UInt8],
        timestamps: [Double]?,
        componentIndex: [UInt16]?,
        uniqueComponents: [String]?,
        sortedByTimestamp: [Int]?,
        parserKind: ParserKind,
        indexElapsed: TimeInterval,
        warmElapsed: TimeInterval,
        sortedSortElapsed: TimeInterval
    ) {
        self.fileURL = fileURL
        self.data = data
        self.offsets = offsets
        self.levels = levels
        self.timestamps = timestamps
        self.componentIndex = componentIndex
        self.uniqueComponents = uniqueComponents
        self.sortedByTimestamp = sortedByTimestamp
        self.parserKind = parserKind
        self.indexElapsed = indexElapsed
        self.warmElapsed = warmElapsed
        self.sortedSortElapsed = sortedSortElapsed
    }

    static func build(fileURL: URL, parserKind: ParserKind = .other) throws -> LogIndex {
        let start = Date()
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)

        // First pass: count newlines so we can size the offsets array
        // exactly. Uses `memchr` (libsystem, SIMD-vectorized) instead of
        // a Swift per-byte loop. In release the two are similar; in
        // debug builds the Swift loop pays a bounds-check per iteration,
        // making it ~50× slower on multi-GB files (5 GB went from
        // minutes-of-hang to ~1 s on M-series).
        var newlineCount = 0
        data.withUnsafeBytes { buf in
            Self.forEachNewline(in: buf) { _ in newlineCount += 1 }
        }

        // The offsets array is at minimum 1 entry (line 0 starts at byte
        // 0, even an empty/no-newline file has one line). Capacity is
        // newlineCount + 1 because the final line may or may not have a
        // trailing newline — we drop one offset in that case.
        let lineCapacity = newlineCount + 1

        // Resolve whether to capture timestamps. CSV and .other parsers
        // don't have a usable byte-level timestamp scanner, so we save
        // the 8 bytes/line by skipping the array entirely.
        let captureTimestamps: Bool = (parserKind == .plainText || parserKind == .sccm)
        let captureComponents: Bool = (parserKind == .plainText || parserKind == .sccm)
        let yearContext = FastTimestampScanner.YearContext.default

        // Pre-allocate the parallel arrays. UInt8 storage for levels is
        // 1 byte/line; Double storage for timestamps is 8 bytes/line;
        // UInt16 per row for component indices. On a 5 GB BSD-syslog
        // file with 36.5 M lines: levels 36 MB, timestamps 292 MB,
        // componentIndex 73 MB.
        var levelsBuf = [UInt8](repeating: FastLevelScanner.encode(.info), count: lineCapacity)
        var timestampsBuf: [Double]? = captureTimestamps
            ? [Double](repeating: .nan, count: lineCapacity)
            : nil
        var componentIndexBuf: [UInt16]? = captureComponents
            ? [UInt16](repeating: 0, count: lineCapacity)
            : nil
        // Index 0 reserved for empty/"no component captured" so a UInt16
        // of 0 means "no component" without burning a real entry.
        var componentTable: [String: UInt16]? = captureComponents ? ["": 0] : nil
        var uniqueComponentsBuf: [String]? = captureComponents ? [""] : nil

        // Track monotonicity of finite timestamps as the build pass
        // writes them. We compare each new finite timestamp against the
        // previous finite one (skipping NaN/continuation lines so they
        // never falsify the flag). On non-monotonic, we build a sorted
        // companion index after this pass so `firstRowInTimeRange` has
        // a view it can bisect over. install.log is the canonical
        // trigger — concurrent daemons writing into the same file
        // interleave timestamps slightly out of order.
        var isMonotonic = true
        var prevFiniteTs = -Double.infinity

        // Second pass: fill the offsets array in pre-allocated capacity,
        // plus the levels and (optional) timestamps in lock-step. Line 0
        // starts at byte 0; subsequent lines start right after each
        // 0x0A. We don't record an offset past the last newline when the
        // file ends with `\n` — line N-1's end is implied by data.count,
        // and the last-line branch in `line(at:)` drops the trailing LF.
        // For files that don't end with `\n`, the last newline opens line
        // N-1, which `line(at:)` reads to end-of-file.
        let offsets = [UInt64](unsafeUninitializedCapacity: lineCapacity) { dst, initializedCount in
            dst[0] = 0
            var k = 1
            var lineStart: Int = 0
            data.withUnsafeBytes { buf in
                let totalCount = buf.count

                // Capture the head fields for line 0 (covers the case
                // where there are no newlines, plus all single-line
                // files). When forEachNewline iterates, we close each
                // previous line at the newline-byte and open the next.
                Self.forEachNewline(in: buf) { foundOffset in
                    // Close-out the previous line (lineStart ..< foundOffset).
                    let lineEnd = foundOffset
                    if k - 1 < lineCapacity {
                        levelsBuf[k - 1] = FastLevelScanner.detect(
                            in: buf,
                            range: lineStart..<lineEnd,
                            kind: parserKind
                        )
                        if captureTimestamps {
                            let ts = FastTimestampScanner.parse(
                                in: buf,
                                range: lineStart..<lineEnd,
                                kind: parserKind,
                                yearContext: yearContext
                            )
                            timestampsBuf![k - 1] = ts
                            if ts.isFinite {
                                if ts < prevFiniteTs { isMonotonic = false }
                                prevFiniteTs = ts
                            }
                        }
                        if captureComponents {
                            componentIndexBuf![k - 1] = Self.componentIndex(
                                for: lineStart..<lineEnd, in: buf, kind: parserKind,
                                table: &componentTable!, unique: &uniqueComponentsBuf!
                            )
                        }
                    }
                    // Skip recording an offset past the final newline
                    // when the file ends with `\n`. Mirrors the pre-
                    // memchr `i + 1 < ptr.count` guard exactly.
                    if foundOffset + 1 < totalCount {
                        dst[k] = UInt64(foundOffset + 1)
                        lineStart = foundOffset + 1
                        k += 1
                    } else {
                        // The trailing-newline case — no more lines
                        // remain. Mark lineStart so the post-loop close
                        // doesn't write past the array.
                        lineStart = totalCount
                    }
                }

                // Close-out the final line if there's content past the
                // last newline (file doesn't end with \n). When the file
                // ends with \n, lineStart == totalCount and we skip.
                if lineStart < totalCount && k - 1 < lineCapacity {
                    levelsBuf[k - 1] = FastLevelScanner.detect(
                        in: buf,
                        range: lineStart..<totalCount,
                        kind: parserKind
                    )
                    if captureTimestamps {
                        let ts = FastTimestampScanner.parse(
                            in: buf,
                            range: lineStart..<totalCount,
                            kind: parserKind,
                            yearContext: yearContext
                        )
                        timestampsBuf![k - 1] = ts
                        if ts.isFinite {
                            if ts < prevFiniteTs { isMonotonic = false }
                            prevFiniteTs = ts
                        }
                    }
                    if captureComponents {
                        componentIndexBuf![k - 1] = Self.componentIndex(
                            for: lineStart..<totalCount, in: buf, kind: parserKind,
                            table: &componentTable!, unique: &uniqueComponentsBuf!
                        )
                    }
                }
            }
            initializedCount = k
        }

        // Trim the parallel arrays in case the file ended with \n
        // (offsets shorter than lineCapacity by 1).
        if offsets.count < lineCapacity {
            levelsBuf.removeLast(lineCapacity - offsets.count)
            timestampsBuf?.removeLast(lineCapacity - offsets.count)
            componentIndexBuf?.removeLast(lineCapacity - offsets.count)
        }

        let indexElapsed = Date().timeIntervalSince(start)

        // Build the sorted companion index only when timestamps were
        // captured AND the build pass observed at least one inversion.
        // Monotonic logs (the common case) pay nothing — the field stays
        // nil and IndexedEntrySource takes the existing fast path.
        // NaN entries naturally sort to the head via the predicate
        // below; the bisect's "NaN counts as less than" check then
        // skips past them without a special case.
        var sortedByTimestamp: [Int]? = nil
        var sortedSortElapsed: TimeInterval = 0
        if let ts = timestampsBuf, !isMonotonic {
            let sortStart = Date()
            sortedByTimestamp = (0..<ts.count).sorted { lhs, rhs in
                let l = ts[lhs]
                let r = ts[rhs]
                if !l.isFinite && r.isFinite { return true }
                if l.isFinite && !r.isFinite { return false }
                if l.isFinite && r.isFinite && l != r { return l < r }
                // Source-index tiebreak. Applies to:
                //   - equal-timestamp finite rows (deterministic order
                //     for firstRowInTimeRange's "first match" guarantee)
                //   - both-NaN rows (NaN != NaN in IEEE, so the
                //     earlier branches all return false and we'd
                //     otherwise leave NaN relative order to the sort
                //     algorithm. Tiebreak here makes the whole array
                //     deterministic across rebuilds and cache loads.)
                return lhs < rhs
            }
            sortedSortElapsed = Date().timeIntervalSince(sortStart)
        }

        // Warm pass — see `warmPages` below for why this is load-bearing.
        let warmStart = Date()
        Self.warmPages(of: data)
        let warmElapsed = Date().timeIntervalSince(warmStart)

        return LogIndex(
            fileURL: fileURL,
            data: data,
            offsets: offsets,
            levels: levelsBuf,
            timestamps: timestampsBuf,
            componentIndex: componentIndexBuf,
            uniqueComponents: uniqueComponentsBuf,
            sortedByTimestamp: sortedByTimestamp,
            parserKind: parserKind,
            indexElapsed: indexElapsed,
            warmElapsed: warmElapsed,
            sortedSortElapsed: sortedSortElapsed
        )
    }

    /// Dedup helper called from the build pass. Extracts a component
    /// byte range from the line via FastComponentScanner, decodes to
    /// String, and assigns it a stable UInt16 ID via the running
    /// `table` dictionary. Index 0 is reserved for empty/no-component;
    /// every subsequent unique component gets the next available ID.
    /// Returns 0 when extraction fails so the row reports "no
    /// component" to the filter pipeline.
    private static func componentIndex(
        for range: Range<Int>,
        in buf: UnsafeRawBufferPointer,
        kind: ParserKind,
        table: inout [String: UInt16],
        unique: inout [String]
    ) -> UInt16 {
        guard let compRange = FastComponentScanner.extractRange(
            in: buf, range: range, kind: kind
        ) else {
            return 0
        }
        // Decode the slice once per unique component. Use the existing
        // dictionary lookup to coalesce repeats (typical syslog has
        // ~10-100 unique components across millions of lines, so
        // post-warmup most lookups hit the cache without allocating).
        guard let base = buf.baseAddress else { return 0 }
        let length = compRange.upperBound - compRange.lowerBound
        let data = Data(bytes: base.advanced(by: compRange.lowerBound), count: length)
        guard let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            return 0
        }
        if let existing = table[string] { return existing }
        // Cap at UInt16.max - 1 unique components. In practice we
        // never get close (real syslog files have <1000), but bound
        // defensively rather than risk an overflow in a runaway file.
        guard unique.count < Int(UInt16.max) else { return 0 }
        let nextID = UInt16(unique.count)
        unique.append(string)
        table[string] = nextID
        return nextID
    }

    /// Phase 4.5 entry point: try the on-disk cache before falling back
    /// to a fresh build. On cache miss the new build's results are
    /// written back atomically, so subsequent opens of the same source
    /// file hit the cache.
    ///
    /// The cache is invalidated when the source file's size or mtime
    /// changes (see `LogIndexCache.tryLoad`) — re-saves of the log file
    /// trigger an automatic rebuild.
    static func buildOrLoad(fileURL: URL, parserKind: ParserKind = .other) throws -> LogIndex {
        // Phase 5.5: respect the "Cache indexes to disk" setting. When
        // false, skip the cache read AND the post-build write so
        // nothing touches disk. Every open pays the full byte-scan
        // cost. Default true when the key has never been set.
        let cacheEnabled: Bool = {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: SettingsManager.indexedModeCacheEnabledKey) == nil {
                return true
            }
            return defaults.bool(forKey: SettingsManager.indexedModeCacheEnabledKey)
        }()

        if cacheEnabled,
           let cached = LogIndexCache.tryLoad(forSourceURL: fileURL, parserKind: parserKind) {
            let start = Date()
            // The source file is still mmap'd separately — its page
            // residency is independent of the cache file. The warmup
            // here pre-touches the source so on-demand line reads from
            // the renderer don't page-fault on the main thread.
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let indexElapsed = Date().timeIntervalSince(start)
            let warmStart = Date()
            warmPages(of: data)
            let warmElapsed = Date().timeIntervalSince(warmStart)
            return LogIndex(
                fileURL: fileURL,
                data: data,
                offsets: cached.offsets,
                levels: cached.levels,
                timestamps: cached.timestamps,
                componentIndex: cached.componentIndex,
                uniqueComponents: cached.uniqueComponents,
                sortedByTimestamp: cached.sortedByTimestamp,
                parserKind: cached.parserKind,
                indexElapsed: indexElapsed,
                warmElapsed: warmElapsed,
                sortedSortElapsed: 0
            )
        }

        // Cache miss (or cache disabled) → full build. Only persist
        // when caching is enabled.
        let index = try build(fileURL: fileURL, parserKind: parserKind)
        if cacheEnabled {
            LogIndexCache.write(
                sourceURL: fileURL,
                offsets: index.offsets,
                levels: index.levels,
                timestamps: index.timestamps,
                componentIndex: index.componentIndex,
                uniqueComponents: index.uniqueComponents,
                sortedByTimestamp: index.sortedByTimestamp,
                parserKind: parserKind
            )
        }
        return index
    }

    /// Warm the kernel's page cache for the given mmap'd source file.
    /// Two-step:
    ///   1. `madvise(MADV_WILLNEED)` — advisory prefetch hint. May or
    ///      may not be honored on macOS depending on memory pressure.
    ///   2. Touch one byte per 16 KB page — forces resident state
    ///      regardless. The `blackHole(sum)` call prevents the
    ///      optimizer from eliminating the reads.
    ///
    /// Without this pass, random-access reads from cell rendering hit
    /// page faults on the main thread → spinner-cursor freezes during
    /// momentum scroll, even on machines with plenty of free RAM.
    private static func warmPages(of data: Data) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let count = buf.count
            _ = madvise(UnsafeMutableRawPointer(mutating: base), count, MADV_WILLNEED)
            let pageSize = 16 * 1024
            var sum: UInt8 = 0
            var i = 0
            while i < count {
                sum = sum &+ base.load(fromByteOffset: i, as: UInt8.self)
                i += pageSize
            }
            blackHole(sum)
        }
    }

    /// memchr-based newline iterator. Invokes `body` with the byte
    /// offset of every `\n` in `buf`. Used by `build` for both the
    /// count-pass and the offset-fill pass. `memchr` is highly
    /// vectorized in libsystem and is dramatically faster than a Swift
    /// per-byte loop, especially in debug builds where Swift's
    /// `UnsafeBufferPointer` subscript pays a bounds check per access.
    private static func forEachNewline(
        in buf: UnsafeRawBufferPointer,
        body: (Int) -> Void
    ) {
        guard let base = buf.baseAddress else { return }
        let totalCount = buf.count
        var consumed = 0
        while consumed < totalCount {
            let cursor = base.advanced(by: consumed)
            let remaining = totalCount - consumed
            // memchr returns nil when no more `\n` exist in the slice.
            guard let found = memchr(cursor, Int32(0x0A), remaining) else { return }
            let foundOffset = base.distance(to: UnsafeRawPointer(found))
            body(foundOffset)
            consumed = foundOffset + 1
        }
    }

    /// Returns the line at the given row index, excluding any trailing
    /// `\n`. Touches only the bytes for that line — adjacent lines stay
    /// paged out.
    func line(at index: Int) -> String? {
        guard index >= 0, index < offsets.count else { return nil }
        let start = Int(offsets[index])
        if index + 1 < offsets.count {
            // End of this line = start of next line - 1 (drop the \n).
            let end = Int(offsets[index + 1]) - 1
            guard end >= start else { return "" }
            return decodeRange(start..<end)
        }
        // Last line — may or may not have a trailing newline.
        if data.count > start, data[data.count - 1] == 0x0A {
            return decodeRange(start..<(data.count - 1))
        }
        guard data.count > start else { return "" }
        return decodeRange(start..<data.count)
    }

    private func decodeRange(_ range: Range<Int>) -> String {
        // data[range] is a Data slice; the explicit Data(...) materializes
        // only this line's bytes into a new buffer for UTF-8 decode.
        // Adjacent pages are not touched.
        let bytes = Data(data[range])
        return String(data: bytes, encoding: .utf8) ?? "<invalid utf-8>"
    }
}

/// Prevents the optimizer from eliminating dead reads in the warm-pages
/// loop. Mirrors the spike's helper.
@inline(never)
private func blackHole<T>(_ value: T) {
    _ = value
}
