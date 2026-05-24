import XCTest
import Combine
@testable import TraceViewCore

final class InMemoryEntrySourceTests: XCTestCase {

    private func makeEntry(_ id: Int) -> LogEntry {
        LogEntry(
            id: id,
            lineNumber: id,
            timestamp: nil,
            level: .info,
            message: "msg \(id)",
            component: nil,
            threadID: nil,
            source: nil,
            rawLine: "raw \(id)"
        )
    }

    func testAppendStoresEntriesAndPublishesSlice() {
        let source = InMemoryEntrySource()
        var publishedBatches: [[LogEntry]] = []
        let cancellable = source.didAppend.sink { publishedBatches.append($0) }
        defer { cancellable.cancel() }

        source.append([makeEntry(1), makeEntry(2)])
        source.append([makeEntry(3)])

        XCTAssertEqual(source.count, 3)
        XCTAssertEqual(source.allEntries.map(\.id), [1, 2, 3])
        XCTAssertEqual(publishedBatches.count, 2)
        XCTAssertEqual(publishedBatches[0].map(\.id), [1, 2])
        XCTAssertEqual(publishedBatches[1].map(\.id), [3])
    }

    func testAppendEmptyDoesNotPublish() {
        let source = InMemoryEntrySource()
        var publishedBatches: [[LogEntry]] = []
        let cancellable = source.didAppend.sink { publishedBatches.append($0) }
        defer { cancellable.cancel() }

        source.append([])

        XCTAssertEqual(source.count, 0)
        XCTAssertTrue(publishedBatches.isEmpty, "Empty appends should not fire didAppend")
    }

    func testResetClearsWithoutPublishing() {
        let source = InMemoryEntrySource()
        source.append([makeEntry(1), makeEntry(2)])

        var publishedAfterReset: [[LogEntry]] = []
        let cancellable = source.didAppend.sink { publishedAfterReset.append($0) }
        defer { cancellable.cancel() }

        source.reset()

        XCTAssertEqual(source.count, 0)
        XCTAssertTrue(source.allEntries.isEmpty)
        XCTAssertTrue(publishedAfterReset.isEmpty, "reset() should not fire didAppend")
    }

    func testReplacePublishesFullPayload() {
        let source = InMemoryEntrySource()
        source.append([makeEntry(1)])

        var publishedAfterReplace: [[LogEntry]] = []
        let cancellable = source.didAppend.sink { publishedAfterReplace.append($0) }
        defer { cancellable.cancel() }

        source.replace(with: [makeEntry(10), makeEntry(11)])

        XCTAssertEqual(source.count, 2)
        XCTAssertEqual(source.allEntries.map(\.id), [10, 11])
        XCTAssertEqual(publishedAfterReplace.count, 1)
        XCTAssertEqual(publishedAfterReplace[0].map(\.id), [10, 11])
    }

    // MARK: - entry(at:) — Phase 3 random-access primitive

    func testEntryAtReturnsEntryForValidIndex() {
        let source = InMemoryEntrySource()
        source.append([makeEntry(1), makeEntry(2), makeEntry(3)])
        XCTAssertEqual(source.entry(at: 0)?.id, 1)
        XCTAssertEqual(source.entry(at: 2)?.id, 3)
    }

    func testEntryAtReturnsNilForOutOfBounds() {
        let source = InMemoryEntrySource()
        source.append([makeEntry(1)])
        XCTAssertNil(source.entry(at: -1))
        XCTAssertNil(source.entry(at: 1))
        XCTAssertNil(source.entry(at: 1_000_000))
    }

    func testEntryAtAfterResetReturnsNil() {
        let source = InMemoryEntrySource()
        source.append([makeEntry(1)])
        source.reset()
        XCTAssertNil(source.entry(at: 0))
    }

    func testSupportsDerivedStatsIsTrue() {
        let source = InMemoryEntrySource()
        XCTAssertTrue(source.supportsDerivedStats)
    }
}
