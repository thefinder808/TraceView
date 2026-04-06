import Foundation

protocol LogParser {
    var name: String { get }
    var supportedExtensions: Set<String> { get }

    /// Test if this parser can handle the given sample lines.
    /// Returns a confidence score 0.0...1.0
    func canParse(sampleLines: [String]) -> Double

    /// Parse a single line into a LogEntry.
    func parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry
}
