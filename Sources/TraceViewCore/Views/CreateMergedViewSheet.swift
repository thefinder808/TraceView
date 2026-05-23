import SwiftUI

// Triggered from Tools → "Create Merged View...". Lists all currently-open
// documents with a checkbox; ≥2 must be selected to create. Filters out
// merged docs from the picker since merging-of-merged is a rabbit hole
// we explicitly punt on for v1.
struct CreateMergedViewSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Create Merged View")
                    .font(.title2.bold())
                Text("Pick two or more open logs to merge into a single timeline.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(eligibleDocs) { doc in
                        row(for: doc, theme: theme)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 280)
            .background(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            )

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Merged View") {
                    let chosen = eligibleDocs.filter { selectedIDs.contains($0.id) }
                    appState.createMergedView(from: chosen)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.count < 2)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var eligibleDocs: [LogDocument] {
        appState.documents.filter { !$0.isMerged }
    }

    @ViewBuilder
    private func row(for doc: LogDocument, theme: any AppTheme) -> some View {
        let isSelected = selectedIDs.contains(doc.id)
        Button {
            if isSelected { selectedIDs.remove(doc.id) }
            else { selectedIDs.insert(doc.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? theme.accentColor : theme.tertiaryText)
                Image(systemName: doc.isLive ? "waveform" : "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Text(doc.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(doc.lineCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
