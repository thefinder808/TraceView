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

            // Filter bar
            FilterBarView(viewModel: viewModel, pane: pane)

            Divider().background(theme.border)

            // Log table + detail pane
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    NSLogTableView(
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
                            appState.toggleBookmark(lineNumber: entry.lineNumber)
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

                // Bottom detail pane (only in .bottomPane mode)
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
        .onChange(of: appState.pendingBookmarkToggleTick) { _, _ in
            guard let entry = selectedEntry else { return }
            appState.toggleBookmark(lineNumber: entry.lineNumber)
        }
        .onChange(of: appState.pendingFindStepTick) { _, _ in
            // Gated to primary so the menu's ⌘G doesn't fire in BOTH panes
            // when split is open (each pane's onChange would otherwise
            // advance its own match cursor and self-scroll). Secondary-pane
            // search-step support depends on tracking which pane has focus
            // — queued for v1.0.3.
            guard pane == .primary else { return }
            guard let line = viewModel.advanceMatch(by: appState.pendingFindStepDirection) else { return }
            appState.goToLine(line, in: pane)
        }
        .sheet(isPresented: $appState.showExport) {
            ExportSheet(
                entries: viewModel.filteredEntries,
                documentName: document.displayName
            )
            .environmentObject(themeManager)
        }
    }

    /// Publisher fed to NSLogTableView so the table self-subscribes once at
    /// makeNSView. Always returned (regardless of sync toggle) — the sender
    /// side, AppState.reportPaneScroll, gates whether anything actually
    /// fires, so a disabled sync just means no Dates ever arrive.
    private var scrollSyncSignal: AnyPublisher<Date, Never> {
        switch pane {
        case .primary:   return appState.primaryScrollSyncSignal.eraseToAnyPublisher()
        case .secondary: return appState.secondaryScrollSyncSignal.eraseToAnyPublisher()
        }
    }

    /// Histogram bucket click → find the first entry in the bucket's time
    /// range that survives the current filter, then route through the
    /// standard go-to-line channel so scroll + selection land the same way
    /// ⌘L does. Respecting the filter matters because the histogram shows
    /// unfiltered density but the table only renders the filtered slice;
    /// jumping to a filtered-out line would be a dead-end.
    ///
    /// Pausing follow is handled downstream: NSLogTableView's pendingGoToLine
    /// path invokes onScrollUp() after scrolling, which routes through
    /// appState.setFollowing and mirrors to the other pane when sync is on.
    ///
    /// Lookup walks `filteredEntries` in line order, so for severely out-of-
    /// order logs (multi-threaded, post-merged) the landing entry is the
    /// first by line whose timestamp falls in the bucket — not necessarily
    /// the first by timestamp. Defensible: clicking a histogram bucket
    /// should land on a real, visible row.
    private func jumpToBucket(_ index: Int) {
        guard let histogram = document.histogram else { return }
        let range = histogram.timeRange(forBucket: index)
        let target = viewModel.filteredEntries.first { entry in
            guard let ts = entry.timestamp else { return false }
            return ts >= range.start
        }
        guard let entry = target else { return }
        appState.goToLine(entry.lineNumber, in: pane)
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
    let entries: [LogEntry]
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
