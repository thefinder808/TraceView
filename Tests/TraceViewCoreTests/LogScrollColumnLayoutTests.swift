import XCTest
@testable import TraceViewCore

final class LogScrollColumnLayoutTests: XCTestCase {

    private let allConfigurableVisible = ColumnVisibility(
        showLineNumber: true,
        showTimestamp: true,
        showComponent: true,
        showSource: false
    )

    // MARK: - Defaults

    /// At a comfortable bounds width, every visible column gets its
    /// default width and the message column fills the remainder.
    func testDefaultLayoutAtWideBounds() {
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1200,
            visibility: allConfigurableVisible
        )

        // Order: line, timestamp, level, component, message. Source is
        // hidden by default (merged-view only).
        XCTAssertEqual(frames.map(\.id), [
            .lineNumber, .timestamp, .level, .component, .message
        ])

        XCTAssertEqual(frames[0].x, 0)
        XCTAssertEqual(frames[0].width, ColumnID.lineNumber.defaultWidth)
        XCTAssertEqual(frames[1].x, ColumnID.lineNumber.defaultWidth)
        XCTAssertEqual(frames[1].width, ColumnID.timestamp.defaultWidth)
        XCTAssertEqual(frames[4].id, .message)

        let nonMessage = frames.dropLast().reduce(CGFloat(0)) { $0 + $1.width }
        XCTAssertEqual(frames.last!.width, 1200 - nonMessage, accuracy: 0.5)
    }

    // MARK: - Hidden columns

    /// Hiding line numbers excludes that frame entirely (not zero-width).
    /// The remaining columns slide left to start at x = 0.
    func testHidingLineNumberRemovesFrame() {
        var visibility = allConfigurableVisible
        visibility.showLineNumber = false

        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1000,
            visibility: visibility
        )

        XCTAssertFalse(frames.contains { $0.id == .lineNumber })
        XCTAssertEqual(frames.first?.id, .timestamp)
        XCTAssertEqual(frames.first?.x, 0)
    }

    func testHidingAllConfigurableLeavesLevelAndMessage() {
        let visibility = ColumnVisibility(
            showLineNumber: false,
            showTimestamp: false,
            showComponent: false,
            showSource: false
        )
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 800,
            visibility: visibility
        )

        XCTAssertEqual(frames.map(\.id), [.level, .message])
        XCTAssertEqual(frames[0].x, 0)
        XCTAssertEqual(frames[0].width, ColumnID.level.defaultWidth)
        XCTAssertEqual(frames[1].x, ColumnID.level.defaultWidth)
        XCTAssertEqual(frames[1].width, 800 - ColumnID.level.defaultWidth, accuracy: 0.5)
    }

    // MARK: - Source column (merged view)

    func testSourceColumnAppearsBeforeMessage() {
        var visibility = allConfigurableVisible
        visibility.showSource = true

        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1400,
            visibility: visibility
        )

        XCTAssertEqual(frames.map(\.id), [
            .lineNumber, .timestamp, .level, .component, .sourceLabel, .message
        ])
        // Source must immediately precede message.
        let sourceIdx = frames.firstIndex(where: { $0.id == .sourceLabel })!
        XCTAssertEqual(frames[sourceIdx + 1].id, .message)
    }

    // MARK: - Min/max clamping

    func testSavedWidthBelowMinIsClampedUp() {
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1000,
            visibility: allConfigurableVisible,
            savedWidths: [.timestamp: 10]  // below minWidth (80)
        )
        let timestamp = frames.first { $0.id == .timestamp }!
        XCTAssertEqual(timestamp.width, ColumnID.timestamp.minWidth)
    }

    func testSavedWidthAboveMaxIsClampedDown() {
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 2000,
            visibility: allConfigurableVisible,
            savedWidths: [.component: 1000]  // above maxWidth (320)
        )
        let component = frames.first { $0.id == .component }!
        XCTAssertEqual(component.width, ColumnID.component.maxWidth)
    }

    func testSavedWidthWithinBandIsUsedVerbatim() {
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1000,
            visibility: allConfigurableVisible,
            savedWidths: [.timestamp: 200]
        )
        let timestamp = frames.first { $0.id == .timestamp }!
        XCTAssertEqual(timestamp.width, 200)
    }

    // MARK: - Message column remainder

    func testMessageFillsRemainderAcrossBoundsWidths() {
        for boundsWidth in [800, 1024, 1440, 1920] as [CGFloat] {
            let frames = LogScrollColumnLayout.compute(
                boundsWidth: boundsWidth,
                visibility: allConfigurableVisible
            )
            let totalNonMessage = frames.filter { $0.id != .message }
                .reduce(CGFloat(0)) { $0 + $1.width }
            let message = frames.first { $0.id == .message }!
            XCTAssertEqual(
                message.width,
                boundsWidth - totalNonMessage,
                accuracy: 0.5,
                "Message column should fill remainder at width \(boundsWidth)"
            )
        }
    }

    /// When the bounds width is so narrow that other columns would consume
    /// it all, message gets its minWidth and the layout overflows past
    /// `boundsWidth`. The scroll view's clip clips visually; horizontal
    /// scrolling is deferred to later phases.
    func testNarrowBoundsClampsMessageToMinWidth() {
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 100,
            visibility: allConfigurableVisible
        )
        let message = frames.first { $0.id == .message }!
        XCTAssertEqual(message.width, ColumnID.message.minWidth)
    }

    // MARK: - Order overrides

    func testCustomOrderRespected() {
        let custom: [ColumnID] = [.level, .lineNumber, .timestamp, .component, .message]
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1200,
            visibility: allConfigurableVisible,
            order: custom
        )
        XCTAssertEqual(frames.map(\.id), custom)
    }

    /// A partial saved order (e.g. from a build before `.sourceLabel`
    /// existed) does not crash — the missing IDs append at the end in
    /// default order. The user's saved relative positions for listed
    /// columns are preserved.
    func testPartialOrderFallsBackToDefault() {
        let partial: [ColumnID] = [.timestamp, .lineNumber]
        var visibility = allConfigurableVisible
        visibility.showSource = true

        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1400,
            visibility: visibility,
            order: partial
        )
        // The two listed IDs must appear first, in their listed order.
        XCTAssertEqual(frames[0].id, .timestamp)
        XCTAssertEqual(frames[1].id, .lineNumber)
        // The remaining IDs should be present (any order acceptable for
        // missing-ID fallback) and message is always last.
        let remaining = frames.dropFirst(2).map(\.id)
        XCTAssertEqual(remaining.last, .message)
        XCTAssertTrue(remaining.contains(.level))
        XCTAssertTrue(remaining.contains(.component))
        XCTAssertTrue(remaining.contains(.sourceLabel))
    }

    // MARK: - Cumulative x-positions

    func testXPositionsAreCumulativeWidths() {
        let frames = LogScrollColumnLayout.compute(
            boundsWidth: 1200,
            visibility: allConfigurableVisible
        )
        var running: CGFloat = 0
        for frame in frames {
            XCTAssertEqual(frame.x, running, accuracy: 0.5)
            running += frame.width
        }
    }
}
