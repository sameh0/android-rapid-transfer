import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class BrowserLoadingProgressTests: XCTestCase {
    func testFolderNameAndItemsRead() {
        let progress = BrowserLoadingProgress(
            path: "/DCIM/Camera",
            itemCount: 2_003,
            fractionCompleted: 0.5
        )
        XCTAssertEqual(progress.folderName, "Camera")
        XCTAssertEqual(progress.itemsRead, 1_002)
        XCTAssertNil(BrowserLoadingProgress(path: "/").folderName)
        XCTAssertNil(BrowserLoadingProgress(path: "/A", itemCount: 4).itemsRead)
    }

    func testFractionIsClampedSoItemsReadNeverExceedsTheCount() {
        let over = BrowserLoadingProgress(path: "/A", itemCount: 10, fractionCompleted: 1.7)
        XCTAssertEqual(over.fractionCompleted, 1)
        XCTAssertEqual(over.itemsRead, 10)
        let under = BrowserLoadingProgress(path: "/A", itemCount: 10, fractionCompleted: -1)
        XCTAssertEqual(under.itemsRead, 0)
    }

    func testDevicePanePublishesWalkProgressWhileOpeningAFolderAndClearsItAfter() async throws {
        let provider = GatedWalkProvider(
            provider: MockMTPProvider(
                storages: [StorageInfo(id: 1, storageDescription: "Internal storage")],
                entries: [
                    walkEntry(path: "/DCIM", folder: true, objectID: 1),
                    walkEntry(path: "/DCIM/photo.jpg", objectID: 2)
                ]
            ),
            gatedPath: "/DCIM",
            progress: WalkProgress(fullPath: "/DCIM", itemCount: 2_000, fractionCompleted: 0.25)
        )
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        XCTAssertNil(model.loadingProgress)

        let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
        let navigation = Task { await model.navigate(to: dcim) }
        await provider.waitUntilGatedWalkStarts()
        await drainMainQueue()

        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(
            model.loadingProgress,
            BrowserLoadingProgress(path: "/DCIM", itemCount: 2_000, fractionCompleted: 0.25)
        )
        XCTAssertEqual(model.loadingProgress?.itemsRead, 500)

        await provider.openGate()
        await navigation.value
        await drainMainQueue()
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.loadingProgress)
        XCTAssertEqual(model.currentLocation, "/DCIM")
    }

    func testLateProgressFromAFinishedLoadIsDropped() async throws {
        let provider = MockMTPProvider(
            storages: [StorageInfo(id: 1, storageDescription: "Internal storage")],
            entries: [walkEntry(path: "/DCIM", folder: true, objectID: 1)],
            walkProgress: [WalkProgress(fullPath: "/", itemCount: 1, fractionCompleted: 1)]
        )
        let model = DeviceBrowserViewModel(provider: provider)
        await model.load()
        await drainMainQueue()
        XCTAssertNil(model.loadingProgress)
    }

    private func drainMainQueue() async {
        for _ in 0..<5 {
            await Task.yield()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func walkEntry(path: String, folder: Bool = false, objectID: UInt32) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: folder ? 0 : 100,
            isFolder: folder,
            modified: nil,
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: folder ? "" : url.pathExtension,
            parentId: 0,
            objectId: objectID
        )
    }
}

/// Reports `progress` for `gatedPath`, then holds that walk until the test
/// opens the gate, so the pane can be observed mid-load.
private actor GatedWalkProvider: MTPDeviceProvider {
    private let provider: any MTPDeviceProvider
    private let gatedPath: String
    private let progress: WalkProgress
    private let gate = MockTransferGate()
    private var didStartGatedWalk = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: any MTPDeviceProvider, gatedPath: String, progress: WalkProgress) {
        self.provider = provider
        self.gatedPath = gatedPath
        self.progress = progress
    }

    func waitUntilGatedWalkStarts() async {
        guard !didStartGatedWalk else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func openGate() async {
        await gate.open()
    }

    func deviceInfo() async throws -> DeviceInfo { try await provider.deviceInfo() }
    func storages() async throws -> [StorageInfo] { try await provider.storages() }
    func walk(input: DirectoryWalkInput) async throws -> [WalkEntry] {
        try await provider.walk(input: input)
    }

    func walk(
        input: DirectoryWalkInput,
        onProgress: @escaping @Sendable (WalkProgress) -> Void
    ) async throws -> [WalkEntry] {
        if input.fullPath == gatedPath {
            onProgress(progress)
            didStartGatedWalk = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await gate.wait()
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
    func dispose() async throws -> Bool { try await provider.dispose() }
}
