import Foundation

final class ParserRegistry {
    static let shared = ParserRegistry()

    private let parsers: [any LogParser] = [
        SCCMLogParser(),
        UnifiedLogParser(),
        JSONLogParser(),
        CSVLogParser(),
        PlainTextParser()  // Fallback
    ]

    /// Pick the highest-confidence parser for the given sample lines.
    /// Callers read/decompress the file once themselves and pass a sample
    /// here, so gzipped files don't get decompressed twice during load.
    func detectParser(sampleLines: [String]) -> any LogParser {
        var bestParser: (any LogParser) = PlainTextParser()
        var bestScore: Double = 0

        for parser in parsers {
            let score = parser.canParse(sampleLines: sampleLines)
            if score > bestScore {
                bestScore = score
                bestParser = parser
            }
        }

        return bestParser
    }
}
