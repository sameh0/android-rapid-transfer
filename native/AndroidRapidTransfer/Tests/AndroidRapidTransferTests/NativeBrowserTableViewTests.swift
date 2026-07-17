import AppKit
import Foundation
@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import Observation
import XCTest

final class NativeBrowserTableViewTests: XCTestCase {
    func testSelectionMappingUsesVisibleRowOrderAndIgnoresMissingIDsAndRows() {
        let entries = [entry(id: "c"), entry(id: "a"), entry(id: "b")]

        let rows = NativeBrowserTableMapping.rowIndexes(
            for: ["a", "c", "missing"],
            in: entries
        )
        XCTAssertEqual(rows, IndexSet([0, 1]))

        let ids = NativeBrowserTableMapping.entryIDs(
            at: IndexSet([1, 2, 99]),
            in: entries
        )
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testSortDescriptorMappingRoundTripsAllColumnsAndDirections() {
        let comparators = [
            KeyPathComparator(\BrowserEntry.name, order: .reverse),
            KeyPathComparator(\BrowserEntry.sortableSize, order: .forward),
            KeyPathComparator(\BrowserEntry.sortableModifiedDate, order: .reverse)
        ]

        let descriptors = NativeBrowserTableMapping.sortDescriptors(for: comparators)
        XCTAssertEqual(descriptors.map(\.key), ["name", "size", "modified"])
        XCTAssertEqual(descriptors.map(\.ascending), [false, true, false])

        let roundTripped = NativeBrowserTableMapping.comparators(for: descriptors)
        XCTAssertEqual(roundTripped.map(\.keyPath), comparators.map(\.keyPath))
        XCTAssertEqual(roundTripped.map(\.order), comparators.map(\.order))
    }

    @MainActor
    func testReloadPreservesSelectionByIdentityAcrossSortAndRefresh() {
        let a = entry(id: "a")
        let b = entry(id: "b")
        let c = entry(id: "c")
        let model = NativeTableTestModel(entries: [a, b, c])
        model.selectedEntryIDs = [b.id]
        let parent = NativeBrowserTableView(
            model: model,
            entries: model.entries,
            location: "/",
            animatesChanges: false,
            highlight: nil,
            navigationDisabled: false,
            filePromiseExporter: nil,
            dragWriter: nil,
            copyAction: nil,
            queueAction: nil,
            dateRangeAction: nil,
            paneKind: .local,
            focusCoordinator: PaneFocusCoordinator(),
            createFolder: {},
            rename: { _ in },
            delete: { _ in },
            showInfo: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        let tableView = BrowserNSTableView()
        coordinator.configure(tableView)
        coordinator.tableView = tableView

        coordinator.entries = [a, b, c]
        coordinator.reloadDataPreservingSelection()
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 1))

        coordinator.entries = [b, c, a]
        coordinator.reloadDataPreservingSelection()
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertEqual(model.selectedEntryIDs, [b.id])

        coordinator.entries = [c, b]
        coordinator.reloadDataPreservingSelection()
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(model.selectedEntryIDs, [b.id])
    }

    func testRowUpdateAnimatesInsertionsAndRemovalsThatKeepOrder() {
        XCTAssertEqual(
            NativeBrowserTableMapping.rowUpdate(from: ["a", "b", "c"], to: ["a", "b", "c"], maxAnimatedRows: 10),
            .unchanged
        )
        XCTAssertEqual(
            NativeBrowserTableMapping.rowUpdate(from: ["a", "b", "c"], to: ["a", "new", "c"], maxAnimatedRows: 10),
            .insertRemove(removed: IndexSet(integer: 1), inserted: IndexSet(integer: 1))
        )
        XCTAssertEqual(
            NativeBrowserTableMapping.rowUpdate(from: ["a", "c"], to: ["a", "b", "c", "d"], maxAnimatedRows: 10),
            .insertRemove(removed: IndexSet(), inserted: IndexSet([1, 3]))
        )
    }

    func testRowUpdateReordersAPermutationWithSequentialMoves() {
        let old = ["a", "b", "c", "d"]
        let new = ["d", "b", "a", "c"]
        guard case let .reorder(moves) = NativeBrowserTableMapping.rowUpdate(
            from: old, to: new, maxAnimatedRows: 10
        ) else {
            return XCTFail("Expected a reorder")
        }
        var working = old
        for move in moves {
            working.insert(working.remove(at: move.from), at: move.to)
        }
        XCTAssertEqual(working, new)
    }

