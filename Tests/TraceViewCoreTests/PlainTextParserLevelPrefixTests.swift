import XCTest
@testable import TraceViewCore

/// Regression tests for `PlainTextParser.bracketLevelPattern`. A level name
/// only counts as a level when it's a whole word, so ordinary messages that
/// merely start with one ("Information loaded") must stay intact instead of
/// being split into a bogus level and a truncated message.
final class PlainTextParserLevelPrefixTests: XCTestCase {

    private func parse(_ line: String) -> LogEntry {
        PlainTextParser().parse(line: line, lineNumber: 1, entryID: 0)
    }

    // MARK: - Words that merely start with a level name

    func testInformationIsNotAnInfoPrefix() {
        let entry = parse("Information loaded")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "Information loaded")
        XCTAssertNil(entry.component)
    }

    func testErrorsIsNotAnErrorPrefix() {
        let entry = parse("Errors: none")
        XCTAssertEqual(entry.level, .info, "\"Errors\" isn't the keyword \"error\", so no level applies")
        XCTAssertEqual(entry.message, "Errors: none")
        XCTAssertNil(entry.component)
    }

    func testDebuggingIsNotADebugPrefix() {
        let entry = parse("Debugging started")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "Debugging started")
        XCTAssertNil(entry.component)
    }

    func testOtherLongerWordsStayIntact() {
        let lines = [
            "Warnings: 0",
            "Noticed a change",
            "Criticality low",
            "Critters found",
            "Fatalistic outlook",
            "Erratic behavior",
            "[Information] loaded",
            "ERR_CONNECTION_REFUSED while loading",
            "INFO2 next",
        ]
        for line in lines {
            let entry = parse(line)
            XCTAssertEqual(entry.level, .info, "Level for '\(line)'")
            XCTAssertEqual(entry.message, line, "Message for '\(line)'")
            XCTAssertNil(entry.component, "Component for '\(line)'")
        }
    }

    /// With no level prefix the line falls through to `LevelDetector`, so
    /// keywords elsewhere in the message still set the level.
    func testKeywordDetectionStillAppliesToIntactMessages() {
        let entry = parse("Debugging failed")
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.message, "Debugging failed")
    }

    // MARK: - Timestamped lines share the same pattern

    func testLongerWordsStayIntactAfterISOTimestamp() {
        let entry = parse("2026-04-23 14:32:01 Information loaded")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "Information loaded")
        XCTAssertNotNil(entry.timestamp)
    }

    func testLongerWordsStayIntactInBSDSyslogMessage() {
        let entry = parse("Apr 23 14:32:01 host proc[1]: Errors: none")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "Errors: none")
        XCTAssertEqual(entry.component, "proc")
    }

    func testLongerWordsStayIntactInDatedSyslogMessage() {
        let entry = parse("2026-03-08 13:46:47 localhost Installer[57]: Debugging started")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "Debugging started")
        XCTAssertEqual(entry.component, "Installer")
    }

    func testRealLevelStillParsedAfterISOTimestamp() {
        let entry = parse("2026-04-23 14:32:01 ERROR disk full")
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.message, "disk full")
        XCTAssertNotNil(entry.timestamp)
    }

    // MARK: - Real level prefixes keep working

    func testColonTerminatedLevel() {
        let entry = parse("INFO: x")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "x")
        XCTAssertNil(entry.component)
    }

    func testBracketedLevel() {
        let entry = parse("[WARN] x")
        XCTAssertEqual(entry.level, .warning)
        XCTAssertEqual(entry.message, "x")
        XCTAssertNil(entry.component)
    }

    func testSpaceTerminatedLevel() {
        let entry = parse("ERROR x")
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.message, "x")
        XCTAssertNil(entry.component)
    }

    func testLevelWithComponent() {
        let entry = parse("CRITICAL component: x")
        XCTAssertEqual(entry.level, .critical)
        XCTAssertEqual(entry.message, "x")
        XCTAssertEqual(entry.component, "component")
    }

    func testBracketedLevelWithColonAndComponent() {
        let entry = parse("[ERROR]: worker: boom")
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.message, "boom")
        XCTAssertEqual(entry.component, "worker")
    }

    func testLevelAloneOnLine() {
        let entry = parse("ERROR")
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.message, "")
        XCTAssertNil(entry.component)
    }

    func testURLIsNotTreatedAsComponent() {
        let entry = parse("INFO: http://example.com/x")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "http://example.com/x")
        XCTAssertNil(entry.component)
    }

    func testFullLevelVocabularyInAnyCase() {
        let cases: [(line: String, level: LogLevel)] = [
            ("DEBUG x", .debug),
            ("INFO x", .info),
            ("NOTICE x", .notice),
            ("WARN x", .warning),
            ("WARNING x", .warning),
            ("ERR x", .error),
            ("ERROR x", .error),
            ("CRIT x", .critical),
            ("CRITICAL x", .critical),
            ("FATAL x", .critical),
            ("warning: x", .warning),
            ("[Notice] x", .notice),
        ]
        for testCase in cases {
            let entry = parse(testCase.line)
            XCTAssertEqual(entry.level, testCase.level, "Level for '\(testCase.line)'")
            XCTAssertEqual(entry.message, "x", "Message for '\(testCase.line)'")
        }
    }

    // MARK: - Agreement with the byte-level scanner

    /// `FastLevelScanner` already required a word boundary, so these rows
    /// used to get different levels from the index and from the parser.
    func testParserAgreesWithIndexScanner() throws {
        let fixture = """
        Information loaded
        Errors: none
        Debugging started
        [WARN] x
        ERROR x
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainTextParserLevelPrefixTests-\(UUID().uuidString).log")
        try (fixture + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertEqual(idx.lineCount, 5)
        for i in 0..<idx.lineCount {
            let raw = idx.line(at: i) ?? ""
            let scanned = FastLevelScanner.decode(idx.levels[i])
            XCTAssertEqual(scanned, parse(raw).level, "Row \(i) '\(raw)'")
        }
    }
}
