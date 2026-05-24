import XCTest
@testable import TraceViewCore

final class LogIndexTests: XCTestCase {

    // MARK: - Fixtures

    /// Writes `contents` to a unique temp file and returns the URL. The
    /// file is deleted in `tearDown` via `temporaryFiles`.
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
        let url = dir.appendingPathComponent("LogIndexTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    // MARK: - Trailing newline boundary conditions

    func testTwoLinesWithTrailingLF() throws {
        let url = writeTempFile(contents: "abc\ndef\n")
        let idx = try LogIndex.build(fileURL: url)
        XCTAssertEqual(idx.lineCount, 2)
        XCTAssertEqual(idx.line(at: 0), "abc")
        XCTAssertEqual(idx.line(at: 1), "def")
    }

    func testTwoLinesWithoutTrailingLF() throws {
        let url = writeTempFile(contents: "abc\ndef")
        let idx = try LogIndex.build(fileURL: url)
        XCTAssertEqual(idx.lineCount, 2)
        XCTAssertEqual(idx.line(at: 0), "abc")
        XCTAssertEqual(idx.line(at: 1), "def")
    }

    func testEmptyLineInMiddle() throws {
        // Three lines: "abc", "", "def". Indexed mode counts every
        // newline-separated line, including empties.
        let url = writeTempFile(contents: "abc\n\ndef\n")
        let idx = try LogIndex.build(fileURL: url)
        XCTAssertEqual(idx.lineCount, 3)
        XCTAssertEqual(idx.line(at: 0), "abc")
        XCTAssertEqual(idx.line(at: 1), "")
        XCTAssertEqual(idx.line(at: 2), "def")
    }

    func testSingleLineNoTrailingLF() throws {
        let url = writeTempFile(contents: "only line")
        let idx = try LogIndex.build(fileURL: url)
        XCTAssertEqual(idx.lineCount, 1)
        XCTAssertEqual(idx.line(at: 0), "only line")
    }

    func testEmptyFile() throws {
        let url = writeTempFile(contents: "")
        let idx = try LogIndex.build(fileURL: url)
        // One offset at 0 (line 0 starts at byte 0). The line is empty.
        XCTAssertEqual(idx.lineCount, 1)
        XCTAssertEqual(idx.line(at: 0), "")
    }

    // MARK: - Out of bounds

    func testLineAtOutOfBoundsReturnsNil() throws {
        let url = writeTempFile(contents: "a\nb\nc\n")
        let idx = try LogIndex.build(fileURL: url)
        XCTAssertNil(idx.line(at: -1))
        XCTAssertNil(idx.line(at: idx.lineCount))
        XCTAssertNil(idx.line(at: 1_000_000))
    }

    // MARK: - Build telemetry

    func testBuildElapsedReflectsBothPhases() throws {
        let url = writeTempFile(contents: String(repeating: "line\n", count: 1000))
        let idx = try LogIndex.build(fileURL: url)
        XCTAssertGreaterThanOrEqual(idx.indexElapsed, 0)
        XCTAssertGreaterThanOrEqual(idx.warmElapsed, 0)
        XCTAssertEqual(idx.buildElapsed, idx.indexElapsed + idx.warmElapsed, accuracy: 1e-9)
    }

    // MARK: - Larger fixture sanity

    func testLargerFixtureLineCount() throws {
        let count = 10_000
        let lines = (0..<count).map { "log line \($0)" }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")
        let idx = try LogIndex.build(fileURL: url)
        XCTAssertEqual(idx.lineCount, count)
        XCTAssertEqual(idx.line(at: 0), "log line 0")
        XCTAssertEqual(idx.line(at: count - 1), "log line \(count - 1)")
        XCTAssertEqual(idx.line(at: 5000), "log line 5000")
    }
}
