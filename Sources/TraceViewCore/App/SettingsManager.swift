import SwiftUI
import Combine

final class SettingsManager: ObservableObject {
    private static let fontSizeKey = "traceview.fontSize"
    private static let showLineNumbersKey = "traceview.showLineNumbers"
    private static let showTimestampKey = "traceview.showTimestamp"
    private static let showComponentKey = "traceview.showComponent"
    private static let savedFiltersKey = "traceview.savedFilters"
    private static let detailDisplayModeKey = "traceview.detailDisplayMode"
    private static let highlightRulesKey = "traceview.highlightRules"
    private static let findModeKey = "traceview.findMode"
    private static let useNewLogViewKey = "traceview.useNewLogView"
    static let restoreTabsOnLaunchKey = "traceview.restoreTabsOnLaunch"

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

    @Published var savedFilters: [LogFilterPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(savedFilters) {
                UserDefaults.standard.set(data, forKey: Self.savedFiltersKey)
            }
        }
    }

    @Published var detailDisplayMode: DetailDisplayMode {
        didSet { UserDefaults.standard.set(detailDisplayMode.rawValue, forKey: Self.detailDisplayModeKey) }
    }

    @Published var highlightRules: [HighlightRule] {
        didSet {
            if let data = try? JSONEncoder().encode(highlightRules) {
                UserDefaults.standard.set(data, forKey: Self.highlightRulesKey)
            }
        }
    }

    @Published var defaultFindMode: FindMode {
        didSet { UserDefaults.standard.set(defaultFindMode.rawValue, forKey: Self.findModeKey) }
    }

    // Phase 2 feature flag. Routes LogDocumentView to the new custom
    // NSView-in-NSScrollView renderer (LogScrollView) instead of the
    // NSTableView-based NSLogTableView. Default off until the new view
    // reaches parity and we flip it during P2.5 dogfood. The toggle stays
    // exposed in Settings as the rollback escape hatch.
    @Published var useNewLogView: Bool {
        didSet { UserDefaults.standard.set(useNewLogView, forKey: Self.useNewLogViewKey) }
    }

    @Published var restoreTabsOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(restoreTabsOnLaunch, forKey: Self.restoreTabsOnLaunchKey)
            if !restoreTabsOnLaunch {
                // Flipping off clears any existing saved state so the next
                // launch is clean — nothing silently persists after opt-out.
                UserDefaults.standard.removeObject(forKey: AppState.savedOpenTabsKey)
                UserDefaults.standard.removeObject(forKey: AppState.savedSelectedTabKey)
            }
        }
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

        if let data = defaults.data(forKey: Self.savedFiltersKey),
           let decoded = try? JSONDecoder().decode([LogFilterPreset].self, from: data) {
            self.savedFilters = decoded
        } else {
            self.savedFilters = []
        }

        let rawMode = defaults.string(forKey: Self.detailDisplayModeKey) ?? DetailDisplayMode.inline.rawValue
        self.detailDisplayMode = DetailDisplayMode(rawValue: rawMode) ?? .inline

        // Default off — tab restoration is opt-in.
        self.restoreTabsOnLaunch = defaults.bool(forKey: Self.restoreTabsOnLaunchKey)

        if let data = defaults.data(forKey: Self.highlightRulesKey),
           let decoded = try? JSONDecoder().decode([HighlightRule].self, from: data) {
            self.highlightRules = decoded
        } else {
            self.highlightRules = []
        }

        let rawFind = defaults.string(forKey: Self.findModeKey) ?? FindMode.filter.rawValue
        self.defaultFindMode = FindMode(rawValue: rawFind) ?? .filter

        // Default ON as of P2.5 — the new renderer is the production
        // path; the toggle remains as a rollback hatch. Users who
        // previously opted out (set the key to false explicitly) keep
        // their preference; users who never touched it get the new
        // renderer on first launch.
        if defaults.object(forKey: Self.useNewLogViewKey) == nil {
            self.useNewLogView = true
        } else {
            self.useNewLogView = defaults.bool(forKey: Self.useNewLogViewKey)
        }
    }
}

enum DetailDisplayMode: String, CaseIterable, Identifiable {
    case inline = "Inline"
    case bottomPane = "Bottom Pane"

    var id: String { rawValue }
}
