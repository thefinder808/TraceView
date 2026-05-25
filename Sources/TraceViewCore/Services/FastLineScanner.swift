import Darwin
import Foundation

/// Byte-level analogues of `LevelDetector` keyword search and
/// `PlainTextParser` / `SCCMLogParser` timestamp extraction. Designed for
/// use inside `LogIndex.build`'s per-line pass.
///
/// Performance budget: ~50-100 ns per line on M-series. No String
/// creation, no DateFormatter, no allocations. The output is intended to
/// match `parser.parse(line:).level` and `parser.parse(line:).timestamp`
/// for the common BSD-syslog / dated-syslog / SCCM-CMTrace cases. Tests
/// in `LogIndexExtendedFieldsTests` document the equivalence boundary.
///
/// Sentinel encoding for `[UInt8]` level arrays: `FastLevelScanner.unknown`
/// (0xFF) represents "not detected" so the in-memory `LogLevel.unknown =
/// -1` survives a UInt8 round-trip. All other values are
/// `UInt8(LogLevel.rawValue)` for raw values 0...5.
enum FastLevelScanner {
    static let unknown: UInt8 = 0xFF

    /// Encode a `LogLevel` to its single-byte storage form.
    static func encode(_ level: LogLevel) -> UInt8 {
        level == .unknown ? unknown : UInt8(level.rawValue)
    }

    /// Decode a stored byte back to `LogLevel`.
    static func decode(_ byte: UInt8) -> LogLevel {
        if byte == unknown { return .unknown }
        return LogLevel(rawValue: Int(byte)) ?? .unknown
    }

    /// Detect a level for the given byte range. `range` is interpreted as
    /// absolute byte offsets into `buf` — `range.lowerBound` is the start
    /// of the line, `range.upperBound` is exclusive (the position of the
    /// newline, or end-of-buffer for the final line).
    static func detect(in buf: UnsafeRawBufferPointer, range: Range<Int>, kind: ParserKind) -> UInt8 {
        guard range.lowerBound < range.upperBound,
              range.upperBound <= buf.count,
              let base = buf.baseAddress else {
            return encode(.info)
        }

        switch kind {
        case .sccm:
            if let lvl = detectSCCMType(base: base, range: range) {
                return encode(lvl)
            }
            // SCCM fallback parser uses LevelDetector — mirror that.
            return encode(scanKeywords(base: base, range: range))

        case .plainText:
            return encode(detectPlainText(base: base, range: range))

        case .csv:
            // CSV's `findLevel` first tries column equality against a
            // closed token set, then falls back to LevelDetector. The
            // column-equality check requires parsing the row, which we
            // skip — keyword scan over the whole line is the next-best
            // approximation.
            return encode(scanKeywords(base: base, range: range))

        case .other:
            return encode(scanKeywords(base: base, range: range))
        }
    }

    // MARK: - PlainText message-aware detection

    /// Mirror of PlainTextParser's BSD-syslog branch: extract `rawMessage`
    /// at the `: ` separator, then route through `parseLevelAndComponent`
    /// (bracket-level prefix → LevelDetector keyword scan).
    private static func detectPlainText(base: UnsafeRawPointer, range: Range<Int>) -> LogLevel {
        // Find first `: ` (colon-space) in the line. In BSD-syslog the
        // timestamp's colons are followed by digits, not spaces, so the
        // first colon-space pair is always the message-body separator.
        // Dated-syslog timestamps include a colon in the TZ field
        // (`+02:00`) but it's followed by a digit too — safe.
        let colonPos = findColonSpace(base: base, range: range)

        // Before-colon scan for `<Level>` annotation (BSD-syslog regex's
        // group 4 captures this slot).
        let prefixEnd = colonPos ?? range.upperBound
        if colonPos != nil,
           let lvl = detectAngleBracketLevel(base: base, range: range.lowerBound..<prefixEnd) {
            return lvl
        }

        // Message body — start after `: ` if found, otherwise the whole
        // line. parseLevelAndComponent runs against this body.
        let bodyStart = colonPos.map { $0 + 2 } ?? range.lowerBound
        guard bodyStart < range.upperBound else { return .info }
        let bodyRange = bodyStart..<range.upperBound

        if let lvl = detectBracketLevelPrefix(base: base, range: bodyRange) {
            return lvl
        }
        return scanKeywords(base: base, range: bodyRange)
    }

    /// Locate the first `: ` (colon-space) within `range`. Returns the
    /// absolute byte offset of the colon, or nil if no such pair exists.
    private static func findColonSpace(base: UnsafeRawPointer, range: Range<Int>) -> Int? {
        let haystack = base.advanced(by: range.lowerBound)
        let haystackLen = range.upperBound - range.lowerBound
        let needle: StaticString = ": "
        guard let found = memmem(haystack, haystackLen, needle.utf8Start, 2) else {
            return nil
        }
        return base.distance(to: UnsafeRawPointer(found))
    }

