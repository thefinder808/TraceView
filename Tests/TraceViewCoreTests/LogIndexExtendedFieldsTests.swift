import XCTest
@testable import TraceViewCore

/// Tests for Phase 4's extended `LogIndex` fields: `levels: [UInt8]` and
/// `timestamps: [Double]?`. The bar these tests enforce is per-row
/// equivalence with `parser.parse(line:).level` and `.timestamp` for the
/// supported parser kinds (PlainText BSD-syslog + dated-syslog, SCCM).
///
/// Where the byte-level scanners can't faithfully mirror the parser (CSV
/// columns require structural parsing; lines with neither timestamp nor
/// recognized keywords get bucketed as `.info`), the tests document the
/// boundary explicitly so future changes don't drift it unintentionally.
final class LogIndexExtendedFieldsTests: XCTestCase {

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
        let url = dir.appendingPathComponent("LogIndexExtendedFieldsTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    // MARK: - Build wires parserKind through

    func testBuildCapturesParserKind() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: hi\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertEqual(idx.parserKind, .plainText)
    }

    func testCSVParserKindSkipsTimestampArray() throws {
        let url = writeTempFile(contents: "timestamp,level,msg\n2026-04-22 10:30:15,error,boom\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .csv)
        XCTAssertNil(idx.timestamps, "CSV parserKind should skip timestamp capture entirely")
    }

    func testOtherParserKindSkipsTimestampArray() throws {
        let url = writeTempFile(contents: "anything\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .other)
        XCTAssertNil(idx.timestamps)
    }

    func testPlainTextParserKindCapturesTimestamps() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: hi\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertNotNil(idx.timestamps)
    }

    func testSCCMParserKindCapturesTimestamps() throws {
        let line = #"<![LOG[hello]LOG]!><time="10:23:01.442+000" date="04-22-2026" component="C" context="" type="1" thread="42" file="f.cpp">"# + "\n"
        let url = writeTempFile(contents: line)
        let idx = try LogIndex.build(fileURL: url, parserKind: .sccm)
        XCTAssertNotNil(idx.timestamps)
    }

    // MARK: - Levels array matches per-line parser output (PlainText BSD-syslog)

    func testBSDSyslogLevelEquivalence() throws {
        // Mix of `<Level>` annotations, `[LEVEL]:` prefixes, and bare
        // keyword detection — all three code paths inside the byte
        // scanner.
        let fixture = """
        Apr 22 10:30:15 host proc[1]: <Notice> Boot complete
        Apr 22 10:30:16 host proc[1]: <Error> Disk failure
        Apr 22 10:30:17 host proc[2]: an ordinary informational message
        Apr 22 10:30:18 host proc[2]: failed to write block 5
        Apr 22 10:30:19 host proc[2]: WARN: queue depth high
        Apr 22 10:30:20 host proc[3]: debug: cache miss
        Apr 22 10:30:21 host proc[3]: critical failure in module
        """
        let url = writeTempFile(contents: fixture + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        let parser = PlainTextParser()
        XCTAssertEqual(idx.lineCount, 7)
        for i in 0..<idx.lineCount {
            let raw = idx.line(at: i) ?? ""
            let parsed = parser.parse(line: raw, lineNumber: i + 1, entryID: i)
            let scanned = FastLevelScanner.decode(idx.levels[i])
            XCTAssertEqual(scanned, parsed.level,
                           "Row \(i) '\(raw)': scanner returned \(scanned), parser returned \(parsed.level)")
        }
    }

    // MARK: - Timestamps array matches per-line parser output (PlainText)

    func testBSDSyslogTimestampEquivalence() throws {
        // Three rows with different month+day combos. Year-inference must
        // pick the most recent past year (current year, or current-1 if
        // that's >1 day in the future).
        let fixture = """
        Jan 15 03:04:05 host proc[1]: message one
        Jul 04 12:00:00 host proc[1]: message two
        Dec 31 23:59:59 host proc[1]: message three
        """
        let url = writeTempFile(contents: fixture + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        let parser = PlainTextParser()
        guard let timestamps = idx.timestamps else {
            XCTFail("Expected timestamps array for plainText parserKind")
            return
        }
        for i in 0..<idx.lineCount {
            let raw = idx.line(at: i) ?? ""
            let parsed = parser.parse(line: raw, lineNumber: i + 1, entryID: i)
            guard let parsedDate = parsed.timestamp else {
                XCTFail("Parser produced no timestamp for row \(i): '\(raw)'")
                continue
            }
            let scanned = timestamps[i]
            XCTAssertFalse(scanned.isNaN, "Scanner produced NaN for row \(i): '\(raw)'")
            // Tolerance: 1.5s covers any minor calendar / TZ rounding
            // differences between the byte-level scanner and Foundation
            // DateFormatter.
            XCTAssertEqual(scanned, parsedDate.timeIntervalSince1970, accuracy: 1.5,
                           "Row \(i) '\(raw)': scanner \(scanned) vs parser \(parsedDate.timeIntervalSince1970)")
        }
    }

    func testDatedSyslogTimestampEquivalence() throws {
        let fixture = """
        2026-03-08 13:46:47 host proc[1]: dated-syslog one
        2026-03-08 13:46:47.123 host proc[1]: dated-syslog with fractional
        2026-03-08T13:46:47Z host proc[1]: ISO-T with Z
        2026-03-08T13:46:47+02:00 host proc[1]: ISO-T with explicit TZ
        """
        let url = writeTempFile(contents: fixture + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        let parser = PlainTextParser()
        guard let timestamps = idx.timestamps else {
            XCTFail("Expected timestamps array for plainText parserKind")
            return
        }
        for i in 0..<idx.lineCount {
            let raw = idx.line(at: i) ?? ""
            let parsed = parser.parse(line: raw, lineNumber: i + 1, entryID: i)
            guard let parsedDate = parsed.timestamp else {
                XCTFail("Parser produced no timestamp for row \(i): '\(raw)'")
                continue
            }
            let scanned = timestamps[i]
            XCTAssertFalse(scanned.isNaN, "Scanner produced NaN for row \(i): '\(raw)'")
            // Same tolerance as BSD test — covers fractional-second
            // representation differences.
            XCTAssertEqual(scanned, parsedDate.timeIntervalSince1970, accuracy: 0.01,
                           "Row \(i) '\(raw)': scanner \(scanned) vs parser \(parsedDate.timeIntervalSince1970)")
        }
    }

    // MARK: - SCCM equivalence

    func testSCCMLevelAndTimestampEquivalence() throws {
        let fixture = """
        <![LOG[Info message]LOG]!><time="10:23:01.442+000" date="04-22-2026" component="A" context="" type="1" thread="42" file="f.cpp">
        <![LOG[Warning message]LOG]!><time="10:23:02.000+000" date="04-22-2026" component="B" context="" type="2" thread="42" file="f.cpp">
        <![LOG[Error message]LOG]!><time="10:23:03.500+000" date="04-22-2026" component="C" context="" type="3" thread="42" file="f.cpp">
        """
        let url = writeTempFile(contents: fixture + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .sccm)
        let parser = SCCMLogParser()
        guard let timestamps = idx.timestamps else {
            XCTFail("Expected timestamps array for sccm parserKind")
            return
        }
        XCTAssertEqual(idx.lineCount, 3)
        for i in 0..<idx.lineCount {
            let raw = idx.line(at: i) ?? ""
            let parsed = parser.parse(line: raw, lineNumber: i + 1, entryID: i)
            let scannedLevel = FastLevelScanner.decode(idx.levels[i])
            XCTAssertEqual(scannedLevel, parsed.level,
                           "SCCM row \(i) level: scanner \(scannedLevel) vs parser \(parsed.level)")
            guard let parsedDate = parsed.timestamp else {
                XCTFail("Parser produced no timestamp for SCCM row \(i)")
                continue
            }
            XCTAssertEqual(timestamps[i], parsedDate.timeIntervalSince1970, accuracy: 0.01,
                           "SCCM row \(i) timestamp mismatch")
        }
    }

    // MARK: - CSV — levels via keyword scan, timestamps absent

    func testCSVLevelDefaultsAndNoTimestamps() throws {
        let fixture = """
        timestamp,level,message
        2026-04-22 10:30:15,error,something failed
        2026-04-22 10:30:16,info,just FYI
        """
        let url = writeTempFile(contents: fixture + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .csv)
        XCTAssertNil(idx.timestamps)
        XCTAssertEqual(idx.lineCount, 3)
        // Header line — no keywords trigger; defaults to .info.
        XCTAssertEqual(FastLevelScanner.decode(idx.levels[0]), .info)
        // "failed" → .error via keyword scan.
        XCTAssertEqual(FastLevelScanner.decode(idx.levels[1]), .error)
        // "just FYI" → no keyword → .info.
        XCTAssertEqual(FastLevelScanner.decode(idx.levels[2]), .info)
    }

    // MARK: - Boundary conditions

    func testFileEndingWithoutNewlineCapturesFinalRowFields() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: warn me")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertEqual(idx.lineCount, 1)
        XCTAssertEqual(FastLevelScanner.decode(idx.levels[0]), .warning)
        XCTAssertFalse(idx.timestamps?[0].isNaN ?? true)
    }

    func testEmptyLinesGetInfoAndNaN() throws {
        // Empty lines aren't typical syslog content but the index counts
        // them. Levels default to .info, timestamps to .nan.
        let url = writeTempFile(contents: "abc\n\ndef\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertEqual(idx.lineCount, 3)
        XCTAssertEqual(FastLevelScanner.decode(idx.levels[1]), .info)
        XCTAssertTrue(idx.timestamps?[1].isNaN ?? false)
    }

    func testSingleEmptyFileProducesEmptyArrays() throws {
        let url = writeTempFile(contents: "")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertEqual(idx.lineCount, 1)
        XCTAssertEqual(idx.levels.count, 1)
        XCTAssertEqual(idx.timestamps?.count, 1)
        // No content → .info default, .nan timestamp.
        XCTAssertEqual(FastLevelScanner.decode(idx.levels[0]), .info)
        XCTAssertTrue(idx.timestamps?[0].isNaN ?? false)
    }

    // MARK: - Encode / decode round-trip

    func testLevelEncodingRoundTrip() {
        for level in LogLevel.allCases {
            let byte = FastLevelScanner.encode(level)
            let decoded = FastLevelScanner.decode(byte)
            XCTAssertEqual(decoded, level, "Round-trip failed for \(level)")
        }
    }

    // MARK: - 5 GB fixture smoke (opt-in)

    /// Build the index against the 5 GB BSD-syslog fixture and report
    /// timings. Skipped unless `TRACEVIEW_BIG_FIXTURE_SMOKE` is set in
    /// the env, because the fixture isn't a tracked test resource and
    /// the path is developer-machine specific.
    func testBigFixtureBuildSmokeOptIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRACEVIEW_BIG_FIXTURE_SMOKE"] != nil,
            "Set TRACEVIEW_BIG_FIXTURE_SMOKE=1 to run against ~/Downloads/big-logs/big-syslog-5gb.log"
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixture = home.appendingPathComponent("Downloads/big-logs/big-syslog-5gb.log")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "5 GB fixture not present at \(fixture.path)"
        )
        let started = Date()
        let idx = try LogIndex.build(fileURL: fixture, parserKind: .plainText)
        let totalElapsed = Date().timeIntervalSince(started)
        print("[5GB smoke] lineCount=\(idx.lineCount) indexElapsed=\(idx.indexElapsed)s warmElapsed=\(idx.warmElapsed)s total=\(totalElapsed)s timestamps=\(idx.timestamps != nil ? "yes" : "nil") levelsBytes=\(idx.levels.count)")
        // Sanity: a 5 GB BSD-syslog file should have tens of millions
        // of lines and a non-nil timestamps array.
        XCTAssertGreaterThan(idx.lineCount, 1_000_000)
        XCTAssertNotNil(idx.timestamps)
    }
}
