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
                LogDocumentView(document: doc)
                    .id(doc.id) // Force fresh view per document
            } else {
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .background(WindowAccessor())
    }
}
