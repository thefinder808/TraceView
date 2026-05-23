import Foundation

enum LogLevel: Int, CaseIterable, Comparable, Codable, Identifiable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4
    case critical = 5
    case unknown = -1

    var id: Int { rawValue }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .warning: return "Warning"
        case .error: return "Error"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    var shortName: String {
        switch self {
        case .debug: return "DBG"
        case .info: return "INFO"
        case .notice: return "NOT"
        case .warning: return "WARN"
        case .error: return "ERR"
        case .critical: return "CRT"
        case .unknown: return "???"
        }
    }

    var systemImage: String {
        switch self {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .notice: return "bell"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        case .critical: return "flame"
        case .unknown: return "questionmark.circle"
        }
    }
}
