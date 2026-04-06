import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isDropTargeted = false

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(theme.tertiaryText)

            Text("TraceView")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            Text("Open a log file or start streaming system logs")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)

            HStack(spacing: 12) {
                Button {
                    appState.openFile()
                } label: {
                    Label("Open File", systemImage: "doc.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }

            Text("or drag and drop a file here")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tableBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(
                    isDropTargeted ? theme.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
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
}
