import SwiftUI

// Inline saved-filter presets — pill-shaped chips. Click applies the preset,
// Alt-click deletes it. The "+" button snapshots the current filter.
struct FilterPresetsView: View {
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var themeManager: ThemeManager

    @State private var showingNameSheet = false
    @State private var draftName: String = ""

    var body: some View {
        let theme = themeManager.current

        HStack(spacing: 4) {
            Image(systemName: "bookmark")
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)

            ForEach(settings.savedFilters) { preset in
                presetChip(preset, theme: theme)
            }

            Button {
                draftName = suggestedName()
                showingNameSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.sidebarHover)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.filter.isActive)
            .opacity(viewModel.filter.isActive ? 1 : 0.4)
            .help("Save current filter as preset")
        }
        .sheet(isPresented: $showingNameSheet) {
            namePresetSheet()
        }
    }

    // MARK: - Chip

    private func presetChip(_ preset: LogFilterPreset, theme: any AppTheme) -> some View {
        let isActive = preset.matches(viewModel.filter)
        return Button {
            var f = viewModel.filter
            preset.applied(to: &f)
            viewModel.filter = f
        } label: {
            Text(preset.name)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? .white : theme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    Capsule().fill(isActive ? theme.accentColor : theme.borderSubtle)
                )
                .overlay(
                    Capsule().stroke(isActive ? theme.accentColor : theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply") {
                var f = viewModel.filter
                preset.applied(to: &f)
                viewModel.filter = f
            }
            Divider()
            Button("Delete", role: .destructive) {
                settings.savedFilters.removeAll { $0.id == preset.id }
            }
        }
    }

    // MARK: - Name sheet

    private func namePresetSheet() -> some View {
        VStack(spacing: 16) {
            Text("Save filter preset")
                .font(.headline)

            TextField("Preset name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack {
                Button("Cancel") { showingNameSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let name = draftName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let preset = LogFilterPreset(name: name, filter: viewModel.filter)
                    settings.savedFilters.append(preset)
                    showingNameSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(width: 280)
        }
        .padding(24)
    }

    private func suggestedName() -> String {
        let f = viewModel.filter
        if !f.searchText.isEmpty { return f.searchText }
        if f.enabledLevels.count == 1, let lvl = f.enabledLevels.first {
            return "\(lvl.displayName) only"
        }
        if let c = f.component { return c }
        return "Preset \(settings.savedFilters.count + 1)"
    }
}
