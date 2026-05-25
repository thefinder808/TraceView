import XCTest
@testable import TraceViewCore

final class IndexedEntrySourceTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
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
