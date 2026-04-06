import SwiftUI

struct LogLevelBadge: View {
    let level: LogLevel
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        Text(level.shortName)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.3)
            .foregroundStyle(theme.badgeText(for: level))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.badgeBackground(for: level))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
