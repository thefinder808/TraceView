import SwiftUI

// User-defined pattern → color rule. Independent from severity-based
// highlighting; a matched rule tints the row on top of the level color
// so both signals stay visible ("ratelimit" matches still look red if
// they're error-level lines).
struct HighlightRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var pattern: String
    var colorHex: UInt32      // 0xRRGGBB
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, pattern: String, colorHex: UInt32, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.colorHex = colorHex
        self.isEnabled = isEnabled
    }

    var color: Color {
        Color(hex: UInt(colorHex))
    }
}
