import SwiftUI

// Severity summary bar — 7 chips (All / Critical / Error / Warning /
// Notice / Info / Debug) with live counts from the current document.
// Clicking a chip toggles that level in the filter (All resets).
struct SeveritySummaryBar: View {
    @ObservedObject var document: LogDocument
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current
        let per = document.levelCounts
        let total = per.values.reduce(0, +)

        HStack(spacing: 6) {
            chip(.all, count: total, theme: theme)
            chip(.level(.critical), count: per[.critical] ?? 0, theme: theme)
            chip(.level(.error),    count: per[.error] ?? 0,    theme: theme)
            chip(.level(.warning),  count: per[.warning] ?? 0,  theme: theme)
            chip(.level(.notice),   count: per[.notice] ?? 0,   theme: theme)
            chip(.level(.info),     count: per[.info] ?? 0,     theme: theme)
            chip(.level(.debug),    count: per[.debug] ?? 0,    theme: theme)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.filterBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - Chip

    private enum ChipTarget { case all; case level(LogLevel) }

    @ViewBuilder
    private func chip(_ target: ChipTarget, count: Int, theme: any AppTheme) -> some View {
        let label: String = {
            switch target {
            case .all: return "All"
            case .level(let lvl): return lvl.displayName
            }
        }()

        let accent: Color = {
            switch target {
            case .all: return theme.primaryText
            case .level(.critical): return theme.badgeBackground(for: .critical)
            case .level(.error):    return theme.errorText
            case .level(.warning):  return theme.warningText
            case .level(.notice):   return theme.accentColor
            case .level(.info):     return theme.primaryText
            case .level(.debug):    return theme.tertiaryText
            case .level(.unknown):  return theme.tertiaryText
            }
        }()

        let isActive = isActiveChip(target)

        Button {
            toggle(target)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(formatCount(count))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minWidth: 70, alignment: .leading)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? accent.opacity(0.08) : theme.tableBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? accent : theme.border, lineWidth: isActive ? 1.2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - State

    private func isActiveChip(_ target: ChipTarget) -> Bool {
        switch target {
        case .all:
            return viewModel.filter.enabledLevels.count == LogLevel.allCases.count
        case .level(let lvl):
            return viewModel.filter.enabledLevels == [lvl]
        }
    }

    private func toggle(_ target: ChipTarget) {
        switch target {
        case .all:
            viewModel.filter.enabledLevels = Set(LogLevel.allCases)
        case .level(let lvl):
            if viewModel.filter.enabledLevels == [lvl] {
                viewModel.filter.enabledLevels = Set(LogLevel.allCases)
            } else {
                viewModel.filter.enabledLevels = [lvl]
            }
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000.0).replacingOccurrences(of: ".0k", with: "k") }
        return String(n)
    }
}
