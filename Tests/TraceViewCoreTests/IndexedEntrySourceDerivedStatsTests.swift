import XCTest
@testable import TraceViewCore

/// Phase 4 PR2: tests for `IndexedEntrySource.derivedLevelCounts` and
/// `derivedHistogram(buckets:)`. The source produces both directly from
/// `logIndex.levels` / `logIndex.timestamps` — no parser invocation, no
/// entries iteration. These tests prove the shape matches what the
/// in-memory pipeline produces from `LogDocument.computeHistogram` so
/// the indexed `SeveritySummaryBar` and `HistogramView` can consume them
/// transparently.
final class IndexedEntrySourceDerivedStatsTests: XCTestCase {

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
        let url = dir.appendingPathComponent("IndexedEntrySourceDerivedStatsTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    // MARK: - derivedLevelCounts

    func testDerivedLevelCountsAcrossSeverities() throws {
        // Build a fixture whose BSD-syslog lines explicitly land in
        // different LogLevel buckets via the `<Level>` annotation and
        // explicit keywords. The exact byte-scan-vs-parser equivalence
        // is covered in LogIndexExtendedFieldsTests; here we only care
        // that the per-level totals match what FastLevelScanner produced
        // for each row.
        let fixture = """
        Apr 22 10:30:15 host proc[1] <Error>: disk failure
        Apr 22 10:30:16 host proc[1] <Error>: bad sector
        Apr 22 10:30:17 host proc[1] <Warning>: queue depth high
        Apr 22 10:30:18 host proc[1] <Info>: routine status
        Apr 22 10:30:19 host proc[1] <Info>: another status
        Apr 22 10:30:20 host proc[1] <Info>: third status
        Apr 22 10:30:21 host proc[1] <Debug>: cache miss
        """
        let url = writeTempFile(contents: fixture + "\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        let counts = source.derivedLevelCounts
        XCTAssertEqual(counts[.error], 2)
        XCTAssertEqual(counts[.warning], 1)
        XCTAssertEqual(counts[.info], 3)
        XCTAssertEqual(counts[.debug], 1)
        let total = counts.values.reduce(0, +)
        XCTAssertEqual(total, 7)
    }

    func testDerivedLevelCountsMemoizationStability() throws {
        // Multiple reads must return identical counts. The lazy var
        // caches after the first call; a second call must not recompute.
        let fixture = (0..<50).map { "Apr 22 10:30:15 host proc[1] <Error>: row \($0)" }
        let url = writeTempFile(contents: fixture.joined(separator: "\n") + "\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        let first = source.derivedLevelCounts
        let second = source.derivedLevelCounts
        XCTAssertEqual(first, second)
        XCTAssertEqual(first[.error], 50)
    }

    // MARK: - derivedHistogram

    func testDerivedHistogramProducesBuckets() throws {
        // 100 rows spanning 100 distinct seconds. With 10 buckets each
        // bucket should hold 10 rows. Verifies basic bucketing math.
        var lines: [String] = []
        for i in 0..<100 {
            let s = String(format: "%02d", i % 60)
            let m = String(format: "%02d", (i / 60) % 60)
            lines.append("Apr 22 10:\(m):\(s) host proc[1] <Info>: row \(i)")
        }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        guard let histo = source.derivedHistogram(buckets: 10) else {
            XCTFail("Expected histogram for 100-row PlainText fixture")
            return
        }
        XCTAssertEqual(histo.bars.count, 10)
        let total = histo.bars.reduce(0) { $0 + $1.total }
        XCTAssertEqual(total, 100, "Every row should land in a bucket")
        XCTAssertEqual(histo.shadows.count, 0, "Indexed mode doesn't track spike peaks")
        XCTAssertGreaterThan(histo.maxTotal, 0)
    }

    func testDerivedHistogramReturnsNilWhenNoTimestampsCaptured() throws {
        // CSV parserKind skips timestamp capture entirely. Even though
        // the underlying lines have parseable dates, the source's
        // `derivedHistogram` returns nil because `logIndex.timestamps`
        // is nil.
        let fixture = "timestamp,level,msg\n2026-04-22 10:30:15,error,boom\n"
        let url = writeTempFile(contents: fixture, suffix: "csv")
        let source = try IndexedEntrySource(fileURL: url, parser: CSVLogParser())
        XCTAssertNil(source.derivedHistogram(buckets: 30))
    }

    func testDerivedHistogramReturnsNilForFewerThanTenTimestamps() throws {
        // Below the 10-row threshold. Matches the in-memory
        // `LogDocument.computeHistogram` guard.
        let fixture = (0..<5).map { "Apr 22 10:30:1\($0) host proc[1] <Info>: row \($0)" }
        let url = writeTempFile(contents: fixture.joined(separator: "\n") + "\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        XCTAssertNil(source.derivedHistogram(buckets: 10))
    }

    func testDerivedHistogramHandlesMixedSeverities() throws {
        // Mixed severities should distribute across err/warn/info
        // accumulators. Critical maps to err alongside .error (matches
        // the in-memory `LogDocument.computeHistogram` switch).
        var lines: [String] = []
        for i in 0..<30 {
            let tag = i < 10 ? "<Error>" : (i < 20 ? "<Warning>" : "<Info>")
            let s = String(format: "%02d", i % 60)
            lines.append("Apr 22 10:30:\(s) host proc[1] \(tag): row \(i)")
        }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        guard let histo = source.derivedHistogram(buckets: 30) else {
            XCTFail("Expected histogram")
            return
        }
        let totalErr = histo.bars.reduce(0) { $0 + $1.err }
        let totalWarn = histo.bars.reduce(0) { $0 + $1.warn }
        let totalInfo = histo.bars.reduce(0) { $0 + $1.info }
        XCTAssertEqual(totalErr, 10)
        XCTAssertEqual(totalWarn, 10)
        XCTAssertEqual(totalInfo, 10)
    }
}
