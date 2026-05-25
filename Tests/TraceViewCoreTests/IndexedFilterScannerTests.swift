import XCTest
import Combine
@testable import TraceViewCore

/// Phase 4 PR3: tests for `IndexedFilterScanner.scan(...)`. The scanner
/// reads `logIndex.levels` (cached byte array) for the level gate and
/// walks line bytes via a case-fold byte loop for the literal text
/// gate. Tests cover the four filter combinations (none / level only /
/// text only / both) plus the case-sensitive vs insensitive switch and
/// the boundary cases that broke equivalence with in-memory in early
/// drafts.
final class IndexedFilterScannerTests: XCTestCase {

    private var temporaryFiles: [URL] = []
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        cancellables.removeAll()
        super.tearDown()
    }

    private func writeTempFile(contents: String, suffix: String = "log") -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("IndexedFilterScannerTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    private func buildSource(contents: String) throws -> IndexedEntrySource {
        let url = writeTempFile(contents: contents)
        return try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
    }

    /// Fixture used across multiple tests. 5 rows, 1 of each level
    /// (info / warning / error / critical / debug — though the byte
    /// scanner doesn't emit .critical, so .error stands in for the
    /// `<Critical>` case). Predictable for index assertions.
    private func smallMixedFixture() -> String {
        return """
        Apr 22 10:30:15 host proc[1] <Info>: routine status
        Apr 22 10:30:16 host proc[1] <Warning>: queue depth high
        Apr 22 10:30:17 host proc[1] <Error>: disk failure
        Apr 22 10:30:18 host proc[1] <Info>: cached result
        Apr 22 10:30:19 host proc[1] <Debug>: cache miss

        """  // trailing newline keeps lineCount == 5
    }

    // MARK: - Empty filter

    func testEmptyFilterReturnsAllRows() throws {
        let source = try buildSource(contents: smallMixedFixture())
        let filter = LogFilter()  // default: all levels, no text
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        XCTAssertEqual(result, [0, 1, 2, 3, 4])
    }

    // MARK: - Level filter only

    func testLevelFilterErrorOnly() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.enabledLevels = [.error]
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        XCTAssertEqual(result, [2])
    }

    func testLevelFilterErrorPlusWarning() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.enabledLevels = [.error, .warning]
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        XCTAssertEqual(result, [1, 2])
    }

    func testMinimumLevelDropsBelow() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.minimumLevel = .warning
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // Only warning + error rows pass.
        XCTAssertEqual(result, [1, 2])
    }

    // MARK: - Text filter only (case-insensitive default)

    func testTextFilterLiteralCaseInsensitive() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.searchText = "FAILURE"  // uppercase needle, lowercase haystack
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        XCTAssertEqual(result, [2])
    }

    func testTextFilterLiteralCaseSensitive() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.searchText = "FAILURE"
        filter.caseSensitive = true
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // Case-sensitive: "FAILURE" is uppercase, message text is
        // "failure" lowercase → no match.
        XCTAssertEqual(result, [])
    }

    func testTextFilterNotFoundReturnsEmpty() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.searchText = "xyzzy"
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        XCTAssertEqual(result, [])
    }

    // MARK: - Combined level + text

    func testLevelAndTextFilter() throws {
        // Two rows match "status" (rows 0 and 3, both .info). Plus a
        // .warning row that says "status" too.
        let fixture = """
        Apr 22 10:30:15 host proc[1] <Info>: routine status
        Apr 22 10:30:16 host proc[1] <Warning>: warn status check
        Apr 22 10:30:17 host proc[1] <Error>: disk failure
        Apr 22 10:30:18 host proc[1] <Info>: another status

        """
        let source = try buildSource(contents: fixture)
        var filter = LogFilter()
        filter.enabledLevels = [.info]
        filter.searchText = "status"
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // Only .info rows that also contain "status" → rows 0 and 3.
        XCTAssertEqual(result, [0, 3])
    }

    // MARK: - Regex

    func testRegexFilterMatchesPattern() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.searchText = "(?i)(disk|cache)"
        filter.isRegex = true
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // "disk failure" (row 2), "cached result" (row 3 has "cached"),
        // "cache miss" (row 4 has "cache"). Note row 3's "cached" also
        // matches "cache" as a substring.
        XCTAssertEqual(result, [2, 3, 4])
    }

    func testInvalidRegexMatchesNothing() throws {
        let source = try buildSource(contents: smallMixedFixture())
        var filter = LogFilter()
        filter.searchText = "(unclosed"  // bad regex
        filter.isRegex = true
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // Mirrors in-memory matchesSearchText: regex compile failure →
        // no match.
        XCTAssertEqual(result, [])
    }

    // MARK: - Progress

    func testProgressCallbackFires() throws {
        // Build a fixture big enough that the 1% progressStep fires
        // multiple times.
        var lines: [String] = []
        for i in 0..<1000 {
            lines.append("Apr 22 10:30:00 host proc[1] <Info>: row \(i)")
        }
        let source = try buildSource(contents: lines.joined(separator: "\n") + "\n")
        var progressTicks: [Double] = []
        let filter = LogFilter()
        _ = IndexedFilterScanner.scan(source: source, filter: filter) { p in
            progressTicks.append(p)
        }
        XCTAssertFalse(progressTicks.isEmpty)
        // Strictly monotonic and bounded [0, 1).
        for (a, b) in zip(progressTicks, progressTicks.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b)
        }
        for p in progressTicks {
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThan(p, 1.0)
        }
    }

    // MARK: - Boundary

    func testEmptyFileReturnsEmpty() throws {
        let source = try buildSource(contents: "")
        let filter = LogFilter()
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // Empty file produces lineCount == 1 (the single empty line) —
        // matches the in-memory behavior at the LogIndex level.
        XCTAssertEqual(result, [0])
    }

    // MARK: - End-to-end via LogDocumentViewModel

    @MainActor
    func testViewModelAppliesIndexedFilter() throws {
        // End-to-end smoke: load a small fixture via LogDocument with
        // the indexed flag set, mutate the view-model's filter, await
        // the filteredEntries publication, assert the backing is the
        // expected .indexed shape with the right indices.
        let fixture = """
        Apr 22 10:30:15 host proc[1] <Info>: row zero
        Apr 22 10:30:16 host proc[1] <Error>: row one (target)
        Apr 22 10:30:17 host proc[1] <Info>: row two
        Apr 22 10:30:18 host proc[1] <Error>: row three (also target)
        Apr 22 10:30:19 host proc[1] <Info>: row four

        """
        let url = writeTempFile(contents: fixture)

        UserDefaults.standard.set(true, forKey: SettingsManager.forceIndexedModeKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsManager.forceIndexedModeKey) }

        let doc = LogDocument(source: .file(url), displayName: url.lastPathComponent)
        let vm = LogDocumentViewModel(document: doc)

        let loadExp = expectation(description: "load complete")
        doc.$loadState
            .sink { state in
                if case .complete = state { loadExp.fulfill() }
            }
            .store(in: &cancellables)
        vm.load()
        wait(for: [loadExp], timeout: 5)

        XCTAssertTrue(doc.entrySource is IndexedEntrySource, "Sanity check: source is indexed")

        // Apply an error-only filter and wait for the scan to land.
        let filterExp = expectation(description: "filtered entries reflect error-only filter")
        vm.$filteredEntries
            .sink { entries in
                if case .indexed(let indices, _) = entries.backing, indices.count == 2 {
                    filterExp.fulfill()
                }
            }
            .store(in: &cancellables)
        vm.filter.enabledLevels = [.error]
        wait(for: [filterExp], timeout: 3)

        // Lines [2, 4] are the .error rows (lineNumber == position + 1
        // by IndexedEntrySource invariant). The scan returns source
        // indices 1 and 3 → lineNumbers 2 and 4.
        let lineNumbers = (0..<vm.filteredEntries.count).map { vm.filteredEntries[$0].lineNumber }
        XCTAssertEqual(lineNumbers, [2, 4], "Filter should land on the two .error rows")
    }

    func testTextFilterOnEmptyLines() throws {
        // Three lines: "abc", "", "def" + a text filter for "abc"
        // → only the first row matches; the empty line is skipped by
        // the lineEnd <= lineStart guard.
        let source = try buildSource(contents: "abc\n\ndef\n")
        var filter = LogFilter()
        filter.searchText = "abc"
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        XCTAssertEqual(result, [0])
    }
}
