import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @State private var logsExpanded = true
    @State private var crashesExpanded = true

    var body: some View {
        let theme = themeManager.current

        ScrollView {
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

                // Log Reports section (browsable)
                collapsibleSection(
                    title: "Log Reports",
                    icon: "doc.text",
                    isExpanded: $logsExpanded,
                    theme: theme
                ) {
                    ForEach(appState.logBrowser.logReports) { file in
                        SidebarBrowsableRow(file: file)
                    }
                }

                // Crash Reports section (browsable)
                collapsibleSection(
                    title: "Crash Reports",
                    icon: "exclamationmark.triangle",
                    isExpanded: $crashesExpanded,
                    theme: theme
                ) {
                    ForEach(appState.logBrowser.crashReports) { file in
                        SidebarBrowsableRow(file: file)
                    }
                }

                // System Logs section
                sectionHeader("System Logs", theme: theme)

                SidebarSystemRow(label: "All System", icon: "waveform", predicate: nil)
                SidebarSystemRow(label: "Kernel", icon: "cpu", predicate: "process == 'kernel'")
                SidebarSystemRow(label: "User", icon: "person", predicate: "senderImagePath CONTAINS '/usr'")
            }
        }
        .background(theme.sidebarBackground)
        .safeAreaInset(edge: .bottom) {
            // Settings button
            VStack(spacing: 0) {
                Divider().background(theme.borderSubtle)

                HStack {
                    Button {
                        appState.logBrowser.scan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh log files")

                    Spacer()

                    Button {
                        appState.showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(theme.sidebarBackground)
            }
        }
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

    private func collapsibleSection<Content: View>(
        title: String,
        icon: String,
        isExpanded: Binding<Bool>,
        theme: any AppTheme,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 12)

                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(theme.tertiaryText)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
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

            Text(formatCount(document.displayLineCount))
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

// MARK: - Browsable Log File Row

struct SidebarBrowsableRow: View {
    let file: BrowsableLogFile
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        Button {
            appState.openFile(at: file.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(file.formattedSize)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.tertiaryText)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System Log Row

struct SidebarSystemRow: View {
    let label: String
    let icon: String
    let predicate: String?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        Button {
            appState.startUnifiedLogStream(predicate: predicate, label: label)
        } label: {
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
        .buttonStyle(.plain)
    }
}
