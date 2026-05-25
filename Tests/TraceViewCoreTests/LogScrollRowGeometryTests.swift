import XCTest
@testable import TraceViewCore

/// Tests for `LogScrollRowGeometry`, the pure-value rect math powering
/// the custom log view's variable-row-height drawing.
final class LogScrollRowGeometryTests: XCTestCase {

    private let baseH: CGFloat = 24       // matches default 12pt font
    private let delta: CGFloat = 160      // LogScrollRowGeometry.expandedDelta
    private let width: CGFloat = 800

    private func geometry(
        expandedRow: Int? = nil,
        entryCount: Int = 100
    ) -> LogScrollRowGeometry {
        LogScrollRowGeometry(
            baseRowHeight: baseH,
            expandedRow: expandedRow,
            entryCount: entryCount,
            width: width
        )
    }

    // MARK: - Constant-height (no expansion) parity

    func testRowFrameWithoutExpansion() {
        let g = geometry()
        for row in [0, 5, 99] {
            let frame = g.rowFrame(for: row)
            XCTAssertEqual(frame.minY, CGFloat(row) * baseH, accuracy: 0.001)
            XCTAssertEqual(frame.height, baseH, accuracy: 0.001)
            XCTAssertEqual(frame.width, width, accuracy: 0.001)
        }
    }

    func testFirstLastRowWithoutExpansion() {
        let g = geometry()
        // Rect covering rows 10..<15.
        let rect = NSRect(x: 0, y: 10 * baseH, width: width, height: 5 * baseH)
        XCTAssertEqual(g.firstRow(in: rect), 10)
        XCTAssertEqual(g.lastRow(in: rect), 15)
    }

    func testDocumentHeightWithoutExpansion() {
        let g = geometry(entryCount: 50)
        XCTAssertEqual(g.documentHeight(), 50 * baseH, accuracy: 0.001)
    }

    // MARK: - Expanded row at index 0

    func testRowFramesWithExpansionAtZero() {
        let g = geometry(expandedRow: 0)
        // Row 0 is expanded: y=0, height=baseH+delta
        XCTAssertEqual(g.rowFrame(for: 0).minY, 0, accuracy: 0.001)
        XCTAssertEqual(g.rowFrame(for: 0).height, baseH + delta, accuracy: 0.001)
        // Row 1: shifted by delta. y = 1*baseH + delta
        XCTAssertEqual(g.rowFrame(for: 1).minY, baseH + delta, accuracy: 0.001)
        XCTAssertEqual(g.rowFrame(for: 1).height, baseH, accuracy: 0.001)
    }

    // MARK: - Expanded row in the middle

    func testRowFramesWithExpansionInMiddle() {
        let g = geometry(expandedRow: 10)
        // Rows before expanded: standard math
        XCTAssertEqual(g.rowFrame(for: 5).minY, 5 * baseH, accuracy: 0.001)
        XCTAssertEqual(g.rowFrame(for: 5).height, baseH, accuracy: 0.001)
        // Expanded row: standard y, expanded height
        XCTAssertEqual(g.rowFrame(for: 10).minY, 10 * baseH, accuracy: 0.001)
        XCTAssertEqual(g.rowFrame(for: 10).height, baseH + delta, accuracy: 0.001)
        // Rows after expanded: y shifted by delta
        XCTAssertEqual(g.rowFrame(for: 11).minY, 11 * baseH + delta, accuracy: 0.001)
        XCTAssertEqual(g.rowFrame(for: 11).height, baseH, accuracy: 0.001)
        XCTAssertEqual(g.rowFrame(for: 50).minY, 50 * baseH + delta, accuracy: 0.001)
    }

    // MARK: - firstRow / lastRow across the expanded band

    func testFirstRowAboveExpansion() {
        let g = geometry(expandedRow: 10)
        let rect = NSRect(x: 0, y: 5 * baseH, width: width, height: baseH)
        XCTAssertEqual(g.firstRow(in: rect), 5)
    }

    func testFirstRowAtExpandedRow() {
        let g = geometry(expandedRow: 10)
        // y starts in the expanded row's cell band
        let rect = NSRect(x: 0, y: 10 * baseH, width: width, height: 10)
        XCTAssertEqual(g.firstRow(in: rect), 10)
    }

    func testFirstRowInsideExpandedDetailBand() {
        let g = geometry(expandedRow: 10)
        // y is in the bottom (detail) portion of the expanded row
        let rect = NSRect(x: 0, y: 10 * baseH + baseH + 50, width: width, height: 10)
        XCTAssertEqual(g.firstRow(in: rect), 10)
    }

    func testFirstRowBelowExpansion() {
        let g = geometry(expandedRow: 10)
        // y is just past the expanded row's detail band
        let rect = NSRect(x: 0, y: 11 * baseH + delta + 5, width: width, height: 10)
        // This should resolve to row 11.
        XCTAssertEqual(g.firstRow(in: rect), 11)
    }

    func testLastRowSpanningExpandedRow() {
        let g = geometry(expandedRow: 10)
        // Rect spans from row 8 through row 12 — lastRow should be 13.
        let topY = 8 * baseH
        let bottomY = 13 * baseH + delta  // row 12's frame is at 12*baseH+delta to 13*baseH+delta
        let rect = NSRect(x: 0, y: topY, width: width, height: bottomY - topY)
        XCTAssertEqual(g.firstRow(in: rect), 8)
        XCTAssertEqual(g.lastRow(in: rect), 13)
    }

    // MARK: - Document height accounting

    func testDocumentHeightWithExpansion() {
        let g = geometry(expandedRow: 5, entryCount: 100)
        XCTAssertEqual(g.documentHeight(), 100 * baseH + delta, accuracy: 0.001)
    }

    // MARK: - Bounds safety

    func testFirstRowClampsToZero() {
        let g = geometry()
        let rect = NSRect(x: 0, y: -50, width: width, height: 10)
        XCTAssertEqual(g.firstRow(in: rect), 0)
    }

    func testLastRowClampsToEntryCount() {
        let g = geometry(entryCount: 20)
        let rect = NSRect(x: 0, y: 0, width: width, height: 1000)
        XCTAssertEqual(g.lastRow(in: rect), 20)
    }

    func testZeroHeightReturnsZero() {
        let g = LogScrollRowGeometry(
            baseRowHeight: 0,
            expandedRow: nil,
            entryCount: 100,
            width: width
        )
        XCTAssertEqual(g.firstRow(in: NSRect(x: 0, y: 100, width: 1, height: 1)), 0)
        XCTAssertEqual(g.lastRow(in: NSRect(x: 0, y: 100, width: 1, height: 1)), 0)
    }

    // MARK: - Cumulative y-positions

    /// rowFrame(for: i+1).minY must equal rowFrame(for: i).minY + rowFrame(for: i).height.
    /// This invariant holds across the expanded row's boundary.
    func testRowFramesAreContiguous() {
        let g = geometry(expandedRow: 10, entryCount: 30)
        for i in 0..<29 {
            let curr = g.rowFrame(for: i)
            let next = g.rowFrame(for: i + 1)
            XCTAssertEqual(
                next.minY,
                curr.minY + curr.height,
                accuracy: 0.001,
                "Gap or overlap between row \(i) and row \(i + 1)"
            )
        }
    }
}
