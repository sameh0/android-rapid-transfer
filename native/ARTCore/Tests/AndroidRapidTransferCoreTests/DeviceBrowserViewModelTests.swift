import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class DeviceBrowserViewModelTests: XCTestCase {
    func testNavigationStackSupportsDownUpBackBreadcrumbsAndStorageDiscovery() async throws {
        let provider = DeviceFixture.makeProvider()
        let model = DeviceBrowserViewModel(provider: provider)

        await model.load()
        XCTAssertEqual(model.title, "Test Pixel")
        XCTAssertEqual(model.storages.map(\.name), ["Internal storage", "SD card"])
        XCTAssertEqual(model.selectedStorageID, 1)

        let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
        await model.navigate(to: dcim)
        let camera = try XCTUnwrap(model.entries.first { $0.name == "Camera" })
        await model.navigate(to: camera)
        XCTAssertEqual(model.currentLocation, "/DCIM/Camera")
        XCTAssertEqual(model.breadcrumbs.map(\.label), ["Device", "DCIM", "Camera"])

        await model.goBack()
        XCTAssertEqual(model.currentLocation, "/DCIM")
        await model.goUp()
        XCTAssertEqual(model.currentLocation, "/")
        await model.goBack()
        XCTAssertEqual(model.currentLocation, "/DCIM")

        let rootCrumb = try XCTUnwrap(model.breadcrumbs.first)
        await model.navigate(to: rootCrumb)
        XCTAssertEqual(model.currentLocation, "/")

        await model.selectStorage(id: 2)
        XCTAssertEqual(model.selectedStorageID, 2)
        XCTAssertEqual(model.currentLocation, "/")
    }

    func testSortTogglingOrdersDeviceFiles() async throws {
        let model = DeviceBrowserViewModel(provider: DeviceFixture.makeProvider())
        await model.load()
        let download = try XCTUnwrap(model.entries.first { $0.name == "Download" })
        await model.navigate(to: download)

        model.toggleSort(.size)
        XCTAssertEqual(model.entries.map(\.name), ["small.txt", "large.zip"])
        XCTAssertEqual(model.sortDescriptor.direction, .ascending)

        model.toggleSort(.size)
        XCTAssertEqual(model.entries.map(\.name), ["large.zip", "small.txt"])
        XCTAssertEqual(model.sortDescriptor.direction, .descending)

        model.toggleSort(.modified)
        XCTAssertEqual(model.sortDescriptor.column, .modified)
        XCTAssertEqual(model.sortDescriptor.direction, .ascending)
    }

    func testScriptedWalkFailureIsSurfacedAndNextRefreshRecovers() async {
        let provider = DeviceFixture.makeProvider()
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        if let selectedID = model.entries.first?.id {
            model.selectEntry(id: selectedID, extending: false, toggling: false)
        }

        await provider.scriptFailure(.deviceLocked, for: .walk)
        await model.refresh()

        XCTAssertEqual(model.entries, [])
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
        XCTAssertTrue(model.error?.message.contains("ErrorDeviceLocked") == true)
        XCTAssertFalse(model.isLoading)

        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.entries.isEmpty)
    }

    func testFailedStorageSwitchPreservesPreviousPathListingAndSelection() async throws {
        let provider = DeviceFixture.makeProvider()
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
        await model.navigate(to: dcim)
        let cameraID = try XCTUnwrap(model.entries.first { $0.name == "Camera" }?.id)
        model.selectedEntryIDs = [cameraID]
        let previousEntries = model.entries

        await provider.scriptFailure(.deviceLocked, for: .walk)
        await model.selectStorage(id: 2)

        XCTAssertEqual(model.selectedStorageID, 1)
        XCTAssertEqual(model.currentLocation, "/DCIM")
        XCTAssertEqual(model.entries, previousEntries)
        XCTAssertEqual(model.selectedEntryIDs, [cameraID])
        XCTAssertTrue(model.error?.message.contains("ErrorDeviceLocked") == true)
    }

    func testSupersededStorageSwitchDoesNotClobberNewerNavigation() async throws {
        let provider = GatedStorageSwitchProvider(provider: DeviceFixture.makeProvider())
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })

        let storageSwitch = Task { await model.selectStorage(id: 2) }
        await provider.waitUntilStorageSwitchWalkStarts()
        await model.navigate(to: dcim)
        await provider.finishStorageSwitchWalk()
        await storageSwitch.value

        XCTAssertEqual(model.selectedStorageID, 1)
        XCTAssertEqual(model.currentLocation, "/DCIM")
        XCTAssertEqual(model.entries.map(\.name), ["Camera"])
        XCTAssertNil(model.error)
    }

    /// A refresh that lands while a navigation is still walking (the transfer
    /// panel refreshes the phone pane right after an upload finishes) walks
    /// where the user is going, instead of the old folder.
    func testRefreshDuringNavigationDoesNotSwallowTheNavigation() async throws {
        let provider = GatedStorageSwitchProvider(
            provider: DeviceFixture.makeProvider(),
            gatedStorageID: 1,
            gatedPath: "/DCIM"
        )
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })

        let navigation = Task { await model.navigate(to: dcim) }
        await provider.waitUntilStorageSwitchWalkStarts()
        let refresh = Task { await model.refresh() }
        await provider.finishStorageSwitchWalk()
        await refresh.value
        await navigation.value

        XCTAssertEqual(model.currentLocation, "/DCIM")
        XCTAssertEqual(model.entries.map(\.name), ["Camera"])
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.canGoBack, "the navigation keeps its history entry")
    }

    func testRefreshDuringStorageSwitchCompletesTheSwitch() async throws {
        let provider = GatedStorageSwitchProvider(provider: DeviceFixture.makeProvider())
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
        await model.navigate(to: dcim)

        let storageSwitch = Task { await model.selectStorage(id: 2) }
        await provider.waitUntilStorageSwitchWalkStarts()
        let refresh = Task { await model.refresh() }
        await provider.finishStorageSwitchWalk()
        await refresh.value
        await storageSwitch.value

        XCTAssertEqual(model.selectedStorageID, 2)
        XCTAssertEqual(model.currentLocation, "/")
        XCTAssertFalse(model.canGoBack)
        XCTAssertNil(model.error)
    }

    func testHiddenFilesPassThroughMockWalkPreference() async {
        let model = DeviceBrowserViewModel(provider: DeviceFixture.makeProvider())

        await model.load()
        XCTAssertFalse(model.showsHiddenFiles)
        XCTAssertFalse(model.entries.contains { $0.name == ".device-secret" })

        await model.setShowsHiddenFiles(true)
        XCTAssertTrue(model.showsHiddenFiles)
        XCTAssertTrue(model.entries.contains { $0.name == ".device-secret" })

        await model.setShowsHiddenFiles(false)
        XCTAssertFalse(model.entries.contains { $0.name == ".device-secret" })
    }

    func testDateRangeScanAppliesDotRuleIndependentlyOfBrowserHiddenFilesSetting() async {
        let model = DeviceBrowserViewModel(provider: DeviceFixture.makeProvider())
        await model.load()
        let scanner = DeviceFolderScanner { path in
            try await model.listDirectoryForScan(path, storageID: 1)
        }
        let filter = DateRangeFilter(start: isoDate("2025-01-01T00:00:00Z"))

        for showsHiddenFiles in [false, true] {
            await model.setShowsHiddenFiles(showsHiddenFiles)
            XCTAssertEqual(
                model.entries.contains { $0.name == ".device-secret" },
                showsHiddenFiles,
                "The browser fixture must reflect the toolbar setting under test"
            )

            let included = await scanner.scan(
                roots: ["/"],
                filter: filter,
                exclusions: ScanExclusionRules(ignoresDotFiles: false)
            )
            XCTAssertTrue(
                included.matches.contains { $0.entry.name == ".device-secret" },
                "The scan must surface dot files independently of the browser setting"
            )

            let excluded = await scanner.scan(
                roots: ["/"],
                filter: filter,
                exclusions: ScanExclusionRules(ignoresDotFiles: true)
            )
            XCTAssertFalse(
                excluded.matches.contains { $0.entry.name == ".device-secret" },
                "ScanExclusionRules must remain the authority for ignoring dot files"
            )
        }
    }

    func testStatusUsesSelectedStorageCapacityAndViewSwitchKeepsSelection() async throws {
        let model = DeviceBrowserViewModel(provider: DeviceFixture.makeProvider())
        await model.load()
        let selectedID = try XCTUnwrap(model.entries.first?.id)
        model.selectEntry(id: selectedID, extending: false, toggling: false)

        model.viewMode = .grid
        XCTAssertEqual(model.selectedEntryIDs, [selectedID])
        model.viewMode = .list
        XCTAssertEqual(model.selectedEntryIDs, [selectedID])

        let capacity = try XCTUnwrap(model.capacity)
        XCTAssertEqual(capacity, BrowserCapacity(freeBytes: 2_000_000_000, totalBytes: 8_000_000_000))
        XCTAssertEqual(
            model.statusText,
            "\(model.entries.count) items (1 selected), free space "
                + "\(capacity.formattedFreeBytes) of \(capacity.formattedTotalBytes)"
        )
    }

    func testCreateRenameAndMultiDeleteMutateProviderAndRefreshDevicePane() async throws {
        let provider = DeviceFixture.makeProvider()
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()

        let didCreate = await model.makeDirectory(named: "Projects")
        XCTAssertTrue(didCreate)
        let projects = try XCTUnwrap(model.entries.first { $0.name == "Projects" })
        model.selectedEntryIDs = [projects.id]
        let didRename = await model.renameSelectedEntry(to: "Work")
        XCTAssertTrue(didRename)

        let work = try XCTUnwrap(model.entries.first { $0.name == "Work" })
        let download = try XCTUnwrap(model.entries.first { $0.name == "Download" })
        model.selectedEntryIDs = [work.id, download.id]
        let confirmation = try XCTUnwrap(model.deletionConfirmation())
        XCTAssertEqual(confirmation.destination, .device)
        XCTAssertTrue(confirmation.message.contains("permanent and cannot be undone"))

        let didDelete = await model.deleteSelectedEntries()
        XCTAssertTrue(didDelete)
        XCTAssertFalse(model.entries.contains { $0.name == "Work" || $0.name == "Download" })
        let calls = await provider.callHistory()
        XCTAssertTrue(calls.contains(.makeDirectory))
        XCTAssertTrue(calls.contains(.renameFile))
        XCTAssertTrue(calls.contains(.deleteFiles))
        XCTAssertGreaterThanOrEqual(calls.filter { $0 == .walk }.count, 6)
    }

    func testDeviceCreateAndRenameValidateAgainstFreshSiblingListing() async throws {
        let provider = DeviceFixture.makeProvider()
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()

        let didCreate = await model.makeDirectory(named: "dcim")
        XCTAssertFalse(didCreate)
        XCTAssertTrue(model.error?.message.contains("already exists") == true)
        let download = try XCTUnwrap(model.entries.first { $0.name == "Download" })
        model.selectedEntryIDs = [download.id]
        let didRename = await model.renameSelectedEntry(to: "DCIM")
        XCTAssertFalse(didRename)

        let calls = await provider.callHistory()
        XCTAssertEqual(calls.filter { $0 == .makeDirectory }.count, 0)
        XCTAssertEqual(calls.filter { $0 == .renameFile }.count, 0)
        XCTAssertEqual(calls.filter { $0 == .walk }.count, 3)
    }

    func testTransferBusyStateGatesEveryDeviceMutation() async throws {
        let provider = DeviceFixture.makeProvider()
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
        model.selectedEntryIDs = [dcim.id]
        model.setFileOperationsDisabled(true)

        XCTAssertTrue(model.fileOperationsDisabled)
        let didCreate = await model.makeDirectory(named: "Blocked")
        let didRename = await model.renameSelectedEntry(to: "Blocked")
        let didDelete = await model.deleteSelectedEntries()
        XCTAssertFalse(didCreate)
        XCTAssertFalse(didRename)
        XCTAssertFalse(didDelete)

        let calls = await provider.callHistory()
        XCTAssertEqual(calls.filter { $0 == .makeDirectory }.count, 0)
        XCTAssertEqual(calls.filter { $0 == .renameFile }.count, 0)
        XCTAssertEqual(calls.filter { $0 == .deleteFiles }.count, 0)
    }
}

