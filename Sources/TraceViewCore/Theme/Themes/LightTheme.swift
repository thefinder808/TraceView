import SwiftUI

struct LightTheme: AppTheme {
    let name = "Light"
    var cardShadow: Bool { true }

    // Surfaces
    var windowBackground: Color { Color(hex: 0xF5F5F7) }
    var sidebarBackground: Color { Color(hex: 0xEEEFF1) }
    var tableBackground: Color { Color.white }
    var filterBarBackground: Color { Color(hex: 0xEEEFF1) }
    var statusBarBackground: Color { Color(hex: 0xE8E8ED) }
    var cardBackground: Color { Color.white }
    var inputBackground: Color { Color.white }

    // Borders
    var border: Color { Color(hex: 0xD1D1D6) }
    var borderSubtle: Color { Color(hex: 0xE5E5EA) }
    var focusRing: Color { Color(hex: 0x007AFF, opacity: 0.4) }

    // Text
    var primaryText: Color { Color(hex: 0x1D1D1F) }
    var secondaryText: Color { Color(hex: 0x86868B) }
    var tertiaryText: Color { Color(hex: 0xAEAEB2) }
    var timestampText: Color { Color(hex: 0x0060CC) }
    var componentText: Color { Color(hex: 0x6E6E73) }

    // Interactive
    var sidebarHover: Color { Color(hex: 0xE5E5EA) }
    var sidebarActive: Color { Color(hex: 0xDCDCE0) }
    var tableRowHover: Color { Color.black.opacity(0.03) }
    var tableRowSelected: Color { Color(hex: 0x007AFF, opacity: 0.12) }
    var accentColor: Color { Color(hex: 0x007AFF) }

    // Log level — row backgrounds
    var errorHighlight: Color { Color(hex: 0xFF3B30, opacity: 0.08) }
    var criticalHighlight: Color { Color(hex: 0xFF3B30, opacity: 0.12) }
    var warningHighlight: Color { Color(hex: 0xFF9500, opacity: 0.10) }

    // Log level — text
    var errorText: Color { Color(hex: 0xD32F2F) }
    var warningText: Color { Color(hex: 0x996300) }
    var debugText: Color { Color(hex: 0xAEAEB2) }

    // Semantic
    var followingIndicator: Color { Color(hex: 0x34C759) }
    var pausedIndicator: Color { Color(hex: 0xAEAEB2) }
    var searchHighlight: Color { Color(hex: 0xFF9500, opacity: 0.25) }
    var searchHighlightActive: Color { Color(hex: 0xFF9500, opacity: 0.45) }
    var errorCodeLink: Color { Color(hex: 0x007AFF) }
    var liveIndicator: Color { Color(hex: 0xFF9500) }

    // Badges
    func badgeBackground(for level: LogLevel) -> Color {
        switch level {
        case .critical: return Color(hex: 0xFF3B30)
        case .error: return Color(hex: 0xFF3B30, opacity: 0.85)
        case .warning: return Color(hex: 0xFF9500, opacity: 0.85)
        case .notice: return Color(hex: 0x007AFF, opacity: 0.12)
        case .info: return Color(hex: 0x86868B, opacity: 0.15)
        case .debug: return Color(hex: 0xAEAEB2, opacity: 0.12)
        case .unknown: return Color(hex: 0xAEAEB2, opacity: 0.12)
        }
    }

    func badgeText(for level: LogLevel) -> Color {
        switch level {
        case .critical, .error, .warning: return .white
        case .notice: return Color(hex: 0x007AFF)
        case .info: return Color(hex: 0x6E6E73)
        case .debug, .unknown: return Color(hex: 0xAEAEB2)
        }
    }
}
