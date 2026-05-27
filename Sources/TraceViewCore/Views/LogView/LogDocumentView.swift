import SwiftUI
import Combine

struct LogDocumentView: View {
    @ObservedObject var document: LogDocument
    @StateObject private var viewModel: LogDocumentViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var selectedEntry: LogEntry?
    @State private var expandedEntryID: Int?
    // Spinner visibility is debounced separately from document.isLoading:
    // 150ms grace before showing (skips flash on fast loads) + 300ms min
    // display once shown (so it's actually perceptible when it does appear).
    @State private var showSpinner: Bool = false
    @State private var spinnerShownAt: Date?
    let pane: Pane

    init(document: LogDocument, pane: Pane = .primary) {
        self.document = document
        self.pane = pane
        self._viewModel = StateObject(wrappedValue: LogDocumentViewModel(document: document))
    }

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 0) {
            // Severity summary chips
            SeveritySummaryBar(document: document, viewModel: viewModel)

            // Event density histogram (hidden if timestamps unavailable)
            HistogramView(document: document, onBucketClick: { bucketIndex in
                jumpToBucket(bucketIndex)
            })

            // Filter bar — zIndex so the mode-toggle's HoverTooltip (which
            // extends past the bar's bottom edge into the table area) draws
            // above the AppKit-backed NSLogTableView's column headers.
            // Same fix pattern as ContentView's paneSyncDivider.zIndex(1).
            FilterBarView(viewModel: viewModel, pane: pane)
                .zIndex(1)

            Divider().background(theme.border)

            // Log table + detail pane
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    loadingOverlay(theme: theme)
                    streamErrorOverlay(theme: theme)

                    logTable()

                    // Jump to bottom button
                    if !document.isFollowing {
                        Button {
                            appState.setFollowing(pane: pane, following: true)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Jump to Bottom")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.accentColor)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                    }
                }

                // Bottom detail pane (only in .bottomPane mode). Inline
                // expansion lands as a per-row drawer in both renderers
                // now, so the new view no longer falls back here.
                if settingsManager.detailDisplayMode == .bottomPane, let entry = selectedEntry {
                    Divider().background(theme.border)

                    DetailPaneView(entry: entry, onClose: { selectedEntry = nil })
                        .frame(minHeight: 80, idealHeight: 120, maxHeight: 250)
                }
            }

            Divider().background(theme.border)

            // Status bar
            StatusBarView(document: document, viewModel: viewModel)
        }
        .onAppear {
            viewModel.findMode = settingsManager.defaultFindMode
            viewModel.load()
        }
        .task(id: document.isLoading) {
            // Spinner debounce. .task(id:) auto-cancels and restarts on each
            // isLoading transition, so a fast load → grace-period sleep gets
            // cancelled before showSpinner ever flips on. A slow load that
            // finishes early in the min-display window finishes the sleep
            // before flipping showSpinner off.
            if document.isLoading {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, document.isLoading else { return }
                showSpinner = true
                spinnerShownAt = Date()
            } else {
                if showSpinner, let started = spinnerShownAt {
                    let remaining = 0.3 - Date().timeIntervalSince(started)
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                }
                guard !Task.isCancelled else { return }
                showSpinner = false
                spinnerShownAt = nil
            }
        }
        .onChange(of: selectedEntry?.lineNumber) { _, newValue in
            // Selecting a row in this pane marks it active. nil transitions
            // (filter-driven entry-list churn) don't count as user intent.
            if newValue != nil { appState.activePane = pane }
        }
        .onChange(of: appState.pendingBookmarkToggleTick) { _, _ in
            guard pane == appState.activePane else { return }
            guard let entry = selectedEntry else { return }
            if document.bookmarks.contains(entry.lineNumber) {
                document.bookmarks.remove(entry.lineNumber)
            } else {
                document.bookmarks.insert(entry.lineNumber)
            }
        }
        .onChange(of: appState.pendingRegexToggleTick) { _, _ in
            guard pane == appState.activePane else { return }
            viewModel.filter.isRegex.toggle()
        }
        .onChange(of: appState.pendingFindStepTick) { _, _ in
            // ⌘G is a no-op in filter mode by design (matches is empty
            // there) — users switch to Find via the labeled mode toggle
            // in the filter bar. The earlier auto-flip workaround that
            // silently changed mode for the user retired with #38's
            // discoverable mode toggle.
            guard pane == appState.activePane else { return }
            guard let line = viewModel.advanceMatch(by: appState.pendingFindStepDirection) else { return }
            appState.goToLine(line, in: pane)
        }
        // Per-pane derived binding: only the pane named in the request
        // attaches its sheet. Both panes have this modifier, but only one
        // ever sees a non-nil item — guarantees the export uses the active
        // pane's filteredEntries and avoids the dual-presentation race the
        // old global-bool attachment had.
        .sheet(item: Binding(
            get: { appState.exportRequest?.pane == pane ? appState.exportRequest : nil },
            set: { _ in appState.exportRequest = nil }
        )) { _ in
            ExportSheet(
                entries: viewModel.filteredEntries,
                documentName: document.displayName
            )
            .environmentObject(themeManager)
        }
    }

    /// The log renderer. Phase 2 cutover left only LogScrollView; the
    /// legacy NSLogTableView path was deleted after the dogfood window.
    /// Extracted from the ZStack body because LogScrollView's argument
    /// list pushes SwiftUI's type-checker close to its limit and
    /// inlining trips a timeout (same reason loadingOverlay is split out).
    @ViewBuilder
    private func logTable() -> some View {
        LogScrollView(
            entries: viewModel.filteredEntries,
            theme: themeManager.current,
            fontSize: settingsManager.fontSize,
            showLineNumbers: settingsManager.showLineNumbers,
            showTimestamp: settingsManager.showTimestamp && document.hasTimestamps,
            showComponent: settingsManager.showComponent && document.hasComponents,
            isFollowing: document.isFollowing,
            selectedEntry: $selectedEntry,
            expandedEntryID: $expandedEntryID,
            pendingGoToLine: paneGoToLineBinding,
            bookmarkedLines: document.bookmarks,
            highlightRules: settingsManager.highlightRules,
            inlineExpansionEnabled: settingsManager.detailDisplayMode == .inline,
            themeManager: themeManager,
            onCopy: { entry in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.message, forType: .string)
            },
            onFilterToComponent: { entry in
                if let comp = entry.component {
                    viewModel.filter.component = comp
                }
            },
            onLookupErrorCode: { code in
                appState.lookupErrorCode(code)
            },
            onToggleBookmark: { entry in
                // Mutate the pane's own document directly — not via
                // AppState — so right-clicking in secondary doesn't
                // bookmark on primary's doc. Same fix shape as the
                // ⌘D observer.
                if document.bookmarks.contains(entry.lineNumber) {
                    document.bookmarks.remove(entry.lineNumber)
                } else {
                    document.bookmarks.insert(entry.lineNumber)
                }
            },
            onScrollUp: {
                appState.setFollowing(pane: pane, following: false)
            },
            onVisibleTopChanged: { entry in
                appState.reportPaneScroll(pane: pane, entry: entry)
            },
            scrollToTimestampSignal: scrollSyncSignal,
            showSource: document.isMerged,
            sourceNameForID: { id in
                document.mergedSourceNames[id]
            },
            onOpenInSourceLog: { entry in
                guard let id = entry.sourceDocumentID,
                      let line = entry.sourceLineNumber else { return }
                appState.openInSourceLog(documentID: id, lineNumber: line)
            }
        )
    }

    /// Centered spinner shown during initial parse. Tiny files flicker it
    /// for a frame; larger files (install.log, 100K+ rows) show it for the
    /// full parse window so the user knows work is happening. Extracted
    /// from the ZStack body because inlining it tripped SwiftUI's
    /// type-checker timeout (LogScrollView's argument list is already
    /// near the limit).
    @ViewBuilder
    private func loadingOverlay(theme: AppTheme) -> some View {
        if showSpinner {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if case .streaming(let rowsLoaded) = document.loadState, rowsLoaded > 0 {
                    Text("Loading… \(rowsLoaded.formatted()) rows")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.tableBackground.opacity(0.6))
            .zIndex(2)
        }
    }

    /// Empty-table message shown when a unified-log stream couldn't
    /// start or exited early. Surfaces what was previously a silent
    /// no-op (typical on managed Macs where `log stream --predicate …`
    /// is denied). Renders only when `streamError` is set — file-backed
    /// docs and successful streams stay clear of the overlay.
    @ViewBuilder
    private func streamErrorOverlay(theme: AppTheme) -> some View {
        if let message = document.streamError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.warningText)
                Text("Stream unavailable")
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 480)
                Text("Some predicates (Kernel, User) need admin on managed Macs. Close this tab and try a different filter, or open Console.app to check what `log stream` allows here.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.tableBackground.opacity(0.95))
            .zIndex(3)
        }
    }

    private var scrollSyncSignal: AnyPublisher<Date, Never> {
        switch pane {
        case .primary:   return appState.primaryScrollSyncSignal.eraseToAnyPublisher()
        case .secondary: return appState.secondaryScrollSyncSignal.eraseToAnyPublisher()
        }
    }

    /// Histogram bucket click → land on a real entry in (or just after)
    /// the bucket's time range, then route through the standard
    /// go-to-line channel so scroll + selection land the same way ⌘L does.
    ///
    /// Two refinements over the naive "first entry in range" lookup:
    ///
    /// 1. Pause Following synchronously BEFORE go-to-line. Otherwise the
    ///    follow timer can tick once before the async onScrollUp callback
    ///    in NSLogTableView.updateNSView gets a chance to pause it,
    ///    snapping the table back to the bottom and producing a "first
    ///    click does nothing, second click works" jerk.
    ///
    /// 2. Prefer the highest-severity level present in the bucket. If
    ///    bar.err > 0, find the first error/critical entry within the
    ///    bucket's range; else if bar.warn > 0, find the first warning;
    ///    else fall back to the original "first by timestamp at or after
    ///    range.start" (which rolls forward past empty buckets).
    private func jumpToBucket(_ index: Int) {
        guard let histogram = document.histogram else { return }
        let range = histogram.timeRange(forBucket: index)
        let bar = histogram.bars[index]
        let entries = viewModel.filteredEntries

        // Phase 4 PR2+PR3 fast path: when the underlying view is an
        // `.identity` or `.indexed` over an `IndexedEntrySource`, every
        // entry access routes through `parser.parse(line:)`
        // (DateFormatter et al). A linear `entries.first { ... }`
        // scan can parse-storm the main thread on a 36 M-row file.
        // Route through the source's bisect over the parallel
        // `logIndex.timestamps` + `.levels` arrays instead —
        // O(log N + bucketWidth), zero parser calls in the search
        // itself. For `.indexed` (post-filter), the bisect runs over
        // the filtered indices array so the jump lands on a visible
        // row, not a hidden one.
        let indexedTarget: (source: IndexedEntrySource, filter: [Int]?)?
        switch entries.backing {
        case .identity(let src):
            indexedTarget = (src as? IndexedEntrySource).map { ($0, nil) }
        case .indexed(let indices, let src):
            indexedTarget = (src as? IndexedEntrySource).map { ($0, indices) }
        case .materialized:
            indexedTarget = nil
        }
        if let indexedTarget {
            let entry = indexedHistogramJump(
                source: indexedTarget.source,
                range: range,
                bar: bar,
                restrictTo: indexedTarget.filter
            )
            guard let entry else { return }
            appState.setFollowing(pane: pane, following: false)
            appState.goToLine(entry.lineNumber, in: pane)
            return
        }

        var target: LogEntry?
        if bar.err > 0 {
            target = firstEntry(in: entries, range: range, levels: [.error, .critical])
        }
        if target == nil && bar.warn > 0 {
            target = firstEntry(in: entries, range: range, levels: [.warning])
        }
        if target == nil {
            target = entries.first { entry in
                guard let ts = entry.timestamp else { return false }
                return ts >= range.start
            }
        }

        guard let entry = target else { return }
        appState.setFollowing(pane: pane, following: false)
        appState.goToLine(entry.lineNumber, in: pane)
    }

    /// Indexed-mode histogram-click resolution. Same precedence as the
    /// general path (err → warn → first-in-range), but every lookup is
    /// a single bisect + bucket-walk over the source's parallel arrays
    /// — at most one parser invocation (the final `entry(at:)`).
    /// `restrictTo` scopes the search to a filtered subset of source
    /// indices when the filtered view's backing is `.indexed` (active
    /// filter) — without it the click would land on a hidden row.
    private func indexedHistogramJump(
        source: IndexedEntrySource,
        range: (start: Date, end: Date),
        bar: LogHistogram.Bar,
        restrictTo filteredIndices: [Int]?
    ) -> LogEntry? {
        let startEpoch = range.start.timeIntervalSince1970
        let endEpoch = range.end.timeIntervalSince1970
        var rowIdx: Int?
        if bar.err > 0 {
            rowIdx = source.firstRowInTimeRange(
                startEpoch: startEpoch, endEpoch: endEpoch,
                matchingLevels: [.error, .critical],
                restrictTo: filteredIndices
            )
        }
        if rowIdx == nil && bar.warn > 0 {
            rowIdx = source.firstRowInTimeRange(
                startEpoch: startEpoch, endEpoch: endEpoch,
                matchingLevels: [.warning],
                restrictTo: filteredIndices
            )
        }
        if rowIdx == nil {
            rowIdx = source.firstRowInTimeRange(
                startEpoch: startEpoch, endEpoch: endEpoch,
                matchingLevels: nil,
                restrictTo: filteredIndices
            )
        }
        guard let rowIdx else { return nil }
        return source.entry(at: rowIdx)
    }

    /// First entry whose timestamp falls within `[range.start, range.end)`
    /// AND matches one of the given levels. Used by jumpToBucket's
    /// level-aware preference to land on an actual error when an
    /// error-spike bucket is clicked.
    private func firstEntry<C: RandomAccessCollection>(
        in entries: C,
        range: (start: Date, end: Date),
        levels: [LogLevel]
    ) -> LogEntry? where C.Element == LogEntry {
        entries.first { entry in
            guard let ts = entry.timestamp,
                  ts >= range.start, ts < range.end else { return false }
            return levels.contains(entry.level)
        }
    }

    /// Per-pane go-to-line binding so each pane only consumes its own
    /// pending scroll. Required for the merged-view "Open in Source Log"
    /// flow which needs to scroll one pane without affecting the other.
    private var paneGoToLineBinding: Binding<Int?> {
        switch pane {
        case .primary:   return $appState.pendingPrimaryGoToLine
        case .secondary: return $appState.pendingSecondaryGoToLine
        }
    }
}

// MARK: - Export Sheet

struct ExportSheet: View {
    let entries: FilteredEntries
    let documentName: String
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedFormat: ExportFormat = .plainText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Log")
                .font(.title2.bold())

            Text("Export \(Formatters.formatCount(entries.count)) entries to a file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Format", selection: $selectedFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export...") {
                    ExportService.export(
                        entries: entries,
                        documentName: documentName,
                        format: selectedFormat
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