    // MARK: - SCCM `type="N"` extraction

    /// Find `type="N"` somewhere in the line and decode N as a CMTrace
    /// severity (1=info, 2=warning, 3=error). Returns nil on no match.
    private static func detectSCCMType(base: UnsafeRawPointer, range: Range<Int>) -> LogLevel? {
        let needle: StaticString = "type=\""
        let needleLen = 6
        guard let p = findNeedle(base: base, range: range, needle: needle, needleLen: needleLen) else {
            return nil
        }
        let digitPos = p + needleLen
        guard digitPos < range.upperBound else { return nil }
        let digit = base.load(fromByteOffset: digitPos, as: UInt8.self)
        switch digit {
        case 0x31: return .info     // '1'
        case 0x32: return .warning  // '2'
        case 0x33: return .error    // '3'
        default: return nil
        }
    }

    // MARK: - BSD-syslog `<Level>` annotation

    /// Look for a `<Word>` annotation within `range` (typically scoped to
    /// the BSD-syslog prefix before the message-body colon). Recognized
    /// words: Debug, Info, Notice, Warn, Warning, Err, Error, Crit,
    /// Critical, Fatal. Matches `PlainTextParser.recognizedLevel` case-
    /// insensitively.
    private static func detectAngleBracketLevel(base: UnsafeRawPointer, range: Range<Int>) -> LogLevel? {
        var i = range.lowerBound
        while i < range.upperBound {
            let b = base.load(fromByteOffset: i, as: UInt8.self)
            if b == 0x3C {  // '<'
                if let result = matchAngleBracketTag(base: base, start: i, end: range.upperBound) {
                    return result
                }
            }
            i += 1
        }
        return nil
    }

    private static func matchAngleBracketTag(base: UnsafeRawPointer, start: Int, end: Int) -> LogLevel? {
        // Start points at '<'. Read until '>' or end-of-window. The tag
        // body must be 3...10 bytes long and match one of the recognized
        // level words exactly (case-insensitive).
        var j = start + 1
        let limit = min(end, start + 12)
        while j < limit {
            let b = base.load(fromByteOffset: j, as: UInt8.self)
            if b == 0x3E {  // '>'
                let len = j - start - 1
                if len >= 3 && len <= 10 {
                    return classifyWord(base: base, start: start + 1, length: len)
                }
                return nil
            }
            j += 1
        }
        return nil
    }

    // MARK: - `[LEVEL]` / `LEVEL:` prefix

    /// Mirror of `parseLevelAndComponent`'s `bracketLevelPattern`. The
    /// regex is:
    ///   `^\[?(LEVEL)\]?\s*:?\s*(?:component:\s+)?(.*)`
    /// All terminators after the level word are optional. Effectively
    /// any line whose first non-whitespace word (optionally bracketed) is
    /// a recognized level, terminated by a word boundary, returns that
    /// level. Used on the message-body region for BSD-syslog lines, or
    /// the whole line for bracket-level-only lines.
    private static func detectBracketLevelPrefix(base: UnsafeRawPointer, range: Range<Int>) -> LogLevel? {
        // Skip leading whitespace.
        var i = range.lowerBound
        while i < range.upperBound {
            let b = base.load(fromByteOffset: i, as: UInt8.self)
            if b != 0x20 && b != 0x09 { break }
            i += 1
        }
        guard i < range.upperBound else { return nil }

        let firstByte = base.load(fromByteOffset: i, as: UInt8.self)
        var tagStart = i
        if firstByte == 0x5B {  // '['
            tagStart = i + 1
        }
        // Read alphabetic word (level names are all alphabetic).
        var j = tagStart
        let cap = min(range.upperBound, tagStart + 10)
        while j < cap {
            let b = base.load(fromByteOffset: j, as: UInt8.self)
            if !isAlpha(b) { break }
            j += 1
        }
        let len = j - tagStart
        guard len >= 3 else { return nil }

        let level = classifyWord(base: base, start: tagStart, length: len)
        guard let level else { return nil }

        // Right-side word boundary required: the byte after the level
        // word must be a non-word byte (whitespace, punctuation, `]`,
        // `:`, end-of-line). This rejects matches inside longer words
        // like "informational" or "errortype".
        if j >= range.upperBound { return level }
        let term = base.load(fromByteOffset: j, as: UInt8.self)
        return isWordByte(term) ? nil : level
    }

    // MARK: - Keyword scan (LevelDetector equivalent)

