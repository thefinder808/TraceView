import SwiftUI

// Document tab bar for a single pane. Each pane (primary/secondary) owns
// its own ordered list of tabs via AppState.primaryTabOrder /
// secondaryTabOrder. Same doc can appear in both panes' tab bars — it's
// the same underlying LogDocument (shared I/O + parsing), but each pane
// keeps its own filter / selection / scroll state.
struct TabBarView: View {
    let pane: Pane
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current
        let docs = appState.documents(in: pane)
        let selectedID = appState.selectedID(in: pane)

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(docs) { doc in
                        TabView(
                            document: doc,
                            pane: pane,
                            isActive: doc.id == selectedID,
                            theme: theme,
                            onSelect: { select(doc.id) },
                            onClose: { appState.closeTab(documentID: doc.id, in: pane) }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)

            // Secondary pane shows a trailing ✕ to close the split entirely.
            if pane == .secondary {
                Button {
                    appState.closeSplitView()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 3).fill(theme.sidebarHover)
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("Close split view (merges tabs back into the left pane)")
            }
        }
        .frame(height: 32)
        .background(theme.filterBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
    }

    private func select(_ id: UUID) {
        switch pane {
        case .primary: appState.selectedDocumentID = id
        case .secondary: appState.secondarySelectedDocumentID = id
        }
    }
}

private struct TabView: View {
    @ObservedObject var document: LogDocument
    let pane: Pane
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
        .contextMenu {
            TabContextMenu(document: document, pane: pane)
        }
    }
}

private struct TabContextMenu: View {
    let document: LogDocument
    let pane: Pane
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Move/send to the other pane. Moving from primary opens the split
        // if it isn't already open.
        let otherPane: Pane = pane == .primary ? .secondary : .primary
        let otherLabel = otherPane == .primary ? "Left Pane" : "Right Pane"
        let alreadyInOther = appState.tabOrder(in: otherPane).contains(document.id)

        if alreadyInOther {
            // Doc is already in both panes — only meaningful action is
            // closing this tab.
            Button("Close Tab") {
                appState.closeTab(documentID: document.id, in: pane)
            }
        } else {
            Button("Move to \(otherLabel)") {
                appState.moveTabToOtherPane(documentID: document.id, from: pane)
            }
            Button("Open in \(otherLabel)") {
                // Duplicate: add to the other pane without removing from
                // this one. Useful for comparing the same doc side-by-side
                // with different filters.
                appState.addTab(documentID: document.id, to: otherPane)
            }
            Divider()
            Button("Close Tab") {
                appState.closeTab(documentID: document.id, in: pane)
            }
        }
    }
}
