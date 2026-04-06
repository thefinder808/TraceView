import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 0) {
            // Open Files section
            if !appState.documents.isEmpty {
                sectionHeader("Open Files", theme: theme)

                ForEach(appState.documents) { doc in
                    SidebarDocumentRow(document: doc)
                        .onTapGesture {
                            appState.selectedDocumentID = doc.id
                        }
                }
            }

            // System Logs section
            sectionHeader("System Logs", theme: theme)

            SidebarSystemRow(label: "All System", icon: "waveform")
            SidebarSystemRow(label: "Kernel", icon: "cpu")
            SidebarSystemRow(label: "User", icon: "person")

            Spacer()

            // Bottom settings button
            Divider()
                .background(theme.borderSubtle)

            Button {
                appState.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
        }
        .background(theme.sidebarBackground)
    }

    private func sectionHeader(_ title: String, theme: any AppTheme) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }
}

// MARK: - Document Row

struct SidebarDocumentRow: View {
    @ObservedObject var document: LogDocument
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current
        let isSelected = appState.selectedDocumentID == document.id

        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)

            Text(document.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            if document.isLive {
                Circle()
                    .fill(theme.liveIndicator)
                    .frame(width: 6, height: 6)
            }

            Spacer()

            Text(formatCount(document.lineCount))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(theme.cardBackground)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.sidebarActive : Color.clear)
        )
        .padding(.horizontal, 6)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}

// MARK: - System Log Row (placeholder for Phase 4)

struct SidebarSystemRow: View {
    let label: String
    let icon: String
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
