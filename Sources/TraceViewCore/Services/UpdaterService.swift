import Combine
import Sparkle
import SwiftUI

@MainActor
public final class UpdaterService: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []

    @Published public private(set) var canCheckForUpdates: Bool = false

    public init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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