private enum DeviceFixture {
    static func makeProvider() -> MockMTPProvider {
        MockMTPProvider(
            deviceInfo: DeviceInfo(model: "Test Pixel"),
            storages: [
                StorageInfo(id: 1, storageDescription: "Internal storage", maxCapacity: 8_000_000_000, freeSpaceInBytes: 2_000_000_000),
                StorageInfo(id: 2, storageDescription: "SD card", maxCapacity: 4_000_000_000, freeSpaceInBytes: 1_000_000_000)
            ],
            entries: [
                entry(path: "/.device-secret", objectID: 7, size: 1, date: "2026-01-01T00:00:00Z"),
                entry(path: "/DCIM", folder: true, objectID: 1, date: "2026-01-01T00:00:00Z"),
                entry(path: "/DCIM/Camera", folder: true, objectID: 2, date: "2026-01-02T00:00:00Z"),
                entry(path: "/DCIM/Camera/photo.jpg", objectID: 3, size: 500, date: "2026-01-03T00:00:00Z"),
                entry(path: "/Download", folder: true, objectID: 4, date: "2026-01-04T00:00:00Z"),
                entry(path: "/Download/large.zip", objectID: 5, size: 2_000, date: "2026-01-06T00:00:00Z"),
                entry(path: "/Download/small.txt", objectID: 6, size: 20, date: "2026-01-05T00:00:00Z")
            ]
        )
    }

