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
            if appState.primaryDocuments.isEmpty && appState.secondaryDocuments.isEmpty {
                WelcomeView()
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleFileDrop(providers: providers, into: .primary)
                    }
            } else {
                HStack(spacing: 0) {
                    primaryColumn
                    if appState.isSplitView {
                        Divider().background(themeManager.current.border)
                        secondaryColumn
                    }
                    if appState.showErrorLookup {
                        Divider().background(themeManager.current.border)
                        ErrorLookupPanel()
                            .frame(minWidth: 260, idealWidth: 280, maxWidth: 380)
                    }
                }
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

    // MARK: - Pane columns

    @ViewBuilder
    private var primaryColumn: some View {
        VStack(spacing: 0) {
            // Hide the bar when the pane has a single tab and no split —
            // preserves the original "no bar when one file" quietness.
            if appState.primaryDocuments.count > 1 || appState.isSplitView {
                TabBarView(pane: .primary)
            }
            if let doc = appState.selectedDocument {
                LogDocumentView(document: doc)
                    .id(doc.id)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
        // Drops on the primary column open into primary.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers: providers, into: .primary)
        }
    }

    @ViewBuilder
    private var secondaryColumn: some View {
        VStack(spacing: 0) {
            TabBarView(pane: .secondary)
            if let doc = appState.secondaryDocument {
                LogDocumentView(document: doc)
                    .id("secondary-\(doc.id)")
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
        // Drops on the secondary column open into secondary.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers: providers, into: .secondary)
        }
    }

    // MARK: - File drop

    private func handleFileDrop(providers: [NSItemProvider], into pane: Pane) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async {
                        appState.openFile(at: url, into: pane)
                    }
                }
            }
        }
        return true
    }
}
