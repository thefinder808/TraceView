import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @State private var logsExpanded = false
    @State private var crashesExpanded = false
    @State private var diagnosticsExpanded = false
    @State private var spinsExpanded = false

    var body: some View {
        let theme = themeManager.current

        ScrollView {
            VStack(spacing: 0) {
                // Open Files section
                if !appState.documents.isEmpty {
                    sectionHeader("Open Files", theme: theme)

                    ForEach(appState.documents) { doc in
                        SidebarDocumentRow(document: doc)
                    }
                }

                // Bookmarks for the selected document (if any).
                if let doc = appState.selectedDocument, !doc.bookmarks.isEmpty {
                    SidebarBookmarksSection(document: doc)
                }

                // Reports — mirrors Console.app's sidebar grouping
                sectionHeader("Reports", theme: theme)

                collapsibleSection(
                    title: "Log Reports",
                    icon: "doc.text",
                    count: appState.logBrowser.logReports.count,
                    isExpanded: $logsExpanded,
                    theme: theme
                ) {
                    ForEach(appState.logBrowser.logReports) { file in
                        SidebarBrowsableRow(file: file)
                    }
                }

                collapsibleSection(
                    title: "Crash Reports",
                    icon: "exclamationmark.triangle",
                    count: appState.logBrowser.crashReports.count,
                    isExpanded: $crashesExpanded,
                    theme: theme
                ) {
                    ForEach(appState.logBrowser.crashReports) { file in
                        SidebarBrowsableRow(file: file)
                    }
                }

                collapsibleSection(
                    title: "Diagnostic Reports",
                    icon: "stethoscope",
                    count: appState.logBrowser.diagnosticReports.count,
                    isExpanded: $diagnosticsExpanded,
                    theme: theme
                ) {
                    ForEach(appState.logBrowser.diagnosticReports) { file in
                        SidebarBrowsableRow(file: file)
                    }
                }

                collapsibleSection(
                    title: "Spin Reports",
                    icon: "hourglass",
                    count: appState.logBrowser.spinReports.count,
                    isExpanded: $spinsExpanded,
                    theme: theme
                ) {
                    ForEach(appState.logBrowser.spinReports) { file in
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
            VStack(spacing: 0) {
                Divider().background(theme.borderSubtle)

                HStack(spacing: 8) {
                    RefreshButton(theme: theme)

                    Spacer()

                    // SettingsLink opens the declared `Settings { SettingsView() }`
                    // scene as a native macOS preferences window — same behavior
                    // as ⌘,. Plain Button + custom state doesn't hook into the
                    // Settings scene on macOS.
                    SettingsLink {
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
        count: Int,
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
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 10)

                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 14)

                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.primaryText)

                    Spacer()

                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.tertiaryText)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
    }
}

// MARK: - Bookmarks Section

// Lists the selected document's bookmarked line numbers. Clicking an entry
// routes through AppState.pendingGoToLine → NSLogTableView scroll.
// Right-click → Remove Bookmark.
private struct SidebarBookmarksSection: View {
    @ObservedObject var document: LogDocument
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current
        let sorted = document.bookmarks.sorted()

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.accentColor)

                Text("Bookmarks")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(theme.tertiaryText)

                Spacer()

                Text("\(sorted.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 6)

            ForEach(sorted, id: \.self) { line in
                BookmarkRow(document: document, line: line, theme: theme)
            }
        }
    }
}

private struct BookmarkRow: View {
    @ObservedObject var document: LogDocument
    let line: Int
    let theme: any AppTheme
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 9))
                .foregroundStyle(theme.accentColor)

            Text("Line \(line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? theme.sidebarHover : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.pendingGoToLine = line
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Remove Bookmark", role: .destructive) {
                document.bookmarks.remove(line)
            }
        }
    }
}

// MARK: - Refresh Button

// Triggers a LogBrowserService rescan; spins while active, flashes a brief
// "Updated" label when the scan completes so the user can tell it did something.
private struct RefreshButton: View {
    let theme: any AppTheme
    @EnvironmentObject var appState: AppState
    @State private var rotation: Double = 0
    @State private var showUpdated: Bool = false
    @State private var updatedTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 6) {
            Button {
                appState.logBrowser.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
                    .rotationEffect(.degrees(rotation))
            }
            .buttonStyle(.plain)
            .disabled(appState.logBrowser.isScanning)
            .help("Refresh log files")

            if showUpdated {
                Text("Updated")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.followingIndicator)
                    .transition(.opacity)
            }
        }
        .onChange(of: appState.logBrowser.isScanning) { _, scanning in
            if scanning {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            } else {
                // Reset rotation and show "Updated" for ~1.5s
                rotation = 0
                updatedTask?.cancel()
                withAnimation { showUpdated = true }
                updatedTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled {
                        withAnimation { showUpdated = false }
                    }
                }
            }
        }
    }
}

// MARK: - Document Row

struct SidebarDocumentRow: View {
    @ObservedObject var document: LogDocument
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isHovered = false

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

            // Close button swaps in for the line-count on hover/selected.
            if isHovered || isSelected {
                Button {
                    appState.closeDocument(document)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.sidebarHover)
                        )
                }
                .buttonStyle(.plain)
                .help("Close")
            } else {
                Text(formatCount(document.displayLineCount))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.cardBackground)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.sidebarActive : (isHovered ? theme.sidebarHover : .clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedDocumentID = document.id
        }
        .onHover { isHovered = $0 }
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
