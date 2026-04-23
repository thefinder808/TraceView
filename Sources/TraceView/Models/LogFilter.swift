import Foundation

struct LogFilter: Equatable {
    var searchText: String = ""
    var isRegex: Bool = false
    var caseSensitive: Bool = false
    var minimumLevel: LogLevel = .debug
    var enabledLevels: Set<LogLevel> = Set(LogLevel.allCases)
    var component: String? = nil

    // Cached compiled regex — rebuilt when searchText/isRegex/caseSensitive changes
    private var _cachedRegex: NSRegularExpression?
    private var _cachedRegexKey: String = ""

    var isActive: Bool {
        !searchText.isEmpty
            || enabledLevels.count != LogLevel.allCases.count
            || component != nil
    }

    mutating func matches(_ entry: LogEntry) -> Bool {
        guard matchesLevelAndComponent(entry) else { return false }
        return matchesSearchText(entry)
    }

    // Level + component only. Used by find mode, where searchText marks
    // match positions rather than hiding rows.
    func matchesLevelAndComponent(_ entry: LogEntry) -> Bool {
        guard enabledLevels.contains(entry.level) else { return false }
        guard entry.level >= minimumLevel else { return false }
        if let component, entry.component != component { return false }
        return true
    }

    // Search-text only. An empty searchText matches everything.
    mutating func matchesSearchText(_ entry: LogEntry) -> Bool {
        guard !searchText.isEmpty else { return true }

        if isRegex {
            guard let regex = compiledRegex() else { return false }
            let range = NSRange(entry.message.startIndex..., in: entry.message)
            return regex.firstMatch(in: entry.message, range: range) != nil
        } else {
            let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
            return entry.message.range(of: searchText, options: options) != nil
        }
    }

    private mutating func compiledRegex() -> NSRegularExpression? {
        let key = "\(searchText)|\(caseSensitive)"
        if key == _cachedRegexKey { return _cachedRegex }
        _cachedRegexKey = key
        let options: NSRegularExpression.Options = caseSensitive ? [] : .caseInsensitive
        _cachedRegex = try? NSRegularExpression(pattern: searchText, options: options)
        return _cachedRegex
    }
}
