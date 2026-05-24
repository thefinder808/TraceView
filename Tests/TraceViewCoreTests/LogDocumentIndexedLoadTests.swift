import XCTest
import Combine
@testable import TraceViewCore

final class LogDocumentIndexedLoadTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryFiles: [URL] = []
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        // Make sure no prior test left the flag on.
        UserDefaults.standard.removeObject(forKey: SettingsManager.forceIndexedModeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsManager.forceIndexedModeKey)
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        cancellables.removeAll()
        super.tearDown()
    }

    private func writeTempFile(contents: String, suffix: String = "log") -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("LogDocumentIndexedLoadTests-\(UUID().uuidString).\(suffix)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return url
    }

    /// Drive a LogDocument through `load()` and wait for it to reach
    /// `.complete`. Returns the resolved document for assertions.
    private func loadAndWait(url: URL, timeout: TimeInterval = 5.0) -> LogDocument {
        let doc = LogDocument(
            source: .file(url),
            displayName: url.lastPathComponent
        )
        let exp = expectation(description: "load complete: \(url.lastPathComponent)")
        doc.$loadState
            .sink { state in
                if case .complete = state { exp.fulfill() }
            }
            .store(in: &cancellables)
        doc.load()
        wait(for: [exp], timeout: timeout)
        return doc
    }

    // MARK: - Flag drives source selection

    func testForceFlagSelectsIndexedSourceForEligibleParser() throws {
        // PlainText / BSD syslog — isLineStateless == true.
        let lines = (0..<200).map { "Jan 01 10:00:00 host proc[1]: msg \($0)" }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")

        UserDefaults.standard.set(true, forKey: SettingsManager.forceIndexedModeKey)
        let doc = loadAndWait(url: url)

        XCTAssertTrue(
            doc.entrySource is IndexedEntrySource,
            "Expected IndexedEntrySource with flag set + line-stateless parser"
        )
        XCTAssertEqual(doc.entrySource.count, 200)
        XCTAssertFalse(doc.entrySource.supportsDerivedStats)
    }

    func testFlagOffUsesInMemoryEvenForEligibleParser() throws {
        let lines = (0..<200).map { "Jan 01 10:00:00 host proc[1]: msg \($0)" }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")

        // Flag not set → eager path.
        let doc = loadAndWait(url: url)

        XCTAssertTrue(
            doc.entrySource is InMemoryEntrySource,
            "Expected InMemoryEntrySource when flag is off"
        )
        XCTAssertTrue(doc.entrySource.supportsDerivedStats)
    }

    func testForceFlagFallsBackForIneligibleParser() throws {
        // NDJSON — JSONLogParser detects this with ~0.85 confidence, and
        // JSONLogParser's isLineStateless is the default false, so the
        // indexed-mode check at the top of loadFile should bail and fall
        // through to the eager path.
        let lines = (0..<50).map { i -> String in
            "{\"timestamp\":\"2026-01-01T00:00:\(String(format: "%02d", i % 60))Z\",\"level\":\"info\",\"message\":\"json msg \(i)\"}"
        }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n", suffix: "jsonl")

        UserDefaults.standard.set(true, forKey: SettingsManager.forceIndexedModeKey)
        let doc = loadAndWait(url: url)

        XCTAssertTrue(
            doc.entrySource is InMemoryEntrySource,
            "Expected fallback to InMemoryEntrySource for non-line-stateless parser"
        )
        XCTAssertTrue(doc.entrySource.supportsDerivedStats)
    }

    // MARK: - Indexed-mode side effects

    func testIndexedDocumentDoesNotComputeHistogramOrLevelCounts() throws {
        let lines = (0..<200).map { "Jan 01 10:00:00 host proc[1]: msg \($0)" }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")

        UserDefaults.standard.set(true, forKey: SettingsManager.forceIndexedModeKey)
        let doc = loadAndWait(url: url)

        XCTAssertNil(doc.histogram, "Indexed-mode load must not compute a histogram")
        XCTAssertTrue(doc.levelCounts.isEmpty, "Indexed-mode load must leave levelCounts empty")
        XCTAssertEqual(doc.lineCount, 200)
    }
}
