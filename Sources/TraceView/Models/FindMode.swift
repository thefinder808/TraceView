import Foundation

// Controls how the filter-bar search text is applied:
//
// - `.filter` hides non-matching rows (the legacy behavior).
// - `.find` keeps every row visible and instead produces a navigable
//   list of match positions that the user steps through with ⌘G / ⌘⇧G.
//
// Level chips and component filters apply in both modes.
enum FindMode: String, CaseIterable, Codable, Identifiable {
    case filter
    case find

    var id: String { rawValue }
}
