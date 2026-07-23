import XCTest
@testable import TraceViewCore

/// Covers the buffer-then-drop-oldest overflow policy for the pause buffer
/// that backs the live-stream Pause/Resume control.
final class PausedLineBufferTests: XCTestCase {

    func testAppendAccumulatesInOrder() {
        var buffer = PausedLineBuffer(capacity: 10)
        buffer.append(["a", "b"])
        buffer.append(["c"])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertFalse(buffer.isEmpty)
        XCTAssertEqual(buffer.lines, ["a", "b", "c"])
        XCTAssertEqual(buffer.droppedCount, 0)
    }

    func testEmptyBatchIsNoOp() {
        var buffer = PausedLineBuffer(capacity: 10)
        buffer.append([])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.droppedCount, 0)
    }

    func testDrainReturnsInArrivalOrderAndEmpties() {
        var buffer = PausedLineBuffer(capacity: 10)
        buffer.append(["one", "two", "three"])
        let drained = buffer.drain()
        XCTAssertEqual(drained, ["one", "two", "three"])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.droppedCount, 0)
    }

    /// Overflow drops the OLDEST lines (keeps the most recent) and tallies
    /// exactly how many were lost.
    func testOverflowDropsOldestAndCounts() {
        var buffer = PausedLineBuffer(capacity: 3)
        buffer.append(["1", "2", "3"])
        buffer.append(["4", "5"]) // pushes out "1" and "2"
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.lines, ["3", "4", "5"])
        XCTAssertEqual(buffer.droppedCount, 2)
    }

    /// A single batch larger than capacity keeps only the last `capacity`
    /// lines and counts the rest as dropped.
    func testSingleOversizedBatchKeepsTail() {
        var buffer = PausedLineBuffer(capacity: 2)
        buffer.append(["a", "b", "c", "d", "e"])
        XCTAssertEqual(buffer.lines, ["d", "e"])
        XCTAssertEqual(buffer.droppedCount, 3)
    }

    func testDroppedCountAccumulatesAcrossAppends() {
        var buffer = PausedLineBuffer(capacity: 2)
        buffer.append(["a", "b", "c"])   // drops "a"
        XCTAssertEqual(buffer.droppedCount, 1)
        buffer.append(["d", "e"])        // drops "b", "c"
        XCTAssertEqual(buffer.droppedCount, 3)
        XCTAssertEqual(buffer.lines, ["d", "e"])
    }

    func testResetClearsLinesAndDropped() {
        var buffer = PausedLineBuffer(capacity: 2)
        buffer.append(["a", "b", "c"]) // drops "a"
        buffer.reset()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.droppedCount, 0)
    }

    func testCapacityFlooredToOne() {
        var buffer = PausedLineBuffer(capacity: 0)
        buffer.append(["a", "b"])
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.lines, ["b"])
        XCTAssertEqual(buffer.droppedCount, 1)
    }
}
