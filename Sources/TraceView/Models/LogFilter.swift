import Foundation

struct LogFilter: Equatable {
    var searchText: String = ""
    var isRegex: Bool = false
    var caseSensitive: Bool = false
    var minimumLevel: LogLevel = .debug
    var enabledLevels: Set<LogLevel> = Set(LogLevel.allCases)
    var component: String? = nil

    var isActive: Bool {
        !searchText.isEmpty
            || enabledLevels.count != LogLevel.allCases.count
            || component != nil
    }

    func matches(_ entry: LogEntry) -> Bool {
        // Level filter
        guard enabledLevels.contains(entry.level) else { return false }
        guard entry.level >= minimumLevel else { return false }

        // Component filter
        if let component, entry.component != component {
            return false
        }

        // Text search
        if !searchText.isEmpty {
            if isRegex {
                let options: NSRegularExpression.Options = caseSensitive ? [] : .caseInsensitive
                guard let regex = try? NSRegularExpression(pattern: searchText, options: options) else {
                    return false
                }
                let range = NSRange(entry.message.startIndex..., in: entry.message)
                return regex.firstMatch(in: entry.message, range: range) != nil
            } else {
                let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
                return entry.message.range(of: searchText, options: options) != nil
            }
        }

        return true
    }
}
