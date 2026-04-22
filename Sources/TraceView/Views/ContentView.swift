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
                        LogDocumentView(document: doc)
                            .id(doc.id)

                        if appState.showErrorLookup {
                            Divider()
                                .background(themeManager.current.border)

                            ErrorLookupPanel()
                                .frame(minWidth: 260, idealWidth: 280, maxWidth: 380)
                        }
                    }
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
    }
}
