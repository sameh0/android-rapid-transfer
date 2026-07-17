import Foundation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class LocalBrowserViewModelTests: XCTestCase {
    func testNavigationStackSupportsDownUpBackAndBreadcrumbs() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)

        await model.load()
        let albums = try XCTUnwrap(model.entries.first { $0.name == "Albums" })
        await model.navigate(to: albums)
        XCTAssertEqual(model.currentLocation, fixture.albums.path)
        XCTAssertTrue(model.canGoBack)
        XCTAssertTrue(model.canGoUp)

        let summer = try XCTUnwrap(model.entries.first { $0.name == "Summer" })
        await model.navigate(to: summer)
        XCTAssertEqual(model.breadcrumbs.map(\.label).suffix(2), ["Albums", "Summer"])

        await model.goBack()
        XCTAssertEqual(model.currentLocation, fixture.albums.path)
        await model.goUp()
        XCTAssertEqual(model.currentLocation, fixture.root.path)
        await model.goBack()
        XCTAssertEqual(model.currentLocation, fixture.albums.path)

        let rootCrumb = try XCTUnwrap(model.breadcrumbs.first)
        await model.navigate(to: rootCrumb)
        XCTAssertEqual(model.currentLocation, fixture.root.path)
    }

    func testDisplayLocationShowsTheHomeFolderAsTilde() {
        let inHome = LocalBrowserViewModel(startURL: URL.homeDirectory.appending(path: "Pictures"))
        XCTAssertEqual(inHome.displayLocation, "~/Pictures")
        XCTAssertEqual(inHome.currentLocation, URL.homeDirectory.appending(path: "Pictures").standardizedFileURL.path)

        let outside = LocalBrowserViewModel(startURL: URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(outside.displayLocation, "/Applications")
    }

    func testSortTogglesDirectionAndChangesColumn() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)

        await model.load()
        XCTAssertEqual(model.sortDescriptor, BrowserSortDescriptor())

        model.toggleSort(.name)
        XCTAssertEqual(model.sortDescriptor.direction, .descending)
        XCTAssertEqual(model.entries.filter { !$0.isDirectory }.map(\.name), ["z-small.txt", "a-large.txt"])

        model.toggleSort(.size)
        XCTAssertEqual(model.sortDescriptor, BrowserSortDescriptor(column: .size, direction: .ascending))
        XCTAssertEqual(model.entries.filter { !$0.isDirectory }.map(\.name), ["z-small.txt", "a-large.txt"])

        model.toggleSort(.size)
        XCTAssertEqual(model.entries.filter { !$0.isDirectory }.map(\.name), ["a-large.txt", "z-small.txt"])
    }

    func testRefreshSurfacesReadErrorsWithoutCrashingOrDiscardingLocation() async throws {
        let fixture = try LocalFixture()
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()
        let originalNames = model.entries.map(\.name)

        fixture.remove()
        await model.refresh()

        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.currentLocation, fixture.root.path)
        XCTAssertEqual(model.entries.map(\.name), originalNames)
        XCTAssertFalse(model.isLoading)

        model.dismissError()
        XCTAssertNil(model.error)
    }

    func testHiddenFilesAreFilteredByDefaultAndCanBeShown() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)

        await model.load()
        XCTAssertFalse(model.showsHiddenFiles)
        XCTAssertFalse(model.entries.contains { $0.name == ".hidden" })

        await model.setShowsHiddenFiles(true)
        XCTAssertTrue(model.showsHiddenFiles)
        XCTAssertTrue(model.entries.contains { $0.name == ".hidden" })

        await model.setShowsHiddenFiles(false)
        XCTAssertFalse(model.entries.contains { $0.name == ".hidden" })
    }

    func testClickToggleRangeSelectAllAndClearSelection() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()
        let ids = model.entries.map(\.id)
        XCTAssertGreaterThanOrEqual(ids.count, 3)

        model.selectEntry(id: ids[0], extending: false, toggling: false)
        XCTAssertEqual(model.selectedEntryIDs, [ids[0]])

        model.selectEntry(id: ids[2], extending: false, toggling: true)
        XCTAssertEqual(model.selectedEntryIDs, [ids[0], ids[2]])

        model.selectEntry(id: ids[1], extending: false, toggling: true)
        XCTAssertEqual(model.selectedEntryIDs, [ids[0], ids[1], ids[2]])
        model.selectEntry(id: ids[1], extending: false, toggling: true)
        XCTAssertEqual(model.selectedEntryIDs, [ids[0], ids[2]])

        model.selectEntry(id: ids[0], extending: false, toggling: false)
        model.selectEntry(id: ids[2], extending: true, toggling: false)
        XCTAssertEqual(model.selectedEntryIDs, Set(ids[0...2]))

        model.selectAll()
        XCTAssertEqual(model.selectedEntryIDs, Set(ids))
        model.clearSelection()
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
    }

    func testViewModeSwitchPreservesSelectionAndStatusUsesVolumeCapacity() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()
        let selectedID = try XCTUnwrap(model.entries.first?.id)
        model.selectEntry(id: selectedID, extending: false, toggling: false)

        model.viewMode = .grid
        XCTAssertEqual(model.selectedEntryIDs, [selectedID])
        model.viewMode = .list
        XCTAssertEqual(model.selectedEntryIDs, [selectedID])

        let capacity = try XCTUnwrap(model.capacity)
        XCTAssertEqual(
            model.statusText,
            "\(model.entries.count) items (1 selected), free space "
                + "\(capacity.formattedFreeBytes) of \(capacity.formattedTotalBytes)"
        )
    }

    func testArrowSelectionAndReturnOnlyDescendIntoFolders() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()

        model.moveSelection(by: 1, extending: false)
        XCTAssertEqual(model.selectedEntryIDs, [model.entries[0].id])
        model.moveSelection(by: 1, extending: true)
        XCTAssertEqual(model.selectedEntryIDs, Set(model.entries[0...1].map(\.id)))

        let file = try XCTUnwrap(model.entries.first { !$0.isDirectory })
        model.selectEntry(id: file.id, extending: false, toggling: false)
        await model.openSelection()
        XCTAssertEqual(model.currentLocation, fixture.root.path)

        let folder = try XCTUnwrap(model.entries.first { $0.isDirectory })
        model.selectEntry(id: folder.id, extending: false, toggling: false)
        await model.openSelection()
        XCTAssertEqual(model.currentLocation, fixture.albums.path)
    }

    func testFilteredEntriesInvalidateAfterRefreshAndQueryChange() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()

        XCTAssertEqual(model.filteredEntries(matching: "small").map(\.name), ["z-small.txt"])

        try Data("second".utf8).write(to: fixture.root.appending(path: "small-second.txt"))
        await model.refresh()
        XCTAssertEqual(
            Set(model.filteredEntries(matching: "small").map(\.name)),
            ["small-second.txt", "z-small.txt"]
        )
        XCTAssertEqual(model.filteredEntries(matching: "large").map(\.name), ["a-large.txt"])
    }

    func testCreateRenameAndMultiDeleteMutateAndRefreshLocalPane() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let fileOperations = TestLocalFileOperationService()
        let model = LocalBrowserViewModel(
            rootURL: fixture.root,
            fileOperations: fileOperations
        )
        await model.load()

        let didCreate = await model.makeDirectory(named: "Projects")
        XCTAssertTrue(didCreate)
        let projects = try XCTUnwrap(model.entries.first { $0.name == "Projects" })
        model.selectEntry(id: projects.id, extending: false, toggling: false)
        let didRename = await model.renameSelectedEntry(to: "Work")
        XCTAssertTrue(didRename)

        let work = try XCTUnwrap(model.entries.first { $0.name == "Work" })
        let smallFile = try XCTUnwrap(model.entries.first { $0.name == "z-small.txt" })
        model.selectedEntryIDs = [work.id, smallFile.id]
        let confirmation = try XCTUnwrap(model.deletionConfirmation())
        XCTAssertEqual(confirmation.destination, .trash)
        XCTAssertEqual(Set(confirmation.names), ["Work", "z-small.txt"])

        let didDelete = await model.deleteSelectedEntries()
        XCTAssertTrue(didDelete)
        XCTAssertFalse(model.entries.contains { $0.name == "Work" || $0.name == "z-small.txt" })
        let trashedURLs = await fileOperations.trashedURLs
        XCTAssertEqual(Set(trashedURLs.map(\.lastPathComponent)), ["Work", "z-small.txt"])
    }

    func testLocalOperationsRejectInvalidNamesAndCollisions() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let fileOperations = TestLocalFileOperationService()
        let model = LocalBrowserViewModel(
            rootURL: fixture.root,
            fileOperations: fileOperations
        )
        await model.load()

        let didCreateEmpty = await model.makeDirectory(named: "")
        XCTAssertFalse(didCreateEmpty)
        XCTAssertEqual(model.error?.message, "The name cannot be empty.")
        model.dismissError()
        let didCreateCollision = await model.makeDirectory(named: "Albums")
        XCTAssertFalse(didCreateCollision)
        XCTAssertTrue(model.error?.message.contains("already exists") == true)
        let createdURLs = await fileOperations.createdURLs
        XCTAssertTrue(createdURLs.isEmpty)
    }

    func testLocalFileOperationServiceExecutesOutsideMainActor() async throws {
        let fixture = try LocalFixture()
        defer { fixture.remove() }
        let fileOperations = ThreadRecordingLocalFileOperationService()
        let model = LocalBrowserViewModel(
            rootURL: fixture.root,
            fileOperations: fileOperations
        )
        await model.load()

        let didCreate = await model.makeDirectory(named: "Background")
        let executedOnMainThread = await fileOperations.executedOnMainThread

        XCTAssertTrue(didCreate)
        XCTAssertEqual(executedOnMainThread, false)
    }
}

