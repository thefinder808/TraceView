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

enum LogReportCategory {
    case log, crash, diagnostic, spin
}

final class LogBrowserService: ObservableObject {
    // One category per Console.app sidebar item (Mac Analytics Data omitted —
    // requires Full Disk Access and is usually empty without TCC grant).
    @Published var logReports: [BrowsableLogFile] = []
    @Published var crashReports: [BrowsableLogFile] = []
    @Published var diagnosticReports: [BrowsableLogFile] = []
    @Published var spinReports: [BrowsableLogFile] = []
    @Published private(set) var isScanning: Bool = false

    private let scanQueue = DispatchQueue(label: "com.traceview.logbrowser", qos: .utility)

    private static let logDirectories: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Logs"),
            URL(fileURLWithPath: "/var/log"),
            URL(fileURLWithPath: "/Library/Logs"),
        ]
    }()

    private static let diagnosticReportDirectories: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
    }()

    init() {
        scan()
    }

    func scan() {
        // Guard against stacking concurrent scans when the user mashes the
        // refresh button. The published flag drives the UI spinner.
        if isScanning { return }
        isScanning = true

        scanQueue.async { [weak self] in
            let logs = Self.scanLogs()
            let diagnostics = Self.scanDiagnosticReports()

            DispatchQueue.main.async {
                self?.logReports = logs
                self?.crashReports = diagnostics.crash
                self?.diagnosticReports = diagnostics.diagnostic
                self?.spinReports = diagnostics.spin
                self?.isScanning = false
            }
        }
    }

    // MARK: - Scanners

    private static func scanLogs() -> [BrowsableLogFile] {
        collectFiles(from: logDirectories, keep: { url in
            let ext = url.pathExtension.lowercased()
            return ext == "log" || ext == "txt"
        })
    }

    private static func scanDiagnosticReports() -> (crash: [BrowsableLogFile], diagnostic: [BrowsableLogFile], spin: [BrowsableLogFile]) {
        var crash: [BrowsableLogFile] = []
        var diagnostic: [BrowsableLogFile] = []
        var spin: [BrowsableLogFile] = []

        for file in collectFiles(from: diagnosticReportDirectories, keep: { url in
            ["ips", "crash", "diag", "spin", "hang"].contains(url.pathExtension.lowercased())
        }) {
            switch classify(file: file) {
            case .crash: crash.append(file)
            case .spin: spin.append(file)
            case .diagnostic: diagnostic.append(file)
            case .log: break // unreachable — log dirs are scanned separately
            }
        }
        return (crash, diagnostic, spin)
    }

    // MARK: - Classification

    // Mirrors Console.app's bucketing by filename prefix / extension.
    private static func classify(file: BrowsableLogFile) -> LogReportCategory {
        let ext = file.url.pathExtension.lowercased()
        if ext == "spin" || ext == "hang" { return .spin }
        if ext == "diag" { return .diagnostic }

        let name = file.name
        if name.hasPrefix("Spin") || name.hasPrefix("StackShot") || name.hasPrefix("Hang") {
            return .spin
        }
        if name.hasPrefix("JetsamEvent")
            || name.hasPrefix("ExcUserFault")
            || name.hasPrefix("wakeups")
            || name.hasPrefix("WakeUp")
            || name.hasPrefix("CPU")
            || name.hasPrefix("HighCPU") {
            return .diagnostic
        }
        return .crash
    }

    // MARK: - File collection

    private static func collectFiles(from dirs: [URL], keep: (URL) -> Bool) -> [BrowsableLogFile] {
        let fm = FileManager.default
        var files: [BrowsableLogFile] = []

        for dir in dirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for url in contents where keep(url) {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }

                let size = UInt64(values.fileSize ?? 0)
                guard size > 0 else { continue }

                files.append(BrowsableLogFile(
                    id: url,
                    url: url,
                    name: url.lastPathComponent,
                    size: size,
                    modified: values.contentModificationDate ?? Date.distantPast
                ))
            }
        }

        return files.sorted { $0.modified > $1.modified }
    }
}
