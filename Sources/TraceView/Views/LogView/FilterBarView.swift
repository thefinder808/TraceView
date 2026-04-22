import SwiftUI

struct FilterBarView: View {
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let theme = themeManager.current

        HStack(spacing: 8) {
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

            Spacer()

            // Match count
            Text(viewModel.matchCountText)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(theme.filterBarBackground)
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
