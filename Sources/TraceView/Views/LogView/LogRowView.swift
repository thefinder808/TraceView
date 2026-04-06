import SwiftUI

struct LogRowView: View {
    let entry: LogEntry
    let showLineNumbers: Bool
    let showTimestamp: Bool
    let showComponent: Bool
    let fontSize: Double
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        HStack(spacing: 0) {
            // Line number
            if showLineNumbers {
                Text("\(entry.lineNumber)")
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: 48, alignment: .trailing)
                    .padding(.trailing, 4)
            }

            // Timestamp
            if showTimestamp {
                Text(entry.timestamp.map { Formatters.formatTimestamp($0) } ?? "—")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(theme.timestampText)
                    .frame(width: 110, alignment: .leading)
                    .padding(.trailing, 8)
            }

            // Level badge
            LogLevelBadge(level: entry.level)
                .frame(width: 52)
                .padding(.trailing, 8)

            // Component
            if showComponent {
                Text(entry.component ?? "—")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(theme.componentText)
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, 8)
            }

            // Message
            Text(entry.message)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(messageColor(for: entry.level, theme: theme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(rowBackground(for: entry.level, theme: theme))
    }

    private func rowBackground(for level: LogLevel, theme: any AppTheme) -> Color {
        switch level {
        case .critical: return theme.criticalHighlight
        case .error: return theme.errorHighlight
        case .warning: return theme.warningHighlight
        default: return .clear
        }
    }

    private func messageColor(for level: LogLevel, theme: any AppTheme) -> Color {
        switch level {
        case .critical: return theme.errorText
        case .error: return theme.errorText
        case .warning: return theme.warningText
        case .debug: return theme.debugText
        default: return theme.primaryText
        }
    }
}