    func testRowUpdateReloadsWhatItShouldNotAnimate() {
        XCTAssertEqual(
            NativeBrowserTableMapping.rowUpdate(from: [], to: ["a"], maxAnimatedRows: 10),
            .reload
        )
        XCTAssertEqual(
            NativeBrowserTableMapping.rowUpdate(from: ["a", "b"], to: ["c", "d"], maxAnimatedRows: 10),
            .reload
        )
        XCTAssertEqual(
            NativeBrowserTableMapping.rowUpdate(
                from: ["a", "b"],
                to: ["a", "b", "c"],
                maxAnimatedRows: 2
            ),
            .reload
        )
        // Survivors changed order and something arrived: reload.
        XCTAssertEqual(
            NativeBrowserTableMapping.rowUpdate(from: ["a", "b"], to: ["b", "a", "c"], maxAnimatedRows: 10),
            .reload
        )
    }

    func testRowsWithChangedContentFindsEntriesThatKeptTheirID() {
        let old = [entry(id: "a"), entry(id: "b")]
        let resized = BrowserEntry(
            id: "b", name: "b", size: 42, modified: nil, isDirectory: false, location: "/b"
        )
        XCTAssertEqual(
            NativeBrowserTableMapping.rowsWithChangedContent(from: old, to: [entry(id: "new"), old[0], resized]),
            IndexSet(integer: 2)
        )
    }

    @MainActor
    func testAnimatedApplyKeepsRowsAndSelectionInStepWithEntries() {
        let a = entry(id: "a")
        let b = entry(id: "b")
        let c = entry(id: "c")
        let model = NativeTableTestModel(entries: [a, b, c])
        model.selectedEntryIDs = [c.id]
        let parent = NativeBrowserTableView(
            model: model,
            entries: model.entries,
            location: "/",
            animatesChanges: true,
            highlight: nil,
            navigationDisabled: false,
            filePromiseExporter: nil,
            dragWriter: nil,
            copyAction: nil,
            queueAction: nil,
            dateRangeAction: nil,
            paneKind: .local,
            focusCoordinator: PaneFocusCoordinator(),
            createFolder: {},
            rename: { _ in },
            delete: { _ in },
            showInfo: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        let tableView = BrowserNSTableView()
        coordinator.configure(tableView)
        coordinator.tableView = tableView
        coordinator.apply([a, b, c], animated: false)
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 2))

        let d = entry(id: "d")
        coordinator.apply([a, d, c], animated: true)
        XCTAssertEqual(tableView.numberOfRows, 3)
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 2))
        XCTAssertEqual(model.selectedEntryIDs, [c.id])

        coordinator.apply([c, d, a], animated: true)
        XCTAssertEqual(tableView.numberOfRows, 3)
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertEqual(model.selectedEntryIDs, [c.id])
    }

    private func entry(id: String) -> BrowserEntry {
        BrowserEntry(
            id: id,
            name: id,
            size: nil,
            modified: nil,
            isDirectory: false,
            location: "/\(id)"
        )
    }
}

@MainActor
@Observable
private final class NativeTableTestModel: BrowserPaneModel {
    let title = "Test"
    var entries: [BrowserEntry]
    let breadcrumbs: [BreadcrumbSegment] = []
    let currentLocation = "/"
    let sortDescriptor = BrowserSortDescriptor()
    var tableSortOrder = [KeyPathComparator(\BrowserEntry.name)]
    var selectedEntryIDs: Set<BrowserEntry.ID> = []
    var viewMode = BrowserViewMode.list
    let showsHiddenFiles = false
    let capacity: BrowserCapacity? = nil
    let isLoading = false
    let hasLoaded = true
    let error: BrowserPaneError? = nil
    let canGoBack = false
    let canGoUp = false
    let fileOperationsDisabled = false

    init(entries: [BrowserEntry]) {
        self.entries = entries
    }

    func load() async {}
    func refresh() async {}
    func navigate(to entry: BrowserEntry) async {}
    func navigate(to breadcrumb: BreadcrumbSegment) async {}
    func goBack() async {}
    func goUp() async {}
    func setShowsHiddenFiles(_ showsHiddenFiles: Bool) async {}
    func selectEntry(id: BrowserEntry.ID, extending: Bool, toggling: Bool) {}
    func selectAll() {}
    func clearSelection() {}
    func moveSelection(by offset: Int, extending: Bool) {}
    func openSelection() async {}
    func toggleSort(_ column: BrowserSortColumn) {}
    func dismissError() {}
}
