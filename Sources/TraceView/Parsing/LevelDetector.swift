import Foundation

enum LevelDetector {
    private static let errorPatterns: [String] = [
        "\\berror\\b", "\\bfailed\\b", "\\bfailure\\b", "\\bfatal\\b",
        "\\bcrash(ed)?\\b", "\\bpanic\\b", "\\babort(ed)?\\b",
        "\\bexception\\b", "\\bcritical\\b", "\\bsevere\\b"
    ]

    private static let warningPatterns: [String] = [
        "\\bwarn(ing)?\\b", "\\bcaution\\b", "\\bdeprecated\\b",
        "\\bretrying\\b", "\\btimeout\\b", "\\btimed out\\b"
    ]

    private static let debugPatterns: [String] = [
        "\\bdebug\\b", "\\btrace\\b", "\\bverbose\\b"
    ]

    private static let compiledError: [NSRegularExpression] = {
        errorPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private static let compiledWarning: [NSRegularExpression] = {
        warningPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private static let compiledDebug: [NSRegularExpression] = {
        debugPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    static func detect(in message: String) -> LogLevel {
        let range = NSRange(message.startIndex..., in: message)

        for regex in compiledError {
            if regex.firstMatch(in: message, range: range) != nil {
                return .error
            }
        }

        for regex in compiledWarning {
            if regex.firstMatch(in: message, range: range) != nil {
                return .warning
            }
        }

        for regex in compiledDebug {
            if regex.firstMatch(in: message, range: range) != nil {
                return .debug
            }
        }

        return .info
    }
}
