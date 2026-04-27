import SwiftUI

// Modal for jumping to a line number (⌘G). Entry is validated against the
// active document's line count; on submit we set AppState.pendingGoToLine
// and dismiss — NSLogTableView watches that and scrolls to the row.
struct GoToLineSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @FocusState private var focused: Bool

    private var totalLines: Int {
        appState.selectedDocument(in: appState.activePane)?.entries.count ?? 0
    }

    private var parsed: Int? {
        let n = Int(input.trimmingCharacters(in: .whitespaces))
        guard let n, n >= 1, n <= totalLines else { return nil }
        return n
    }

    var body: some View {
        let theme = themeManager.current

        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Line")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("Line number", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .frame(width: 160)

                Text("of \(totalLines)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .monospacedDigit()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func submit() {
        guard let line = parsed else { return }
        appState.goToLine(line, in: appState.activePane)
        dismiss()
    }
}
