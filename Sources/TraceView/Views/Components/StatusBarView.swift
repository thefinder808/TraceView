import SwiftUI

struct StatusBarView: View {
    @ObservedObject var document: LogDocument
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager

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

            Spacer()

            // Following indicator
            statusItem(theme: theme) {
                if document.isFollowing {
                    Circle()
                        .fill(theme.followingIndicator)
                        .frame(width: 6, height: 6)
                        .opacity(pulseOpacity)
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: pulseOpacity)

                    Text("Following")
                        .fontWeight(.medium)
                        .foregroundStyle(theme.followingIndicator)
                } else {
                    Circle()
                        .fill(theme.pausedIndicator)
                        .frame(width: 6, height: 6)

                    Text("Paused")
                        .foregroundStyle(theme.pausedIndicator)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondaryText)
        .frame(height: 28)
        .background(theme.statusBarBackground)
    }

    @State private var pulseOpacity: Double = 0.6

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