    /// Mirror of `LevelDetector.detect`. Scans the line for case-
    /// insensitive word-boundary matches against the priority-ordered
    /// keyword tables: error first, warning second, debug third, else
    /// info. Each scan walks the line bytes once and short-circuits on
    /// the first match at that priority.
    private static func scanKeywords(base: UnsafeRawPointer, range: Range<Int>) -> LogLevel {
        if firstKeywordMatch(base: base, range: range, table: errorKeywords) {
            return .error
        }
        if firstKeywordMatch(base: base, range: range, table: warningKeywords) {
            return .warning
        }
        if firstKeywordMatch(base: base, range: range, table: debugKeywords) {
            return .debug
        }
        return .info
    }

    /// Walk `range` byte by byte. At each position with a left-side word
    /// boundary, check every keyword in the table for a case-insensitive
    /// match terminated by a right-side word boundary. Return true on
    /// first hit.
    private static func firstKeywordMatch(
        base: UnsafeRawPointer,
        range: Range<Int>,
        table: [[UInt8]]
    ) -> Bool {
        let end = range.upperBound
        var i = range.lowerBound
        while i < end {
            // Left-side word boundary: previous byte is not a word char,
            // or we're at the start of the line.
            let leftOK: Bool
            if i == range.lowerBound {
                leftOK = true
            } else {
                let prev = base.load(fromByteOffset: i - 1, as: UInt8.self)
                leftOK = !isWordByte(prev)
            }
            if leftOK {
                // Quick prefilter: only consider positions whose current
                // byte is alphabetic. Non-letters can't start any of our
                // keywords.
                let cur = base.load(fromByteOffset: i, as: UInt8.self)
                if isAlpha(cur) {
                    for kw in table {
                        if matchKeywordAt(base: base, pos: i, end: end, keyword: kw) {
                            return true
                        }
                    }
                }
            }
            i += 1
        }
        return false
    }

    /// Check if `keyword` (uppercase ASCII) matches at `pos` case-
    /// insensitively, ending on a word boundary.
    @inline(__always)
    private static func matchKeywordAt(
        base: UnsafeRawPointer,
        pos: Int,
        end: Int,
        keyword: [UInt8]
    ) -> Bool {
        let kwLen = keyword.count
        if pos + kwLen > end { return false }
        for k in 0..<kwLen {
            let line = base.load(fromByteOffset: pos + k, as: UInt8.self)
            // Uppercase-fold any ASCII letter; non-letters compare as-is.
            let folded = (line >= 0x61 && line <= 0x7A) ? line &- 0x20 : line
            if folded != keyword[k] { return false }
        }
        // Right-side word boundary.
        if pos + kwLen == end { return true }
        let next = base.load(fromByteOffset: pos + kwLen, as: UInt8.self)
        return !isWordByte(next)
    }

    // MARK: - Word classification

    /// Classify a `length`-byte word starting at `start` against the
    /// recognized-level vocabulary. Mirrors
    /// `PlainTextParser.recognizedLevel` (case-insensitive ASCII).
    private static func classifyWord(base: UnsafeRawPointer, start: Int, length: Int) -> LogLevel? {
        for (kw, lvl) in recognizedLevelWords {
            if kw.count == length && bytesEqualIgnoringCase(base: base, start: start, against: kw) {
                return lvl
            }
        }
        return nil
    }

    @inline(__always)
    private static func bytesEqualIgnoringCase(
        base: UnsafeRawPointer,
        start: Int,
        against keyword: [UInt8]
    ) -> Bool {
        for i in 0..<keyword.count {
            let b = base.load(fromByteOffset: start + i, as: UInt8.self)
            let folded = (b >= 0x61 && b <= 0x7A) ? b &- 0x20 : b
            if folded != keyword[i] { return false }
        }
        return true
    }

    // MARK: - Byte classifiers

    @inline(__always) private static func isAlpha(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    @inline(__always) private static func isDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always) private static func isWordByte(_ b: UInt8) -> Bool {
        // Matches regex \w semantics: [A-Za-z0-9_]
        isAlpha(b) || isDigit(b) || b == 0x5F
    }

    // MARK: - Keyword tables (uppercase ASCII)

    private static let errorKeywords: [[UInt8]] = [
        ascii("ERROR"), ascii("FAILED"), ascii("FAILURE"), ascii("FATAL"),
        ascii("CRASH"), ascii("CRASHED"),
        ascii("PANIC"), ascii("ABORT"), ascii("ABORTED"),
        ascii("EXCEPTION"), ascii("CRITICAL"), ascii("SEVERE"),
    ]

    private static let warningKeywords: [[UInt8]] = [
        ascii("WARN"), ascii("WARNING"),
        ascii("CAUTION"), ascii("DEPRECATED"),
        ascii("RETRYING"), ascii("TIMEOUT"),
        // "timed out" is two words; the regex anchors on \b which permits
        // the space. Approximate by matching just "TIMED" here — false
        // positives on lines containing "timed" alone are rare.
        ascii("TIMED"),
    ]

