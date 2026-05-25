import XCTest
import Combine
@testable import TraceViewCore

final class FilteredEntriesTests: XCTestCase {

    private func entry(_ id: Int) -> LogEntry {
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

    // MARK: - Materialized backing

    func testEmptyIsEmpty() {
        XCTAssertEqual(FilteredEntries.empty.count, 0)
        XCTAssertTrue(FilteredEntries.empty.isEmpty)
    }

    func testMaterializedRoundTrip() {
        var fe = FilteredEntries(backing: .materialized([entry(1), entry(2), entry(3)]))
        XCTAssertEqual(fe.count, 3)
        XCTAssertEqual(fe[0].id, 1)
        XCTAssertEqual(fe[2].id, 3)
        XCTAssertEqual(fe.first?.id, 1)
        XCTAssertEqual(fe.last?.id, 3)

        fe.append(matching: [entry(4)])
        XCTAssertEqual(fe.count, 4)
        XCTAssertEqual(fe[3].id, 4)

        fe.replace(with: [entry(99)])
        XCTAssertEqual(fe.count, 1)
        XCTAssertEqual(fe[0].id, 99)
    }

    func testMaterializedFirstIndexWhere() {
        let fe = FilteredEntries(backing: .materialized([entry(1), entry(2), entry(3)]))
        XCTAssertEqual(fe.firstIndex(where: { $0.id == 2 }), 1)
        XCTAssertNil(fe.firstIndex(where: { $0.id == 999 }))
    }

    // MARK: - Indexed backing

    func testIndexedRoutesSubscriptThroughSource() {
        let source = InMemoryEntrySource()
        source.append([entry(10), entry(11), entry(12), entry(13), entry(14)])
        // Filter "keeps even ids": pick rows 0, 2, 4 of the source.
        let fe = FilteredEntries(backing: .indexed(indices: [0, 2, 4], source: source))

        XCTAssertEqual(fe.count, 3)
        XCTAssertEqual(fe[0].id, 10)
        XCTAssertEqual(fe[1].id, 12)
        XCTAssertEqual(fe[2].id, 14)
    }

    func testIndexedAppendExtendsIndices() {
        let source = InMemoryEntrySource()
        source.append([entry(20), entry(21), entry(22), entry(23)])
        var fe = FilteredEntries(backing: .indexed(indices: [0], source: source))

        // Match rows 2 and 3 of the source — pass the source-row indices.
        fe.append(matching: [entry(22), entry(23)], sourceIndices: [2, 3])
        XCTAssertEqual(fe.count, 3)
        XCTAssertEqual(fe[0].id, 20)
        XCTAssertEqual(fe[1].id, 22)
        XCTAssertEqual(fe[2].id, 23)
    }

    func testIndexedReplaceSwapsBacking() {
        let source = InMemoryEntrySource()
        source.append([entry(30), entry(31), entry(32)])
        var fe = FilteredEntries(backing: .materialized([entry(99)]))

        fe.replace(indices: [0, 1, 2], source: source)
        XCTAssertEqual(fe.count, 3)
        XCTAssertEqual(fe[0].id, 30)
        XCTAssertEqual(fe[2].id, 32)
    }

    // MARK: - Identity backing (Phase 3 indexed-mode no-filter case)

    func testIdentityForwardsCountAndSubscript() {
        let source = InMemoryEntrySource()
        source.append([entry(40), entry(41), entry(42)])
        var fe = FilteredEntries(backing: .materialized([]))

        fe.replace(identity: source)
        XCTAssertEqual(fe.count, 3)
        XCTAssertEqual(fe[0].id, 40)
        XCTAssertEqual(fe[1].id, 41)
        XCTAssertEqual(fe[2].id, 42)
    }

    // MARK: - Fast lookup helpers (Phase 3 hang fix)

    func testPositionForLineNumberIdentityO1() {
        let source = InMemoryEntrySource()
        // Mimic the IndexedEntrySource invariant: id == position and
        // lineNumber == position + 1.
        let entries = (0..<100).map { i in
            LogEntry(
                id: i, lineNumber: i + 1, timestamp: nil, level: .info,
                message: "m \(i)", component: nil, threadID: nil,
                source: nil, rawLine: "raw \(i)"
            )
        }
        source.append(entries)
        let fe = FilteredEntries(backing: .identity(source: source))

        XCTAssertEqual(fe.position(forLineNumber: 1), 0)
        XCTAssertEqual(fe.position(forLineNumber: 42), 41)
        XCTAssertEqual(fe.position(forLineNumber: 100), 99)
        XCTAssertNil(fe.position(forLineNumber: 0))
        XCTAssertNil(fe.position(forLineNumber: 101))
        XCTAssertNil(fe.position(forLineNumber: -5))
    }

    func testPositionForLineNumberMaterializedFallsBackToLinearScan() {
        let entries = (0..<10).map { i in
            LogEntry(
                id: i, lineNumber: i * 7 + 1,  // sparse line numbers
                timestamp: nil, level: .info,
                message: "m \(i)", component: nil, threadID: nil,
                source: nil, rawLine: "raw \(i)"
            )
        }
        let fe = FilteredEntries(backing: .materialized(entries))

        XCTAssertEqual(fe.position(forLineNumber: 1), 0)
        XCTAssertEqual(fe.position(forLineNumber: 22), 3)   // i=3 → 3*7+1=22
        XCTAssertEqual(fe.position(forLineNumber: 64), 9)   // i=9 → 9*7+1=64
        XCTAssertNil(fe.position(forLineNumber: 100))
    }

    func testPositionForEntryIDIdentityO1() {
        let source = InMemoryEntrySource()
        let entries = (0..<100).map { i in
            LogEntry(
                id: i, lineNumber: i + 1, timestamp: nil, level: .info,
                message: "m \(i)", component: nil, threadID: nil,
                source: nil, rawLine: "raw \(i)"
            )
        }
        source.append(entries)
        let fe = FilteredEntries(backing: .identity(source: source))

        XCTAssertEqual(fe.position(forEntryID: 0), 0)
        XCTAssertEqual(fe.position(forEntryID: 42), 42)
        XCTAssertEqual(fe.position(forEntryID: 99), 99)
        XCTAssertNil(fe.position(forEntryID: 100))
        XCTAssertNil(fe.position(forEntryID: -1))
    }

    // MARK: - .indexed backing position bisect (Phase 4 PR3 hang fix)

    /// Mock EntrySource that returns parsed entries from a fixed array.
    /// Used here to test FilteredEntries' position helpers without
    /// touching IndexedEntrySource — we only need a source whose
    /// `entry(at:)` returns LogEntry with lineNumber == position + 1.
    private final class StubSource: EntrySource {
        let entries: [LogEntry]
        init(entries: [LogEntry]) { self.entries = entries }
        var allEntries: [LogEntry] { entries }
        var count: Int { entries.count }
        let supportsLevelCounts = true
        let supportsHistogram = true
        let supportsFilter = true
        let didAppend: AnyPublisher<[LogEntry], Never> = Empty().eraseToAnyPublisher()
        func entry(at index: Int) -> LogEntry? {
            guard index >= 0, index < entries.count else { return nil }
            return entries[index]
        }
        func append(_ entries: [LogEntry]) { fatalError("not supported") }
        func reset() { }
        func replace(with entries: [LogEntry]) { fatalError("not supported") }
    }

    func testPositionForLineNumberIndexedBisects() {
        // Source has 100 rows; filter keeps every 3rd one (indices
        // 0, 3, 6, ..., 99). Lookup must return the position in the
        // filtered indices array, not the source row.
        let entries = (0..<100).map { i in
            LogEntry(
                id: i, lineNumber: i + 1, timestamp: nil, level: .info,
                message: "m \(i)", component: nil, threadID: nil,
                source: nil, rawLine: "raw \(i)"
            )
        }
        let source = StubSource(entries: entries)
        let filtered = Array(stride(from: 0, to: 100, by: 3))  // 34 entries
        let fe = FilteredEntries(backing: .indexed(indices: filtered, source: source))

        // lineNumber 1 → source idx 0 → position 0 in filtered.
        XCTAssertEqual(fe.position(forLineNumber: 1), 0)
        // lineNumber 4 → source idx 3 → position 1.
        XCTAssertEqual(fe.position(forLineNumber: 4), 1)
        // lineNumber 100 → source idx 99 → position 33 (last).
        XCTAssertEqual(fe.position(forLineNumber: 100), 33)
        // lineNumber 2 → source idx 1 → NOT in filter → nil.
        XCTAssertNil(fe.position(forLineNumber: 2))
        // lineNumber 5 → source idx 4 → NOT in filter → nil.
        XCTAssertNil(fe.position(forLineNumber: 5))
        // Out of range.
        XCTAssertNil(fe.position(forLineNumber: 101))
        XCTAssertNil(fe.position(forLineNumber: 0))
    }

    func testPositionForEntryIDIndexedBisects() {
        let entries = (0..<100).map { i in
            LogEntry(
                id: i, lineNumber: i + 1, timestamp: nil, level: .info,
                message: "m \(i)", component: nil, threadID: nil,
                source: nil, rawLine: "raw \(i)"
            )
        }
        let source = StubSource(entries: entries)
        let filtered = Array(stride(from: 0, to: 100, by: 3))
        let fe = FilteredEntries(backing: .indexed(indices: filtered, source: source))

        XCTAssertEqual(fe.position(forEntryID: 0), 0)
        XCTAssertEqual(fe.position(forEntryID: 3), 1)
        XCTAssertEqual(fe.position(forEntryID: 99), 33)
        XCTAssertNil(fe.position(forEntryID: 1))
        XCTAssertNil(fe.position(forEntryID: 100))
    }

    func testPositionForLineNumberIndexedEmptyFilter() {
        let source = StubSource(entries: [])
        let fe = FilteredEntries(backing: .indexed(indices: [], source: source))
        XCTAssertNil(fe.position(forLineNumber: 1))
        XCTAssertNil(fe.position(forEntryID: 0))
    }
}
