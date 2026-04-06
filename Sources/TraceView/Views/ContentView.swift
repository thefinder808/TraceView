import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager

    var body: some View {
        let theme = themeManager.current

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if appState.selectedDocument != nil {
                // Placeholder — log table view comes in Phase 2
                logPlaceholder(theme: theme)
            } else {
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .background(WindowAccessor())
    }

    @ViewBuilder
    private func logPlaceholder(theme: any AppTheme) -> some View {
        VStack(spacing: 0) {
            // Filter bar placeholder
            HStack {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(theme.secondaryText)
                Text("Filter bar — coming in Phase 2")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(theme.filterBarBackground)

            Divider().background(theme.border)

            // Log table placeholder
            VStack {
                Spacer()
                if let doc = appState.selectedDocument {
                    Text(doc.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    Text("\(doc.lineCount) entries")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                    Text("Log table — coming in Phase 2")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.top, 4)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.tableBackground)

            Divider().background(theme.border)

            // Status bar placeholder
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward")
                        .font(.system(size: 10))
                    Text("\(appState.selectedDocument?.lineCount ?? 0) lines")
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 12)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(theme.followingIndicator)
                        .frame(width: 6, height: 6)
                    Text("Following")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.followingIndicator)
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 28)
            .background(theme.statusBarBackground)
        }
    }
}
