import Foundation
import Combine

/// EntrySource backed by a memory-mapped file + offset index. Built once
/// from a file URL; rows are decoded and parsed on demand via the
/// supplied `LogParser` and cached in an LRU so repeated accesses (draw
/// loop redraws, bisect probes, selection re-lookups) only parse once
/// per viewport-warm window.
///
/// Phase 3/4 constraints:
/// - The parser MUST be line-stateless (`parser.isLineStateless == true`).
///   `LogDocument.loadFile` enforces this before constructing the source.
///   PlainText, SCCM, CSV qualify; IPS, Diag, UnifiedLog, JSONLog don't.
/// - The source is static after build — no live tail, no live append.
///   `append` and `replace` assertionFailure in debug.
/// - Per-feature capability flags (Phase 4 PR2):
///   - `supportsLevelCounts == true` (always — `logIndex.levels` exists).
///   - `supportsHistogram == (logIndex.timestamps != nil)` — CSV's
///     column-driven timestamps aren't byte-addressable, so CSV-backed
///     indexed mode keeps histogram hidden.
///   - `supportsFilter == false` for PR2 — PR3 lights it up by wiring a
///     background raw-byte scan.
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
    let supportsLevelCounts = true
    var supportsHistogram: Bool { logIndex.timestamps != nil }
    let supportsFilter = false

    /// Documented "do not use" — synthesizing the full array defeats lazy
    /// loading. Returns []. Callers that need to iterate every entry in
    /// indexed mode should bail on the per-feature flags or use the
    /// `derivedLevelCounts` / `derivedHistogram(...)` accessors below.
    var allEntries: [LogEntry] { [] }

    /// Per-level counts populated from `logIndex.levels` in a single O(N)
    /// pass. Lazy because the source may be built before any view binds
    /// to the count (e.g. `LogDocument.loadFileIndexed` copies into
    /// `levelCounts` once on `.complete`); subsequent reads hit the
    /// cached value.
    private(set) lazy var derivedLevelCounts: [LogLevel: Int] = {
        var counts: [LogLevel: Int] = [:]
        for byte in logIndex.levels {
            let level = FastLevelScanner.decode(byte)
            counts[level, default: 0] += 1
        }
        return counts
    }()

    /// Build a `LogHistogram` directly from `logIndex.timestamps` +
    /// `logIndex.levels`. Returns nil if the parser kind doesn't
    /// support byte-level timestamp capture (no timestamps array) or
    /// fewer than 10 valid timestamps exist (mirrors the in-memory
    /// histogram's minimum-row threshold).
    ///
    /// The shape matches `LogDocument.computeHistogram`'s output — same
    /// `Bar` / `Shadow` types, same buckets / maxTotal / labels — so
    /// `HistogramView` consumes both transparently. Spike peaks are not
    /// produced (the source is static-after-build; rebucketing rounds
    /// don't happen, so the shadow projection isn't meaningful).
    func derivedHistogram(buckets: Int) -> LogHistogram? {
        guard let timestamps = logIndex.timestamps, buckets > 0 else { return nil }

        var first: Double = .greatestFiniteMagnitude
        var last: Double = -.greatestFiniteMagnitude
        var timestampedCount = 0
        let total = timestamps.count
        for ts in timestamps {
            guard ts.isFinite else { continue }
            timestampedCount += 1
            if ts < first { first = ts }
            if ts > last { last = ts }
        }
        guard timestampedCount >= 10,
              Double(timestampedCount) / Double(total) >= 0.1,
              last > first else {
            return nil
        }

        let totalSpan = last - first
        let bucketSize = totalSpan / Double(buckets)
        var bars = Array(repeating: LogHistogram.Bar(err: 0, warn: 0, info: 0), count: buckets)

        for i in 0..<total {
            let ts = timestamps[i]
            guard ts.isFinite else { continue }
            let offset = ts - first
            let idx = min(buckets - 1, max(0, Int(offset / bucketSize)))
            let level = FastLevelScanner.decode(logIndex.levels[i])
            let existing = bars[idx]
            switch level {
            case .error, .critical:
                bars[idx] = LogHistogram.Bar(err: existing.err + 1, warn: existing.warn, info: existing.info)
            case .warning:
                bars[idx] = LogHistogram.Bar(err: existing.err, warn: existing.warn + 1, info: existing.info)
            default:
                bars[idx] = LogHistogram.Bar(err: existing.err, warn: existing.warn, info: existing.info + 1)
            }
        }

        let maxTotal = bars.map(\.total).max() ?? 1
        let firstDate = Date(timeIntervalSince1970: first)
        let lastDate = Date(timeIntervalSince1970: last)
        let formatter = totalSpan > 86400
            ? Self.histogramLabelFormatterLong
            : Self.histogramLabelFormatterShort

        return LogHistogram(
            bars: bars,
            maxTotal: maxTotal,
            startLabel: formatter.string(from: firstDate),
            endLabel: formatter.string(from: lastDate),
            startTime: firstDate,
            bucketSize: bucketSize,
            shadows: []  // see comment above — no peaks in indexed mode
        )
    }

    /// Find the first row whose timestamp falls in
    /// `[startEpoch, endEpoch)` and whose level (decoded from
    /// `logIndex.levels`) is in `matchingLevels` — or any row when
    /// `matchingLevels` is nil. Returns the row index or nil if no row
    /// qualifies.
    ///
    /// O(log N + bucketWidth) — bisect `logIndex.timestamps` for the
    /// first index whose timestamp is `>= startEpoch`, then walk
    /// forward through the bucket checking the level byte directly.
    /// No parser invocation occurs in the search itself; the caller
    /// can `entry(at:)` the returned index for a single parse.
    ///
    /// Replaces the in-memory pattern
    /// `entries.first { ... timestamp + level predicate ... }` for
    /// indexed mode, which would otherwise route every probe through
    /// `entry(at:)` → `parser.parse` and parse-storm the main thread
    /// on a 36 M-row file (5GB BSD-syslog: ~37 s hang before the OS
    /// spills a stackshot — confirmed via the histogram-click bug in
    /// Phase 4 PR2 smoke).
    func firstRowInTimeRange(
        startEpoch: Double,
        endEpoch: Double,
        matchingLevels: Set<LogLevel>?
    ) -> Int? {
        guard let timestamps = logIndex.timestamps, !timestamps.isEmpty else {
            return nil
        }
        // Bisect for the smallest i with timestamps[i] >= startEpoch.
        // NaN entries fail the >= comparison so they sink to the "less
        // than" side; bisect skips past long NaN prefixes correctly.
        var lo = 0
        var hi = timestamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let ts = timestamps[mid]
            if ts.isFinite && ts >= startEpoch {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        // Walk forward through the bucket checking levels directly.
        var i = lo
        let limit = timestamps.count
        while i < limit {
            let ts = timestamps[i]
            if ts.isFinite && ts >= endEpoch { break }
            if ts.isFinite && ts >= startEpoch {
                if let matchingLevels {
                    let level = FastLevelScanner.decode(logIndex.levels[i])
                    if matchingLevels.contains(level) {
                        return i
                    }
                } else {
                    return i
                }
            }
            i += 1
        }
        return nil
    }

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

    init(fileURL: URL, parser: any LogParser) throws {
        precondition(
            parser.isLineStateless,
            "IndexedEntrySource requires a line-stateless parser; got \(parser.name)"
        )
        self.parser = parser
        // Phase 4: pass the parser's ParserKind into LogIndex so its
        // build pass can pick the right byte-level level + timestamp
        // scanner. Bytes captured into logIndex.levels / .timestamps;
        // see FastLineScanner for the equivalence boundary with
        // parser.parse(line:).
        self.logIndex = try LogIndex.build(fileURL: fileURL, parserKind: parser.kind)
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
