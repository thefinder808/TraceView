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
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