private actor TestLocalFileOperationService: LocalFileOperationService {
    private(set) var createdURLs: [URL] = []
    private(set) var renamedItems: [(URL, URL)] = []
    private(set) var trashedURLs: [URL] = []

    func createDirectory(at url: URL) async throws {
        createdURLs.append(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func renameItem(at sourceURL: URL, to destinationURL: URL) async throws {
        renamedItems.append((sourceURL, destinationURL))
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func trashItem(at url: URL) async throws {
        trashedURLs.append(url)
        try FileManager.default.removeItem(at: url)
    }
}

private actor ThreadRecordingLocalFileOperationService: LocalFileOperationService {
    private(set) var executedOnMainThread: Bool?

    func createDirectory(at url: URL) async throws {
        executedOnMainThread = isExecutingOnMainThread()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func renameItem(at sourceURL: URL, to destinationURL: URL) async throws {
        executedOnMainThread = isExecutingOnMainThread()
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func trashItem(at url: URL) async throws {
        executedOnMainThread = isExecutingOnMainThread()
        try FileManager.default.removeItem(at: url)
    }

    private func isExecutingOnMainThread() -> Bool {
        Thread.isMainThread
    }
}

private struct LocalFixture {
    let root: URL
    let albums: URL
    let summer: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ART-LocalBrowserTests-\(UUID().uuidString)")
        albums = root.appending(path: "Albums")
        summer = albums.appending(path: "Summer")
        try FileManager.default.createDirectory(at: summer, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: root.appending(path: "z-small.txt"))
        try Data(repeating: 2, count: 1_000).write(to: root.appending(path: "a-large.txt"))
        try Data("secret".utf8).write(to: root.appending(path: ".hidden"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
