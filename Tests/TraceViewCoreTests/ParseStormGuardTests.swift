import XCTest
import Combine
@testable import TraceViewCore

/// Phase 4 PR4: regression guards for the parse-storm class of bugs.
///
/// Phase 3 + Phase 4 PR2/PR3 fixed three separate parse-storms (go-to-
/// line, inline expansion, histogram click filtered + unfiltered) each
/// caused by a `firstIndex(where:)` / `entries.first { ... }` linear
/// scan over a `FilteredEntries` backed by an `IndexedEntrySource`.
/// Each scan routes every probe through `entry(at:)` →
/// `parser.parse(line:)` → `NSDateFormatter` and parse-storms the main
/// thread on a 36 M-row file (multi-minute hang, OS spills a
/// stackshot).
///
/// This harness wraps a real parser in a counting proxy and asserts
/// that representative UI flows over the indexed source stay within a
/// bounded parse budget. A future PR that re-introduces a linear scan
/// in any of these flows will fail these tests immediately, before the
/// 5 GB user smoke catches it.
final class ParseStormGuardTests: XCTestCase {

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
        let url = dir.appendingPathComponent("ParseStormGuardTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    /// Counting wrapper around `PlainTextParser`. `kind` is forwarded
    /// (`.plainText`) so `LogIndex.build` picks the right byte-level
    /// scanner path. `parseCount` increments on every `parse(...)` call,
    /// which is the only place the harness cares about — that's where
    /// the parse-storm bug class lives.
    private final class CountingParser: LogParser {
        let name = "CountingPlainText"
        let supportedExtensions: Set<String> = []
        let isLineStateless = true
        let kind: ParserKind = .plainText
        private(set) var parseCount = 0
        private let inner = PlainTextParser()
        func canParse(sampleLines: [String]) -> Double { 0.1 }
        func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
            parseCount += 1
            return inner.parse(line: line, lineNumber: lineNumber, entryID: entryID)
        }
    }

    /// Build a 1000-row BSD-syslog fixture. Enough rows that a linear
    /// scan would be visibly slow but cheap enough to run fast in CI.
    private func buildSource() throws -> (source: IndexedEntrySource, parser: CountingParser) {
        var lines: [String] = []
        for i in 0..<1000 {
            let h = String(format: "%02d", (i / 60) % 24)
            let m = String(format: "%02d", (i / 60) % 60)
            let s = String(format: "%02d", i % 60)
            let tag = (i % 3 == 0) ? "<Error>" : (i % 3 == 1 ? "<Warning>" : "<Info>")
            lines.append("Apr 22 \(h):\(m):\(s) host proc[1] \(tag): row \(i)")
        }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")
        let parser = CountingParser()
        let source = try IndexedEntrySource(fileURL: url, parser: parser)
        return (source, parser)
    }

    // MARK: - position(forLineNumber:) / position(forEntryID:)

    func testPositionForLineNumberIdentityDoesNotParse() throws {
        let (source, parser) = try buildSource()
        let fe = FilteredEntries(backing: .identity(source: source))
        let baseline = parser.parseCount

        // Multiple lookups across the file.
        XCTAssertEqual(fe.position(forLineNumber: 1), 0)
        XCTAssertEqual(fe.position(forLineNumber: 500), 499)
        XCTAssertEqual(fe.position(forLineNumber: 1000), 999)

        XCTAssertEqual(parser.parseCount, baseline,
                       "position(forLineNumber:) on .identity must not parse")
    }

    func testPositionForLineNumberIndexedDoesNotParse() throws {
        let (source, parser) = try buildSource()
        let filtered = Array(stride(from: 0, to: 1000, by: 3))  // 334 entries
        let fe = FilteredEntries(backing: .indexed(indices: filtered, source: source))
        let baseline = parser.parseCount

        // Filtered indices are 0, 3, 6, ..., 999 → lineNumbers 1, 4,
        // 7, ..., 1000. The probes below are the present lineNumbers
        // (first, mid, last), the IN-filter case.
        XCTAssertNotNil(fe.position(forLineNumber: 1))
        XCTAssertNotNil(fe.position(forLineNumber: 502))   // source idx 501 = 3*167
        XCTAssertNotNil(fe.position(forLineNumber: 1000))  // source idx 999 = 3*333
        // Out-of-filter probes (the parse-storm bait — bisect must
        // return nil cheaply).
        XCTAssertNil(fe.position(forLineNumber: 2))
        XCTAssertNil(fe.position(forLineNumber: 500))

        XCTAssertEqual(parser.parseCount, baseline,
                       "position(forLineNumber:) on .indexed must bisect, not parse")
    }

    func testPositionForEntryIDIndexedDoesNotParse() throws {
        let (source, parser) = try buildSource()
        let filtered = Array(stride(from: 0, to: 1000, by: 3))
        let fe = FilteredEntries(backing: .indexed(indices: filtered, source: source))
        let baseline = parser.parseCount

        XCTAssertNotNil(fe.position(forEntryID: 0))
        XCTAssertNotNil(fe.position(forEntryID: 300))
        XCTAssertNotNil(fe.position(forEntryID: 999))

        XCTAssertEqual(parser.parseCount, baseline,
                       "position(forEntryID:) on .indexed must bisect, not parse")
    }

    // MARK: - Histogram-click bisect (firstRowInTimeRange)

