import XCTest
@testable import TraceViewCore

/// Phase 0 smoke tests — minimal coverage to prove the new test target is
/// wired correctly. Exercises the lazy-eligible (line-by-line stateless)
/// parsers and ErrorCodeLookup, which are the primitives Phases 1+ build on.
final class PhaseZeroSmokeTests: XCTestCase {

    // MARK: PlainTextParser

    func testPlainTextParserParsesDatedSyslogLine() {
        let parser = PlainTextParser()
        let line = "2026-03-08 13:46:47 localhost Installer[57]: progress complete"
        let entry = parser.parse(line: line, lineNumber: 1, entryID: 42)

        XCTAssertEqual(entry.id, 42)
        XCTAssertEqual(entry.lineNumber, 1)
        XCTAssertEqual(entry.rawLine, line)
        XCTAssertNotNil(entry.timestamp, "Dated-syslog format should yield a parsed timestamp")
        XCTAssertEqual(entry.component, "Installer")
    }

    // MARK: SCCMLogParser

    func testSCCMLogParserParsesCMTraceLine() {
        let parser = SCCMLogParser()
        let line = #"<![LOG[Successfully connected to management point]LOG]!><time="10:23:01.442+000" date="04-06-2026" component="CcmMessaging" context="" type="1" thread="4128" file="ccmmessaging.cpp">"#
        let entry = parser.parse(line: line, lineNumber: 1, entryID: 99)

        XCTAssertEqual(entry.id, 99)
        XCTAssertEqual(entry.lineNumber, 1)
        XCTAssertEqual(entry.component, "CcmMessaging")
        XCTAssertEqual(entry.threadID, "4128")
        XCTAssertEqual(entry.level, .info, "SCCM type=1 should map to .info")
        XCTAssertEqual(entry.message, "Successfully connected to management point")
        XCTAssertNotNil(entry.timestamp)
    }

    func testSCCMLogParserCanParseReturnsHighConfidence() {
        let parser = SCCMLogParser()
        let samples = [
            #"<![LOG[foo]LOG]!><time="01:23:45.000+000" date="01-01-2026" component="X" context="" type="1" thread="1" file="x.cpp">"#,
            #"<![LOG[bar]LOG]!><time="01:23:46.000+000" date="01-01-2026" component="X" context="" type="2" thread="1" file="x.cpp">"#,
        ]
        XCTAssertGreaterThan(parser.canParse(sampleLines: samples), 0.5)
    }

    // MARK: ErrorCodeLookup

    func testErrorCodeLookupResolvesErrnoEACCES() {
        let results = ErrorCodeLookup.shared.lookup(input: "13")
        let errnoMatch = results.first { $0.domain == .errno }
        XCTAssertNotNil(errnoMatch, "errno 13 should resolve to at least one ErrorCodeInfo in .errno domain")
        XCTAssertEqual(errnoMatch?.symbolicName, "EACCES")
    }
}
