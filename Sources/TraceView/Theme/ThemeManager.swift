import SwiftUI
import Combine

enum ThemeOption: String, CaseIterable, Identifiable {
    case system = "System"
    case console = "Console"
    case dark = "Dark"
    case light = "Light"
    case neon = "Neon"

    var id: String { rawValue }
}

final class ThemeManager: ObservableObject {
    @Published var selectedOption: ThemeOption {
        didSet {
            UserDefaults.standard.set(selectedOption.rawValue, forKey: "traceview.theme")
            resolveTheme()
        }
    }

    @Published private(set) var current: any AppTheme

    private var appearanceObserver: NSObjectProtocol?

    init() {
        let saved = UserDefaults.standard.string(forKey: "traceview.theme") ?? "Console"
        let option = ThemeOption(rawValue: saved) ?? .console
        self.selectedOption = option
        self.current = ConsoleTheme()
        resolveTheme()
        observeSystemAppearance()
    }

    func cycleTheme() {
        let all = ThemeOption.allCases
        guard let idx = all.firstIndex(of: selectedOption) else { return }
        let next = all[(idx + 1) % all.count]
        selectedOption = next
    }

    private func resolveTheme() {
        switch selectedOption {
        case .console:
            current = ConsoleTheme()
        case .dark:
            current = DarkTheme()
        case .light:
            current = LightTheme()
        case .neon:
            current = NeonTheme()
        case .system:
            let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .darkAqua)!
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            current = isDark ? DarkTheme() : ConsoleTheme()
        }
    }

    private func observeSystemAppearance() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.selectedOption == .system else { return }
            self?.resolveTheme()
        }
    }

    deinit {
        if let observer = appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
