import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var themeManager: ThemeManager

    /// Phase 5.5: refreshed on every settings panel open so the
    /// "Cache size" label shows current usage. Recomputed when the user
    /// clicks "Clear Index Cache".
    @State private var cacheSizeBytes: Int64 = 0

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

            // Performance / indexed loading
            Section("Performance") {
                Toggle("Use indexed mode for large files", isOn: $settingsManager.indexedModeEnabled)

                HStack {
                    Text("Threshold")
                    Spacer()
                    Text("\(settingsManager.indexedModeThresholdMB) MB")
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                    Stepper("", value: $settingsManager.indexedModeThresholdMB, in: 10...10_000, step: 10)
                        .labelsHidden()
                }
                .disabled(!settingsManager.indexedModeEnabled)

                Text("Files at or above the threshold are loaded with a memory-mapped index instead of read into RAM. Severity chips, histogram, and filter still work — the file just doesn't need to fit in memory.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                Toggle("Cache indexes to disk", isOn: $settingsManager.indexedModeCacheEnabled)
                    .disabled(!settingsManager.indexedModeEnabled)
                    .onChange(of: settingsManager.indexedModeCacheEnabled) { _, newValue in
                        // Flipping off implies "I don't want a cache on
                        // disk" — wipe what's already there so the
                        // toggle's effect is immediate.
                        if !newValue {
                            _ = LogIndexCache.clearAll()
                            cacheSizeBytes = 0
                        }
                    }

                HStack {
                    Text("Index cache")
                    Spacer()
                    Text(formattedCacheSize(cacheSizeBytes))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                    Button("Clear") {
                        _ = LogIndexCache.clearAll()
                        cacheSizeBytes = LogIndexCache.totalCacheSize()
                    }
                    .disabled(cacheSizeBytes == 0)
                }
                .disabled(!settingsManager.indexedModeCacheEnabled)

                Text("Cached indexes live in ~/Library/Caches/com.traceview.app/. macOS evicts them automatically under disk pressure. Turning the cache off means every open of a large file rebuilds the index from scratch (~5 s per 5 GB) but uses zero disk.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }

            // Session
            Section("Session") {
                Toggle("Restore open tabs on launch", isOn: $settingsManager.restoreTabsOnLaunch)

                Text("Reopens the log files you had open the last time TraceView quit. Live system-log streams aren't restored.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }

            // Highlight rules
            Section("Highlight Rules") {
                ForEach($settingsManager.highlightRules) { $rule in
                    HighlightRuleRow(rule: $rule) {
                        settingsManager.highlightRules.removeAll { $0.id == rule.id }
                    }
                }

                Button {
                    settingsManager.highlightRules.append(
                        HighlightRule(name: "New rule", pattern: "", colorHex: 0xFFB84D)
                    )
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }

                if settingsManager.highlightRules.isEmpty {
                    Text("Rows whose message matches a rule's pattern are tinted with its color. Pattern is a regex.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .onAppear {
            cacheSizeBytes = LogIndexCache.totalCacheSize()
        }
    }

    private func formattedCacheSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

// Single row in the Highlight Rules list: enable toggle, name field,
// regex pattern, color picker, delete button. Invalid regex patterns
// show a red outline so the user gets fast feedback.
private struct HighlightRuleRow: View {
    @Binding var rule: HighlightRule
    let onDelete: () -> Void

    private var isValidRegex: Bool {
        rule.pattern.isEmpty || (try? NSRegularExpression(pattern: rule.pattern)) != nil
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $rule.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                TextField("Name", text: $rule.name)
                    .textFieldStyle(.roundedBorder)

                ColorPicker("", selection: Binding(
                    get: { rule.color },
                    set: { newColor in
                        if let hex = newColor.asHexRGB { rule.colorHex = hex }
                    }
                ))
                .labelsHidden()
                .frame(width: 40)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                TextField("Regex pattern", text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isValidRegex ? .clear : .red, lineWidth: 1)
                    )

                if !isValidRegex {
                    Text("invalid regex")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// Small helper to round-trip SwiftUI Color through an RGB hex.
private extension Color {
    var asHexRGB: UInt32? {
        let ns = NSColor(self).usingColorSpace(.sRGB)
        guard let rgb = ns else { return nil }
        let r = UInt32(max(0, min(255, Int(rgb.redComponent * 255))))
        let g = UInt32(max(0, min(255, Int(rgb.greenComponent * 255))))
        let b = UInt32(max(0, min(255, Int(rgb.blueComponent * 255))))
        return (r << 16) | (g << 8) | b
    }
}
