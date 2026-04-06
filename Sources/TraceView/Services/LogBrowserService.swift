import Foundation
import Combine

struct BrowsableLogFile: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let size: UInt64
    let modified: Date

    var formattedSize: String {
        Formatters.formatBytes(size)
    }

    var formattedDate: String {
        Formatters.formatDateTime(modified)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: BrowsableLogFile, rhs: BrowsableLogFile) -> Bool {
        lhs.url == rhs.url
    }
}

struct LogBrowserSection: Identifiable {
    let id: String
    let name: String
    let icon: String
    let directories: [URL]
    let extensions: Set<String>
}

final class LogBrowserService: ObservableObject {
    @Published var logReports: [BrowsableLogFile] = []
    @Published var crashReports: [BrowsableLogFile] = []

    private let scanQueue = DispatchQueue(label: "com.traceview.logbrowser", qos: .utility)

    static let sections: [LogBrowserSection] = {
        let home = FileManager.default.homeDirectoryForCurrentUser

        return [
            LogBrowserSection(
                id: "logs",
                name: "Log Reports",
                icon: "doc.text",
                directories: [
                    home.appendingPathComponent("Library/Logs"),
                    URL(fileURLWithPath: "/var/log"),
                    URL(fileURLWithPath: "/Library/Logs"),
                ],
                extensions: ["log", "txt"]
            ),
            LogBrowserSection(
                id: "crashes",
                name: "Crash Reports",
                icon: "exclamationmark.triangle",
                directories: [
                    home.appendingPathComponent("Library/Logs/DiagnosticReports"),
                ],
                extensions: ["ips", "crash"]
            ),
        ]
    }()

    init() {
        scan()
    }

    func scan() {
        scanQueue.async { [weak self] in
            let logs = Self.scanSection(Self.sections[0])
            let crashes = Self.scanSection(Self.sections[1])

            DispatchQueue.main.async {
                self?.logReports = logs
                self?.crashReports = crashes
            }
        }
    }

    private static func scanSection(_ section: LogBrowserSection) -> [BrowsableLogFile] {
        let fm = FileManager.default
        var files: [BrowsableLogFile] = []

        for dir in section.directories {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for url in contents {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }

                let ext = url.pathExtension.lowercased()
                guard section.extensions.contains(ext) else { continue }

                let size = UInt64(values.fileSize ?? 0)
                guard size > 0 else { continue } // Skip empty files

                let modified = values.contentModificationDate ?? Date.distantPast

                files.append(BrowsableLogFile(
                    id: url,
                    url: url,
                    name: url.lastPathComponent,
                    size: size,
                    modified: modified
                ))
            }
        }

        // Sort by modification date, newest first
        return files.sorted { $0.modified > $1.modified }
    }
}
