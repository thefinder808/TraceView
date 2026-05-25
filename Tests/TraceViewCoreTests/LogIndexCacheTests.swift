import XCTest
@testable import TraceViewCore

/// Phase 4.5 PR1: tests for `LogIndexCache` and the `buildOrLoad` cache
/// path. Covers round-trip persistence (build → write → load returns
/// equivalent arrays), invalidation when the source file's mtime / size
/// changes, rejection of corrupted or mismatched cache files, and the
/// end-to-end `LogIndex.buildOrLoad` flow.
///
/// Important: tests must isolate their cache files from each other and
/// from any developer-machine cache state. Each test uses a unique
/// source-file path (UUID), and we delete the corresponding cache file
/// in tearDown.
final class LogIndexCacheTests: XCTestCase {

    private var temporaryFiles: [URL] = []
    private var temporaryCacheFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        for url in temporaryCacheFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        temporaryCacheFiles.removeAll()
        super.tearDown()
    }

    private func writeTempFile(contents: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("LogIndexCacheTests-\(UUID().uuidString).log")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        // Cache file path for cleanup.
        if let cacheURL = LogIndexCache.cacheURL(forSourceURL: url) {
            temporaryCacheFiles.append(cacheURL)
        }
        return url
    }

    // MARK: - Round-trip

    func testRoundTripWriteThenLoad() throws {
        // Build an index from a small PlainText fixture, write it,
        // load it back, assert the arrays match.
        let fixture = (0..<20).map {
            "Apr 22 10:30:0\($0 % 10) host proc[1] <Info>: row \($0)"
        }
        let url = writeTempFile(contents: fixture.joined(separator: "\n") + "\n")
        let built = try LogIndex.build(fileURL: url, parserKind: .plainText)

        XCTAssertTrue(LogIndexCache.write(
            sourceURL: url,
            offsets: built.offsets,
            levels: built.levels,
            timestamps: built.timestamps,
            componentIndex: built.componentIndex,
            uniqueComponents: built.uniqueComponents,
            parserKind: .plainText
        ))

        guard let loaded = LogIndexCache.tryLoad(forSourceURL: url, parserKind: .plainText) else {
            XCTFail("Expected cache hit after write")
            return
        }
        XCTAssertEqual(loaded.offsets, built.offsets)
        XCTAssertEqual(loaded.levels, built.levels)
        XCTAssertNotNil(loaded.timestamps)
        XCTAssertEqual(loaded.timestamps?.count, built.timestamps?.count)
        XCTAssertEqual(loaded.parserKind, .plainText)
    }

    func testRoundTripCSVHasNoTimestampsArray() throws {
        // CSV parserKind skips timestamp capture → the cache should
        // round-trip with timestamps == nil.
        let fixture = "timestamp,level,msg\n2026-04-22 10:30:15,error,boom\n"
        let url = writeTempFile(contents: fixture)
        let built = try LogIndex.build(fileURL: url, parserKind: .csv)
        XCTAssertNil(built.timestamps)

        XCTAssertTrue(LogIndexCache.write(
            sourceURL: url, offsets: built.offsets, levels: built.levels,
            timestamps: built.timestamps, componentIndex: built.componentIndex, uniqueComponents: built.uniqueComponents, parserKind: .csv
        ))
        guard let loaded = LogIndexCache.tryLoad(forSourceURL: url, parserKind: .csv) else {
            XCTFail("Expected cache hit for CSV")
            return
        }
        XCTAssertNil(loaded.timestamps)
        XCTAssertEqual(loaded.parserKind, .csv)
    }

    // MARK: - Invalidation

    func testMtimeChangeInvalidatesCache() throws {
        let fixture = "Apr 22 10:30:15 host proc[1]: row\n"
        let url = writeTempFile(contents: fixture)
        let built = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertTrue(LogIndexCache.write(
            sourceURL: url, offsets: built.offsets, levels: built.levels,
            timestamps: built.timestamps, componentIndex: built.componentIndex, uniqueComponents: built.uniqueComponents, parserKind: .plainText
        ))

        // Sleep briefly + touch the file so its mtime advances past
        // the cache's snapshot.
        Thread.sleep(forTimeInterval: 0.05)
        try fixture.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(
            LogIndexCache.tryLoad(forSourceURL: url, parserKind: .plainText),
            "Touching the source file should invalidate the cache"
        )
    }

    func testSizeChangeInvalidatesCache() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: original\n")
        let built = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertTrue(LogIndexCache.write(
            sourceURL: url, offsets: built.offsets, levels: built.levels,
            timestamps: built.timestamps, componentIndex: built.componentIndex, uniqueComponents: built.uniqueComponents, parserKind: .plainText
        ))

        // Replace with a much larger file so size differs.
        let larger = (0..<100).map {
            "Apr 22 10:30:0\($0 % 10) host proc[1] <Info>: row \($0)"
        }.joined(separator: "\n") + "\n"
        try larger.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(
            LogIndexCache.tryLoad(forSourceURL: url, parserKind: .plainText),
            "Size change should invalidate the cache"
        )
    }

    func testParserKindMismatchRejectsCache() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: row\n")
        let built = try LogIndex.build(fileURL: url, parserKind: .plainText)
        XCTAssertTrue(LogIndexCache.write(
            sourceURL: url, offsets: built.offsets, levels: built.levels,
            timestamps: built.timestamps, componentIndex: built.componentIndex, uniqueComponents: built.uniqueComponents, parserKind: .plainText
        ))

        // Caller asks for a different parserKind → reject.
        XCTAssertNil(
            LogIndexCache.tryLoad(forSourceURL: url, parserKind: .sccm),
            "Mismatched parserKind should reject the cache"
        )
    }

    // MARK: - Corruption

    func testCorruptedMagicRejectsCache() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: row\n")
        let built = try LogIndex.build(fileURL: url, parserKind: .plainText)
        _ = LogIndexCache.write(
            sourceURL: url, offsets: built.offsets, levels: built.levels,
            timestamps: built.timestamps, componentIndex: built.componentIndex, uniqueComponents: built.uniqueComponents, parserKind: .plainText
        )
        guard let cacheURL = LogIndexCache.cacheURL(forSourceURL: url) else {
            XCTFail("Expected cache URL")
            return
        }

        // Overwrite the first 4 bytes (magic) with garbage.
        var data = try Data(contentsOf: cacheURL)
        data[0] = 0xFF; data[1] = 0xFF; data[2] = 0xFF; data[3] = 0xFF
        try data.write(to: cacheURL)

        XCTAssertNil(LogIndexCache.tryLoad(forSourceURL: url, parserKind: .plainText))
    }

    func testTruncatedCacheFileRejected() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: row\n")
        let built = try LogIndex.build(fileURL: url, parserKind: .plainText)
        _ = LogIndexCache.write(
            sourceURL: url, offsets: built.offsets, levels: built.levels,
            timestamps: built.timestamps, componentIndex: built.componentIndex, uniqueComponents: built.uniqueComponents, parserKind: .plainText
        )
        guard let cacheURL = LogIndexCache.cacheURL(forSourceURL: url) else {
            XCTFail("Expected cache URL")
            return
        }

        // Truncate to just below header size.
        let data = try Data(contentsOf: cacheURL)
        let truncated = data.prefix(LogIndexCache.headerSize - 4)
        try truncated.write(to: cacheURL)

        XCTAssertNil(LogIndexCache.tryLoad(forSourceURL: url, parserKind: .plainText))
    }

    func testMissingCacheReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-no-cache-\(UUID().uuidString).log")
        XCTAssertNil(LogIndexCache.tryLoad(forSourceURL: url, parserKind: .plainText))
    }

    // MARK: - End-to-end via LogIndex.buildOrLoad

    func testBuildOrLoadPopulatesCacheOnFirstRun() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: row\n")
        guard let cacheURL = LogIndexCache.cacheURL(forSourceURL: url) else {
            XCTFail("Expected cache URL")
            return
        }
        try? FileManager.default.removeItem(at: cacheURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        _ = try LogIndex.buildOrLoad(fileURL: url, parserKind: .plainText)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheURL.path),
            "buildOrLoad should persist the index on first build"
        )
    }

    func testBuildOrLoadUsesCacheOnSecondRun() throws {
        let url = writeTempFile(contents: "Apr 22 10:30:15 host proc[1]: row\n")
        // First call populates the cache.
        let first = try LogIndex.buildOrLoad(fileURL: url, parserKind: .plainText)
        // Second call should produce an identical-shape index.
        let second = try LogIndex.buildOrLoad(fileURL: url, parserKind: .plainText)
        XCTAssertEqual(first.offsets, second.offsets)
        XCTAssertEqual(first.levels, second.levels)
        XCTAssertEqual(first.timestamps, second.timestamps)
        XCTAssertEqual(first.lineCount, second.lineCount)
    }
}
