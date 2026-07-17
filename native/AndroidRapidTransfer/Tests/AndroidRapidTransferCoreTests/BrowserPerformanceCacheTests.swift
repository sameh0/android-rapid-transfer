import XCTest
@testable import AndroidRapidTransferCore

final class BrowserPerformanceCacheTests: XCTestCase {
    func testSelectionIndicesFollowMutatedEntryOrderAndDiscardRemovedIDs() {
        var selection = BrowserSelectionState()
        selection.updateOrderedIDs(["a", "b", "c"])
        selection.select("b", extending: false, toggling: false)

        selection.updateOrderedIDs(["c", "b", "d", "a"])
        selection.select("a", extending: true, toggling: false)
        XCTAssertEqual(selection.selectedIDs, ["b", "d", "a"])

        selection.updateOrderedIDs(["c", "d"])
        XCTAssertEqual(selection.selectedIDs, ["d"])
        selection.move(by: -1, extending: false)
        XCTAssertEqual(selection.selectedIDs, ["c"])
    }

    func testFilterCacheInvalidatesForEntryAndQueryChanges() {
        var cache = BrowserEntryFilterCache()
        cache.updateEntries([
            Self.entry(id: "alpha", name: "Alpha.txt"),
            Self.entry(id: "beta", name: "Beta.txt")
        ])

        XCTAssertEqual(cache.entries(matching: "alp").map(\.id), ["alpha"])

        cache.updateEntries([
            Self.entry(id: "alpine", name: "Alpine.txt"),
            Self.entry(id: "beta", name: "Beta.txt")
        ])
        XCTAssertEqual(cache.entries(matching: "alp").map(\.id), ["alpine"])
        XCTAssertEqual(cache.entries(matching: "beta").map(\.id), ["beta"])
        XCTAssertEqual(cache.entries(matching: "").map(\.id), ["alpine", "beta"])
    }

    private static func entry(id: String, name: String) -> BrowserEntry {
        BrowserEntry(
            id: id,
            name: name,
            size: nil,
            modified: nil,
            isDirectory: false,
            location: "/\(name)"
        )
    }
}
