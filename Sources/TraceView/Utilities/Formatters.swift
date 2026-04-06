import Foundation

enum Formatters {
    /// Format bytes to human-readable: "48.0 GB", "512 MB"
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unitIndex])
    }

    /// Format integer with locale grouping: "1,234"
    static func formatCount(_ count: Int) -> String {
        countFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// Format timestamp for log display: "10:23:01.442"
    static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Format full date+time: "2026-04-06 10:23:01"
    static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    // MARK: - Cached Formatters

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
