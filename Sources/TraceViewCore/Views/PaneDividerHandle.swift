import SwiftUI
import AppKit

/// SwiftUI wrapper around an `NSView` that handles the pane-divider
/// drag-resize gesture. Implemented in AppKit because the equivalent
/// SwiftUI `DragGesture` + `.onHover` combo had two quality problems:
///
/// 1. **Jumpy drag.** The gesture lives in a `GeometryReader` whose
///    children rebuild on every width change. SwiftUI's gesture state
///    is tied to view identity; when the view rebuilds mid-drag, the
///    gesture's reference position can be lost and the drag jumps to
///    cursor position.
/// 2. **Sporadic cursor.** `.onHover { NSCursor.set() }` flickers as
///    SwiftUI re-runs layout passes during the drag. `addCursorRect`
///    is the canonical AppKit cursor mechanism and is stable across
///    parent re-renders.
///
/// The NSView holds its own drag state (`dragStartX`) and posts back
/// to SwiftUI only through the closures. SwiftUI never re-evaluates
/// the divider mid-drag — its `updateNSView` is a no-op.
struct PaneDividerHandle: NSViewRepresentable {
    /// Called on mouseDown, before any drag delta. The caller captures
    /// the current pane width as the start reference.
    var onDragStart: () -> Void
    /// Called continuously during the drag. Argument is the cumulative
    /// horizontal delta in points from the mouseDown position.
    var onDrag: (CGFloat) -> Void
    /// Called once on mouseUp. The caller persists the final width.
    var onDragEnd: () -> Void

    func makeNSView(context: Context) -> PaneDividerNSView {
        let view = PaneDividerNSView()
        view.onDragStart = onDragStart
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ nsView: PaneDividerNSView, context: Context) {
        // Re-bind closures so the latest captured state (current pane
        // width, current settings reference, etc.) flows through on
        // each SwiftUI update — but the view itself doesn't restart
        // any in-flight drag.
        nsView.onDragStart = onDragStart
        nsView.onDrag = onDrag
        nsView.onDragEnd = onDragEnd
    }
}

final class PaneDividerNSView: NSView {
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    /// X-coordinate (in window space) at mouseDown. Set in mouseDown,
    /// nil otherwise. Window-space is stable while the document view
    /// shifts position during the drag, which is exactly the property
    /// we lost with SwiftUI's `.local`-default DragGesture.
    private var dragStartX: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Hit-test the full bounds. Without this the view would only
    /// receive events on the visible rectangle, which is invisible
    /// (transparent in the SwiftUI layout). `isOpaque = false` is the
    /// default; we just need a non-nil hitTest to receive clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        // The canonical AppKit cursor mechanism. Re-fires automatically
        // when the view's geometry changes, so we don't need to touch
        // cursors during the drag.
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartX else { return }
        let delta = event.locationInWindow.x - start
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onDragEnd?()
    }
}
