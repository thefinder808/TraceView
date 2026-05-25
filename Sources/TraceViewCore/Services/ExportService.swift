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

    private static func exportCSV<C: Sequence>(entries: C) -> String where C.Element == LogEntry {
        var lines = ["Line,Timestamp,Level,Component,Message"]
        for entry in entries {
            let ts = entry.timestamp.map { Formatters.formatDateTime($0) } ?? ""
            let comp = entry.component ?? ""
            let msg = entry.message.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(entry.lineNumber),\"\(ts)\",\(entry.level.shortName),\"\(comp)\",\"\(msg)\"")
        }
        return lines.joined(separator: "\n")
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
