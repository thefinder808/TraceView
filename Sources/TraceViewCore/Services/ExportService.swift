import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case plainText = "Plain Text"
    case csv = "CSV"
    case json = "JSON"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .plainText: return "log"
        case .csv: return "csv"
        case .json: return "json"
        }
    }

    // Drives NSSavePanel's allowedContentTypes so Finder/Quick Look see
    // the written file as its real type rather than generic plain text.
    var contentType: UTType {
        switch self {
        case .plainText: return .plainText
        case .csv: return .commaSeparatedText
        case .json: return .json
        }
    }
}

enum ExportService {
    static func export<C: RandomAccessCollection>(
        entries: C,
        documentName: String,
        format: ExportFormat
    ) where C.Element == LogEntry {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(documentName)-export.\(format.fileExtension)"
        panel.message = "Export \(entries.count) log entries"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content: String
        switch format {
        case .plainText:
            content = entries.map(\.rawLine).joined(separator: "\n")
        case .csv:
            content = exportCSV(entries: entries)
        case .json:
            content = exportJSON(entries: entries)
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Render the given entries as CSV. Exposed (non-private) so
    /// `ExportServiceCSVTests` can exercise the escaping without driving an
    /// `NSSavePanel`. The header row and column order match the on-disk
    /// format `Line,Timestamp,Level,Component,Message`.
    static func exportCSV<C: Sequence>(entries: C) -> String where C.Element == LogEntry {
        var lines = ["Line,Timestamp,Level,Component,Message"]
        for entry in entries {
            let ts = entry.timestamp.map { Formatters.formatDateTime($0) } ?? ""
            let comp = entry.component ?? ""
            // Every free-text column goes through csvField so a comma,
            // quote, or newline in the value can't break the row/column
            // structure. Line number and level are numeric/enum and safe
            // to emit bare.
            lines.append("\(entry.lineNumber),\(csvField(ts)),\(entry.level.shortName),\(csvField(comp)),\(csvField(entry.message))")
        }
        return lines.joined(separator: "\n")
    }

    /// Escape one CSV field per RFC 4180: wrap in double quotes and double
    /// any embedded quote. Applied to every free-text field. The previous
    /// implementation only escaped the message's quotes and interpolated
    /// the component raw inside quotes, so a component like `foo"bar`
    /// produced malformed CSV (`"foo"bar"`) that split into extra columns
    /// in any spec-compliant reader.
    static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func exportJSON<C: Sequence>(entries: C) -> String where C.Element == LogEntry {
        let items = entries.map { entry -> [String: Any] in
            var dict: [String: Any] = [
                "line": entry.lineNumber,
                "level": entry.level.displayName,
                "message": entry.message
            ]
            if let ts = entry.timestamp {
                dict["timestamp"] = Formatters.formatDateTime(ts)
            }
            if let comp = entry.component {
                dict["component"] = comp
            }
            return dict
        }

        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }
}
