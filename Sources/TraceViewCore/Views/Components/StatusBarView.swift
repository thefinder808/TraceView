import SwiftUI

struct StatusBarView: View {
    @ObservedObject var document: LogDocument
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        let theme = themeManager.current

        HStack(spacing: 0) {
            // Line count
            statusItem(theme: theme) {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .font(.system(size: 10))
                Text("\(Formatters.formatCount(document.lineCount)) lines")
            }

            statusDivider(theme: theme)

            // Encoding
            statusItem(theme: theme) {
                Text(encodingName)
            }

            statusDivider(theme: theme)

            // File size
            statusItem(theme: theme) {
                Text(Formatters.formatBytes(document.fileSize))
            }

            if document.isCompressed {
                statusDivider(theme: theme)
                statusItem(theme: theme) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 10))
                    Text("gzip")
                }
            }

            // Phase 4 PR3 finished filling in the indexed-mode UI gaps
            // — chips, histogram, filter, find all work. Status-bar
            // warning is no longer needed; the "Scanning" indicator in
            // the filter bar covers the rare-but-non-instant indexed
            // filter operation. (Kept the if-block for symmetry; if any
            // future source type genuinely loses filter support, we'd
            // restore a note here.)
            EmptyView()

            Spacer()

            // SYNCED pill — only visible while the two panes are actively
            // kept in scroll-lock. Placed next to the Following indicator
            // so the two "pane-wide mode flags" sit together.
            if appState.paneScrollSyncEnabled && appState.isSplitView {
                statusItem(theme: theme) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("SYNCED")
                        .fontWeight(.semibold)
                }
                .foregroundStyle(theme.accentColor)

                statusDivider(theme: theme)
            }

            // Following / Paused / Stalled + rolling rate
            statusItem(theme: theme) {
                streamHealth(theme: theme)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondaryText)
        .frame(height: 28)
        .background(theme.statusBarBackground)
    }

    @State private var pulseOpacity: Double = 0.6

    private enum StreamState { case following, paused, stalled }

    private var streamState: StreamState {
        if !document.isFollowing { return .paused }
        // Stalled only applies to unified-log streams where silence is
        // unexpected. Static file watchers sit quiet whenever the file
        // isn't being appended to — that's normal, not a problem.
        if case .unifiedLog = document.source,
           document.idleTicks >= 5 {
            return .stalled
        }
        return .following
    }

    @ViewBuilder
    private func streamHealth(theme: any AppTheme) -> some View {
        switch streamState {
        case .following:
            Circle()
                .fill(theme.followingIndicator)
                .frame(width: 6, height: 6)
                .opacity(pulseOpacity)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: pulseOpacity)
                .onAppear { pulseOpacity = 1.0 }
            Text("Following")
                .fontWeight(.medium)
                .foregroundStyle(theme.followingIndicator)
            if document.isLive && document.linesPerSecond >= 0.5 {
                Text("· \(rateLabel)/s")
                    .foregroundStyle(theme.tertiaryText)
                    .monospacedDigit()
            }
        case .paused:
            Circle()
                .fill(theme.pausedIndicator)
                .frame(width: 6, height: 6)
            Text("Paused")
                .foregroundStyle(theme.pausedIndicator)
        case .stalled:
            Circle()
                .fill(theme.warningText)
                .frame(width: 6, height: 6)
            Text("Stalled")
                .fontWeight(.medium)
                .foregroundStyle(theme.warningText)
        }
    }

    private var rateLabel: String {
        let rate = document.linesPerSecond
        if rate >= 100 { return String(Int(rate.rounded())) }
        if rate >= 10  { return String(format: "%.0f", rate) }
        return String(format: "%.1f", rate)
    }

    private var encodingName: String {
        switch document.encoding {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .ascii: return "ASCII"
        case .isoLatin1: return "ISO-8859-1"
        default: return "UTF-8"
        }
    }

    private func statusItem<Content: View>(theme: any AppTheme, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(.horizontal, 8)
    }

    private func statusDivider(theme: any AppTheme) -> some View {
        Rectangle()
            .fill(theme.borderSubtle)
            .frame(width: 1, height: 14)
    }
}
