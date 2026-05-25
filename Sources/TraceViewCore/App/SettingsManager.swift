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
    private static let primaryPaneWidthKey = "traceview.primaryPaneWidth"
    static let restoreTabsOnLaunchKey = "traceview.restoreTabsOnLaunch"
    /// Phase 5 hidden emergency opt-out. Set via `defaults write
    /// com.traceview.app traceview.disableIndexedMode -bool YES` to
    /// force every file through the eager in-memory loader regardless
    /// of size. For users who hit an indexed-mode bug and need to
    /// recover before a fix ships. No UI surface — documented in
    /// CLAUDE.md.
    static let disableIndexedModeKey = "traceview.disableIndexedMode"
    /// Phase 5 hidden test-and-tuning override. Set via `defaults write
    /// com.traceview.app traceview.indexedModeThresholdBytes -int N`
    /// to use indexed mode for files ≥ N bytes. Default 100 MB. Used
    /// by tests to drive indexed mode on small fixtures (set to 1) and
    /// by power users who want a different cutoff than the default.
    /// No UI surface.
    static let indexedModeThresholdKey = "traceview.indexedModeThresholdBytes"
    /// Phase 5 default threshold: 100 MB. Files at or above this size
    /// (and parser-eligible) go through `IndexedEntrySource`; smaller
    /// files use the eager chunked parse. 100 MB is roughly the point
    /// where the in-memory `LogEntry` array's RAM cost starts to feel
    /// real on typical Macs.
    static let indexedModeDefaultThresholdBytes: Int64 = 100 * 1024 * 1024

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

    /// Width of the primary pane when split-view is active. The
    /// secondary pane takes the remaining space (via maxWidth: .infinity).
    /// Persisted so the user's preferred layout survives quit/relaunch.
    /// Drag-resized via the divider between the two panes (see ContentView).
    @Published var primaryPaneWidth: Double {
        didSet { UserDefaults.standard.set(primaryPaneWidth, forKey: Self.primaryPaneWidthKey) }
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

        // Validate against a sane minimum. A previous build could have
        // saved a sub-min value through a clamp bug (drag-during-tiny-
        // window race, etc.); rather than honoring that and rendering a
        // wedged-too-small primary pane forever, fall back to the
        // default. The actual lower-bound clamp lives in ContentView
        // alongside PaneSplitLayout.minWidth — we keep a safe floor
        // here (200pt) just to reject genuinely broken saved values.
        let savedPaneWidth = defaults.double(forKey: Self.primaryPaneWidthKey)
        self.primaryPaneWidth = savedPaneWidth >= 200 ? savedPaneWidth : 640
    }
}

enum DetailDisplayMode: String, CaseIterable, Identifiable {
    case inline = "Inline"
    case bottomPane = "Bottom Pane"

    var id: String { rawValue }
}