    private static let debugKeywords: [[UInt8]] = [
        ascii("DEBUG"), ascii("TRACE"), ascii("VERBOSE"),
    ]

    /// `PlainTextParser.recognizedLevel`'s exact vocabulary, uppercase.
    private static let recognizedLevelWords: [(keyword: [UInt8], level: LogLevel)] = [
        (ascii("DEBUG"), .debug),
        (ascii("INFO"), .info),
        (ascii("NOTICE"), .notice),
        (ascii("WARN"), .warning),
        (ascii("WARNING"), .warning),
        (ascii("ERR"), .error),
        (ascii("ERROR"), .error),
        (ascii("CRIT"), .critical),
        (ascii("CRITICAL"), .critical),
        (ascii("FATAL"), .critical),
    ]

    @inline(__always)
    private static func ascii(_ s: StaticString) -> [UInt8] {
        precondition(s.hasPointerRepresentation)
        let buf = UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount)
        return Array(buf)
    }

    // MARK: - Needle search helper

    /// Locate the first occurrence of `needle` (ASCII) within `range`.
    /// Wraps `memmem`. Returns absolute byte offset or nil.
    private static func findNeedle(
        base: UnsafeRawPointer,
        range: Range<Int>,
        needle: StaticString,
        needleLen: Int
    ) -> Int? {
        let haystack = base.advanced(by: range.lowerBound)
        let haystackLen = range.upperBound - range.lowerBound
        guard let found = memmem(haystack, haystackLen, needle.utf8Start, needleLen) else {
            return nil
        }
        return base.distance(to: UnsafeRawPointer(found))
    }
}

/// Byte-level timestamp parser for the common log-format prefixes.
///
/// Produces seconds-since-1970 (UTC) as `Double`, or `Double.nan` when no
/// recognized format matches. Calling code stores the result in the
/// `LogIndex.timestamps` parallel array; `nan` round-trips to
/// `LogEntry.timestamp == nil` semantics at read time.
///
/// Formats covered in PR1:
/// - PlainText: BSD-syslog (`MMM dd HH:mm:ss`) at offset 0, dated-syslog
///   (`YYYY-MM-DD HH:MM:SS[.fff][±HH:MM]`) at offset 0.
/// - SCCM: `time="HH:mm:ss.fff[±offset]" date="MM-DD-YYYY"` embedded.
/// - CSV / other: returns `.nan` (column-driven, not addressable without
///   row parsing).
enum FastTimestampScanner {
    /// Resolved "now" used for BSD-syslog year inference. Computed once
    /// per `LogIndex.build` and passed in so all rows reference the same
    /// calendar year.
    struct YearContext {
        let currentYear: Int
        let now: Double  // seconds since 1970

        static let `default` = YearContext(currentYear: Calendar(identifier: .gregorian).component(.year, from: Date()), now: Date().timeIntervalSince1970)
    }

    /// Parse the timestamp at the head of (or embedded in) the line range.
    /// Returns seconds-since-1970 as `Double`, or `.nan` on no match.
    static func parse(
        in buf: UnsafeRawBufferPointer,
        range: Range<Int>,
        kind: ParserKind,
        yearContext: YearContext
    ) -> Double {
        guard range.lowerBound < range.upperBound,
              range.upperBound <= buf.count,
              let base = buf.baseAddress else {
            return .nan
        }

        switch kind {
        case .plainText:
            if let t = parseBSDSyslog(base: base, range: range, ctx: yearContext) {
                return t
            }
            if let t = parseDatedSyslog(base: base, range: range) {
                return t
            }
            return .nan

        case .sccm:
            return parseSCCM(base: base, range: range) ?? .nan

        case .csv, .other:
            return .nan
        }
    }

    // MARK: - BSD-syslog ("Apr 22 10:30:15")

