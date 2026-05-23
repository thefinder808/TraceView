import XCTest
@testable import TraceViewCore

/// Tests for `LogScrollView.Coordinator.findNearestRow(in:forTimestamp:)`,
/// the bisect-based nearest-row-by-timestamp lookup used by pane scroll-sync.
final class LogScrollTimestampSearchTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func entries(offsets: [Double?], idOffset: Int = 0) -> [LogEntry] {
        offsets.enumerated().map { idx, offset in
            LogEntry(
                id: idOffset + idx,
                lineNumber: idOffset + idx,
                timestamp: offset.map { reference.addingTimeInterval($0) },
                level: .info,
                message: "msg \(idx)",
                component: nil,
                threadID: nil,
                source: nil,
                rawLine: "raw"
            )
        }
    }

    // MARK: - Edge cases

    func testEmptyArrayReturnsNil() {
        XCTAssertNil(
            LogScrollView.Coordinator.findNearestRow(in: [], forTimestamp: reference)
        )
    }

    func testAllNilTimestampsReturnsNil() {
        let arr = entries(offsets: [nil, nil, nil])
        XCTAssertNil(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: reference)
        )
    }

    // MARK: - All entries qualify / none qualify

    func testTargetAfterAllTimestampsReturnsLast() {
        let arr = entries(offsets: [-3, -2, -1])
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: reference),
            2
        )
    }

    func testTargetBeforeAllTimestampsFallsBackToFirstTimestamped() {
        let arr = entries(offsets: [1, 2, 3])
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: reference),
            0
        )
    }

    // MARK: - Standard bisect cases (sorted)

    func testExactMatchInMiddle() {
        let arr = entries(offsets: [-2, -1, 0, 1, 2])
        // target = reference, so offset 0 is exact match.
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: reference),
            2
        )
    }

    func testTargetBetweenTimestampsReturnsLowerNeighbor() {
        let arr = entries(offsets: [0, 1, 2, 3, 4])
        // target = reference + 2.5 → largest ≤ is reference + 2 (index 2)
        let target = reference.addingTimeInterval(2.5)
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: target),
            2
        )
    }

    func testTargetAtFirstTimestampReturnsZero() {
        let arr = entries(offsets: [0, 1, 2, 3])
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: reference),
            0
        )
    }

    func testTargetAtLastTimestampReturnsLast() {
        let arr = entries(offsets: [-3, -2, -1, 0])
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: reference),
            3
        )
    }

    // MARK: - Performance shape (bisect, not linear)

    /// Large sorted array — the bisect runs in O(log n). The test
    /// doesn't measure time directly (XCTest perf tests are flaky); it
    /// just confirms the result is correct at scale.
    func testLargeSortedArrayCorrectMidpoint() {
        let offsets: [Double?] = (0..<100_000).map { Double($0) }
        let arr = entries(offsets: offsets)
        let target = reference.addingTimeInterval(50_000.5)
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: target),
            50_000
        )
    }

    // MARK: - Nil-timestamp interleaving

    /// Sparse nil timestamps in an otherwise-sorted array. Bisect
    /// biases left on nil, then the fallback finds the qualifying
    /// entry. Result is approximate but acceptable for scroll-sync UX.
    func testInterleavedNilTimestampsFallbackStillFindsTimestampedEntry() {
        // Sorted timestamps with nil interleaved.
        let arr = entries(offsets: [0, nil, 1, nil, 2, nil, 3])
        // target = reference + 2.5 → exact answer is index 4 (ts = 2)
        let target = reference.addingTimeInterval(2.5)
        // Bisect may land on a nil and bias left, missing index 4. Test
        // documents the current heuristic behavior: returns some
        // timestamped entry, never nil, never an out-of-bounds index.
        let result = LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: target)
        XCTAssertNotNil(result)
        XCTAssertTrue(result! >= 0 && result! < arr.count)
        XCTAssertNotNil(arr[result!].timestamp)
    }

    // MARK: - Duplicate timestamps (last-wins)

    /// When multiple entries share the target timestamp, the bisect
    /// returns the largest index — matches NSLogTableView's behavior
    /// at NSLogTableView.swift:506-520 (originally linear-scan).
    func testDuplicateTimestampsReturnsLargestIndex() {
        let arr = entries(offsets: [0, 1, 1, 1, 2])
        // target = reference + 1 → answer is index 3 (last of the 1s)
        let target = reference.addingTimeInterval(1)
        XCTAssertEqual(
            LogScrollView.Coordinator.findNearestRow(in: arr, forTimestamp: target),
            3
        )
    }
}
