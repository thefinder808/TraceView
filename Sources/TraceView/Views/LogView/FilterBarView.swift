import SwiftUI

struct FilterBarView: View {
    @ObservedObject var viewModel: LogDocumentViewModel
    let pane: Pane
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var appState: AppState
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let theme = themeManager.current

        HStack(spacing: 8) {
            modeSegmentedControl(theme: theme)

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)

                TextField("Filter log...", text: $viewModel.filter.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isSearchFocused)

                if !viewModel.filter.searchText.isEmpty {
                    Button {
                        viewModel.filter.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(theme.inputBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSearchFocused ? theme.accentColor : theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 200, maxWidth: 260)

            // Regex toggle
            filterToggle(
                label: ".*",
                isActive: viewModel.filter.isRegex,
                theme: theme
            ) {
                viewModel.filter.isRegex.toggle()
            }

            // Case sensitive toggle
            filterToggle(
                label: "Aa",
                isActive: viewModel.filter.caseSensitive,
                theme: theme
            ) {
                viewModel.filter.caseSensitive.toggle()
            }

            // Separator
            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 18)

            // Level chips
            HStack(spacing: 3) {
                ForEach([LogLevel.critical, .error, .warning, .notice, .info, .debug], id: \.self) { level in
                    levelChip(level: level, theme: theme)
                }
            }

            // Separator
            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 18)

            // Saved filter presets
            FilterPresetsView(viewModel: viewModel)

            // Per-source toggles for merged-view docs.
            if viewModel.document.isMerged {
                Rectangle()
                    .fill(theme.border)
                    .frame(width: 1, height: 18)
                ForEach(mergedSourceList(), id: \.id) { src in
                    sourceChip(id: src.id, name: src.name, theme: theme)
                }
            }

            Spacer()

            if viewModel.findMode == .find && !viewModel.filter.searchText.isEmpty {
                findNavControls(theme: theme)
            } else {
                Text(viewModel.matchCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(theme.filterBarBackground)
        .onChange(of: appState.focusSearchTick) { _, _ in
            // Both panes observe the global tick; only the active pane
            // should grab focus, otherwise primary always wins the SwiftUI
            // single-focus race.
            guard pane == appState.activePane else { return }
            isSearchFocused = true
        }
        .onChange(of: isSearchFocused) { _, focused in
            // Clicking into this pane's search field marks the pane active
            // so ⌘G / ⇧⌘G / ⌘D land here, even before the user has clicked
            // a row.
            if focused { appState.activePane = pane }
        }
    }

    // "N of M" + ‹ › nav buttons shown in find mode with a non-empty query.
    // Clicking a nav button routes through AppState.pendingGoToLine like
    // ⌘G would; the VM method is the same.
    private func findNavControls(theme: any AppTheme) -> some View {
        HStack(spacing: 6) {
            Text(matchCounterText)
                .font(.system(size: 11))
                .foregroundStyle(viewModel.matches.isEmpty ? theme.tertiaryText : theme.secondaryText)
                .monospacedDigit()

            Button {
                if let line = viewModel.advanceMatch(by: -1) { routeTo(line) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.matches.isEmpty)

            Button {
                if let line = viewModel.advanceMatch(by: 1) { routeTo(line) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.matches.isEmpty)
        }
    }

    private var matchCounterText: String {
        if viewModel.matches.isEmpty { return "No matches" }
        let index = (viewModel.currentMatchIndex ?? 0) + 1
        return "\(index) of \(viewModel.matches.count)"
    }

    private func routeTo(_ line: Int) {
        // Menu/button both pipe through the pane's go-to-line channel so
        // scroll + selection land the same way as the ⌘L sheet.
        appState.goToLine(line, in: pane)
    }

    /// Two-segment mode picker that replaces the old single-icon button.
    /// Active segment fills with the theme accent and shows white text;
    /// inactive segment is a quiet outline. Hover tooltips on each
    /// segment explain what the mode does, since "Filter" vs "Find" alone
    /// can be ambiguous to first-time users.
    private func modeSegmentedControl(theme: any AppTheme) -> some View {
        HStack(spacing: 0) {
            modeSegment(
                label: "Filter",
                mode: .filter,
                tooltip: "Filter mode — hides rows that don't match your search.",
                theme: theme
            )
            modeSegment(
                label: "Find",
                mode: .find,
                tooltip: "Find mode — keeps all rows visible; ⌘G / ⇧⌘G step through matches.",
                theme: theme
            )
        }
        .frame(height: 24)
        .background(theme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private func modeSegment(
        label: String,
        mode: FindMode,
        tooltip: String,
        theme: any AppTheme
    ) -> some View {
        let isActive = viewModel.findMode == mode
        return Button {
            // No-op on click of the already-active segment so we don't fire
            // a needless @Published mutation through the findMode publisher.
            if viewModel.findMode != mode { viewModel.findMode = mode }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? .white : theme.secondaryText)
                .frame(width: 44, height: 22)
                .background(isActive ? theme.accentColor : .clear)
        }
        .buttonStyle(.plain)
        .hoverTooltip(tooltip, edge: .bottom)
    }

    /// Stable-ordered list of (id, displayName) for the merged sources of
    /// the current doc. Sorted by display name so chip order doesn't
    /// shuffle around as the dictionary's iteration order would.
    private func mergedSourceList() -> [(id: UUID, name: String)] {
        viewModel.document.mergedSourceNames
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func sourceChip(id: UUID, name: String, theme: any AppTheme) -> some View {
        // hidden = "this source is filtered OUT". Active chip = visible.
        let isVisible = !viewModel.filter.hiddenSourceIDs.contains(id)
        return Button {
            if isVisible {
                viewModel.filter.hiddenSourceIDs.insert(id)
            } else {
                viewModel.filter.hiddenSourceIDs.remove(id)
            }
        } label: {
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isVisible ? .white : theme.tertiaryText)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(isVisible ? theme.accentColor : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isVisible ? theme.accentColor : theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(isVisible ? "Hide rows from \(name)" : "Show rows from \(name)")
    }

    private func filterToggle(label: String, isActive: Bool, theme: any AppTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isActive ? .white : theme.tertiaryText)
                .frame(width: 26, height: 26)
                .background(isActive ? theme.accentColor : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isActive ? theme.accentColor : theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func levelChip(level: LogLevel, theme: any AppTheme) -> some View {
        let isEnabled = viewModel.filter.enabledLevels.contains(level)

        return Button {
            if isEnabled {
                viewModel.filter.enabledLevels.remove(level)
            } else {
                viewModel.filter.enabledLevels.insert(level)
            }
        } label: {
            Text(level.shortName)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(isEnabled ? theme.badgeText(for: level) : theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isEnabled ? theme.badgeBackground(for: level) : theme.borderSubtle)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
