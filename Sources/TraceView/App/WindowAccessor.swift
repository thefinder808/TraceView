import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            window.styleMask.insert(.miniaturizable)
            window.styleMask.insert(.closable)
            window.styleMask.insert(.titled)
            window.minSize = NSSize(width: 800, height: 500)
            window.isMovableByWindowBackground = false
            // Suppress AppKit's automatic window-tabbing menu items
            // ("Show Tab Bar", "Show All Tabs", "Move Tab to New Window")
            // — TraceView is not a tab-aware document app, and these
            // items flicker in/out of the View menu as macOS reevaluates
            // tabbing eligibility.
            window.tabbingMode = .disallowed

            // Explicitly opt the window into full-screen mode. Without
            // .fullScreenPrimary, macOS shows "Enter Full Screen" in the
            // View menu briefly then removes it once it determines the
            // window can't go full-screen. Declaring support keeps the
            // item permanent and functional.
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
