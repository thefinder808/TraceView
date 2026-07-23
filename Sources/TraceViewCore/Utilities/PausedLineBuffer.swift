import Foundation

/// Bounded FIFO buffer for the raw log lines a live stream produces while
/// the user has paused ingestion. Lines accumulate here instead of being
/// parsed and appended to the table; `drain()` returns them in arrival
/// order for replay when the user resumes.
///
/// **Overflow policy — buffer, then drop oldest.** Incoming lines are
/// *buffered* (not dropped) so a normal pause loses nothing on resume. The
/// buffer is capped only so a very long pause on a high-rate stream can't
/// grow memory without bound: once appending would exceed `capacity`, the
/// oldest buffered lines are discarded (and tallied in `droppedCount`) so
/// the most recent activity — what a live-tail user wants to catch up on —
/// survives. Because lines are stored raw and only numbered when they're
/// finally appended on resume, dropping the oldest leaves no gap in the
/// visible line numbers; `droppedCount` is the honest record of the loss.
///
/// The default cap of 100k lines is ~10-20 MB at typical log-line sizes,
/// far more than any normal pause accumulates.
struct PausedLineBuffer {
    private(set) var lines: [String] = []
    private(set) var droppedCount: Int = 0
    let capacity: Int

    init(capacity: Int = 100_000) {
        self.capacity = max(1, capacity)
    }

    var count: Int { lines.count }
    var isEmpty: Bool { lines.isEmpty }

    /// Append a batch of raw lines, enforcing the cap by dropping the
    /// oldest lines when the buffer would overflow.
    mutating func append(_ batch: [String]) {
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > capacity {
            let overflow = lines.count - capacity
            lines.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    /// Return every buffered line in arrival order and empty the buffer
    /// (including the dropped tally). Called on resume to replay the pause.
    mutating func drain() -> [String] {
        let out = lines
        lines.removeAll(keepingCapacity: false)
        droppedCount = 0
        return out
    }

    /// Discard everything without returning it. Used when the stream stops
    /// or dies while paused — the buffered lines belong to a session that
    /// is over.
    mutating func reset() {
        lines.removeAll(keepingCapacity: false)
        droppedCount = 0
    }
}
