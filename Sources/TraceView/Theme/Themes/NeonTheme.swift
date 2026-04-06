import SwiftUI

struct NeonTheme: AppTheme {
    let name = "Neon"
    var glowEnabled: Bool { true }

    // Surfaces
    var windowBackground: Color { Color(hex: 0x0D0D12) }
    var sidebarBackground: Color { Color(hex: 0x12121A) }
    var tableBackground: Color { Color(hex: 0x0F0F16) }
    var filterBarBackground: Color { Color(hex: 0x12121A) }
    var statusBarBackground: Color { Color(hex: 0x0A0A10) }
    var cardBackground: Color { Color(hex: 0x18182A) }
    var inputBackground: Color { Color(hex: 0x1A1A2E) }

    // Borders
    var border: Color { Color(hex: 0x2A2A40) }
    var borderSubtle: Color { Color(hex: 0x1E1E30) }
    var focusRing: Color { Color(hex: 0x00D4FF, opacity: 0.5) }

    // Text
    var primaryText: Color { Color(hex: 0xE0E0F0) }
    var secondaryText: Color { Color(hex: 0x7878A0) }
    var tertiaryText: Color { Color(hex: 0x4A4A6A) }
    var timestampText: Color { Color(hex: 0x00D4FF) }
    var componentText: Color { Color(hex: 0x9898C0) }

    // Interactive
    var sidebarHover: Color { Color(hex: 0x1A1A2E) }
    var sidebarActive: Color { Color(hex: 0x222240) }
    var tableRowHover: Color { Color(hex: 0x00D4FF, opacity: 0.04) }
    var tableRowSelected: Color { Color(hex: 0x00D4FF, opacity: 0.15) }
    var accentColor: Color { Color(hex: 0x00D4FF) }

    // Log level — row backgrounds
    var errorHighlight: Color { Color(hex: 0xFF0040, opacity: 0.14) }
    var criticalHighlight: Color { Color(hex: 0xFF0040, opacity: 0.20) }
    var warningHighlight: Color { Color(hex: 0xFFE000, opacity: 0.12) }

    // Log level — text
    var errorText: Color { Color(hex: 0xFF4070) }
    var warningText: Color { Color(hex: 0xFFE000) }
    var debugText: Color { Color(hex: 0x4A4A6A) }

    // Semantic
    var followingIndicator: Color { Color(hex: 0x00FF88) }
    var pausedIndicator: Color { Color(hex: 0x4A4A6A) }
    var searchHighlight: Color { Color(hex: 0xFFE000, opacity: 0.30) }
    var searchHighlightActive: Color { Color(hex: 0xFFE000, opacity: 0.55) }
    var errorCodeLink: Color { Color(hex: 0x00D4FF) }
    var liveIndicator: Color { Color(hex: 0xFF6600) }

    // Badges
    func badgeBackground(for level: LogLevel) -> Color {
        switch level {
        case .critical: return Color(hex: 0xFF0040)
        case .error: return Color(hex: 0xFF0040, opacity: 0.85)
        case .warning: return Color(hex: 0xFFE000, opacity: 0.80)
        case .notice: return Color(hex: 0x00D4FF, opacity: 0.20)
        case .info: return Color(hex: 0x4A4A6A, opacity: 0.30)
        case .debug: return Color(hex: 0x4A4A6A, opacity: 0.15)
        case .unknown: return Color(hex: 0x4A4A6A, opacity: 0.15)
        }
    }

    func badgeText(for level: LogLevel) -> Color {
        switch level {
        case .critical, .error: return .white
        case .warning: return Color(hex: 0x0D0D12)
        case .notice: return Color(hex: 0x00D4FF)
        case .info: return Color(hex: 0x7878A0)
        case .debug, .unknown: return Color(hex: 0x4A4A6A)
        }
    }
}
