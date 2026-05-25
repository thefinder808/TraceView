import XCTest
import Combine
@testable import TraceViewCore

final class LogDocumentIndexedLoadTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryFiles: [URL] = []
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        // Explicit reset — XCTest's UserDefaults sometimes leaks values
        // across test methods in ways removeObject doesn't clear.
        UserDefaults.standard.set(0, forKey: SettingsManager.indexedModeThresholdKey)
        UserDefaults.standard.set(false, forKey: SettingsManager.disableIndexedModeKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(0, forKey: SettingsManager.indexedModeThresholdKey)
        UserDefaults.standard.set(false, forKey: SettingsManager.disableIndexedModeKey)
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

        UserDefaults.standard.set(1, forKey: SettingsManager.indexedModeThresholdKey)
        let doc = loadAndWait(url: url)

        XCTAssertTrue(
            doc.entrySource is IndexedEntrySource,
            "Expected IndexedEntrySource with flag set + line-stateless parser"
        )
        XCTAssertEqual(doc.entrySource.count, 200)
        // Phase 4 PR3: indexed PlainText supports all three derived
        // capabilities (levelCounts, histogram, filter).
        XCTAssertTrue(doc.entrySource.supportsLevelCounts)
        XCTAssertTrue(doc.entrySource.supportsHistogram)
        XCTAssertTrue(doc.entrySource.supportsFilter)
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
        XCTAssertTrue(doc.entrySource.supportsLevelCounts)
        XCTAssertTrue(doc.entrySource.supportsHistogram)
        XCTAssertTrue(doc.entrySource.supportsFilter)
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

        UserDefaults.standard.set(1, forKey: SettingsManager.indexedModeThresholdKey)
        let doc = loadAndWait(url: url)

        XCTAssertTrue(
            doc.entrySource is InMemoryEntrySource,
            "Expected fallback to InMemoryEntrySource for non-line-stateless parser"
        )
        XCTAssertTrue(doc.entrySource.supportsLevelCounts)
        XCTAssertTrue(doc.entrySource.supportsHistogram)
        XCTAssertTrue(doc.entrySource.supportsFilter)
    }

    // MARK: - Phase 5 auto-dispatch

    func testSmallFileUsesEagerByDefault() throws {
        // Phase 5: no override, small fixture → eager. The default
        // 100 MB threshold rules out indexed mode for any test
        // fixture we can reasonably generate inline.
        let lines = (0..<200).map { "Jan 01 10:00:00 host proc[1]: msg \($0)" }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")

        let doc = loadAndWait(url: url)

        XCTAssertTrue(
            doc.entrySource is InMemoryEntrySource,
            "Small fixture should use eager loader by default"
        )
    }

    func testDisableOverrideForcesEagerEvenWithThresholdOverride() throws {
        // disable=true wins over threshold override. Verifies the
        // emergency opt-out works.
        let lines = (0..<200).map { "Jan 01 10:00:00 host proc[1]: msg \($0)" }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")

        UserDefaults.standard.set(1, forKey: SettingsManager.indexedModeThresholdKey)
        UserDefaults.standard.set(true, forKey: SettingsManager.disableIndexedModeKey)
        let doc = loadAndWait(url: url)

        XCTAssertTrue(
            doc.entrySource is InMemoryEntrySource,
            "disable flag should win over threshold override"
        )
    }

    func testDefaultThresholdIs100MB() {
        // Lock the default in a test so an accidental constant flip
        // doesn't ship without a visible test failure.
        XCTAssertEqual(
            SettingsManager.indexedModeDefaultThresholdBytes,
            100 * 1024 * 1024,
            "Phase 5 default threshold should be 100 MB"
        )
    }

    // MARK: - Indexed-mode side effects

    func testIndexedDocumentPopulatesLevelCountsAndHistogram() throws {
        // Phase 4 PR2 replaces the Phase 3 "no histogram or counts in
        // indexed mode" semantics — the source now exposes
        // `derivedLevelCounts` (always) and `derivedHistogram(buckets:)`
        // (when timestamps captured). LogDocument copies the counts and
        // kicks an immediate histogram compute as part of
        // `loadFileIndexed`. 200 BSD-syslog rows is enough to clear the
        // 10-timestamp threshold inside `derivedHistogram`.
        let lines = (0..<200).map { "Jan 01 10:00:0\($0 % 10) host proc[1]: msg \($0)" }
        let url = writeTempFile(contents: lines.joined(separator: "\n") + "\n")

        UserDefaults.standard.set(1, forKey: SettingsManager.indexedModeThresholdKey)
        let doc = loadAndWait(url: url)

        XCTAssertEqual(doc.lineCount, 200)
        XCTAssertFalse(doc.levelCounts.isEmpty, "Phase 4: indexed mode populates levelCounts")
        let totalCounted = doc.levelCounts.values.reduce(0, +)
        XCTAssertEqual(totalCounted, 200, "Every row contributes a level")

        // Histogram is computed off-main; spin briefly until it lands or
        // give up after a short timeout. The compute path is fast
        // (single-pass over 200 doubles).
        let deadline = Date().addingTimeInterval(2)
        while doc.histogram == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(doc.histogram, "Phase 4: indexed mode populates the histogram")
    }
}
