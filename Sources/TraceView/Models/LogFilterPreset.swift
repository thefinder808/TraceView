import Foundation

// A saved filter snapshot users can recall from the FilterBar. Persisted to
// UserDefaults via SettingsManager as a JSON-encoded array.
struct LogFilterPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var searchText: String
    var isRegex: Bool
    var caseSensitive: Bool
    var enabledLevels: Set<LogLevel>
    var component: String?

    init(id: UUID = UUID(), name: String, filter: LogFilter) {
        self.id = id
        self.name = name
        self.searchText = filter.searchText
        self.isRegex = filter.isRegex
        self.caseSensitive = filter.caseSensitive
        self.enabledLevels = filter.enabledLevels
        self.component = filter.component
    }

    func applied(to filter: inout LogFilter) {
        filter.searchText = searchText
        filter.isRegex = isRegex
        filter.caseSensitive = caseSensitive
        filter.enabledLevels = enabledLevels
        filter.component = component
    }

    func matches(_ filter: LogFilter) -> Bool {
        return searchText == filter.searchText
            && isRegex == filter.isRegex
            && caseSensitive == filter.caseSensitive
            && enabledLevels == filter.enabledLevels
            && component == filter.component
    }
}
