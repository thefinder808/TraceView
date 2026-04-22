import SwiftUI

struct LogDocumentView: View {
    @ObservedObject var document: LogDocument
    @StateObject private var viewModel: LogDocumentViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var selectedEntry: LogEntry?

    init(document: LogDocument) {
        self.document = document
        self._viewModel = StateObject(wrappedValue: LogDocumentViewModel(document: document))
    }

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 0) {
            // Severity summary chips
            SeveritySummaryBar(viewModel: viewModel)

            // Event density histogram (hidden if timestamps unavailable)
            HistogramView(viewModel: viewModel)

            // Filter bar
            FilterBarView(viewModel: viewModel)

            Divider().background(theme.border)

            // Log table + detail pane
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    NSLogTableView(
                        entries: viewModel.filteredEntries,
                        theme: themeManager.current,
                        fontSize: settingsManager.fontSize,
                        showLineNumbers: settingsManager.showLineNumbers,
                        showTimestamp: settingsManager.showTimestamp,
                        showComponent: settingsManager.showComponent,
                        isFollowing: document.isFollowing,
                        selectedEntry: $selectedEntry,
                        onScrollUp: {
                            document.isFollowing = false
                        }
                    )

                    // Jump to bottom button
                    if !document.isFollowing {
                        Button {
                            document.isFollowing = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Jump to Bottom")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.accentColor)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                    }
                }

                // Detail pane (shown when a row is selected)
                if let entry = selectedEntry {
                    Divider().background(theme.border)

                    DetailPaneView(entry: entry)
                        .frame(minHeight: 80, idealHeight: 120, maxHeight: 250)
                }
            }

            Divider().background(theme.border)

            // Status bar
            StatusBarView(document: document, viewModel: viewModel)
        }
        .onAppear {
            viewModel.load()
        }
        .sheet(isPresented: $appState.showExport) {
            ExportSheet(
                entries: viewModel.filteredEntries,
                documentName: document.displayName
            )
            .environmentObject(themeManager)
        }
    }
}

// MARK: - Export Sheet

struct ExportSheet: View {
    let entries: [LogEntry]
    let documentName: String
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedFormat: ExportFormat = .plainText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Log")
                .font(.title2.bold())

            Text("Export \(Formatters.formatCount(entries.count)) entries to a file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Format", selection: $selectedFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export...") {
                    ExportService.export(
                        entries: entries,
                        documentName: documentName,
                        format: selectedFormat
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