    /// Match `MMM dd HH:mm:ss` at line head. 15 bytes total. Day may be
    /// space-padded (` 1`) or zero-padded (`01`).
    private static func parseBSDSyslog(
        base: UnsafeRawPointer,
        range: Range<Int>,
        ctx: YearContext
    ) -> Double? {
        let start = range.lowerBound
        guard range.upperBound - start >= 15 else { return nil }

        let month = parseMonthAbbrev(base: base, at: start)
        guard let month else { return nil }
        guard base.load(fromByteOffset: start + 3, as: UInt8.self) == 0x20 else { return nil }

        // Day: byte 4 may be space (" 8") or digit ("18"); byte 5 must be digit.
        let day0 = base.load(fromByteOffset: start + 4, as: UInt8.self)
        let day1 = base.load(fromByteOffset: start + 5, as: UInt8.self)
        let dayHi: Int
        if day0 == 0x20 {
            dayHi = 0
        } else if day0 >= 0x30 && day0 <= 0x39 {
            dayHi = Int(day0 - 0x30)
        } else {
            return nil
        }
        guard day1 >= 0x30 && day1 <= 0x39 else { return nil }
        let day = dayHi * 10 + Int(day1 - 0x30)
        guard day >= 1 && day <= 31 else { return nil }

        guard base.load(fromByteOffset: start + 6, as: UInt8.self) == 0x20 else { return nil }

        guard let hms = parseHHMMSS(base: base, at: start + 7) else { return nil }

        // Year inference: start with current year, walk back one year if
        // the resulting timestamp would be >1 day in the future (matches
        // PlainTextParser.injectYearIfMissing).
        let yearAttempt = ctx.currentYear
        if let t = epochSeconds(year: yearAttempt, month: month, day: day,
                                hour: hms.h, minute: hms.m, second: hms.s,
                                fractional: 0, tzOffsetSeconds: nil) {
            if t - ctx.now > 86_400 {
                return epochSeconds(year: yearAttempt - 1, month: month, day: day,
                                    hour: hms.h, minute: hms.m, second: hms.s,
                                    fractional: 0, tzOffsetSeconds: nil) ?? t
            }
            return t
        }
        return nil
    }

    // MARK: - Dated-syslog ("2026-03-08 13:46:47.123+0100")

    /// Match `YYYY-MM-DD[ T]HH:mm:ss[.fff][TZ]` at line head. Returns
    /// nil if the prefix doesn't conform.
    private static func parseDatedSyslog(
        base: UnsafeRawPointer,
        range: Range<Int>
    ) -> Double? {
        let start = range.lowerBound
        guard range.upperBound - start >= 19 else { return nil }

        guard let year = parseFixedDigits(base: base, at: start, count: 4) else { return nil }
        guard base.load(fromByteOffset: start + 4, as: UInt8.self) == 0x2D else { return nil }
        guard let month = parseFixedDigits(base: base, at: start + 5, count: 2),
              month >= 1 && month <= 12 else { return nil }
        guard base.load(fromByteOffset: start + 7, as: UInt8.self) == 0x2D else { return nil }
        guard let day = parseFixedDigits(base: base, at: start + 8, count: 2),
              day >= 1 && day <= 31 else { return nil }

        let sep = base.load(fromByteOffset: start + 10, as: UInt8.self)
        guard sep == 0x20 || sep == 0x54 else { return nil }  // ' ' or 'T'

        guard let hms = parseHHMMSS(base: base, at: start + 11) else { return nil }

        var cursor = start + 19
        var fractional: Double = 0
        if cursor < range.upperBound {
            let b = base.load(fromByteOffset: cursor, as: UInt8.self)
            if b == 0x2E {  // '.'
                cursor += 1
                var digits = 0
                var accum = 0
                while cursor < range.upperBound && digits < 9 {
                    let d = base.load(fromByteOffset: cursor, as: UInt8.self)
                    if d < 0x30 || d > 0x39 { break }
                    accum = accum * 10 + Int(d - 0x30)
                    digits += 1
                    cursor += 1
                }
                if digits > 0 {
                    fractional = Double(accum) / pow(10.0, Double(digits))
                }
            }
        }

        var tzOffsetSeconds: Int? = nil
        if cursor < range.upperBound {
            let b = base.load(fromByteOffset: cursor, as: UInt8.self)
            if b == 0x5A {  // 'Z'
                tzOffsetSeconds = 0
                cursor += 1
            } else if b == 0x2B || b == 0x2D {  // '+' / '-'
                let sign = (b == 0x2B) ? 1 : -1
                cursor += 1
                guard let hh = parseFixedDigits(base: base, at: cursor, count: 2) else {
                    return epochSeconds(year: year, month: month, day: day,
                                        hour: hms.h, minute: hms.m, second: hms.s,
                                        fractional: fractional, tzOffsetSeconds: nil)
                }
                cursor += 2
                var mm = 0
                if cursor < range.upperBound {
                    let nb = base.load(fromByteOffset: cursor, as: UInt8.self)
                    if nb == 0x3A {  // ':' in "+01:00"
                        cursor += 1
                    }
                    if cursor + 2 <= range.upperBound,
                       let parsedMM = parseFixedDigits(base: base, at: cursor, count: 2) {
                        mm = parsedMM
                        cursor += 2
                    }
                }
                tzOffsetSeconds = sign * (hh * 3600 + mm * 60)
            }
        }

        return epochSeconds(year: year, month: month, day: day,
                            hour: hms.h, minute: hms.m, second: hms.s,
                            fractional: fractional, tzOffsetSeconds: tzOffsetSeconds)
    }

