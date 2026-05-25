import SwiftUI

struct DetailPaneView: View {
    let entry: LogEntry
    let onClose: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var showRawLine = false

    var body: some View {
        let theme = themeManager.current

        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                // Line number
                metadataItem(label: "Line", value: "\(entry.lineNumber)", theme: theme)

                // Level
                LogLevelBadge(level: entry.level)

                // Timestamp
                if let ts = entry.timestamp {
                    metadataItem(label: "Time", value: Formatters.formatDateTime(ts), theme: theme)
                }

                // Component
                if let comp = entry.component {
                    metadataItem(label: "Component", value: comp, theme: theme)
                }

                // Thread
                if let thread = entry.threadID {
                    metadataItem(label: "Thread", value: thread, theme: theme)
                }

                Spacer()

                // Raw toggle
                Button {
                    showRawLine.toggle()
                } label: {
                    Text(showRawLine ? "Parsed" : "Raw")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                // Copy button
                Button {
                    let text = showRawLine ? entry.rawLine : entry.message
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")

                // Close button — dismisses the pane
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.sidebarHover)
                        )
                }
                .buttonStyle(.plain)
                .help("Close detail pane")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.filterBarBackground)

            Divider().background(theme.border)

            // Message body — scales with the table-row font setting so
            // ⌘= / ⌘- affects this pane in lockstep with the rows above.
            ScrollView {
                Text(showRawLine ? entry.rawLine : entry.message)
                    .font(.system(size: settingsManager.fontSize, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(theme.tableBackground)
        }
    }

    private func metadataItem(label: String, value: String, theme: any AppTheme) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tertiaryText)
                .textCase(.uppercase)

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
        }
    }
}
