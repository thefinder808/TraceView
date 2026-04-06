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
            } else {
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .background(WindowAccessor())
    }
}
