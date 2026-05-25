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
    let parserKind: ParserKind
    let indexElapsed: TimeInterval
    let warmElapsed: TimeInterval
    var buildElapsed: TimeInterval { indexElapsed + warmElapsed }

    var lineCount: Int { offsets.count }
    var totalBytes: Int { data.count }

    private init(
        fileURL: URL,
        data: Data,
        offsets: [UInt64],
        levels: [UInt8],
        timestamps: [Double]?,
        parserKind: ParserKind,
        indexElapsed: TimeInterval,
        warmElapsed: TimeInterval
    ) {
        self.fileURL = fileURL
        self.data = data
        self.offsets = offsets
        self.levels = levels
        self.timestamps = timestamps
        self.parserKind = parserKind
        self.indexElapsed = indexElapsed
        self.warmElapsed = warmElapsed
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
        let yearContext = FastTimestampScanner.YearContext.default

        // Pre-allocate the parallel arrays. UInt8 storage for levels is
        // 1 byte/line; Double storage for timestamps is 8 bytes/line. On
        // a 5 GB BSD-syslog file with 36.5 M lines, levels are 36 MB and
        // timestamps are 292 MB.
        var levelsBuf = [UInt8](repeating: FastLevelScanner.encode(.info), count: lineCapacity)
        var timestampsBuf: [Double]? = captureTimestamps
            ? [Double](repeating: .nan, count: lineCapacity)
            : nil

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
                            timestampsBuf![k - 1] = FastTimestampScanner.parse(
                                in: buf,
                                range: lineStart..<lineEnd,
                                kind: parserKind,
                                yearContext: yearContext
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
                        timestampsBuf![k - 1] = FastTimestampScanner.parse(
                            in: buf,
                            range: lineStart..<totalCount,
                            kind: parserKind,
                            yearContext: yearContext
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
        }

        let indexElapsed = Date().timeIntervalSince(start)

        // Warm pass: the indexing scan above touched every byte to find
        // newlines, but the kernel can evict pages aggressively under any
        // memory pressure and the early-file pages may already be cold
        // by the time later pages were scanned. Without this pass,
        // random-access reads from cell rendering hit page faults on the
        // main thread → spinner-cursor freezes during momentum scroll,
        // even on machines with plenty of free RAM.
        //
        // Two-step:
        //   1. madvise(MADV_WILLNEED) — advisory prefetch hint. May or
        //      may not be honored on macOS.
        //   2. Touch one byte per 16 KB page — forces resident state
        //      regardless. The `blackHole(sum)` call prevents the
        //      optimizer from eliminating the reads.
        let warmStart = Date()
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
        let warmElapsed = Date().timeIntervalSince(warmStart)

        return LogIndex(
            fileURL: fileURL,
            data: data,
            offsets: offsets,
            levels: levelsBuf,
            timestamps: timestampsBuf,
            parserKind: parserKind,
            indexElapsed: indexElapsed,
            warmElapsed: warmElapsed
        )
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
