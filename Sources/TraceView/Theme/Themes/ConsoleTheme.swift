import SwiftUI

// Console Dense — Xcode-console-adjacent default theme.
// Palette mirrors the `.tv-console` block in the handoff design canvas:
// monochrome chrome, near-white surfaces, muted blue accent, SF Mono rows.
struct ConsoleTheme: AppTheme {
    let name = "Console"

    // Surfaces
    var windowBackground: Color { Color(hex: 0xFFFFFF) }
    var sidebarBackground: Color { Color(hex: 0xFAFAFA) }
    var tableBackground: Color { Color(hex: 0xFFFFFF) }
    var filterBarBackground: Color { Color(hex: 0xF6F6F6) }
    var statusBarBackground: Color { Color(hex: 0xF4F4F4) }
    var cardBackground: Color { Color(hex: 0xFFFFFF) }
    var inputBackground: Color { Color(hex: 0xFFFFFF) }

    // Borders
    var border: Color { Color(hex: 0xDCDCDC) }
    var borderSubtle: Color { Color(hex: 0xEBEBEB) }
    var focusRing: Color { Color(hex: 0x0066CC, opacity: 0.4) }

    // Text
    var primaryText: Color { Color(hex: 0x161616) }
    var secondaryText: Color { Color(hex: 0x5A5A5A) }
    var tertiaryText: Color { Color(hex: 0x9B9B9B) }
    var timestampText: Color { Color(hex: 0x4A4A4A) }
    var componentText: Color { Color(hex: 0x5A5A5A) }

    // Interactive
    var sidebarHover: Color { Color.black.opacity(0.04) }
    var sidebarActive: Color { Color.black.opacity(0.08) }
    var tableRowHover: Color { Color.black.opacity(0.04) }
    var tableRowSelected: Color { Color(hex: 0x0066CC, opacity: 0.10) }
    var accentColor: Color { Color(hex: 0x0066CC) }

    // Row backgrounds
    var errorHighlight: Color { Color(hex: 0xC4241A, opacity: 0.10) }
    var criticalHighlight: Color { Color(hex: 0x8C1410, opacity: 0.14) }
    var warningHighlight: Color { Color(hex: 0x9A6B00, opacity: 0.10) }

    // Level text
    var errorText: Color { Color(hex: 0x9B1D14) }
    var warningText: Color { Color(hex: 0x7A5400) }
    var debugText: Color { Color(hex: 0x9B9B9B) }

    // Semantic
    var followingIndicator: Color { Color(hex: 0x267A38) }
    var pausedIndicator: Color { Color(hex: 0x9B9B9B) }
    var searchHighlight: Color { Color(hex: 0x0066CC, opacity: 0.25) }
    var searchHighlightActive: Color { Color(hex: 0x0066CC, opacity: 0.45) }
    var errorCodeLink: Color { Color(hex: 0x0066CC) }
    var liveIndicator: Color { Color(hex: 0xC46B00) }

    // Badges — tinted background + dark colored text for error/critical/
    // warning so the label reads as an annotation rather than stamping a
    // saturated block into an already-tinted error row.
    func badgeBackground(for level: LogLevel) -> Color {
        switch level {
        case .critical: return Color(hex: 0x8C1410, opacity: 0.16)
        case .error:    return Color(hex: 0xC4241A, opacity: 0.14)
        case .warning:  return Color(hex: 0x9A6B00, opacity: 0.14)
        case .notice:   return Color(hex: 0x0066CC, opacity: 0.14)
        case .info:     return Color(hex: 0xEDEDED)
        case .debug:    return Color(hex: 0xEDEDED)
        case .unknown:  return Color(hex: 0xEDEDED)
        }
    }

    func badgeText(for level: LogLevel) -> Color {
        switch level {
        case .critical: return Color(hex: 0x8C1410)
        case .error:    return Color(hex: 0x9B1D14)
        case .warning:  return Color(hex: 0x7A5400)
        case .notice:   return Color(hex: 0x0066CC)
        case .info:     return Color(hex: 0x5A5A5A)
        case .debug:    return Color(hex: 0x9B9B9B)
        case .unknown:  return Color(hex: 0x9B9B9B)
        }
    }
}
