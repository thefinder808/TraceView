import SwiftUI
import AppKit

/// Runs before the main menu is loaded so we can disable AppKit's
/// automatic window tabbing globally. Doing this in `WindowAccessor`'s
/// async block was too late — AppKit had already validated the View
/// menu once with tabs allowed, then the dispatched mutation forced a
/// re-validation, which made "Show Tab Bar" / "Enter Full Screen"
/// flicker on first menu open. Setting the class property in
/// `applicationWillFinishLaunching` runs early enough that the items
/// never get injected to begin with.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

public struct TraceViewApp: App {
    public init() {}

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var settingsManager = SettingsManager()

    public var body: some Scene {
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
                // Handles file URLs delivered via the AppleEvent open-document
                // path: `open -a TraceView.app /file`, right-click → Open With →
                // TraceView, double-click a .log in Finder, or any other system
                // mechanism that routes a file to the app. Without this, those
                // paths silently no-op (the app launches but never sees the URL).
                .onOpenURL { url in
                    appState.openFile(at: url)
                }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open Log File...") { appState.openFile(into: .primary) }
                    .keyboardShortcut("o", modifiers: .command)

                Button("Open Log File in Right Pane...") {
                    appState.openFile(into: .secondary)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Stream System Log") {
                    appState.startUnifiedLogStream()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()

                // ⌘W closes the primary pane's active tab. The split pane's
                // active tab has its own × in the secondary tab bar and a
                // trailing "close split" button. (A focused-pane concept
                // could route ⌘W to whichever pane has focus; deferred.)
                Button("Close Tab") {
                    if let id = appState.selectedDocumentID {
                        appState.closeTab(documentID: id, in: .primary)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.primaryTabOrder.isEmpty)
            }

            // Navigate menu
            CommandMenu("Navigate") {
                Button("Command Palette") { appState.showCommandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Jump to Bottom") { appState.jumpToBottom(in: appState.activePane) }
                    .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Toggle Following") { appState.toggleFollowing(in: appState.activePane) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                // Tab switching — ⌘1…⌘9 navigate primary-pane tabs.
                ForEach(Array(appState.primaryDocuments.prefix(9).enumerated()), id: \.element.id) { index, doc in
                    Button("Tab \(index + 1): \(doc.displayName)") {
                        appState.selectDocument(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }

            // Filter menu
            CommandMenu("Filter") {
                Button("Find...") { appState.focusSearchField() }
                    .keyboardShortcut("f", modifiers: .command)

                // ⌘G / ⌘⇧G step matches in find mode. The VM no-ops if
                // there are no matches or the doc isn't in find mode, so
                // the menu items are just gated on having a doc open.
                Button("Find Next") { appState.stepFindMatch(by: 1) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(appState.selectedDocument(in: appState.activePane) == nil)

                Button("Find Previous") { appState.stepFindMatch(by: -1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(appState.selectedDocument(in: appState.activePane) == nil)

                Divider()

                Button("Use Regular Expression") { appState.toggleRegex() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(appState.selectedDocument(in: appState.activePane) == nil)

                Divider()

                Button("Go to Line...") { appState.showGoToLine = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(appState.selectedDocument(in: appState.activePane) == nil)
            }

            // Tools menu
            CommandMenu("Tools") {
                Button("Error Code Lookup") { appState.showErrorLookup.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Reload File") { appState.reloadFile(in: appState.activePane) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(appState.selectedDocument(in: appState.activePane) == nil)

                Divider()

                Button(appState.isSplitView ? "Close Split View" : "Open Split View") {
                    appState.toggleSplitView()
                }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(appState.selectedDocument == nil)

                Button(appState.paneScrollSyncEnabled
                       ? "Disable Pane Scroll Sync"
                       : "Sync Pane Scrolling") {
                    appState.togglePaneScrollSync()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.isSplitView)

                Button("Create Merged View...") {
                    appState.showCreateMergedView = true
                }
                .disabled(appState.documents.count < 2)

                Divider()

                Button("Toggle Bookmark on Selected Line") { appState.toggleBookmarkOnSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(appState.selectedDocument(in: appState.activePane) == nil)

                Divider()

                Button("Export Filtered Log...") { appState.requestExport(in: appState.activePane) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            // Add view-level controls to SwiftUI's standard View menu. A
            // top-level `CommandMenu("View")` would add a SECOND menu rather
            // than augment the existing one. Font range matches the Settings
            // stepper (9...18); reset = 12pt.
            CommandGroup(after: .toolbar) {
                Button(appState.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    appState.toggleSidebarVisibility()
                }

                Divider()

                Button("Increase Font Size") {
                    settingsManager.fontSize = min(18, settingsManager.fontSize + 1)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Font Size") {
                    settingsManager.fontSize = max(9, settingsManager.fontSize - 1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Font Size") {
                    settingsManager.fontSize = 12
                }
                .keyboardShortcut("0", modifiers: .command)
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
