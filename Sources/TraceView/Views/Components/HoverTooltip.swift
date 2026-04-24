import SwiftUI

/// Lightweight hover-triggered tooltip that mimics native macOS styling but
/// fires much faster than `.help()` (the system default is ~2s; this runs
/// at 400ms). Use instead of `.help()` when the slow native delay hurts
/// discoverability — toolbar / divider / overlay buttons.
struct HoverTooltip: ViewModifier {
    let text: String
    let delay: Duration
    let edge: Edge

    @State private var isShowing = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        guard !Task.isCancelled else { return }
                        isShowing = true
                    }
                } else {
                    isShowing = false
                }
            }
            .overlay(alignment: overlayAlignment) {
                if isShowing {
                    tooltipBody
                        .fixedSize()
                        .offset(tooltipOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(1000)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isShowing)
    }

    private var tooltipBody: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
    }

    private var overlayAlignment: Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    private var tooltipOffset: CGSize {
        switch edge {
        case .top: return CGSize(width: 0, height: -32)
        case .bottom: return CGSize(width: 0, height: 32)
        case .leading: return CGSize(width: -8, height: 0)
        case .trailing: return CGSize(width: 8, height: 0)
        }
    }
}

extension View {
    /// Faster drop-in for `.help()`. `edge` controls which side of the
    /// view the tooltip lands on — default `.bottom` works for most
    /// top-of-window buttons.
    func hoverTooltip(
        _ text: String,
        edge: Edge = .bottom,
        delay: Duration = .milliseconds(400)
    ) -> some View {
        modifier(HoverTooltip(text: text, delay: delay, edge: edge))
    }
}
