import Foundation

protocol LogParser {
    var name: String { get }
    var supportedExtensions: Set<String> { get }

    /// Test if this parser can handle the given sample lines.
    /// Returns a confidence score 0.0...1.0
    func canParse(sampleLines: [String]) -> Double

    /// Parse a single line into a LogEntry.
    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry

    /// Optional: parse the entire file at once. Returns nil to fall back
    /// to line-by-line via `parse(line:)`. Use this when a format needs
    /// state across lines — e.g. .ips crash reports where the JSON header
    /// on line 1 carries the timestamp for every subsequent body line.
    func parseFile(lines: [String], startingEntryID: Int) -> (entries: [LogEntry], nextID: Int)?

    /// True iff `parse(line:lineNumber:entryID:)` produces a complete
    /// LogEntry from a single line in isolation — no cross-line state,
    /// no header lookup, no whole-file context. Required for Phase 3's
    /// `IndexedEntrySource`, which re-parses lines on demand via mmap.
    /// Defaults to `false` (conservative). Override `true` only when the
    /// parser is genuinely line-by-line.
    var isLineStateless: Bool { get }
}

extension LogParser {
    /// Default: no whole-file parse available, caller should iterate
    /// line-by-line.
    func parseFile(lines: [String], startingEntryID: Int) -> (entries: [LogEntry], nextID: Int)? {
        nil
    }

    /// Default: assume the parser may need cross-line context. Only the
    /// three line-stateless parsers (PlainText, SCCM, CSV) override.
    var isLineStateless: Bool { false }
}