    // MARK: - SCCM (`time="..." date="..."` embedded)

    private static func parseSCCM(
        base: UnsafeRawPointer,
        range: Range<Int>
    ) -> Double? {
        // Locate `time="`
        let timeNeedle: StaticString = "time=\""
        let timeLen = 6
        let dateNeedle: StaticString = "date=\""
        let dateLen = 6

        let haystack = base.advanced(by: range.lowerBound)
        let haystackLen = range.upperBound - range.lowerBound

        guard let tPtr = memmem(haystack, haystackLen, timeNeedle.utf8Start, timeLen) else {
            return nil
        }
        guard let dPtr = memmem(haystack, haystackLen, dateNeedle.utf8Start, dateLen) else {
            return nil
        }

        let timeStart = base.distance(to: UnsafeRawPointer(tPtr)) + timeLen
        let dateStart = base.distance(to: UnsafeRawPointer(dPtr)) + dateLen

        // Time: HH:mm:ss(.fff)? then optional [+-]offset, terminated by '"'.
        guard timeStart + 8 <= range.upperBound,
              let hms = parseHHMMSS(base: base, at: timeStart) else { return nil }
        var cursor = timeStart + 8
        var fractional: Double = 0
        if cursor < range.upperBound,
           base.load(fromByteOffset: cursor, as: UInt8.self) == 0x2E {
            cursor += 1
            var digits = 0
            var accum = 0
            while cursor < range.upperBound && digits < 9 {
                let d = base.load(fromByteOffset: cursor, as: UInt8.self)
                if d < 0x30 || d > 0x39 { break }
                accum = accum * 10 + Int(d - 0x30)
                digits += 1
                cursor += 1
            }
            if digits > 0 {
                fractional = Double(accum) / pow(10.0, Double(digits))
            }
        }
        // SCCM ignores its `+offset` suffix — `parseDateTime` strips it
        // via regex before formatting. Mirror that: drop anything after
        // the fractional digits.

        // Date: MM-dd-yyyy
        guard dateStart + 10 <= range.upperBound,
              let month = parseFixedDigits(base: base, at: dateStart, count: 2),
              base.load(fromByteOffset: dateStart + 2, as: UInt8.self) == 0x2D,
              let day = parseFixedDigits(base: base, at: dateStart + 3, count: 2),
              base.load(fromByteOffset: dateStart + 5, as: UInt8.self) == 0x2D,
              let year = parseFixedDigits(base: base, at: dateStart + 6, count: 4) else {
            return nil
        }

        return epochSeconds(year: year, month: month, day: day,
                            hour: hms.h, minute: hms.m, second: hms.s,
                            fractional: fractional, tzOffsetSeconds: nil)
    }

    // MARK: - Common parsers

    @inline(__always)
    private static func parseHHMMSS(base: UnsafeRawPointer, at pos: Int) -> (h: Int, m: Int, s: Int)? {
        guard let h = parseFixedDigits(base: base, at: pos, count: 2),
              h >= 0 && h <= 23,
              base.load(fromByteOffset: pos + 2, as: UInt8.self) == 0x3A,
              let m = parseFixedDigits(base: base, at: pos + 3, count: 2),
              m >= 0 && m <= 59,
              base.load(fromByteOffset: pos + 5, as: UInt8.self) == 0x3A,
              let s = parseFixedDigits(base: base, at: pos + 6, count: 2),
              s >= 0 && s <= 60 else {
            return nil
        }
        return (h, m, s)
    }

    @inline(__always)
    private static func parseFixedDigits(base: UnsafeRawPointer, at pos: Int, count: Int) -> Int? {
        var result = 0
        for i in 0..<count {
            let b = base.load(fromByteOffset: pos + i, as: UInt8.self)
            if b < 0x30 || b > 0x39 { return nil }
            result = result * 10 + Int(b - 0x30)
        }
        return result
    }

    @inline(__always)
    private static func parseMonthAbbrev(base: UnsafeRawPointer, at pos: Int) -> Int? {
        // Read 3 bytes, fold to uppercase, match against the 12 abbrev'd
        // English month names.
        let m0 = foldUpper(base.load(fromByteOffset: pos, as: UInt8.self))
        let m1 = foldUpper(base.load(fromByteOffset: pos + 1, as: UInt8.self))
        let m2 = foldUpper(base.load(fromByteOffset: pos + 2, as: UInt8.self))

        // Pack into a 24-bit value for switch-on-int compactness.
        let key = (Int(m0) << 16) | (Int(m1) << 8) | Int(m2)
        switch key {
        case 0x4A_41_4E: return 1   // JAN
        case 0x46_45_42: return 2   // FEB
        case 0x4D_41_52: return 3   // MAR
        case 0x41_50_52: return 4   // APR
        case 0x4D_41_59: return 5   // MAY
        case 0x4A_55_4E: return 6   // JUN
        case 0x4A_55_4C: return 7   // JUL
        case 0x41_55_47: return 8   // AUG
        case 0x53_45_50: return 9   // SEP
        case 0x4F_43_54: return 10  // OCT
        case 0x4E_4F_56: return 11  // NOV
        case 0x44_45_43: return 12  // DEC
        default: return nil
        }
    }

