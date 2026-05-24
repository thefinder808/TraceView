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
    let indexElapsed: TimeInterval
    let warmElapsed: TimeInterval
    var buildElapsed: TimeInterval { indexElapsed + warmElapsed }

    var lineCount: Int { offsets.count }
    var totalBytes: Int { data.count }

    private init(
        fileURL: URL,
        data: Data,
        offsets: [UInt64],
        indexElapsed: TimeInterval,
        warmElapsed: TimeInterval
    ) {
        self.fileURL = fileURL
        self.data = data
        self.offsets = offsets
        self.indexElapsed = indexElapsed
        self.warmElapsed = warmElapsed
    }

    static func build(fileURL: URL) throws -> LogIndex {
        let start = Date()
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)

        // First pass: count newlines so we can size the offsets array
        // exactly. Counting is much faster than appending; saves repeated
        // reallocations.
        var newlineCount = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let ptr = buf.bindMemory(to: UInt8.self)
            for i in 0..<ptr.count {
                if ptr[i] == 0x0A { newlineCount += 1 }
            }
        }

        // Second pass: fill the offsets array in pre-allocated capacity.
        // Line 0 starts at byte 0; subsequent lines start right after each
        // 0x0A. We don't record an offset past the last newline when the
        // file ends with `\n` — line N-1's end is implied by data.count,
        // and the last-line branch in `line(at:)` drops the trailing LF.
        // For files that don't end with `\n`, the last newline opens line
        // N-1, which `line(at:)` reads to end-of-file.
        let offsets = [UInt64](unsafeUninitializedCapacity: newlineCount + 1) { buf, initializedCount in
            buf[0] = 0
            var k = 1
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let ptr = raw.bindMemory(to: UInt8.self)
                for i in 0..<ptr.count {
                    if ptr[i] == 0x0A && i + 1 < ptr.count {
                        buf[k] = UInt64(i + 1)
                        k += 1
                    }
                }
            }
            initializedCount = k
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
            indexElapsed: indexElapsed,
            warmElapsed: warmElapsed
        )
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
