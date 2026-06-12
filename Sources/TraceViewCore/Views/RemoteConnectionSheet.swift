import SwiftUI

// Triggered from File → "New Remote Connection..." and the sidebar
// "Connections" section. Captures an SSH tail target, saves it to
// SettingsManager (metadata only — no credentials), and opens it.
// Auth rides on the user's ~/.ssh keys + ssh-agent.
struct RemoteConnectionSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var target = ""
    @State private var portText = ""
    @State private var remotePath = ""
    @State private var showAdvanced = false
    @State private var customCommand = ""
    @State private var initialLines = 500

    var body: some View {
        let theme = themeManager.current

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Remote Connection")
                    .font(.title2.bold())
                Text("Tail a log over SSH. Uses your ~/.ssh keys and ssh-agent — no passwords are stored. The host must already be trusted in known_hosts (connect once in Terminal first).")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Name", theme: theme) {
                TextField("My server", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 10) {
                field("Host (alias or user@host)", theme: theme) {
                    TextField("deploy@example.com", text: $target)
                        .textFieldStyle(.roundedBorder)
                }
                field("Port", theme: theme) {
                    TextField("22", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
            }

            if !showAdvanced {
                field("Log file path", theme: theme) {
                    TextField("/var/log/syslog", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Text("Initial lines")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    TextField("", value: $initialLines, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("", value: $initialLines, in: 0...100_000, step: 100)
                        .labelsHidden()
                    Spacer()
                }
            } else {
                field("Custom remote command", theme: theme) {
                    TextField("journalctl -fu nginx", text: $customCommand)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Runs verbatim in your remote shell. Use a following command (tail -F, journalctl -f, docker logs -f …).")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Advanced: custom command", isOn: $showAdvanced)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save & Open") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var canSave: Bool {
        let hasTarget = !target.trimmingCharacters(in: .whitespaces).isEmpty
        let hasCommand = showAdvanced
            ? !customCommand.trimmingCharacters(in: .whitespaces).isEmpty
            : !remotePath.trimmingCharacters(in: .whitespaces).isEmpty
        return hasTarget && hasCommand
    }

    private func save() {
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
        let cfg = SSHConfig(
            target: trimmedTarget,
            port: Int(portText.trimmingCharacters(in: .whitespaces)),
            remotePath: showAdvanced ? nil : remotePath.trimmingCharacters(in: .whitespaces),
            customCommand: showAdvanced ? customCommand.trimmingCharacters(in: .whitespaces) : nil,
            initialLines: initialLines
        )
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let fallback = showAdvanced
            ? trimmedTarget
            : "\(trimmedTarget): \((remotePath as NSString).lastPathComponent)"
        let connection = RemoteConnection(
            displayName: name.isEmpty ? fallback : name,
            kind: .ssh(cfg)
        )
        settingsManager.savedRemoteConnections.append(connection)
        appState.openRemoteConnection(connection)
        dismiss()
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, theme: any AppTheme,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            content()
        }
    }
}
