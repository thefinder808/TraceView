import Foundation

/// A saved remote log source. v1 ships a single transport (`.ssh`); the
/// `kind` discriminator exists so future adapters (Coolify, Docker) slot in
/// as additional cases + builders without reshaping callers. Persisted via
/// SettingsManager — METADATA ONLY. No passwords or keys are ever stored;
/// SSH auth rides entirely on the user's ~/.ssh keys + ssh-agent.
struct RemoteConnection: Codable, Identifiable, Hashable {
    var id: UUID
    var displayName: String
    var kind: RemoteKind

    init(id: UUID = UUID(), displayName: String, kind: RemoteKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

enum RemoteKind: Codable, Hashable {
    case ssh(SSHConfig)
}

/// SSH transport config. `target` is whatever you'd type after `ssh` —
/// a `~/.ssh/config` host alias or `user@host`. We never parse it; ssh does.
struct SSHConfig: Codable, Hashable {
    /// Host alias (from ~/.ssh/config) or `user@host`.
    var target: String
    /// Explicit port. nil ⇒ let ssh/ssh_config decide (usually 22).
    var port: Int?
    /// File to tail when `customCommand` is nil. We build
    /// `tail -n <initialLines> -F <quoted path>` from this.
    var remotePath: String?
    /// Advanced escape hatch: a full remote command run verbatim in the
    /// user's remote shell (e.g. `journalctl -fu nginx`, `docker logs -f web`).
    /// When set, `remotePath`/`initialLines` are ignored.
    var customCommand: String?
    /// Lines of backlog to fetch before following. Only used for the
    /// generated `tail` command.
    var initialLines: Int

    init(target: String,
         port: Int? = nil,
         remotePath: String? = nil,
         customCommand: String? = nil,
         initialLines: Int = 500) {
        self.target = target
        self.port = port
        self.remotePath = remotePath
        self.customCommand = customCommand
        self.initialLines = initialLines
    }

    /// The command string handed to the remote shell. Either the verbatim
    /// custom command or a generated `tail -n N -F <path>` with the path
    /// single-quote-escaped so spaces/specials in the path can't break out
    /// of the argument. (The remote shell still interprets this string —
    /// expected; it's the user's own server, same trust model as a terminal.)
    ///
    /// `followOnly` is set on reconnects: it uses `tail -n 0` so a transient
    /// drop doesn't replay the whole backlog as duplicate rows. The cost is
    /// that lines written during the outage window are missed — the standard
    /// `tail -f` reconnect trade-off, and far less harmful than duplicating
    /// `initialLines` rows on every blip. Custom commands are run verbatim
    /// regardless (we can't know how to make an arbitrary command follow-only).
    func effectiveRemoteCommand(followOnly: Bool = false) -> String {
        if let custom = customCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        let path = remotePath ?? ""
        let lines = followOnly ? 0 : max(0, initialLines)
        return "tail -n \(lines) -F \(Self.shellQuote(path))"
    }

    /// POSIX single-quote escaping: wrap in single quotes, and replace any
    /// embedded single quote with the `'\''` idiom.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Live state of a remote stream, surfaced in the status bar.
enum RemoteConnectionState: Equatable {
    case connecting
    case connected
    case reconnecting
    case failed(String)
}
