import Foundation

struct PlainTextParser: LogParser {
    let name = "Plain Text"
    let supportedExtensions: Set<String> = ["log", "txt", ""]

    func canParse(sampleLines: [String]) -> Double {
        // Fallback parser — always matches with low confidence
        0.1
    }

    // Pattern order matters: specific formats first, general last. A pattern
    // that matches too-eagerly on a wrong format would wrongly "win" against
    // a later pattern that would extract more fields. Dated-syslog's host
    // field in particular was historically a greedy \S+ — see notes below.

    // Classic BSD syslog: "MMM dd HH:mm:ss hostname process[pid]: message"
    // The optional " <Notice>" / " <Warning>" annotation appears in macOS
    // ~/Library/Logs/*.log files (CoreSimulator, many frameworks). Group 4
    // captures the level if present — otherwise `parseLevelAndComponent`
    // on the message body handles explicit `LEVEL:` prefixes.
    private static let syslogPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+(\S+)\s+(\S+?)(?:\[\d+\])?(?:\s*<(\w+)>)?:\s*(.*)"#
    )

    // Apple daemon format, common in /var/log/wifi.log and similar:
    //   "Wed Apr 22 00:40:27.253 [airport]/616 @[...] (file:line) message"
    // Captures: timestamp (with day-of-week), component, and the remainder.
    private static let appleDaemonPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\.\d+)\s+\[([^\]]+)\]/\d+\s+(.*)$"#
    )

    // Dated-syslog (e.g. /var/log/install.log):
    //   "2026-03-08 13:46:47-07 localhost Installer Progress[57]: message"
    // Host field restricted to hostname-legal chars (letters/digits/._-)
    // so it won't greedy-match "process[pid]:" when a log has no host at
    // all. [^\[]+? for the process name tolerates multi-word process names
    // like "Installer Progress" that \S+? would truncate.
    private static let datedSyslogPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}(?::?\d{2})?)?)\s+([A-Za-z0-9][A-Za-z0-9._-]*)\s+([^\[]+?)(?:\[\d+\])?(?:\s*<\w+>)?:\s*(.*)"#
    )

    // Bracketed timestamp optionally followed by a bracketed or prefix-
    // tagged level. Matches Electron / Node / LM Studio / chrome-native-
    // host / many dev-tool logs:
    //   "[2026-04-19 19:54:24.115] [info] App starting..."      (split)
    //   "[2026-04-03 11:52:48 INFO chrome-native-host] message" (combined)
    //
    // Two forms:
    //   - Split: first bracket is just the timestamp, second bracket is
    //     the level / tag.
    //   - Combined: first bracket contains timestamp + tag separated by
    //     whitespace.
    //
    // Groups:
    //   1: timestamp
    //   2: optional trailing content inside the timestamp bracket ("INFO chrome-native-host")
    //   3: optional separate bracket tag ("info")
    //   4: rest of line
    private static let bracketedTimestampPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\[(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)(?:\s+([^\]]+))?\]\s*(?:\[([^\]]+)\]\s*)?(.*)"#
    )

    // Prefix-tagged: a bracketed prefix before an ISO timestamp.
    //   "[VM] 2026-03-28 15:17:57 [info] startVM called for ..."
    // Captures: prefix (used as component), timestamp, rest (goes through
    // parseLevelAndComponent so "[info]" becomes the level).
    private static let prefixTaggedPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\[([^\]]+)\]\s+(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+(.*)"#
    )

    // logfmt (Go / Docker / many CI tools):
    //   time="2026-04-20T15:37:24-05:00" level=info msg="usernet: starting ..."
    // Level is unquoted. Message is double-quoted (most common) or unquoted.
    private static let logfmtPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^time="([^"]+)"\s+level=(\w+)\s+msg=(?:"((?:[^"\\]|\\.)*)"|(\S.*))$"#
    )

    // Timestamp-first with component: ISO-like timestamp followed by a
    // component[pid]: — the common pattern when a log has no hostname.
    //   "2026-04-23 14:32:01.812 kernel[0]: NOTICE: en0: link down"
    //   "2026-04-23 14:32:01.812 worker: processing job"
    // This runs AFTER dated-syslog so proper host+component formats still
    // win, and BEFORE plain ISO so we get the component column populated.
    private static let datedComponentPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+([^\[\s:]+)(?:\[\d+\])?:\s*(.*)"#
    )

    // Plain ISO timestamp followed by arbitrary content — the most general
    // fallback when a line just starts with a timestamp. Everything after
    // goes through parseLevelAndComponent to extract bracketed level hints.
    private static let isoPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+(.*)"#
    )

    // Captures three groups: level, optional component, message. Component
    // token is constrained to letter-initial alphanumeric/dot/underscore/
    // dash up to 30 chars to avoid swallowing paths (/path/to/file) or URLs
    // pre-`://`. The URL-scheme guard in `parseLevelAndComponent` backs
    // this up for `http`/`https`/`ftp` etc. cases that do match the token
    // regex but would produce a misleading component.
    private static let bracketLevelPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\[?(DEBUG|INFO|NOTICE|WARN(?:ING)?|ERROR|ERR|CRITICAL|FATAL|CRIT)\]?\s*:?\s*(?:([A-Za-z][A-Za-z0-9._-]{0,30}):\s+)?(.*)"#,
        options: .caseInsensitive
    )

    // Tokens that would match the component regex above but are almost
    // certainly a URL scheme introducing a URL in the message. If the
    // captured "component" matches one of these AND the remaining message
    // starts with `//`, we discard the component capture.
    private static let urlSchemeTokens: Set<String> = [
        "http", "https", "ftp", "file", "mailto", "data", "ws", "wss", "s3", "gs"
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let syslogFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // "EEE MMM d HH:mm:ss.SSS" — no year; DateFormatter fills in current year.
    private static let appleDaemonFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // Covers all dated-syslog-ish permutations seen in the wild: with/
    // without fractional seconds, with/without timezone, space or T
    // separator. The `.SSS` variant without TZ was missing before and
    // caused `2026-04-23 14:32:01.812` (common dev-log format) to parse
    // as nil — visible symptom was the timestamp column silently
    // disappearing.
    private static let datedSyslogFormatters: [DateFormatter] = {
        [
            // Space-separated (dated syslog, dev logs)
            "yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd HH:mm:ssXXX", "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSSX", "yyyy-MM-dd HH:mm:ss.SSSXXX", "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
            // T-separated (ISO-style with and without TZ)
            "yyyy-MM-dd'T'HH:mm:ssX", "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
        ].map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    // ISO8601DateFormatter variant for strings with fractional seconds is
    // kept in `isoFormatter` above. This one covers ISO strings WITHOUT
    // fractional seconds (common in logfmt, Docker) — they fail the other
    // formatter because it requires fractional seconds when configured.
    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Formats without a year in the pattern (`MMM dd HH:mm:ss`, `EEE MMM d
    /// HH:mm:ss.SSS`) cause DateFormatter to fall back to year 2000. Real
    /// macOS logs use these formats heavily, so without this fixup every
    /// BSD-syslog and Apple-daemon entry would render decades old.
    ///
    /// Fix: if the parsed year looks like a default (< 2020), rebuild the
    /// date in the current calendar year. Rollover heuristic: if that puts
    /// the result >1 day in the future, subtract a year (handles parsing
    /// a December-dated log on January 1).
    static func injectYearIfMissing(_ date: Date?, now: Date = Date()) -> Date? {
        guard let date else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: date)
        guard year < 2020 else { return date }

        let currentYear = cal.component(.year, from: now)
        var comps = cal.dateComponents([.month, .day, .hour, .minute, .second, .nanosecond], from: date)
        comps.year = currentYear
        guard var candidate = cal.date(from: comps) else { return date }

        // 1-day tolerance handles timezone skew without accidentally
        // kicking a legitimately-recent log back a year.
        if candidate.timeIntervalSince(now) > 86_400 {
            comps.year = currentYear - 1
            candidate = cal.date(from: comps) ?? candidate
        }
        return candidate
    }

    private static func parseDatedSyslog(_ s: String) -> Date? {
        // Try both ISO8601DateFormatter variants first (fast and lenient
        // for well-formed ISO strings). Fall back to per-format
        // DateFormatter list for dated-syslog permutations.
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFormatterNoFraction.date(from: s) { return d }
        for f in datedSyslogFormatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let nsLine = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        // 1. Classic BSD syslog. If a <Level> annotation is present
        //    (CoreSimulator-style), use it directly. Otherwise route the
        //    message through parseLevelAndComponent to catch explicit
        //    prefixes, falling back to keyword detection.
        if let regex = Self.syslogPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 6 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let component = nsLine.substring(with: match.range(at: 3))
            let levelTag: String? = match.range(at: 4).location != NSNotFound
                ? nsLine.substring(with: match.range(at: 4))
                : nil
            let rawMessage = nsLine.substring(with: match.range(at: 5))
            let level: LogLevel
            let message: String
            if let lvl = levelTag.flatMap(recognizedLevel) {
                level = lvl
                message = rawMessage
            } else {
                let (l, m, _) = parseLevelAndComponent(from: rawMessage)
                level = l
                message = m
            }
            let timestamp = Self.injectYearIfMissing(Self.syslogFormatter.date(from: timeStr))
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 2. Apple daemon (wifi.log, airportd)
        if let regex = Self.appleDaemonPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 4 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let component = nsLine.substring(with: match.range(at: 2))
            let message = nsLine.substring(with: match.range(at: 3))
            let timestamp = Self.injectYearIfMissing(Self.appleDaemonFormatter.date(from: timeStr))
            let level = LevelDetector.detect(in: message)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 3. Dated syslog (install.log and many /var/log/*.log). Host is
        //    discarded (no column for it). Route the extracted message
        //    through parseLevelAndComponent so an explicit `NOTICE:` /
        //    `[INFO]` prefix is consumed as the level.
        if let regex = Self.datedSyslogPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 5 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let component = nsLine.substring(with: match.range(at: 3))
                .trimmingCharacters(in: .whitespaces)
            let rawMessage = nsLine.substring(with: match.range(at: 4))
            let (level, message, _) = parseLevelAndComponent(from: rawMessage)
            let timestamp = Self.parseDatedSyslog(timeStr)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 4. Bracketed timestamp with optional bracketed level (LM Studio,
        //    Electron, chrome-native-host, many dev-tool logs). The tag
        //    can live inside the timestamp bracket (combined form) or in
        //    a separate bracket (split form) — try both.
        if let regex = Self.bracketedTimestampPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 5 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let innerTag: String? = match.range(at: 2).location != NSNotFound
                ? nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                : nil
            let separateTag: String? = match.range(at: 3).location != NSNotFound
                ? nsLine.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                : nil
            let rest = nsLine.substring(with: match.range(at: 4))
            let timestamp = Self.parseDatedSyslog(timeStr)
            let tag = innerTag ?? separateTag
            let (level, component) = interpretBracketTag(tag)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level ?? LevelDetector.detect(in: rest),
                message: rest, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 5. Prefix-tagged: "[VM] 2026-03-28 15:17:57 [info] message"
        if let regex = Self.prefixTaggedPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 4 {
            let prefix = nsLine.substring(with: match.range(at: 1))
            let timeStr = nsLine.substring(with: match.range(at: 2))
            let rest = nsLine.substring(with: match.range(at: 3))
            let timestamp = Self.parseDatedSyslog(timeStr)
            let (innerLevel, innerMessage, _) = parseLevelAndComponent(from: rest)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: innerLevel,
                message: innerMessage, component: prefix,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 6. logfmt (Go/Docker/CI): time="..." level=info msg="..."
        if let regex = Self.logfmtPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 5 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let levelStr = nsLine.substring(with: match.range(at: 2))
            // msg can be quoted (group 3) or unquoted (group 4)
            let message: String
            if match.range(at: 3).location != NSNotFound {
                message = nsLine.substring(with: match.range(at: 3))
                    .replacingOccurrences(of: #"\""#, with: "\"")
            } else if match.range(at: 4).location != NSNotFound {
                message = nsLine.substring(with: match.range(at: 4))
            } else {
                message = ""
            }
            let timestamp = Self.parseDatedSyslog(timeStr)
                ?? Self.isoFormatter.date(from: timeStr)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: parseLevel(levelStr),
                message: message, component: nil,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 7. ISO timestamp + component[pid]: (no hostname). Runs before
        //    the general ISO fallback so we populate the Component column.
        if let regex = Self.datedComponentPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 4 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let component = nsLine.substring(with: match.range(at: 2))
            let rest = nsLine.substring(with: match.range(at: 3))
            let timestamp = Self.parseDatedSyslog(timeStr)
            let (level, message, _) = parseLevelAndComponent(from: rest)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 8. Plain ISO — anything-timestamp-prefixed fallback.
        if let regex = Self.isoPattern,
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           match.numberOfRanges >= 3 {
            let timeStr = nsLine.substring(with: match.range(at: 1))
            let rest = nsLine.substring(with: match.range(at: 2))
            let timestamp = Self.isoFormatter.date(from: timeStr)
                ?? Self.parseDatedSyslog(timeStr)
            let (level, message, component) = parseLevelAndComponent(from: rest)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: timestamp, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 9. Bracketed level prefix only (no timestamp). Uses the same
        //    parseLevelAndComponent path as the timestamped branches so
        //    the optional `component:` and URL-scheme guard behave
        //    consistently.
        if let regex = Self.bracketLevelPattern,
           regex.firstMatch(in: trimmed, range: fullRange) != nil {
            let (level, message, component) = parseLevelAndComponent(from: trimmed)
            return LogEntry(
                id: entryID, lineNumber: lineNumber,
                timestamp: nil, level: level,
                message: message, component: component,
                threadID: nil, source: nil, rawLine: line
            )
        }

        // 10. Bare text fallback
        return LogEntry(
            id: entryID, lineNumber: lineNumber,
            timestamp: nil, level: LevelDetector.detect(in: trimmed),
            message: trimmed, component: nil,
            threadID: nil, source: nil, rawLine: line
        )
    }

    // MARK: - Helpers

    /// Interpret the contents of a bracketed tag after a bracketed
    /// timestamp. The tag may be just a level ("info"), a level + component
    /// ("INFO chrome-native-host"), or a component alone. Returns
    /// (level, component) — either may be nil if not detected.
    private func interpretBracketTag(_ tag: String?) -> (LogLevel?, String?) {
        guard let tag, !tag.isEmpty else { return (nil, nil) }
        let parts = tag.split(separator: " ", omittingEmptySubsequences: true)
        // Single token: treat as level if recognized, else as component.
        if parts.count == 1 {
            if let lvl = recognizedLevel(String(parts[0])) {
                return (lvl, nil)
            }
            return (nil, String(parts[0]))
        }
        // First token looks like a level → level + rest-as-component.
        if let lvl = recognizedLevel(String(parts[0])) {
            let component = parts.dropFirst().joined(separator: " ")
            return (lvl, component.isEmpty ? nil : component)
        }
        // No level found → whole tag is the component.
        return (nil, tag)
    }

    private func recognizedLevel(_ s: String) -> LogLevel? {
        switch s.uppercased() {
        case "DEBUG": return .debug
        case "INFO": return .info
        case "NOTICE": return .notice
        case "WARN", "WARNING": return .warning
        case "ERROR", "ERR": return .error
        case "CRITICAL", "FATAL", "CRIT": return .critical
        default: return nil
        }
    }

    private func parseLevelAndComponent(from text: String) -> (LogLevel, String, String?) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if let regex = Self.bracketLevelPattern,
           let match = regex.firstMatch(in: text, range: fullRange),
           match.numberOfRanges >= 4 {
            let levelStr = nsText.substring(with: match.range(at: 1))
            let compRange = match.range(at: 2)
            var component: String? = compRange.location != NSNotFound
                ? nsText.substring(with: compRange)
                : nil
            let message = nsText.substring(with: match.range(at: 3))

            // URL-scheme guard: "[INFO] http://example.com failed" should
            // not produce component="http". If the extracted component is a
            // known URL scheme and the message begins with "//", reconstitute
            // the full URL as the message.
            if let c = component, Self.urlSchemeTokens.contains(c.lowercased()),
               message.hasPrefix("//") {
                component = nil
                return (parseLevel(levelStr), "\(c)://\(message.dropFirst(2))", nil)
            }

            return (parseLevel(levelStr), message, component)
        }
        return (LevelDetector.detect(in: text), text, nil)
    }

    private func parseLevel(_ str: String) -> LogLevel {
        recognizedLevel(str) ?? .info
    }
}
