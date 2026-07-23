import XCTest
@testable import TraceViewCore

/// Covers the CSV rendering used by "Export Filtered Log… → CSV". The
/// export already scopes to the pane's `filteredEntries` (the rows visible
/// under the active filter), so these tests focus on the output format —
/// specifically that every free-text field is escaped so a comma, quote,
/// or newline in a component or message can't corrupt the row structure.
final class ExportServiceCSVTests: XCTestCase {

    private func entry(
        line: Int,
        level: LogLevel = .info,
        message: String,
        component: String? = nil,
        timestamp: Date? = nil
    ) -> LogEntry {
        LogEntry(
            id: line - 1,
            lineNumber: line,
            timestamp: timestamp,
            level: level,
            message: message,
            component: component,
            threadID: nil,
            source: nil,
            rawLine: message
        )
    }

    // MARK: - Header + basic shape

    func testHeaderRowIsFirstLine() {
        let csv = ExportService.exportCSV(entries: [entry(line: 1, message: "hello")])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Line,Timestamp,Level,Component,Message")
    }

    func testBasicRowColumns() {
        let csv = ExportService.exportCSV(entries: [
            entry(line: 7, level: .error, message: "boom", component: "kernel")
        ])
        let lines = csv.components(separatedBy: "\n")
        // Line and level are bare; timestamp/component/message are quoted.
        XCTAssertEqual(lines[1], #"7,"",ERR,"kernel","boom""#)
    }

    // MARK: - Escaping (the fixed defect)

    /// A component containing a double quote must have that quote doubled.
    /// The previous implementation interpolated the component raw inside
    /// quotes (`"foo"bar"`), which a spec-compliant reader splits into two
    /// columns. Regression guard for that bug.
    func testComponentWithQuoteIsEscaped() {
        let csv = ExportService.exportCSV(entries: [
            entry(line: 1, message: "m", component: #"foo"bar"#)
        ])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], #"1,"",INFO,"foo""bar","m""#)
    }

    func testMessageWithQuoteIsEscaped() {
        let csv = ExportService.exportCSV(entries: [
            entry(line: 1, message: #"said "hi""#)
        ])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], #"1,"",INFO,"","said ""hi""""#)
    }

    /// A comma inside a quoted field stays a single field — it must not
    /// introduce a new column.
    func testCommaInMessageStaysOneField() {
        let csv = ExportService.exportCSV(entries: [
            entry(line: 1, message: "a, b, c", component: "x,y")
        ])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], #"1,"",INFO,"x,y","a, b, c""#)
    }

    /// An embedded newline lives inside the quoted message field, so the
    /// logical row spans two physical lines but the field structure holds.
    func testNewlineInMessageIsContainedInQuotedField() {
        let csv = ExportService.exportCSV(entries: [
            entry(line: 1, message: "first\nsecond")
        ])
        // Header + the two physical lines of the single logical row.
        let physicalLines = csv.components(separatedBy: "\n")
        XCTAssertEqual(physicalLines.count, 3)
        XCTAssertEqual(physicalLines[1], #"1,"",INFO,"","first"#)
        XCTAssertEqual(physicalLines[2], #"second""#)
    }

    // MARK: - Optional fields

    func testNilComponentBecomesEmptyQuotedField() {
        let csv = ExportService.exportCSV(entries: [
            entry(line: 1, message: "m", component: nil)
        ])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], #"1,"",INFO,"","m""#)
    }

    // MARK: - Scope: only the entries passed are exported

    /// The service exports exactly the collection it is handed — the call
    /// site passes `viewModel.filteredEntries`, so filtering-out happens
    /// upstream and every entry given here appears once, in order.
    func testExportsExactlyTheGivenEntriesInOrder() {
        let csv = ExportService.exportCSV(entries: [
            entry(line: 10, message: "one"),
            entry(line: 20, message: "two"),
        ])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3) // header + 2 rows
        XCTAssertTrue(lines[1].hasPrefix("10,"))
        XCTAssertTrue(lines[2].hasPrefix("20,"))
    }

    // MARK: - csvField unit

    func testCsvFieldQuotesAndDoublesEmbeddedQuotes() {
        XCTAssertEqual(ExportService.csvField(""), #""""#)
        XCTAssertEqual(ExportService.csvField("plain"), #""plain""#)
        XCTAssertEqual(ExportService.csvField(#"a"b"#), #""a""b""#)
    }
}
