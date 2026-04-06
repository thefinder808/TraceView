import SwiftUI
import Combine

struct LogTableView: View {
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var scrollProxy: ScrollViewProxy?
    @State private var lastScrolledCount: Int = 0

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
            ZStack(alignment: .bottomTrailing) {
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
                            }
                        }
                    }
                    .background(theme.tableBackground)
                    .onAppear { scrollProxy = proxy }
                    .onReceive(scrollTimer) { _ in
                        // Persistent follow: if following is on, always scroll to latest
                        guard viewModel.document.isFollowing else { return }
                        let count = viewModel.filteredEntries.count
                        guard count > 0, count != lastScrolledCount else { return }
                        lastScrolledCount = count
                        if let lastID = viewModel.filteredEntries.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                    // Detect user scroll-up via scroll wheel / trackpad
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                // User is dragging/scrolling up — pause following
                                if value.translation.height > 10 {
                                    viewModel.document.isFollowing = false
                                }
                            }
                    )
                }

                // Jump to bottom button (shown when not following)
                if !viewModel.document.isFollowing {
                    jumpToBottomButton(theme: theme)
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // 200ms throttle timer for scroll updates
    private var scrollTimer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    }

    private func jumpToBottomButton(theme: any AppTheme) -> some View {
        Button {
            viewModel.document.isFollowing = true
            if let lastID = viewModel.filteredEntries.last?.id {
                scrollProxy?.scrollTo(lastID, anchor: .bottom)
            }
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
