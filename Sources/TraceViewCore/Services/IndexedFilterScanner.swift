import Darwin
import Foundation

/// Background raw-byte filter pipeline for indexed-mode `EntrySource`.
/// Walks `logIndex.offsets` line by line, applying a level filter via the
/// cached `logIndex.levels` array (zero parse cost) and a text filter via
/// `memmem` or a case-folded byte loop over each line's slice of the
/// mmap'd Data. Never materializes a `LogEntry`; the output is a
/// `[Int]` of source-row indices that the view-model wraps in a
/// `FilteredEntries(.indexed(indices: source:))`.
///
/// Designed to run from `Task.detached` so cancellation is meaningful.
/// Cooperative cancellation: `Task.isCancelled` polled every 65 536
/// rows (~2 ms at typical scan rate). Progress is reported via the
/// supplied callback at 1 % granularity — caller is responsible for
/// hopping to main if updating `@Published` state.
///
/// Equivalence with in-memory filter:
/// - Level / minimumLevel: byte-level read of `logIndex.levels[i]`
///   matches the encoded LogLevel exactly (PR1's `FastLevelScanner`
///   guarantees ≥99 % parity with `parser.parse(line:).level` on the
///   supported parser kinds).
/// - Search text (literal): ASCII byte-level case-fold via `| 0x20`,
///   equivalent to `String.range(of:options:.caseInsensitive)` for
///   ASCII-only needles. Multi-byte UTF-8 case folding (e.g. ß ↔ SS)
///   is not supported; document the boundary in tests.
/// - Search text (regex): per-candidate decode + NSRegularExpression
///   match (post-level filter only, so candidate count is small).
/// - Component: NOT applied in indexed mode (PR3 ships text + level
///   only; per the Phase 4 plan).
///
/// Returns nil on cancellation, an array of indices otherwise (possibly
/// empty when the filter excludes everything).
enum IndexedFilterScanner {

    /// Synchronous entry point. Designed for invocation from
    /// `Task.detached`. Cancellation is checked periodically via
    /// `Task.isCancelled`. The progress callback is invoked from the
    /// calling thread at 1 % granularity.
    static func scan(
        source: IndexedEntrySource,
        filter: LogFilter,
        progress: (Double) -> Void
    ) -> [Int]? {
        let logIndex = source.logIndex
        let lineCount = logIndex.lineCount
        guard lineCount > 0 else { return [] }

        // Snapshot filter state up-front so the loop body works against
        // immutable locals (no per-iteration property reads).
        let enabledLevels = filter.enabledLevels
        let minimumLevel = filter.minimumLevel
        let allLevelsEnabled = enabledLevels.count == LogLevel.allCases.count
        let hasLevelFilter = !allLevelsEnabled || minimumLevel != .debug

        let searchText = filter.searchText
        let isRegex = filter.isRegex
        let caseSensitive = filter.caseSensitive
        let hasTextFilter = !searchText.isEmpty

        // Phase 4.5 PR2 component gate. Resolved up-front to a UInt16
        // index into `logIndex.uniqueComponents`; per-row check is a
        // single UInt16 compare. If the requested component isn't in
        // the unique list, the filter excludes everything (matches
        // in-memory `LogFilter.matchesLevelAndComponent` semantics —
        // filter.component non-nil but no entry has that component
        // → zero results).
        let targetComponent = filter.component
        let componentIndex = logIndex.componentIndex
        let uniqueComponents = logIndex.uniqueComponents
        let hasComponentFilter = targetComponent != nil && componentIndex != nil && uniqueComponents != nil
        let targetComponentID: UInt16?
        if let target = targetComponent,
           let unique = uniqueComponents,
           let id = unique.firstIndex(of: target) {
            targetComponentID = UInt16(id)
        } else {
            targetComponentID = nil
        }

        // Pre-compile the needle representation for byte-level search.
        // Regex path goes through NSRegularExpression on candidates only
        // (after level filter), so the cost is bounded by candidate
        // count.
        let literalNeedle: [UInt8]?
        let regex: NSRegularExpression?
        if hasTextFilter && !isRegex {
            literalNeedle = Array(searchText.utf8)
            regex = nil
        } else if hasTextFilter && isRegex {
            let opts: NSRegularExpression.Options = caseSensitive ? [] : .caseInsensitive
            literalNeedle = nil
            regex = try? NSRegularExpression(pattern: searchText, options: opts)
        } else {
            literalNeedle = nil
            regex = nil
        }

        // Pre-lowercase the literal needle for case-insensitive ASCII
        // fold via `byte | 0x20`. No allocation per iteration.
        let foldedNeedle: [UInt8]? = literalNeedle.map { needle in
            caseSensitive ? needle : needle.map { $0 | 0x20 }
        }

        var matched: [Int] = []
        // Heuristic: assume ~10 % of rows pass. Worst case the array
        // grows under the hood; this just avoids a long startup of
        // doublings on million-row scans.
        matched.reserveCapacity(max(1024, lineCount / 10))

        let cancelCheckInterval = 65_536
        let progressDenominator = Double(lineCount)
        let progressStep = max(1, lineCount / 100)

        let data = logIndex.data
        let offsets = logIndex.offsets
        let levels = logIndex.levels

        // The mmap'd buffer is valid only for the duration of this
        // closure. The scan is fully synchronous inside it.
        let result: [Int]? = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [Int]? in
            guard let base = buf.baseAddress else { return [] }
            let totalCount = buf.count

            var i = 0
            while i < lineCount {
                if i % cancelCheckInterval == 0, Task.isCancelled {
                    return nil
                }
                if i % progressStep == 0 {
                    progress(Double(i) / progressDenominator)
                }

                // Level / minimumLevel.
                if hasLevelFilter {
                    let level = FastLevelScanner.decode(levels[i])
                    if !enabledLevels.contains(level) {
                        i += 1
                        continue
                    }
                    if level < minimumLevel {
                        i += 1
                        continue
                    }
                }

                // Component filter — UInt16 lookup against the cached
                // per-row index. If the target component isn't in the
                // file's unique-components table, every row is rejected.
                if hasComponentFilter {
                    guard let targetID = targetComponentID else {
                        i += 1
                        continue
                    }
                    if componentIndex![i] != targetID {
                        i += 1
                        continue
                    }
                }

                // Text filter — runs only on level-passing candidates.
                if hasTextFilter {
                    let lineStart = Int(offsets[i])
                    let lineEnd: Int
                    if i + 1 < lineCount {
                        // Drop the trailing `\n` byte.
                        lineEnd = Int(offsets[i + 1]) - 1
                    } else if totalCount > 0,
                              base.load(fromByteOffset: totalCount - 1, as: UInt8.self) == 0x0A {
                        lineEnd = totalCount - 1
                    } else {
                        lineEnd = totalCount
                    }
                    if lineEnd <= lineStart {
                        i += 1
                        continue
                    }

                    let textMatches: Bool
                    if let regex {
                        textMatches = regexMatchesLine(
                            base: base, start: lineStart, end: lineEnd, regex: regex
                        )
                    } else if let foldedNeedle {
                        textMatches = lineContains(
                            base: base, start: lineStart, end: lineEnd,
                            needle: foldedNeedle, caseSensitive: caseSensitive
                        )
                    } else {
                        // hasTextFilter is set but neither regex nor
                        // literal needle was constructed — only happens
                        // when an `isRegex` filter's pattern failed to
                        // compile. In-memory `matchesSearchText` returns
                        // false in that case; mirror it.
                        textMatches = false
                    }
                    if !textMatches {
                        i += 1
                        continue
                    }
                }

                matched.append(i)
                i += 1
            }

            return matched
        }

