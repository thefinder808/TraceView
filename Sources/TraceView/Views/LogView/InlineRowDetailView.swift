import SwiftUI

// Content of the expand-in-place drawer. Hosted inside an NSHostingView
// placed below the expanded row by LogTableRowView.
struct InlineRowDetailView: View {
    let entry: LogEntry
    let onCopy: () -> Void
    let onFilterToComponent: () -> Void
    let onLookupErrorCode: (String) -> Void

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        VStack(alignment: .leading, spacing: 6) {
            // Header: title + metadata line
            HStack {
                Text("Context · line \(entry.lineNumber)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                Text(metadataLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Message body — scrolls vertically for long messages
            ScrollView(.vertical, showsIndicators: true) {
                Text(entry.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.tableBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Action pills
            HStack(spacing: 6) {
                if let code = firstErrorCode() {
                    pill(label: "Lookup \(code)", theme: theme) { onLookupErrorCode(code) }
                }
                pill(label: "Copy message", theme: theme, action: onCopy)
                if entry.component != nil {
                    pill(label: "Filter to \(entry.component ?? "component")", theme: theme, action: onFilterToComponent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.filterBarBackground)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let ts = entry.timestamp { parts.append(Formatters.formatDateTime(ts)) }
        if let comp = entry.component { parts.append(comp) }
        if let thread = entry.threadID { parts.append("thread \(thread)") }
        parts.append(entry.level.displayName)
        return parts.joined(separator: " · ")
    }

    private func pill(label: String, theme: any AppTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(theme.tableBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // Regex mirrors the renderMessage inline-errcode pattern in the handoff
    // components.jsx — matches hex codes, errno=N, OSStatus/IOReturn, etc.
    private static let errorCodeRegex: NSRegularExpression? = {
        let pattern = #"(0x[0-9A-Fa-f]{4,}|errno=\d+|OSStatus\s-?\d+|error\s-?\d+|kIOReturn\w*|-\d{6,})"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    private func firstErrorCode() -> String? {
        guard let regex = Self.errorCodeRegex else { return nil }
        let range = NSRange(entry.message.startIndex..., in: entry.message)
        guard let match = regex.firstMatch(in: entry.message, range: range),
              let swiftRange = Range(match.range, in: entry.message) else { return nil }
        return String(entry.message[swiftRange])
    }
}
