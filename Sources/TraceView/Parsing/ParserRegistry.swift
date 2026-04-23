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

    /// Auto-detect the best parser for a file by reading sample lines.
    /// Transparently handles `.gz` — we decompress the whole file here too
    /// rather than trying to partial-stream, because the compressed size is
    /// already small enough that it's cheaper than spawning gunzip twice.
    func detectParser(for url: URL) -> any LogParser {
        let rawData: Data?
        if GzipDecompressor.isGzipped(url: url) {
            rawData = GzipDecompressor.decompress(url: url)
        } else {
            rawData = try? Data(contentsOf: url, options: .mappedIfSafe)
        }

        guard let data = rawData,
              let text = String(data: data.prefix(8192), encoding: .utf8) else {
            return PlainTextParser()
        }

        let sampleLines = text.components(separatedBy: .newlines)
            .prefix(50)
            .filter { !$0.isEmpty }
            .map { String($0) }

        return detectParser(sampleLines: Array(sampleLines))
    }

    /// Pick the highest-confidence parser for the given sample lines.
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
