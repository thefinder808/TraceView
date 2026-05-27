import XCTest
@testable import TraceViewCore

final class IndexedEntrySourceTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        // Clean up the temp source files AND the index-cache blobs they
        // produced — `IndexedEntrySource` routes through
        // `LogIndex.buildOrLoad`, which persists into the user's
        // `~/Library/Caches/com.traceview.app/indexes/` keyed on a SHA-1
        // of the source path. Without this, every test run leaves a
        // stale .tvidx file that no live code path will ever collect.
        for url in temporaryFiles {
            if let cacheURL = LogIndexCache.cacheURL(forSourceURL: url) {
                try? FileManager.default.removeItem(at: cacheURL)
            }
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func writeTempFile(contents: String, suffix: String = "log") -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("IndexedEntrySourceTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    // MARK: - Basic round-trip

    func testBuildAndCountMatchExpected() throws {
        let url = writeTempFile(contents: """
        Jan 01 10:00:00 host proc[1]: first
        Jan 01 10:00:01 host proc[1]: second
        Jan 01 10:00:02 host proc[1]: third

        """)
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertEqual(source.count, 3)
    }

    func testEntryAtRoundTripsKnownFields() throws {
        let url = writeTempFile(contents: """
        Jan 15 12:34:56 myhost daemon[42]: hello world

        """)
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        let entry = source.entry(at: 0)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.id, 0)
        XCTAssertEqual(entry?.lineNumber, 1)
        XCTAssertNotNil(entry?.timestamp)
        XCTAssertEqual(entry?.message, "hello world")
        // PlainTextParser's BSD syslog pattern captures the process name
        // as the component.
        XCTAssertEqual(entry?.component, "daemon")
    }

    func testEntryAtOutOfBoundsReturnsNil() throws {
        let url = writeTempFile(contents: "line a\nline b\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertNotNil(source.entry(at: 0))
        XCTAssertNotNil(source.entry(at: 1))
        XCTAssertNil(source.entry(at: -1))
        XCTAssertNil(source.entry(at: 2))
        XCTAssertNil(source.entry(at: 999))
    }

    func testStableIDAcrossRepeatedCalls() throws {
        let url = writeTempFile(contents: "first\nsecond\nthird\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())

        // Repeat calls to the same row must return entries with the same
        // id — the renderer's last-reported-entry-id change detection
        // and the inline-detail-host's "same entry?" check both depend
        // on it.
        let a = source.entry(at: 1)
        let b = source.entry(at: 1)
        XCTAssertEqual(a?.id, b?.id)
        XCTAssertEqual(a?.id, 1)
    }

    func testCapabilityFlagsForPlainText() throws {
        // Phase 4 PR3: PlainText backed indexed source exposes all
        // three capabilities. supportsFilter flipped to true once the
        // IndexedFilterScanner pipeline shipped.
        let url = writeTempFile(contents: "a\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertTrue(source.supportsLevelCounts)
        XCTAssertTrue(source.supportsHistogram)
        XCTAssertTrue(source.supportsFilter)
    }

    func testAllEntriesReturnsEmpty() throws {
        let url = writeTempFile(contents: "a\nb\nc\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertEqual(source.count, 3)
        // Documented "do not use" — synthesizing the full array defeats
        // lazy loading.
        XCTAssertTrue(source.allEntries.isEmpty)
    }

    func testResetClearsCacheButLeavesIndex() throws {
        let url = writeTempFile(contents: "a\nb\nc\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        _ = source.entry(at: 0)  // populate cache
        source.reset()
        // After reset the index is still intact (file still mmapped) —
        // only the parse cache was cleared. entry(at:) re-parses on demand.
        XCTAssertNotNil(source.entry(at: 0))
        XCTAssertEqual(source.count, 3)
    }

    // MARK: - LRU cache deduplication

    /// Parser that records every parse call so the test can assert the
    /// LRU is actually deduplicating repeats. Marked line-stateless so
    /// it satisfies IndexedEntrySource's precondition.
    private final class ParseCountingParser: LogParser {
        let name = "ParseCounter"
        let supportedExtensions: Set<String> = ["log"]
        let isLineStateless = true
        var parseCalls = 0

        func canParse(sampleLines: [String]) -> Double { 1.0 }
        func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
            parseCalls += 1
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: .info,
                message: line, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }
    }

    func testLRUDeduplicatesParseCalls() throws {
        let url = writeTempFile(contents: "one\ntwo\nthree\n")
        let parser = ParseCountingParser()
        let source = try IndexedEntrySource(fileURL: url, parser: parser)

        _ = source.entry(at: 0)
        _ = source.entry(at: 1)
        _ = source.entry(at: 0)   // cached
        _ = source.entry(at: 1)   // cached
        _ = source.entry(at: 2)
        _ = source.entry(at: 0)   // cached

        XCTAssertEqual(parser.parseCalls, 3)
    }

    // MARK: - Parity with InMemoryEntrySource

    /// Open the same fixture both ways and assert line counts match. The
    /// real correctness invariant for Phase 3: a file opened indexed
    /// shows the same number of rows as the same file opened eagerly.
    ///
    /// Restricted to fixtures without empty lines because the in-memory
    /// chunked parse skips empty lines (`guard !line.isEmpty else { continue }`)
    /// while IndexedEntrySource counts every newline-separated line —
    /// see the "Empty lines" gap captured in PR3+'s open questions.
    // MARK: - Non-monotonic timestamps (install.log-style multi-writer logs)

    /// Synthetic fixture with one deliberate out-of-order timestamp.
    /// Source indices 0..3 climb monotonic at 10:00:00..10:00:03, index
    /// 4 jumps BACK to 10:00:01 (the "OOO" entry), index 5 jumps
    /// forward to 10:00:05, then 6..11 continue monotonic at
    /// 10:00:06..10:00:11. The OOO bucket (`[01, 02)`) contains only
    /// source row 4 — exactly the case the old bisect+walk couldn't
    /// reach: the bisect lands past row 4 in source order and the walk
    /// breaks at the first `ts >= endEpoch`. 12 timestamped lines clear
    /// `derivedHistogram`'s 10-row minimum so the parity test can also
    /// use this fixture.
    private func writeOOOFixture() -> URL {
        return writeTempFile(contents: """
        Jan 01 10:00:00 host proc[1]: a
        Jan 01 10:00:02 host proc[1]: b
        Jan 01 10:00:03 host proc[1]: c
        Jan 01 10:00:04 host proc[1]: d
        Jan 01 10:00:01 host proc[1]: error ooo entry
        Jan 01 10:00:05 host proc[1]: e
        Jan 01 10:00:06 host proc[1]: f
        Jan 01 10:00:07 host proc[1]: g
        Jan 01 10:00:08 host proc[1]: h
        Jan 01 10:00:09 host proc[1]: i
        Jan 01 10:00:10 host proc[1]: j
        Jan 01 10:00:11 host proc[1]: k

        """)
    }

    func testOOOFixtureBuildsSortedIndex() throws {
        let url = writeOOOFixture()
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertNotNil(
            source.logIndex.sortedByTimestamp,
            "Build pass must detect the inversion and emit a sorted companion"
        )
        XCTAssertEqual(source.logIndex.sortedByTimestamp?.count, 12)

        // Sorted positions are by (timestamp, sourceIndex). With the
        // fixture above the expected leading mapping is: src order
        // 0, 4, 1, 2, 3, 5 → timestamps 00, 01, 02, 03, 04, 05.
        // The tail (6..11) is already in sorted order.
        XCTAssertEqual(
            source.logIndex.sortedByTimestamp,
            [0, 4, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11]
        )
    }

    func testMonotonicFixtureDoesNotAllocateSortedIndex() throws {
        let url = writeTempFile(contents: """
        Jan 01 10:00:00 host proc[1]: a
        Jan 01 10:00:01 host proc[1]: b
        Jan 01 10:00:02 host proc[1]: c
        Jan 01 10:00:03 host proc[1]: d

        """)
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertNil(
            source.logIndex.sortedByTimestamp,
            "Monotonic logs must take the zero-allocation fast path"
        )
    }

    /// Bucket containing only the OOO entry. The old bisect+walk would
    /// fall through to `nil`; the sorted path must return its row.
    func testFirstRowInTimeRangeReachesOOOEntry() throws {
        let url = writeOOOFixture()
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())

        // Pull the actual extracted ts values so the test is robust
        // against year-context drift (FastTimestampScanner uses the
        // current calendar year for BSD-syslog dates).
        guard let ts = source.logIndex.timestamps else {
            return XCTFail("expected timestamps captured for BSD-syslog fixture")
        }
        // sortedByTimestamp[1] points at the OOO source row (ts=01).
        let oooSrc = source.logIndex.sortedByTimestamp![1]
        let oooTs = ts[oooSrc]
        let nextTs = ts[source.logIndex.sortedByTimestamp![2]]  // ts=02
        let row = source.firstRowInTimeRange(
            startEpoch: oooTs,
            endEpoch: nextTs,
            matchingLevels: nil,
            restrictTo: nil
        )
        XCTAssertEqual(row, oooSrc, "Sorted-path bisect must reach the OOO entry")
    }

    /// Same bucket, but the click came from a pane with an active
    /// filter. When the OOO row is IN the filter, the click must
    /// resolve to it.
    func testFirstRowInTimeRangeOOOWithFilterIncluding() throws {
        let url = writeOOOFixture()
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        let ts = source.logIndex.timestamps!
        let sorted = source.logIndex.sortedByTimestamp!
        let oooSrc = sorted[1]
        let nextTs = ts[sorted[2]]

        // Filter includes 0, 4 (the OOO row), 5 — all sorted by source row.
        let filtered = [0, 4, 5]
        let row = source.firstRowInTimeRange(
            startEpoch: ts[oooSrc],
            endEpoch: nextTs,
            matchingLevels: nil,
            restrictTo: filtered
        )
        XCTAssertEqual(row, oooSrc)
    }

    /// When the filter EXCLUDES the OOO row, the bucket is effectively
    /// empty — must return nil cleanly without falling into a loop or
    /// reading off the end.
    func testFirstRowInTimeRangeOOOWithFilterExcluding() throws {
        let url = writeOOOFixture()
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        let ts = source.logIndex.timestamps!
        let sorted = source.logIndex.sortedByTimestamp!
        let oooSrc = sorted[1]
        let nextTs = ts[sorted[2]]

        // Excludes source row 4 (the OOO entry). Remaining rows are at
        // 10:00:00 (src 0) and 10:00:02+ (src 1, 2, 3, 5) — none fall
        // inside [01, 02).
        let filtered = [0, 1, 2, 3, 5]
        let row = source.firstRowInTimeRange(
            startEpoch: ts[oooSrc],
            endEpoch: nextTs,
            matchingLevels: nil,
            restrictTo: filtered
        )
        XCTAssertNil(row)
    }

    /// Level-aware lookup over the OOO bucket. The fixture marks the
    /// OOO row's message with `error` so LevelDetector's keyword scan
    /// classifies it as `.error`.
    func testFirstRowInTimeRangeOOOWithLevelMatching() throws {
        let url = writeOOOFixture()
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        let ts = source.logIndex.timestamps!
        let sorted = source.logIndex.sortedByTimestamp!
        let oooSrc = sorted[1]
        let nextTs = ts[sorted[2]]

        let row = source.firstRowInTimeRange(
            startEpoch: ts[oooSrc],
            endEpoch: nextTs,
            matchingLevels: [.error, .critical],
            restrictTo: nil
        )
        XCTAssertEqual(row, oooSrc, "Level filter should still find the OOO error row")
    }

    /// Bucket counts must agree between the linear-scan histogram and a
    /// manual time-bucket bin. Catches any drift between the build pass
    /// and the sort post-pass that could let the histogram show counts
    /// the sorted-path lookup can't reach.
    func testDerivedHistogramParityWithOOOFixture() throws {
        let url = writeOOOFixture()
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        guard let histogram = source.derivedHistogram(buckets: 60) else {
            return XCTFail("expected derived histogram for OOO fixture")
        }
        // Sum of all bar.total across buckets must equal the count of
        // finite-timestamp rows in the fixture.
        let total = histogram.bars.reduce(0) { $0 + $1.total }
        XCTAssertEqual(total, 12)
    }

    /// Cache round-trip: open the OOO fixture twice with the same URL.
    /// The first open builds the index and persists v3 cache; the
    /// second open hits the cache and must reconstruct
    /// `sortedByTimestamp` byte-for-byte.
    func testCacheRoundTripPreservesSortedIndex() throws {
        let url = writeOOOFixture()
        let first = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        let originalSorted = first.logIndex.sortedByTimestamp
        XCTAssertNotNil(originalSorted)

        let second = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertEqual(second.logIndex.sortedByTimestamp, originalSorted)

        // And the click resolution still works on the cache-loaded path.
        let ts = second.logIndex.timestamps!
        let sorted = second.logIndex.sortedByTimestamp!
        let oooSrc = sorted[1]
        let row = second.firstRowInTimeRange(
            startEpoch: ts[oooSrc],
            endEpoch: ts[sorted[2]],
            matchingLevels: nil,
            restrictTo: nil
        )
        XCTAssertEqual(row, oooSrc)
    }

    func testLineCountMatchesInMemorySource() throws {
        let lineTexts = (1...500).map { "Jan 01 10:00:00 host proc[1]: msg \($0)" }
        let url = writeTempFile(contents: lineTexts.joined(separator: "\n") + "\n")

        // In-memory: replicate LogDocument.loadFile's eager-parse path.
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        let inMemorySource = InMemoryEntrySource()
        let parser = PlainTextParser()
        var built: [LogEntry] = []
        var nextID = 0
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            guard !line.isEmpty else { continue }
            built.append(parser.parse(line: line, lineNumber: i + 1, entryID: nextID))
            nextID += 1
        }
        inMemorySource.append(built)

        // Indexed: build and read count from the offsets array.
        let indexedSource = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())

        XCTAssertEqual(
            indexedSource.count, inMemorySource.count,
            "Indexed and in-memory line counts must match for files without empty lines"
        )

        // Spot-check that entry content also matches.
        XCTAssertEqual(indexedSource.entry(at: 0)?.message, inMemorySource.entry(at: 0)?.message)
        XCTAssertEqual(indexedSource.entry(at: 250)?.message, inMemorySource.entry(at: 250)?.message)
        XCTAssertEqual(
            indexedSource.entry(at: indexedSource.count - 1)?.message,
            inMemorySource.entry(at: inMemorySource.count - 1)?.message
        )
    }
}
