import SwiftUI

struct LogDocumentView: View {
    @ObservedObject var document: LogDocument
    @StateObject private var viewModel: LogDocumentViewModel
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
    }
}
