import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        Form {
            // Theme selection
            Section("Appearance") {
                Picker("Theme", selection: $themeManager.selectedOption) {
                    ForEach(ThemeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Log display
            Section("Log Display") {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(settingsManager.fontSize))pt")
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                    Stepper("", value: $settingsManager.fontSize, in: 9...18, step: 1)
                        .labelsHidden()
                }

                Toggle("Show Line Numbers", isOn: $settingsManager.showLineNumbers)
                Toggle("Show Timestamps", isOn: $settingsManager.showTimestamp)
                Toggle("Show Component", isOn: $settingsManager.showComponent)
            }

            // Detail view
            Section("Detail View") {
                Picker("Show detail as", selection: $settingsManager.detailDisplayMode) {
                    ForEach(DetailDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settingsManager.detailDisplayMode == .inline
                     ? "Click a log row to expand it in place with context and actions."
                     : "Click a log row to show details in a pane at the bottom of the window.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
    }
}