    @inline(__always)
    private static func foldUpper(_ b: UInt8) -> UInt8 {
        (b >= 0x61 && b <= 0x7A) ? b &- 0x20 : b
    }

    // MARK: - Epoch math

    /// Compute seconds since 1970-01-01 00:00:00 UTC for a Gregorian date.
    /// When `tzOffsetSeconds` is nil the interpretation matches Date-
    /// Formatter's default behavior — the wall-clock time is in the
    /// device's current time zone *for that specific date*. This handles
    /// DST transitions correctly. PlainTextParser's BSD-syslog and dated-
    /// syslog paths (without explicit TZ in the line) both rely on this
    /// behavior.
    private static func epochSeconds(
        year: Int, month: Int, day: Int,
        hour: Int, minute: Int, second: Int,
        fractional: Double,
        tzOffsetSeconds: Int?
    ) -> Double? {
        guard month >= 1 && month <= 12, day >= 1 && day <= 31 else { return nil }

        // Days since 1970-01-01 using a fixed Gregorian calendar formula.
        let daysFromEpoch = gregorianDaysFromEpoch(year: year, month: month, day: day)
        let pseudoUTC = Double(daysFromEpoch) * 86400.0
            + Double(hour) * 3600.0
            + Double(minute) * 60.0
            + Double(second)
            + fractional

        if let tz = tzOffsetSeconds {
            return pseudoUTC - Double(tz)
        }
        // No explicit TZ → interpret wall clock as local time for that
        // date. `secondsFromGMT(for:)` returns the offset that was active
        // at that moment in TimeZone.current. The probe-Date built from
        // pseudoUTC isn't quite the moment in question, but it's the same
        // wall-clock instant as the parsed time interpreted as UTC, and
        // for any non-DST-transition day the offset is identical.
        let probe = Date(timeIntervalSince1970: pseudoUTC)
        let localOffset = TimeZone.current.secondsFromGMT(for: probe)
        return pseudoUTC - Double(localOffset)
    }

    /// Howard Hinnant's date algorithm: days from civil date (Gregorian)
    /// to 1970-01-01. Correct for all years; no leap-year table lookup.
    @inline(__always)
    private static func gregorianDaysFromEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = (month <= 2) ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = month + (month > 2 ? -3 : 9)
        let doy = (153 * m + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}

/// Phase 4.5 PR2: byte-level component extraction so the indexed-mode
/// filter can gate on `filter.component`. The extracted string must
/// match `parser.parse(line:).component` for the supported parser
/// kinds (PlainText BSD-syslog / dated-syslog, SCCM) — otherwise the
/// right-click "Filter to component" workflow would produce zero
/// matches. CSV and other parsers return nil; the filter pipeline
/// treats nil as "no component captured" and skips the gate for that
/// row.
///
/// Output is a `Range<Int>` of absolute byte offsets into the buffer
/// so the caller can decode to String once for the dedup table.
/// Returns nil when the line doesn't conform to the expected shape
/// (e.g. bare-text PlainText fallback patterns) or when the parser
/// kind doesn't support byte-level extraction.
enum FastComponentScanner {
    /// Extract a component byte range for the given line. Caller is
    /// responsible for materializing the String (typically into a
    /// dedupe dictionary so 36 M lines don't allocate 36 M Strings).
    static func extractRange(
        in buf: UnsafeRawBufferPointer,
        range: Range<Int>,
        kind: ParserKind
    ) -> Range<Int>? {
        guard range.lowerBound < range.upperBound,
              range.upperBound <= buf.count,
              let base = buf.baseAddress else {
            return nil
        }
        switch kind {
        case .plainText: return extractPlainText(base: base, range: range)
        case .sccm:      return extractSCCM(base: base, range: range)
        case .csv, .other: return nil
        }
    }

    // MARK: - PlainText

