import Foundation

/// State machine for a `LogDocument`'s initial load.
///
/// `.idle` — no load in progress (e.g. a `.unifiedLog` doc that hasn't started
/// streaming, or a `.merged` doc waiting for source subscriptions).
/// `.streaming(rowsLoaded:)` — a chunked initial parse is in flight; the
/// associated row count is updated per chunk arrival so the spinner UI can
/// show progress.
/// `.complete` — initial parse finished; subsequent appends (live-tail, file
/// watcher) flow through `didAppend` without changing this state.
///
/// Equatable so SwiftUI views can use `.task(id: loadState)` if they want
/// per-state side effects, though most UI surfaces should observe the
/// `LogDocument.isLoading: Bool` shim instead — the boolean changes only
/// on the meaningful idle ↔ streaming ↔ complete transitions, not on every
/// chunk's `rowsLoaded` increment, so it doesn't churn the SwiftUI graph.
enum LoadState: Equatable {
    case idle
    case streaming(rowsLoaded: Int)
    case complete
}
