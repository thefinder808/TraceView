import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var sidebarWidth: CGFloat = SidebarLayout.defaultWidth
    @State private var sidebarDragStartWidth: CGFloat?
    /// Live width during a pane-divider drag. Initialized from
    /// `settingsManager.primaryPaneWidth` in `.onAppear`, mutated as the
    /// drag progresses, and persisted back to `SettingsManager` on
    /// `onEnded`. Keeping the in-flight value as @State (not @Published)
    /// avoids the cascading rebuild of every view that observes
    /// SettingsManager — which is what was making the drag feel jumpy
    /// (the rebuild storm was interrupting the gesture mid-flight).
    @State private var primaryPaneWidth: CGFloat = 640
    @State private var paneDragStartWidth: CGFloat?

    var body: some View {
        rootLayout
        .onAppear {
            // Sync the live drag-state @State with the persisted value
            // from SettingsManager. Done once per view lifetime; subsequent
            // drag updates go straight to the local @State.
            primaryPaneWidth = CGFloat(settingsManager.primaryPaneWidth)
        }
        .background(WindowAccessor())
        .overlay {
            if appState.showCommandPalette {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(duration: 0.2), value: appState.showCommandPalette)
        .animation(.spring(duration: 0.2), value: appState.isSidebarVisible)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.toggleSidebarVisibility()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .hoverTooltip(appState.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            }

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

    // MARK: - Root layout

    @ViewBuilder
    private var rootLayout: some View {
        // Single always-present HStack: the sidebar visibility toggle adds /
        // removes the sidebar pieces, but detailContent stays at a stable
        // position so SwiftUI preserves its identity (and the @StateObject
        // viewModels of every LogDocumentView inside it) across toggles.
        // The previous if/else around the whole HStack swapped two
        // structurally-distinct _ConditionalContent branches, which
        // recreated every LogDocumentViewModel on each toggle — wiping
        // filteredEntries, filter state, scroll position, etc. (Verified
        // via the [VM-INIT] diagnostic in LogDocumentViewModel.)
        HStack(spacing: 0) {
            if appState.isSidebarVisible {
                sidebarColumn
                    .frame(width: sidebarWidth)
                sidebarResizeDivider
            }
            detailContent
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarColumn: some View {
        SidebarView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.current.sidebarBackground)
    }

    private var sidebarResizeDivider: some View {
        Rectangle()
            .fill(themeManager.current.border)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: SidebarLayout.dividerHitWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // Always re-assign — the previous `if nil`
                                // guard could leak a stale start width if the
                                // divider was removed mid-drag (e.g. user
                                // toggled the sidebar via shortcut while
                                // dragging). onEnded doesn't fire when the
                                // gesture's host view disappears, so the next
                                // drag's first onChanged would compute against
                                // the stale start and the divider would jump.
                                let startWidth = sidebarDragStartWidth ?? sidebarWidth
                                sidebarDragStartWidth = startWidth
                                sidebarWidth = clampedSidebarWidth(startWidth + value.translation.width)
                            }
                            .onEnded { _ in
                                sidebarDragStartWidth = nil
                            }
                    )
                    // Recover from the same stale-start scenario by clearing
                    // dragStart whenever the divider re-appears. Cheap and
                    // covers the toggle-during-drag edge case.
                    .onAppear { sidebarDragStartWidth = nil }
            }
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.primaryDocuments.isEmpty && appState.secondaryDocuments.isEmpty {
            WelcomeView()
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers, into: .primary)
                }
        } else {
            HStack(spacing: 0) {
                if appState.isSplitView {
                    // The split panes live inside a GeometryReader so the
                    // divider drag can clamp `primaryPaneWidth` against the
                    // actual available width — without that, dragging right
                    // could push the secondary pane below its usable
                    // minimum. The error-lookup panel stays outside the
                    // GeometryReader as a sibling so its min/max sizing
                    // negotiates with the rest of the HStack as before.
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            primaryColumn
                                .frame(width: clampedPrimaryPaneWidth(
                                    primaryPaneWidth,
                                    available: geo.size.width
                                ))
                            paneSyncDivider(available: geo.size.width)
                                .zIndex(1)
                            secondaryColumn
                        }
                    }
                } else {
                    primaryColumn
                }
                if appState.showErrorLookup {
                    Divider().background(themeManager.current.border)
                    ErrorLookupPanel()
                        .frame(minWidth: 260, idealWidth: 280, maxWidth: 380)
                }
            }
        }
    }

    // MARK: - Pane columns

    @ViewBuilder
    private var primaryColumn: some View {
        VStack(spacing: 0) {
            // Show the tab bar whenever the primary pane has at least one
            // doc — provides consistent chrome regardless of split or tab
            // count. (The previous "no bar when one file" rule was relaxed
            // after the sidebar-toggle UX work made consistent chrome the
            // expected behavior across pane states.)
            if !appState.primaryDocuments.isEmpty {
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
    ///
    /// Drag handle: an 8pt-wide invisible rectangle catches drags anywhere
    /// on the divider except on the sync/merge buttons themselves. The
    /// rectangle is layered below the buttons in the ZStack so SwiftUI's
    /// hit-test routes button clicks to the buttons; drags away from the
    /// button band fall through to the rectangle.
    @ViewBuilder
    private func paneSyncDivider(available: CGFloat) -> some View {
        let theme = themeManager.current
        let synced = appState.paneScrollSyncEnabled

        ZStack {
            // PaneDividerHandle is FIRST in the ZStack so SwiftUI/AppKit
            // place its NSViewRepresentable host at the bottom of the
            // z-stack. That matters because NSViewRepresentable wraps
            // the NSView in a hosting layer that can paint an opaque
            // background, which would otherwise obscure the visible
            // divider line. Putting the handle first + marking the line
            // non-hit-testable keeps both visible and interactive.
            PaneDividerHandle(
                onDragStart: {
                    paneDragStartWidth = primaryPaneWidth
                },
                onDrag: { delta in
                    let start = paneDragStartWidth ?? primaryPaneWidth
                    primaryPaneWidth = clampedPrimaryPaneWidth(
                        start + delta,
                        available: available
                    )
                },
                onDragEnd: {
                    paneDragStartWidth = nil
                    // Persist once on release so the @Published mutation
                    // doesn't cascade a rebuild storm during the drag.
                    settingsManager.primaryPaneWidth = Double(primaryPaneWidth)
                }
            )
            .frame(width: PaneSplitLayout.dividerHitWidth)

            Rectangle()
                .fill(synced ? theme.accentColor : theme.border)
                // 2pt minimum keeps the divider visible against dark
                // backgrounds — a 1pt line + 1px monitor pixel grid
                // routinely made the line look "transparent" mid-stream.
                .frame(width: synced ? 3 : 2)
                // The line is purely visual — clicks should fall through
                // to the PaneDividerHandle below, which owns the drag.
                .allowsHitTesting(false)

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
                // Anchor above — the merge button sits ~34pt below sync,
                // so a default `.bottom` tooltip would land on top of it.
                .hoverTooltip(synced
                              ? "Disable Pane Scroll Sync (⇧⌘S)"
                              : "Sync Pane Scrolling (⇧⌘S)",
                              edge: .top)

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

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, SidebarLayout.minWidth), SidebarLayout.maxWidth)
    }

    /// Clamp the primary pane width so both primary and secondary stay
    /// at least `PaneSplitLayout.minWidth` wide. `available` is the
    /// total horizontal space allocated to both panes plus the divider
    /// (from the GeometryReader wrapping the split-pane region).
    ///
    /// If `available` is too small for both panes at their minimum
    /// (rare — only happens during the first layout pass, when the
    /// GeometryReader might briefly report a 0 size), skip clamping
    /// entirely and return the requested width. The next pass with
    /// real geometry will land correctly. Without this guard, a
    /// 0-width initial pass would clamp the saved width down to
    /// minWidth, and that small value would then stick (via the
    /// drag-end persist path) on the next user interaction.
    private func clampedPrimaryPaneWidth(_ width: CGFloat, available: CGFloat) -> CGFloat {
        guard available > 2 * PaneSplitLayout.minWidth else { return width }
        let lowerBound = PaneSplitLayout.minWidth
        let upperBound = available - PaneSplitLayout.minWidth
        return min(max(width, lowerBound), upperBound)
    }

    private enum SidebarLayout {
        static let minWidth: CGFloat = 180
        static let defaultWidth: CGFloat = 220
        static let maxWidth: CGFloat = 300
        static let dividerHitWidth: CGFloat = 8
    }

    private enum PaneSplitLayout {
        /// Each pane (primary and secondary) needs at least this much
        /// horizontal space. Clamping enforces it on both edges of the
        /// drag — the user can't shrink either pane below this.
        static let minWidth: CGFloat = 280
        /// Width of the invisible drag-catcher rectangle inside the
        /// paneSyncDivider's ZStack. Wider than the visible line so the
        /// user has a reasonable target to grab.
        static let dividerHitWidth: CGFloat = 8
    }
}
