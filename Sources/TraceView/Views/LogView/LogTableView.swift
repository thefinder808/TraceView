import SwiftUI

struct LogTableView: View {
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 0) {
            // Column headers
            LogTableHeader(
                showLineNumbers: settingsManager.showLineNumbers,
                showTimestamp: settingsManager.showTimestamp,
                showComponent: settingsManager.showComponent,
                theme: theme
            )

            Divider().background(theme.border)

            // Log rows
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredEntries) { entry in
                            LogRowView(
                                entry: entry,
                                showLineNumbers: settingsManager.showLineNumbers,
                                showTimestamp: settingsManager.showTimestamp,
                                showComponent: settingsManager.showComponent,
                                fontSize: settingsManager.fontSize
                            )
                            .id(entry.id)

                            Divider()
                                .background(theme.borderSubtle)
                        }

                        // Bottom anchor for auto-follow detection
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                            .onAppear {
                                viewModel.isAtBottom = true
                                viewModel.document.isFollowing = true
                            }
                            .onDisappear {
                                viewModel.isAtBottom = false
                                viewModel.document.isFollowing = false
                            }
                    }
                }
                .background(theme.tableBackground)
                .onChange(of: viewModel.filteredEntries.count) { _, _ in
                    if viewModel.isAtBottom {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    }
                }
            }

            // Jump to bottom button (shown when not at bottom)
            if !viewModel.isAtBottom {
                jumpToBottomOverlay(theme: theme)
            }
        }
    }

    private func jumpToBottomOverlay(theme: any AppTheme) -> some View {
        HStack {
            Spacer()
            Button {
                viewModel.isAtBottom = true
                viewModel.document.isFollowing = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .medium))
                    Text("Jump to Bottom")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.accentColor)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Column Header

struct LogTableHeader: View {
    let showLineNumbers: Bool
    let showTimestamp: Bool
    let showComponent: Bool
    let theme: any AppTheme

    var body: some View {
        HStack(spacing: 0) {
            if showLineNumbers {
                headerCell("#", width: 48, alignment: .trailing)
                    .padding(.trailing, 4)
            }

            if showTimestamp {
                headerCell("Timestamp", width: 110, alignment: .leading)
                    .padding(.trailing, 8)
            }

            headerCell("Level", width: 52, alignment: .center)
                .padding(.trailing, 8)

            if showComponent {
                headerCell("Component", width: 110, alignment: .leading)
                    .padding(.trailing, 8)
            }

            headerCell("Message", width: nil, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(theme.filterBarBackground)
    }

    private func headerCell(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        Group {
            if let width {
                Text(title)
                    .frame(width: width, alignment: alignment)
            } else {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.3)
        .foregroundStyle(theme.tertiaryText)
    }
}