        return result
    }

    // MARK: - Byte-level helpers

    /// ASCII case-fold substring search. `needle` is already folded
    /// (lowercased) when `caseSensitive == false`. Returns true iff the
    /// haystack contains the needle. Pure byte equality when
    /// `caseSensitive == true` (delegated to libc `memmem`).
    @inline(__always)
    private static func lineContains(
        base: UnsafeRawPointer,
        start: Int,
        end: Int,
        needle: [UInt8],
        caseSensitive: Bool
    ) -> Bool {
        let haystackLen = end - start
        let needleLen = needle.count
        guard needleLen > 0, needleLen <= haystackLen else { return false }

        if caseSensitive {
            return needle.withUnsafeBufferPointer { needleBuf -> Bool in
                guard let needlePtr = needleBuf.baseAddress else { return false }
                return memmem(
                    base.advanced(by: start), haystackLen,
                    needlePtr, needleLen
                ) != nil
            }
        }

        // Case-insensitive ASCII fold. `byte | 0x20` lowercases A-Z and
        // is a no-op on already-lowercase letters and digits. Punctuation
        // and multi-byte UTF-8 bytes get the same transformation on both
        // sides so equality still holds for substring identity (the
        // exception is Unicode case-pair like ß ↔ SS, which this can't
        // express — documented in tests).
        let limit = haystackLen - needleLen
        var i = 0
        while i <= limit {
            var matched = true
            for j in 0..<needleLen {
                let h = base.load(fromByteOffset: start + i + j, as: UInt8.self) | 0x20
                if h != needle[j] {
                    matched = false
                    break
                }
            }
            if matched { return true }
            i += 1
        }
        return false
    }

    /// Decode the line's bytes to a `String` and run a regex match.
    /// Slower than the literal byte scan but only runs on level-passing
    /// candidates, so the total cost is bounded by candidate count.
    private static func regexMatchesLine(
        base: UnsafeRawPointer,
        start: Int,
        end: Int,
        regex: NSRegularExpression
    ) -> Bool {
        let length = end - start
        guard length > 0 else { return false }
        let bytes = Data(bytes: base.advanced(by: start), count: length)
        guard let line = String(data: bytes, encoding: .utf8) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }
}
