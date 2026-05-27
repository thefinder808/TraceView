import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
public final class UpdaterService: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []

    @Published public private(set) var canCheckForUpdates: Bool = false

    public override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    public var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

extension UpdaterService: SPUUpdaterDelegate {
    nonisolated public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // SUInstallationWriteNoPermissionError (4012) fires when Sparkle's
        // installer can't write to /Applications/TraceView.app. On macOS
        // Sonoma+ that usually means the OS just popped the App Management
        // TCC prompt — the install failed because permission wasn't granted
        // *yet*. Sparkle's default error dialog says "Update failed", which
        // looks like a real failure even though one click in System Settings
        // unblocks the whole thing. Replace that with an actionable alert.
        // SUInstallationWriteNoPermissionError. Hardcoded because Sparkle's
        // SUErrors enum isn't bridged to Swift as named constants — the
        // header defines it as a C enum case at value 4012 in SUErrors.h.
        let writeNoPermissionCode = 4012
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              nsError.code == writeNoPermissionCode else { return }

        Task { @MainActor [weak self] in
            self?.showAppManagementPermissionAlert()
        }
    }

    @MainActor
    private func showAppManagementPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Grant App Management permission to finish updating"
        alert.informativeText = """
            macOS asks for App Management permission the first time TraceView updates itself. \
            Open System Settings → Privacy & Security → App Management, switch TraceView on, \
            then check for updates again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
            NSWorkspace.shared.open(url)
        }
    }
}
