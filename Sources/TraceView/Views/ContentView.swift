import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if let doc = appState.selectedDocument {
                VStack(spacing: 0) {
                    if appState.documents.count > 1 {
                        TabBarView()
                    }

                    HStack(spacing: 0) {
                        primaryDocumentPane(doc: doc)

                        if let secondaryDoc = appState.secondaryDocument {
                            Divider().background(themeManager.current.border)
                            secondaryDocumentPane(doc: secondaryDoc)
                        }

                        if appState.showErrorLookup {
                            Divider()
                                .background(themeManager.current.border)

                            ErrorLookupPanel()
                                .frame(minWidth: 260, idealWidth: 280, maxWidth: 380)
                        }
                    }
                }
                // Drop anywhere on the detail column opens the file as a new
                // tab — same handler as WelcomeView. The outer TraceViewApp
                // drop doesn't reach here reliably because NavigationSplitView
                // subviews swallow it first.
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                }
            } else {
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .background(WindowAccessor())
        .overlay {
            if appState.showCommandPalette {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(duration: 0.2), value: appState.showCommandPalette)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showErrorLookup.toggle()
                } label: {
                    Image(systemName: appState.showErrorLookup
                          ? "sidebar.right"
                          : "exclamationmark.magnifyingglass")
                }
                .help(appState.showErrorLookup ? "Hide Error Lookup" : "Show Error Lookup (⇧⌘L)")
            }
        }
        .sheet(isPresented: $appState.showGoToLine) {
            GoToLineSheet()
        }
    }

    // Primary pane: the default LogDocumentView. `.id` ensures per-doc
    // @State (selection, expanded row) resets when the tab changes.
    @ViewBuilder
    private func primaryDocumentPane(doc: LogDocument) -> some View {
        LogDocumentView(document: doc)
            .id(doc.id)
            .frame(maxWidth: .infinity)
    }

    // Secondary pane: small header with the doc name + close button, then
    // the same LogDocumentView. Compound id so the secondary instance has
    // its own @State even when it happens to display the same doc as the
    // primary pane.
    @ViewBuilder
    private func secondaryDocumentPane(doc: LogDocument) -> some View {
        let theme = themeManager.current
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: doc.isLive ? "waveform" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)

                Text(doc.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Menu {
                    ForEach(appState.documents) { candidate in
                        Button(candidate.displayName) {
                            appState.secondarySelectedDocumentID = candidate.id
                        }
                        .disabled(candidate.id == doc.id)
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change split-pane document")

                Button {
                    appState.closeSplitView()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 3).fill(theme.sidebarHover)
                        )
                }
                .buttonStyle(.plain)
                .help("Close split view")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.filterBarBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.border).frame(height: 1)
            }

            LogDocumentView(document: doc)
                .id("secondary-\(doc.id)")
        }
        .frame(maxWidth: .infinity)
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async {
                        appState.openFile(at: url)
                    }
                }
            }
        }
        return true
    }
}
