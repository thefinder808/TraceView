import XCTest
@testable import TraceViewCore

final class LRUCacheTests: XCTestCase {

    func testGetReturnsNilForMissingKey() {
        let cache = LRUCache<Int, String>(capacity: 4)
        XCTAssertNil(cache.get(42))
    }

    func testPutThenGetRoundTrips() {
        let cache = LRUCache<Int, String>(capacity: 4)
        cache.put(1, "one")
        XCTAssertEqual(cache.get(1), "one")
        XCTAssertEqual(cache.count, 1)
    }

    func testPutEvictsOldestWhenAtCapacity() {
        let cache = LRUCache<Int, String>(capacity: 3)
        cache.put(1, "one")
        cache.put(2, "two")
        cache.put(3, "three")
        cache.put(4, "four")   // evicts 1

        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.get(2), "two")
        XCTAssertEqual(cache.get(3), "three")
        XCTAssertEqual(cache.get(4), "four")
        XCTAssertEqual(cache.count, 3)
    }

    func testGetTouchesRecencyOrder() {
        let cache = LRUCache<Int, String>(capacity: 3)
        cache.put(1, "one")
        cache.put(2, "two")
        cache.put(3, "three")
        _ = cache.get(1)        // 1 becomes most-recent
        cache.put(4, "four")    // evicts 2, not 1

        XCTAssertEqual(cache.get(1), "one")
        XCTAssertNil(cache.get(2))
        XCTAssertEqual(cache.get(3), "three")
        XCTAssertEqual(cache.get(4), "four")
    }

    func testPutOnExistingKeyUpdatesValue() {
        let cache = LRUCache<Int, String>(capacity: 3)
        cache.put(1, "one")
        cache.put(1, "ONE")
        XCTAssertEqual(cache.get(1), "ONE")
        XCTAssertEqual(cache.count, 1)
    }

    func testRemoveAllClears() {
        let cache = LRUCache<Int, String>(capacity: 3)
        cache.put(1, "one")
        cache.put(2, "two")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.get(1))
        XCTAssertNil(cache.get(2))
    }
}
