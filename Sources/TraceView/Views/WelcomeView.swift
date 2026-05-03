import SwiftUI

/// Empty-state view shown when no logs are open in either pane. Splits the
/// area into two side-by-side drop zones, one per pane, so users can set up
/// either single-pane (open into primary) or split-view (open into secondary)
/// without having to find the toolbar's right-pane button.
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 0) {
            // Title strip — keeps the brand visible. Compact so the drop
            // zones below get most of the vertical real estate.
            VStack(spacing: 6) {
                Text("TraceView")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text("Open a log to begin investigating")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            Divider().background(theme.border)

            // Two zones: primary on the left, secondary on the right. Each
            // owns its own drop target + hover state so the user gets clear
            // feedback about which pane the file will land in.
            HStack(spacing: 0) {
                WelcomePaneZone(
                    pane: .primary,
                    icon: "rectangle.lefthalf.fill",
                    label: "Primary Pane",
                    buttonLabel: "Open File",
                    theme: theme,
                    onOpen: { appState.openFile(into: .primary) },
                    onDropURL: { appState.openFile(at: $0, into: .primary) }
                )

                Divider().background(theme.border)

                WelcomePaneZone(
                    pane: .secondary,
                    icon: "rectangle.righthalf.fill",
                    label: "Right Pane",
                    buttonLabel: "Open in Right Pane",
                    theme: theme,
                    onOpen: { appState.openFile(into: .secondary) },
                    onDropURL: { appState.openFile(at: $0, into: .secondary) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tableBackground)
    }
}

/// One side of the split WelcomeView. Self-contained so that hover and
/// drop-target highlighting only affect this zone, not its sibling.
private struct WelcomePaneZone: View {
    let pane: Pane
    let icon: String
    let label: String
    let buttonLabel: String
    let theme: any AppTheme
    let onOpen: () -> Void
    let onDropURL: (URL) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(theme.tertiaryText)

            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.primaryText)

            Button(action: onOpen) {
                Label(buttonLabel, systemImage: "doc.badge.plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentColor)

            Text("or drag a file here")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Per-zone overlay so only the targeted zone highlights on drag.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? theme.accentColor : Color.clear,
                    lineWidth: 2
                )
                .padding(8)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async { onDropURL(url) }
                    }
                }
            }
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label). \(buttonLabel) or drop a file to open in this pane.")
    }
}