    /// Mirror of `PlainTextParser`'s BSD-syslog / dated-syslog branch:
    /// component is the process-name segment that ends right before
    /// `[pid]`, ` <Level>`, or the message `:`. We walk backward from
    /// the message-body colon-space and reverse-engineer the layout.
    private static func extractPlainText(base: UnsafeRawPointer, range: Range<Int>) -> Range<Int>? {
        guard let colonPos = findColonSpaceBackwards(base: base, range: range) else { return nil }

        // Position the cursor just before the `:` and walk back over
        // optional ` <Level>` and `[pid]` annotations until the
        // component's last character is under the cursor.
        var cursor = colonPos - 1
        guard cursor >= range.lowerBound else { return nil }

        // Skip optional ` <Word>` tag.
        if base.load(fromByteOffset: cursor, as: UInt8.self) == 0x3E {  // '>'
            // Walk back to '<'.
            var k = cursor - 1
            while k >= range.lowerBound, base.load(fromByteOffset: k, as: UInt8.self) != 0x3C {
                k -= 1
            }
            guard k >= range.lowerBound else { return nil }
            // Skip whitespace before '<'.
            cursor = k - 1
            while cursor >= range.lowerBound {
                let b = base.load(fromByteOffset: cursor, as: UInt8.self)
                if b != 0x20 && b != 0x09 { break }
                cursor -= 1
            }
            guard cursor >= range.lowerBound else { return nil }
        }

        // Skip optional `[pid]`.
        if base.load(fromByteOffset: cursor, as: UInt8.self) == 0x5D {  // ']'
            var k = cursor - 1
            while k >= range.lowerBound, base.load(fromByteOffset: k, as: UInt8.self) != 0x5B {
                k -= 1
            }
            guard k >= range.lowerBound else { return nil }
            cursor = k - 1
            guard cursor >= range.lowerBound else { return nil }
        }

        // cursor now points at the last byte of the component. Walk
        // back to the preceding whitespace.
        let compEnd = cursor + 1
        var k = cursor
        while k >= range.lowerBound {
            let b = base.load(fromByteOffset: k, as: UInt8.self)
            if b == 0x20 || b == 0x09 { break }
            k -= 1
        }
        let compStart = k + 1
        guard compStart < compEnd else { return nil }

        // Sanity: component must not contain a `:` (would mean we
        // started inside the timestamp's HH:mm:ss). PlainText
        // components are alphanumeric / dot / underscore / dash by the
        // parser's regex, so reject anything outside that vocabulary.
        for i in compStart..<compEnd {
            let b = base.load(fromByteOffset: i, as: UInt8.self)
            if !isComponentByte(b) { return nil }
        }
        return compStart..<compEnd
    }

    /// Find the position of the message-body colon (the `:` immediately
    /// before the message). The `: ` (colon-space) heuristic from the
    /// level scanner works in reverse too — colons inside the timestamp
    /// are followed by digits, not spaces.
    private static func findColonSpaceBackwards(base: UnsafeRawPointer, range: Range<Int>) -> Int? {
        // We use the same forward memmem search as the level scanner —
        // backwards parity isn't needed for correctness, and the forward
        // search hits the right colon since it's always the first one.
        let length = range.upperBound - range.lowerBound
        guard length >= 2 else { return nil }
        let haystack = base.advanced(by: range.lowerBound)
        let needle: StaticString = ": "
        guard let found = memmem(haystack, length, needle.utf8Start, 2) else {
            return nil
        }
        return base.distance(to: UnsafeRawPointer(found))
    }

    @inline(__always)
    private static func isComponentByte(_ b: UInt8) -> Bool {
        // PlainTextParser's dated-syslog regex character class for
        // process: `[A-Za-z0-9][A-Za-z0-9._-]*`. Same vocabulary works
        // for BSD-syslog's `\S+?` since real-world process names
        // conform to this. Anything outside (e.g. `:`, `[`, `]`,
        // whitespace) means we walked into the wrong region.
        if (b >= 0x30 && b <= 0x39) { return true }  // 0-9
        if (b >= 0x41 && b <= 0x5A) { return true }  // A-Z
        if (b >= 0x61 && b <= 0x7A) { return true }  // a-z
        if b == 0x2E || b == 0x2D || b == 0x5F { return true }  // . - _
        return false
    }

    // MARK: - SCCM

    /// Locate `component="..."` and return its byte range (exclusive of
    /// the surrounding quotes).
    private static func extractSCCM(base: UnsafeRawPointer, range: Range<Int>) -> Range<Int>? {
        let needle: StaticString = "component=\""
        let needleLen = 11
        let length = range.upperBound - range.lowerBound
        guard length > needleLen,
              let found = memmem(base.advanced(by: range.lowerBound), length, needle.utf8Start, needleLen) else {
            return nil
        }
        let start = base.distance(to: UnsafeRawPointer(found)) + needleLen
        // Walk forward to the closing quote.
        var i = start
        while i < range.upperBound {
            if base.load(fromByteOffset: i, as: UInt8.self) == 0x22 { break }  // '"'
            i += 1
        }
        guard i > start, i < range.upperBound else { return nil }
        return start..<i
    }
}

