import SwiftUI

struct CommandPalette: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @State private var query = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let theme = themeManager.current

        ZStack {
            // Backdrop
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.showCommandPalette = false
                }

            // Palette
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.tertiaryText)

                    TextField("Type a command...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isFocused)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                Divider().background(theme.border)

                // Results
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredCommands) { command in
                            CommandRow(command: command, theme: theme) {
                                command.action()
                                appState.showCommandPalette = false
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            .background(theme.sidebarBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .frame(width: 480)
            .padding(.bottom, 200)
        }
        .onAppear { isFocused = true }
        .onExitCommand { appState.showCommandPalette = false }
    }

    private var filteredCommands: [PaletteCommand] {
        let all = allCommands
        if query.isEmpty { return all }
        let q = query.lowercased()
        return all.filter { $0.label.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    private var allCommands: [PaletteCommand] {
        var cmds: [PaletteCommand] = [
            PaletteCommand(label: "Open Log File", category: "File", shortcut: "Cmd+O", icon: "doc.badge.plus") {
                appState.openFile()
            },
            PaletteCommand(label: "Stream System Log", category: "File", shortcut: "Cmd+Shift+U", icon: "waveform") {
                appState.startUnifiedLogStream()
            },
            PaletteCommand(label: "Toggle Error Lookup", category: "Tools", shortcut: "Cmd+Shift+L", icon: "number.circle") {
                appState.showErrorLookup.toggle()
            },
            PaletteCommand(label: "Toggle Following", category: "Navigate", shortcut: "Cmd+Shift+F", icon: "arrow.down.to.line") {
                appState.toggleFollowing()
            },
            PaletteCommand(label: "Jump to Bottom", category: "Navigate", shortcut: "Cmd+Down", icon: "arrow.down") {
                appState.jumpToBottom()
            },
            PaletteCommand(label: "Cycle Theme", category: "Theme", shortcut: "Cmd+T", icon: "paintbrush") {
                themeManager.cycleTheme()
            },
        ]

        // Add tab switching
        for (i, doc) in appState.documents.prefix(9).enumerated() {
            cmds.append(PaletteCommand(
                label: doc.displayName,
                category: "Tabs",
                shortcut: "Cmd+\(i + 1)",
                icon: "doc.text"
            ) {
                appState.selectDocument(at: i)
            })
        }

        return cmds
    }
}

// MARK: - Command Model

struct PaletteCommand: Identifiable {
    let id = UUID()
    let label: String
    let category: String
    let shortcut: String
    let icon: String
    let action: () -> Void
}

// MARK: - Command Row

struct CommandRow: View {
    let command: PaletteCommand
    let theme: any AppTheme
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(command.label)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.primaryText)

                    Text(command.category)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                }

                Spacer()

                Text(command.shortcut)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isHovered ? theme.sidebarHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
