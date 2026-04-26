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
                        paneSyncDivider
                            .zIndex(1)
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
                    appState.openFile(into: .secondary)
                } label: {
                    Image(systemName: "rectangle.righthalf.inset.filled")
                }
                .hoverTooltip("Open Log File in Right Pane (⇧⌘O)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showErrorLookup.toggle()
                } label: {
                    Image(systemName: appState.showErrorLookup
                          ? "sidebar.right"
                          : "exclamationmark.magnifyingglass")
                }
                .hoverTooltip(appState.showErrorLookup ? "Hide Error Lookup" : "Show Error Lookup (⇧⌘L)")
            }
        }
        .sheet(isPresented: $appState.showGoToLine) {
            GoToLineSheet()
        }
        .sheet(isPresented: $appState.showCreateMergedView) {
            CreateMergedViewSheet()
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
                LogDocumentView(document: doc, pane: .primary)
                    .id(doc.id)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
        .overlay(alignment: .top) { activePaneAccent(for: .primary) }
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
                LogDocumentView(document: doc, pane: .secondary)
                    .id("secondary-\(doc.id)")
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
        .overlay(alignment: .top) { activePaneAccent(for: .secondary) }
        // Drops on the secondary column open into secondary.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers: providers, into: .secondary)
        }
    }

    // MARK: - Pane sync divider

    /// Divider between primary and secondary panes, with a sync-toggle
    /// button sitting over it. When sync is on the line goes accent-colored
    /// and thicker, giving a hard-to-miss "these panes are linked" cue.
    @ViewBuilder
    private var paneSyncDivider: some View {
        let theme = themeManager.current
        let synced = appState.paneScrollSyncEnabled

        ZStack {
            Rectangle()
                .fill(synced ? theme.accentColor : theme.border)
                .frame(width: synced ? 3 : 1)

            // Stack the two buttons vertically with a small gap. Sync sits
            // above merge — sync is the more frequent action, merge is a
            // commit-this-investigation moment.
            VStack(spacing: 8) {
                Button {
                    appState.togglePaneScrollSync()
                } label: {
                    ZStack {
                        Circle()
                            .fill(synced ? theme.accentColor : theme.tableBackground)
                        Circle()
                            .stroke(synced ? theme.accentColor : theme.border, lineWidth: 1)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(synced ? .white : theme.secondaryText)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .hoverTooltip(synced
                              ? "Disable Pane Scroll Sync (⇧⌘S)"
                              : "Sync Pane Scrolling (⇧⌘S)")

                mergePanesButton(theme: theme)
            }
        }
        .frame(width: 26)
    }

    /// One-click merge of the two visible pane docs into a combined view.
    /// Disabled when either pane is empty or both visible docs are merged
    /// (merging a merged-of-A+B with C is unsupported in v1).
    @ViewBuilder
    private func mergePanesButton(theme: any AppTheme) -> some View {
        let canMerge = canMergeVisiblePanes
        Button {
            mergeVisiblePanes()
        } label: {
            ZStack {
                Circle()
                    .fill(theme.tableBackground)
                Circle()
                    .stroke(canMerge ? theme.border : theme.borderSubtle, lineWidth: 1)
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canMerge ? theme.secondaryText : theme.tertiaryText)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(!canMerge)
        .hoverTooltip("Merge Both Panes into a Combined View")
    }

    private var canMergeVisiblePanes: Bool {
        guard let primary = appState.selectedDocument,
              let secondary = appState.secondaryDocument,
              primary.id != secondary.id else { return false }
        // Merging-of-merged is out of scope for v1 — disable when EITHER
        // pane already holds a merged view. Matches CreateMergedViewSheet's
        // eligibility filter (which excludes merged docs from the picker).
        return !primary.isMerged && !secondary.isMerged
    }

    private func mergeVisiblePanes() {
        guard let primary = appState.selectedDocument,
              let secondary = appState.secondaryDocument,
              primary.id != secondary.id else { return }
        appState.createMergedView(from: [primary, secondary])
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

    /// 2px top accent strip on the active pane when split is open. Hidden
    /// in single-pane mode (no ambiguity) and on the inactive pane in
    /// split mode. Color tracks the current theme's accent.
    @ViewBuilder
    private func activePaneAccent(for pane: Pane) -> some View {
        if appState.isSplitView && appState.activePane == pane {
            Rectangle()
                .fill(themeManager.current.accentColor)
                .frame(height: 2)
                .allowsHitTesting(false)
        }
    }
}
