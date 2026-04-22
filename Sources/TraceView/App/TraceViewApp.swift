import SwiftUI

@main
struct TraceViewApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var settingsManager = SettingsManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(themeManager)
                .environmentObject(settingsManager)
                .background(themeManager.current.windowBackground)
                .preferredColorScheme(colorScheme)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
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
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open Log File...") { appState.openFile() }
                    .keyboardShortcut("o", modifiers: .command)

                Button("Stream System Log") {
                    appState.startUnifiedLogStream()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()

                Button("Close Tab") {
                    if let doc = appState.selectedDocument {
                        appState.closeDocument(doc)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.documents.isEmpty)
            }

            // Navigate menu
            CommandMenu("Navigate") {
                Button("Command Palette") { appState.showCommandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Jump to Bottom") { appState.jumpToBottom() }
                    .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Toggle Following") { appState.toggleFollowing() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                // Tab switching
                ForEach(Array(appState.documents.prefix(9).enumerated()), id: \.element.id) { index, doc in
                    Button("Tab \(index + 1): \(doc.displayName)") {
                        appState.selectDocument(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }

            // Filter menu
            CommandMenu("Filter") {
                Button("Find...") { appState.focusSearch = true }
                    .keyboardShortcut("f", modifiers: .command)
            }

            // Tools menu
            CommandMenu("Tools") {
                Button("Error Code Lookup") { appState.showErrorLookup.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Reload File") { appState.reloadCurrentFile() }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Export Filtered Log...") { appState.showExport = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Theme menu
            CommandMenu("Theme") {
                ForEach(ThemeOption.allCases) { option in
                    Button(option.rawValue) {
                        themeManager.selectedOption = option
                    }
                }

                Divider()

                Button("Cycle Theme") { themeManager.cycleTheme() }
                    .keyboardShortcut("t", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settingsManager)
                .environmentObject(themeManager)
        }
    }

    private var colorScheme: ColorScheme? {
        switch themeManager.selectedOption {
        case .dark, .neon: return .dark
        case .light, .console: return .light
        case .system: return nil
        }
    }
}