    private static func entry(
        path: String,
        folder: Bool = false,
        objectID: UInt32,
        size: Int64 = 0,
        date: String
    ) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: size,
            isFolder: folder,
            modified: wallClockDate(date),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: folder ? "" : url.pathExtension,
            parentId: 0,
            objectId: objectID
        )
    }
}

private actor GatedStorageSwitchProvider: MTPDeviceProvider {
    private let provider: any MTPDeviceProvider
    private let storageSwitchGate = MockTransferGate()
    private var didStartStorageSwitchWalk = false
    private var storageSwitchStartWaiters: [CheckedContinuation<Void, Never>] = []

    private let gatedStorageID: UInt32
    private let gatedPath: String

    /// Holds every walk of `gatedPath` on `gatedStorageID` until
    /// ``finishStorageSwitchWalk()``.
    init(provider: any MTPDeviceProvider, gatedStorageID: UInt32 = 2, gatedPath: String = "/") {
        self.provider = provider
        self.gatedStorageID = gatedStorageID
        self.gatedPath = gatedPath
    }

    func waitUntilStorageSwitchWalkStarts() async {
        guard !didStartStorageSwitchWalk else { return }
        await withCheckedContinuation { continuation in
            storageSwitchStartWaiters.append(continuation)
        }
    }

    func finishStorageSwitchWalk() async {
        await storageSwitchGate.open()
    }

    func deviceInfo() async throws -> DeviceInfo {
        try await provider.deviceInfo()
    }

    func storages() async throws -> [StorageInfo] {
        try await provider.storages()
    }

    func walk(input: DirectoryWalkInput) async throws -> [WalkEntry] {
        if input.storageId == gatedStorageID, input.fullPath == gatedPath {
            didStartStorageSwitchWalk = true
            let waiters = storageSwitchStartWaiters
            storageSwitchStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await storageSwitchGate.wait()
        }
        return try await provider.walk(input: input)
    }

    func fileExists(input: FileExistsInput) async throws -> [FileExistsData] {
        try await provider.fileExists(input: input)
    }

    func deleteFiles(input: DeleteFileInput) async throws -> Bool {
        try await provider.deleteFiles(input: input)
    }

    func makeDirectory(input: MakeDirectoryInput) async throws -> Bool {
        try await provider.makeDirectory(input: input)
    }

    func renameFile(input: RenameFileInput) async throws -> Bool {
        try await provider.renameFile(input: input)
    }

    func downloadFiles(input: DownloadFilesInput) async throws -> TransferOperation {
        try await provider.downloadFiles(input: input)
    }

    func uploadFiles(input: UploadFilesInput) async throws -> TransferOperation {
        try await provider.uploadFiles(input: input)
    }

    func dispose() async throws -> Bool {
        try await provider.dispose()
    }
}
