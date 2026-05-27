import XCTest
@testable import TraceViewCore

/// Phase 4.5 PR2: tests for component capture in `LogIndex` and the
/// component-gate path in `IndexedFilterScanner`. The bar these tests
/// enforce is per-row equivalence with `parser.parse(line:).component`
/// for the supported parser kinds, plus correct cache round-trip and
/// filter behavior over a known fixture.
final class LogIndexComponentsTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        // Wipe cache files we may have written.
        for url in temporaryFiles {
            if let cacheURL = LogIndexCache.cacheURL(forSourceURL: url) {
                try? FileManager.default.removeItem(at: cacheURL)
            }
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func writeTempFile(contents: String, suffix: String = "log") -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("LogIndexComponentsTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    // MARK: - Capture equivalence with parser

    func testBSDSyslogComponentEquivalence() throws {
        let fixture = """
        Apr 22 10:30:15 host kernel[0]: <Notice> boot message
        Apr 22 10:30:16 host launchd[1]: starting up
        Apr 22 10:30:17 host kernel: another kernel message
        Apr 22 10:30:18 host worker[1234]: processing job
        """
        let url = writeTempFile(contents: fixture + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        let parser = PlainTextParser()
        guard let componentIndex = idx.componentIndex,
              let uniqueComponents = idx.uniqueComponents else {
            XCTFail("Expected componentIndex + uniqueComponents on PlainText")
            return
        }
        XCTAssertEqual(idx.lineCount, 4)
        for i in 0..<idx.lineCount {
            let raw = idx.line(at: i) ?? ""
            let parsed = parser.parse(line: raw, lineNumber: i + 1, entryID: i)
            let capturedID = componentIndex[i]
            let captured = uniqueComponents[Int(capturedID)]
            XCTAssertEqual(captured, parsed.component ?? "",
                           "Row \(i) '\(raw)': scanner '\(captured)' vs parser '\(parsed.component ?? "nil")'")
        }
    }

    func testSCCMComponentEquivalence() throws {
        let fixture = """
        <![LOG[Info]LOG]!><time="10:00:00.000+000" date="04-22-2026" component="Worker" context="" type="1" thread="1" file="f.cpp">
        <![LOG[Warn]LOG]!><time="10:00:01.000+000" date="04-22-2026" component="Network" context="" type="2" thread="1" file="f.cpp">
        <![LOG[Error]LOG]!><time="10:00:02.000+000" date="04-22-2026" component="Worker" context="" type="3" thread="1" file="f.cpp">
        """
        let url = writeTempFile(contents: fixture + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .sccm)
        let parser = SCCMLogParser()
        guard let componentIndex = idx.componentIndex,
              let uniqueComponents = idx.uniqueComponents else {
            XCTFail("Expected components on SCCM")
            return
        }
        for i in 0..<idx.lineCount {
            let raw = idx.line(at: i) ?? ""
            let parsed = parser.parse(line: raw, lineNumber: i + 1, entryID: i)
            let captured = uniqueComponents[Int(componentIndex[i])]
            XCTAssertEqual(captured, parsed.component ?? "")
        }
        // Worker appears on rows 0 and 2 → both should map to the same
        // unique-table ID (and that ID's string is "Worker").
        XCTAssertEqual(componentIndex[0], componentIndex[2])
        XCTAssertEqual(uniqueComponents[Int(componentIndex[0])], "Worker")
    }

    func testCSVParserKindHasNoComponentArray() throws {
        let fixture = "timestamp,level,msg\n2026-04-22 10:30:15,error,boom\n"
        let url = writeTempFile(contents: fixture)
        let idx = try LogIndex.build(fileURL: url, parserKind: .csv)
        XCTAssertNil(idx.componentIndex)
        XCTAssertNil(idx.uniqueComponents)
    }

    func testUniqueComponentsTableIsDeduped() throws {
        // 200 rows alternating between 2 components → uniqueComponents
        // should have exactly 3 entries: "" (sentinel), "comp_a",
        // "comp_b".
        var lines: [String] = []
        for i in 0..<200 {
            let comp = (i % 2 == 0) ? "comp_a" : "comp_b"
            lines.append("Apr 22 10:30:00 host \(comp): row \(i)")
        }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")
        let idx = try LogIndex.build(fileURL: url, parserKind: .plainText)
        guard let uniqueComponents = idx.uniqueComponents else {
            XCTFail("Expected unique components")
            return
        }
        XCTAssertEqual(uniqueComponents.count, 3)
        XCTAssertEqual(uniqueComponents[0], "", "Index 0 is the no-component sentinel")
        XCTAssertTrue(uniqueComponents.contains("comp_a"))
        XCTAssertTrue(uniqueComponents.contains("comp_b"))
    }

    // MARK: - Filter scanner integration

    func testFilterScannerComponentGate() throws {
        let fixture = """
        Apr 22 10:30:15 host kernel: msg one
        Apr 22 10:30:16 host launchd: msg two
        Apr 22 10:30:17 host kernel: msg three
        Apr 22 10:30:18 host worker: msg four
        Apr 22 10:30:19 host kernel: msg five
        """
        let url = writeTempFile(contents: fixture + "\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())

        var filter = LogFilter()
        filter.component = "kernel"
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // kernel appears on rows 0, 2, 4.
        XCTAssertEqual(result, [0, 2, 4])
    }

    func testFilterScannerComponentNotInTableReturnsEmpty() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host kernel: msg\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())
        var filter = LogFilter()
        filter.component = "nonexistent"
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        XCTAssertEqual(result, [])
    }

    func testFilterScannerCombinedComponentLevelAndText() throws {
        let fixture = """
        Apr 22 10:30:15 host kernel: ordinary message
        Apr 22 10:30:16 host kernel: error in module
        Apr 22 10:30:17 host worker: error in module
        Apr 22 10:30:18 host kernel: another kernel message
        """
        let url = writeTempFile(contents: fixture + "\n")
        let source = try IndexedEntrySource(fileURL: url, parser: PlainTextParser())

        var filter = LogFilter()
        filter.component = "kernel"
        filter.searchText = "error"
        filter.enabledLevels = [.error]
        let result = IndexedFilterScanner.scan(source: source, filter: filter) { _ in }
        // Component kernel + level error + text "error" → only row 1.
        XCTAssertEqual(result, [1])
    }

    // MARK: - Cache round-trip (v2 format)

    func testCacheRoundTripsComponents() throws {
        let fixture = """
        Apr 22 10:30:15 host kernel: msg
        Apr 22 10:30:16 host launchd: msg
        Apr 22 10:30:17 host kernel: msg
        """
        let url = writeTempFile(contents: fixture + "\n")
        let built = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertTrue(LogIndexCache.write(
            sourceURL: url,
            offsets: built.offsets,
            levels: built.levels,
            timestamps: built.timestamps,
            componentIndex: built.componentIndex,
            uniqueComponents: built.uniqueComponents,
            sortedByTimestamp: built.sortedByTimestamp,
            parserKind: .plainText
        ))
        guard let loaded = LogIndexCache.tryLoad(forSourceURL: url, parserKind: .plainText) else {
            XCTFail("Cache hit expected")
            return
        }
        XCTAssertEqual(loaded.componentIndex, built.componentIndex)
        XCTAssertEqual(loaded.uniqueComponents, built.uniqueComponents)
    }
}