    func testFirstRowInTimeRangeUnfilteredDoesNotParse() throws {
        let (source, parser) = try buildSource()
        guard let timestamps = source.logIndex.timestamps else {
            XCTFail("Expected timestamps")
            return
        }
        let baseline = parser.parseCount

        let start = timestamps[100]
        let end = timestamps[200]
        _ = source.firstRowInTimeRange(
            startEpoch: start, endEpoch: end, matchingLevels: [.error, .critical]
        )

        XCTAssertEqual(parser.parseCount, baseline,
                       "firstRowInTimeRange must not invoke parser during the search")
    }

    func testFirstRowInTimeRangeFilteredDoesNotParse() throws {
        let (source, parser) = try buildSource()
        guard let timestamps = source.logIndex.timestamps else {
            XCTFail("Expected timestamps")
            return
        }
        let filtered = Array(stride(from: 0, to: 1000, by: 3))
        let baseline = parser.parseCount

        _ = source.firstRowInTimeRange(
            startEpoch: timestamps[100], endEpoch: timestamps[200],
            matchingLevels: nil, restrictTo: filtered
        )

        XCTAssertEqual(parser.parseCount, baseline,
                       "firstRowInTimeRange with restrictTo must bisect, not parse")
    }

    // MARK: - derived stats

    func testDerivedLevelCountsDoesNotParse() throws {
        let (source, parser) = try buildSource()
        let baseline = parser.parseCount
        _ = source.derivedLevelCounts
        XCTAssertEqual(parser.parseCount, baseline,
                       "derivedLevelCounts reads logIndex.levels directly, not via parser")
    }

    func testDerivedHistogramDoesNotParse() throws {
        let (source, parser) = try buildSource()
        let baseline = parser.parseCount
        _ = source.derivedHistogram(buckets: 60)
        XCTAssertEqual(parser.parseCount, baseline,
                       "derivedHistogram reads logIndex.timestamps/levels directly")
    }

    // MARK: - IndexedFilterScanner

    func testFilterScannerLevelOnlyDoesNotParse() throws {
        let (source, parser) = try buildSource()
        let baseline = parser.parseCount

        var filter = LogFilter()
        filter.enabledLevels = [.error]
        _ = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }

        XCTAssertEqual(parser.parseCount, baseline,
                       "Level-only filter scan reads logIndex.levels; no parse needed")
    }

    func testFilterScannerTextLiteralDoesNotParse() throws {
        let (source, parser) = try buildSource()
        let baseline = parser.parseCount

        var filter = LogFilter()
        filter.searchText = "row"  // literal, not regex
        _ = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }

        XCTAssertEqual(parser.parseCount, baseline,
                       "Literal text scan uses memmem / byte fold; no parse needed")
    }

    // MARK: - Bounded parse on subscript

    func testFilteredEntriesSubscriptParsesExactlyOnce() throws {
        let (source, parser) = try buildSource()
        let fe = FilteredEntries(backing: .identity(source: source))
        let baseline = parser.parseCount

        // Single subscript access triggers one entry(at:) → one parse.
        // The LRU caches it, so a repeat access is free.
        _ = fe[500]
        XCTAssertEqual(parser.parseCount, baseline + 1,
                       "First subscript parses once via entry(at:)")
        _ = fe[500]
        XCTAssertEqual(parser.parseCount, baseline + 1,
                       "Second subscript hits the LRU; no additional parse")
    }

    // MARK: - Empty find-mode short-circuit (PR4 regression)

    @MainActor
    func testFindModeWithEmptySearchTextDoesNotPopulateMatches() throws {
        // Phase 4 PR4 short-circuit: applyFilterIndexed in find mode
        // with empty searchText must NOT run the scanner (it would
        // return all 36 M source indices on a 5 GB fixture → 290 MB
        // array allocation and a wasted ~2 s scan).
        let fixture = (0..<100).map {
            "Apr 22 10:30:\(String(format: "%02d", $0 % 60)) host proc[1] <Info>: row \($0)"
        }
        let url = writeTempFile(contents: fixture.joined(separator: "\n") + "\n")

        UserDefaults.standard.set(1, forKey: SettingsManager.indexedModeThresholdKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsManager.indexedModeThresholdKey) }

        let doc = LogDocument(source: .file(url), displayName: url.lastPathComponent)
        let vm = LogDocumentViewModel(document: doc)

        var cancellables = Set<AnyCancellable>()
        let loadExp = expectation(description: "load complete")
        doc.$loadState.sink { state in
            if case .complete = state { loadExp.fulfill() }
        }.store(in: &cancellables)
        vm.load()
        wait(for: [loadExp], timeout: 5)

        // Enter find mode with empty searchText.
        vm.findMode = .find

        // Spin briefly to let the @Published settle through the filter
        // pipeline's 150 ms debounce.
        let spinDeadline = Date().addingTimeInterval(0.5)
        while Date() < spinDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        // matches must be empty AND filteredEntries must be identity
        // (no .indexed backing with 100 indices).
        XCTAssertTrue(vm.matches.isEmpty,
                      "Empty searchText in find mode must produce empty matches")
        if case .identity = vm.filteredEntries.backing {
            // ok
        } else {
            XCTFail("Find-mode with empty searchText should leave .identity backing")
        }
    }
}
