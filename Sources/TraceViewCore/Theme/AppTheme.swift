import SwiftUI

protocol AppTheme {
    var name: String { get }

    // Surfaces
    var windowBackground: Color { get }
    var sidebarBackground: Color { get }
    var tableBackground: Color { get }
    var filterBarBackground: Color { get }
    var statusBarBackground: Color { get }
    var cardBackground: Color { get }
    var inputBackground: Color { get }

    // Borders & dividers
    var border: Color { get }
    var borderSubtle: Color { get }
    var focusRing: Color { get }

    // Text
    var primaryText: Color { get }
    var secondaryText: Color { get }
    var tertiaryText: Color { get }
    var timestampText: Color { get }
    var componentText: Color { get }

    // Interactive
    var sidebarHover: Color { get }
    var sidebarActive: Color { get }
    var tableRowHover: Color { get }
    var tableRowSelected: Color { get }
    var accentColor: Color { get }

    // Log level — row backgrounds
    var errorHighlight: Color { get }
    var criticalHighlight: Color { get }
    var warningHighlight: Color { get }

    // Log level — text
    var errorText: Color { get }
    var warningText: Color { get }
    var debugText: Color { get }
    var infoText: Color { get }

    // Log level — badges
    func badgeBackground(for level: LogLevel) -> Color
    func badgeText(for level: LogLevel) -> Color

    // Semantic
    var followingIndicator: Color { get }
    var pausedIndicator: Color { get }
    var searchHighlight: Color { get }
    var searchHighlightActive: Color { get }
    var errorCodeLink: Color { get }
    var liveIndicator: Color { get }
    var lineNumberColor: Color { get }

    // Effects
    var glowEnabled: Bool { get }
    var cardShadow: Bool { get }
}

// Defaults
extension AppTheme {
    var glowEnabled: Bool { false }
    var cardShadow: Bool { false }
    var lineNumberColor: Color { tertiaryText }
    var infoText: Color { primaryText }
}
