import SwiftUI
import Combine

final class SettingsManager: ObservableObject {
    private static let fontSizeKey = "traceview.fontSize"
    private static let showLineNumbersKey = "traceview.showLineNumbers"
    private static let showTimestampKey = "traceview.showTimestamp"
    private static let showComponentKey = "traceview.showComponent"

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }

    @Published var showLineNumbers: Bool {
        didSet { UserDefaults.standard.set(showLineNumbers, forKey: Self.showLineNumbersKey) }
    }

    @Published var showTimestamp: Bool {
        didSet { UserDefaults.standard.set(showTimestamp, forKey: Self.showTimestampKey) }
    }

    @Published var showComponent: Bool {
        didSet { UserDefaults.standard.set(showComponent, forKey: Self.showComponentKey) }
    }

    init() {
        let defaults = UserDefaults.standard

        let saved = defaults.double(forKey: Self.fontSizeKey)
        self.fontSize = saved > 0 ? saved : 12.0

        // Default to true if never set
        if defaults.object(forKey: Self.showLineNumbersKey) == nil {
            self.showLineNumbers = true
        } else {
            self.showLineNumbers = defaults.bool(forKey: Self.showLineNumbersKey)
        }

        if defaults.object(forKey: Self.showTimestampKey) == nil {
            self.showTimestamp = true
        } else {
            self.showTimestamp = defaults.bool(forKey: Self.showTimestampKey)
        }

        if defaults.object(forKey: Self.showComponentKey) == nil {
            self.showComponent = true
        } else {
            self.showComponent = defaults.bool(forKey: Self.showComponentKey)
        }
    }
}
