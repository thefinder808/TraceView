import SwiftUI

struct LogDocumentView: View {
    @ObservedObject var document: LogDocument
    @StateObject private var viewModel: LogDocumentViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager

    init(document: LogDocument) {
        self.document = document
        self._viewModel = StateObject(wrappedValue: LogDocumentViewModel(document: document))
    }

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 0) {
            // Filter bar
            FilterBarView(viewModel: viewModel)

            Divider().background(theme.border)

            // Log table
            LogTableView(viewModel: viewModel)

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
