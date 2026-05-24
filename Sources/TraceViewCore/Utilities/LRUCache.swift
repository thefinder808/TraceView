import Foundation

/// Fixed-capacity least-recently-used cache. Keys are touched on `get` and
/// `put`; when the cache is full a new put evicts the oldest entry.
///
/// Phase 3 uses this to absorb redraw and binary-search re-lookups in
/// `IndexedEntrySource.entry(at:)` so the parser only runs once per
/// recently-touched row. Main-thread-only — no internal synchronization.
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var dict: [Key: Value] = [:]
    private var order: [Key] = []   // most-recent at end

    init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be > 0")
        self.capacity = capacity
        dict.reserveCapacity(capacity)
        order.reserveCapacity(capacity)
    }

    var count: Int { dict.count }

    func get(_ key: Key) -> Value? {
        guard let value = dict[key] else { return nil }
        if let idx = order.firstIndex(of: key), idx != order.count - 1 {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    func put(_ key: Key, _ value: Value) {
        if dict[key] != nil {
            dict[key] = value
            if let idx = order.firstIndex(of: key), idx != order.count - 1 {
                order.remove(at: idx)
                order.append(key)
            }
            return
        }
        if dict.count >= capacity, let oldest = order.first {
            order.removeFirst()
            dict.removeValue(forKey: oldest)
        }
        dict[key] = value
        order.append(key)
    }

    func removeAll() {
        dict.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
