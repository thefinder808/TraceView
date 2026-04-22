import SwiftUI

// Document tab bar. Sits above the detail content. Each open LogDocument
// becomes a tab. Click selects, middle-click/close-button closes, live
// documents get a pulsing dot.
struct TabBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.documents) { doc in
                        TabView(
                            document: doc,
                            isActive: doc.id == appState.selectedDocumentID,
                            theme: theme,
                            onSelect: { appState.selectedDocumentID = doc.id },
                            onClose: { appState.closeDocument(doc) }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .background(theme.filterBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
    }
}

private struct TabView: View {
    @ObservedObject var document: LogDocument
    let isActive: Bool
    let theme: any AppTheme
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var livePulse: Double = 0.6

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: document.isLive ? "waveform" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? theme.primaryText : theme.tertiaryText)

            Text(document.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? theme.primaryText : theme.secondaryText)

            if document.isLive {
                Circle()
                    .fill(theme.liveIndicator)
                    .frame(width: 5, height: 5)
                    .opacity(livePulse)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: livePulse)
                    .onAppear { livePulse = 1.0 }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: 14, height: 14)
                    .background(isHovered ? theme.sidebarHover : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? theme.tableBackground : (isHovered ? theme.sidebarHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? theme.border : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
