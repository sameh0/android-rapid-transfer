import Foundation
import MTPKit
import Observation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class TransferViewModelTests: XCTestCase {
    func testInitiationBuildsMultiSelectRequestsWithDestinationAndStorage() async throws {
        let local = TestTransferPane(
            title: "This Mac",
            entries: [
                Self.entry(id: "local-a", path: "/Users/test/Downloads/a.txt"),
                Self.entry(id: "local-b", path: "/Users/test/Downloads/b.txt")
            ],
            currentLocation: "/Users/test/Downloads"
        )
        local.selectedEntryIDs = ["local-a", "local-b"]
        let device = TestTransferPane(
            title: "Phone",
            entries: [
                Self.entry(id: "device-a", path: "/DCIM/a.jpg"),
                Self.entry(id: "device-b", path: "/DCIM/b.jpg")
            ],
            currentLocation: "/DCIM",
            selectedStorageID: 42
        )
        device.selectedEntryIDs = ["device-a", "device-b"]
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)

        XCTAssertEqual(
            model.downloadRequest(),
            TransferRequest(
                direction: .download,
                sources: ["/DCIM/a.jpg", "/DCIM/b.jpg"],
                destination: "/Users/test/Downloads",
                storageId: 42
            )
        )
        XCTAssertEqual(
            model.uploadRequest(),
            TransferRequest(
                direction: .upload,
                sources: [
                    "/Users/test/Downloads/a.txt",
                    "/Users/test/Downloads/b.txt"
                ],
                destination: "/DCIM",
                storageId: 42
            )
        )
        XCTAssertEqual(
            model.downloadRequest(
                sources: ["/Pictures/dropped.jpg"],
                destination: "/Users/test/Desktop",
                storageID: 99
            ),
            TransferRequest(
                direction: .download,
                sources: ["/Pictures/dropped.jpg"],
                destination: "/Users/test/Desktop",
                storageId: 99
            )
        )
        XCTAssertEqual(
            model.uploadRequest(
                sources: ["/Users/test/Desktop/dropped.txt"],
                destination: "/Documents",
                storageID: 100
            ),
            TransferRequest(
                direction: .upload,
                sources: ["/Users/test/Desktop/dropped.txt"],
                destination: "/Documents",
                storageId: 100
            )
        )

        model.detach()
        XCTAssertFalse(model.canDownload)
        XCTAssertFalse(model.canUpload)
        XCTAssertNil(model.downloadRequest())
        XCTAssertNil(model.uploadRequest())
    }


    func testEmptyCopyQueueCannotExecute() async {
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 1)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)

        XCTAssertTrue(model.copyQueue.isEmpty)
        XCTAssertFalse(model.canExecuteCopyQueue)

        model.detach()
    }


    func testCopyQueueClearsWhenTransferSessionDetaches() async {
        let local = TestTransferPane(title: "This Mac")
        let queuedEntry = Self.entry(id: "photo", path: "/DCIM/photo.jpg")
        let device = TestTransferPane(
            title: "Phone",
            entries: [queuedEntry],
            selectedStorageID: 1
        )
        device.selectedEntryIDs = [queuedEntry.id]
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)
        model.addSelectedDeviceEntriesToCopyQueue(
            storage: DeviceStorage(id: 1, name: "Internal Storage")
        )
        XCTAssertEqual(model.copyQueue.count, 1)

        model.detach()

        XCTAssertTrue(model.copyQueue.isEmpty)
        XCTAssertNil(model.copyQueue.sessionID)
        XCTAssertNil(model.copyQueue.storageID)
    }


    func testCopyReplacesQueueAppendDeduplicatesAndBothClearSourceSelection() async {
        let photo = Self.entry(id: "photo", path: "/DCIM/photo.jpg")
        let video = Self.entry(id: "video", path: "/DCIM/video.mp4")
        let device = TestTransferPane(
            title: "Phone",
            entries: [photo, video],
            selectedStorageID: 1
        )
        let storage = DeviceStorage(id: 1, name: "Internal Storage")
        let model = TransferViewModel(localModel: TestTransferPane(title: "This Mac"))
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)

        device.selectedEntryIDs = [photo.id]
        XCTAssertTrue(model.copySelectionToQueue(from: .device, storage: storage, replacing: true))
        XCTAssertEqual(model.copyQueue.items.map(\.path), ["/DCIM/photo.jpg"])
        XCTAssertTrue(device.selectedEntryIDs.isEmpty)

        device.selectedEntryIDs = [photo.id, video.id]
        model.copySelectionToQueue(from: .device, storage: storage, replacing: false)
        XCTAssertEqual(model.copyQueue.items.map(\.path), ["/DCIM/photo.jpg", "/DCIM/video.mp4"])
        XCTAssertTrue(device.selectedEntryIDs.isEmpty)

        device.selectedEntryIDs = [video.id]
        model.copySelectionToQueue(from: .device, storage: storage, replacing: true)
        XCTAssertEqual(model.copyQueue.items.map(\.path), ["/DCIM/video.mp4"])
        XCTAssertEqual(model.copyQueue.source, .device)
        model.detach()
    }

    func testCopyWithEmptySelectionLeavesQueueUntouched() async {
        let photo = Self.entry(id: "photo", path: "/Users/test/photo.jpg")
        let local = TestTransferPane(title: "This Mac", entries: [photo])
        let model = TransferViewModel(localModel: local)
        local.selectedEntryIDs = [photo.id]
        model.copySelectionToQueue(from: .local, replacing: true)

        XCTAssertFalse(model.copySelectionToQueue(from: .local, replacing: true))
        XCTAssertEqual(model.copyQueue.items.map(\.path), ["/Users/test/photo.jpg"])
    }

    func testPasteIsAvailableOnlyIntoTheOppositePane() async {
        let file = Self.entry(id: "file", path: "/Users/test/notes.txt")
        let local = TestTransferPane(title: "This Mac", entries: [file])
        let device = TestTransferPane(title: "Phone", selectedStorageID: 1)
        let model = TransferViewModel(localModel: local)

        local.selectedEntryIDs = [file.id]
        model.copySelectionToQueue(from: .local, replacing: true)
        XCTAssertFalse(model.canPaste(into: .device), "No device session yet")

        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)
        XCTAssertTrue(model.canPaste(into: .device))
        XCTAssertFalse(model.canPaste(into: .local))

        device.isLoading = true
        XCTAssertFalse(model.canPaste(into: .device))
        device.isLoading = false

        model.copyQueue.removeAll()
        XCTAssertFalse(model.canPaste(into: .device))
        XCTAssertFalse(model.canPaste(into: .local))
        model.detach()
    }

    func testDeviceQueuePasteRequiresTheSameSessionAndStorage() async {
        let photo = Self.entry(id: "photo", path: "/DCIM/photo.jpg")
        let device = TestTransferPane(title: "Phone", entries: [photo], selectedStorageID: 1)
        let model = TransferViewModel(localModel: TestTransferPane(title: "This Mac"))
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)
        device.selectedEntryIDs = [photo.id]
        model.copySelectionToQueue(
            from: .device,
            storage: DeviceStorage(id: 1, name: "Internal Storage"),
            replacing: true
        )

        XCTAssertTrue(model.canPaste(into: .local))
        XCTAssertFalse(model.canPaste(into: .device))

        device.selectedStorageID = 2
        XCTAssertFalse(model.canPaste(into: .local))
        model.detach()
    }

    func testPastingLocalItemsUploadsIntoDeviceFolderAndEmptiesQueue() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "upload.txt")
        try Data("payload".utf8).write(to: source)
        let file = Self.entry(id: "upload", path: source.path)
        let local = TestTransferPane(title: "This Mac", entries: [file])
        let device = TestTransferPane(title: "Phone", currentLocation: "/DCIM", selectedStorageID: 7)
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)
        local.selectedEntryIDs = [file.id]
        model.copySelectionToQueue(from: .local, replacing: true)

        let didPaste = await model.paste(into: .device)
        let jobs = await queue.snapshot.jobs

        XCTAssertTrue(didPaste)
        XCTAssertTrue(model.copyQueue.isEmpty)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.request.direction, .upload)
        XCTAssertEqual(jobs.first?.request.destination, "/DCIM")
        XCTAssertEqual(jobs.first?.request.storageId, 7)
        XCTAssertEqual(jobs.first?.request.sources, [source.path])
        model.detach()
    }

    func testPastingDeviceItemsDownloadsIntoLocalFolderWithQueuedMetadata() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "art-paste-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let folder = BrowserEntry(
            id: "trip",
            name: "Trip",
            size: nil,
            modified: nil,
            isDirectory: true,
            location: "/Pictures/Trip",
            objectId: 42
        )
        let device = TestTransferPane(title: "Phone", entries: [folder], selectedStorageID: 7)
        let local = TestTransferPane(title: "This Mac", currentLocation: destination.path)
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)
        device.selectedEntryIDs = [folder.id]
        model.copySelectionToQueue(
            from: .device,
            storage: DeviceStorage(id: 7, name: "Internal Storage"),
            replacing: true
        )
        // The device pane has since navigated elsewhere: the queued item's
        // directory flag and handle must come from the queue, not the listing.
        device.entries = []

        let didPaste = await model.paste(into: .local)
        let jobs = await queue.snapshot.jobs

        XCTAssertTrue(didPaste)
        XCTAssertTrue(model.copyQueue.isEmpty)
        let request = try XCTUnwrap(jobs.first?.request)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(request.direction, .download)
        XCTAssertEqual(request.sources, ["/Pictures/Trip"])
        XCTAssertEqual(request.destination, destination.standardizedFileURL.path)
        XCTAssertEqual(request.directorySources, ["/Pictures/Trip"])
        XCTAssertEqual(request.sourceObjectIds, ["/Pictures/Trip": 42])
        model.detach()
    }

    func testBatchExecuteIsUnavailableForLocalQueues() async {
        let file = Self.entry(id: "file", path: "/Users/test/notes.txt")
        let local = TestTransferPane(title: "This Mac", entries: [file])
        let device = TestTransferPane(title: "Phone", selectedStorageID: 1)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)
        local.selectedEntryIDs = [file.id]
        model.copySelectionToQueue(from: .local, replacing: true)

        XCTAssertFalse(model.canExecuteCopyQueue)
        model.detach()
    }

    func testExecuteCopyQueueEnqueuesNestedRequestThenClearsStagingQueue() async throws {
        let local = TestTransferPane(title: "This Mac")
        let queuedEntry = Self.entry(id: "photo", path: "/DCIM/Camera/photo.jpg")
        let device = TestTransferPane(
            title: "Phone",
            entries: [queuedEntry],
            selectedStorageID: 7
        )
        device.selectedEntryIDs = [queuedEntry.id]
        let transferQueue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: local)
        model.attach(queue: transferQueue, deviceModel: device)
        model.addSelectedDeviceEntriesToCopyQueue(
            storage: DeviceStorage(id: 7, name: "Internal Storage")
        )
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "art-copy-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let didEnqueue = await model.executeCopyQueue(destination: destination)
        let snapshot = await transferQueue.snapshot

        XCTAssertTrue(didEnqueue)
        XCTAssertTrue(model.copyQueue.isEmpty)
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertEqual(
            snapshot.jobs.first?.request.destination,
            destination.appending(path: "DCIM/Camera", directoryHint: .isDirectory).path
        )
        model.detach()
    }


    func testExecuteCopyQueueRetainsStagingQueueWhenEnqueuePreparationFails() async throws {
        let local = TestTransferPane(title: "This Mac")
        let queuedEntry = Self.entry(id: "photo", path: "/DCIM/photo.jpg")
        let device = TestTransferPane(
            title: "Phone",
            entries: [queuedEntry],
            selectedStorageID: 7
        )
        device.selectedEntryIDs = [queuedEntry.id]
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)
        model.addSelectedDeviceEntriesToCopyQueue(
            storage: DeviceStorage(id: 7, name: "Internal Storage")
        )
        let destinationFile = FileManager.default.temporaryDirectory
            .appending(path: "art-copy-queue-file-\(UUID().uuidString)")
        try Data().write(to: destinationFile)
        defer { try? FileManager.default.removeItem(at: destinationFile) }

        let didEnqueue = await model.executeCopyQueue(destination: destinationFile)

        XCTAssertFalse(didEnqueue)
        XCTAssertEqual(model.copyQueue.count, 1)
        XCTAssertTrue(model.isShowingOperationError)
        model.operationErrorMessage = nil
        model.detach()
    }

    func testPanelRowMapsQueueStatesAndDeviceNavigationBusyState() async {
        let local = TestTransferPane(title: "This Mac")
        let model = TransferViewModel(localModel: local)
        let id = UUID()
        let request = Self.uploadRequest

        model.receive(.jobUpdated(TransferJobSnapshot(id: id, request: request, state: .queued)))
        XCTAssertEqual(model.rows.first?.state, .queued)
        XCTAssertFalse(model.isDeviceNavigationDisabled)

        model.receive(
            .jobUpdated(TransferJobSnapshot(id: id, request: request, state: .preprocessing))
        )
        XCTAssertEqual(model.rows.first?.state, .preprocessing)
        XCTAssertTrue(model.isDeviceNavigationDisabled)

        let progress = TransferProgressSnapshot(progress: Self.progress(percent: 35))
        model.receive(
            .jobUpdated(
                TransferJobSnapshot(id: id, request: request, state: .transferring(progress))
            )
        )
        XCTAssertEqual(model.rows.first?.state, .transferring(progress))
        XCTAssertTrue(model.isDeviceNavigationDisabled)

        model.receive(
            .jobUpdated(
                TransferJobSnapshot(
                    id: id,
                    request: request,
                    state: .failed(
                        errorType: .device(.fileTransfer),
                        message: "Scripted failure"
                    )
                )
            )
        )
        XCTAssertEqual(
            model.rows.first?.state,
            .failed(TransferFailureDescription(
                type: .device(.fileTransfer),
                message: "Scripted failure",
                direction: request.direction
            ))
        )
        guard case let .failed(failure) = model.rows.first?.state else {
            return XCTFail("Expected a failed row")
        }
        // The panel titles the failure in words, keeping the code for reports.
        XCTAssertEqual(failure.title, "Copy didn’t finish")
        XCTAssertEqual(failure.technicalDetail, "ErrorFileTransfer: Scripted failure")
        XCTAssertFalse(model.isDeviceNavigationDisabled)
    }

    func testDetachTerminalizesRowsReleasesQueuesAndReenablesNavigation() async throws {
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            transferScripts: [MockTransferScript(completionGate: gate)]
        )
        let queue = TransferQueue(provider: provider)
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            currentLocation: "/",
            selectedStorageID: 1
        )
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)
        let id = await queue.enqueue(Self.uploadRequest)

        try await eventually {
            model.isDeviceNavigationDisabled && model.retainedQueueCount == 1
        }

        model.detach()

        XCTAssertFalse(model.isDeviceNavigationDisabled)
        XCTAssertFalse(model.isTransferSessionAvailable)
        XCTAssertNil(model.transferSessionID)
        XCTAssertEqual(model.retainedQueueCount, 0)
        XCTAssertEqual(
            model.rows.first(where: { $0.id == id })?.state,
            .failed(TransferFailureDescription(
                type: .deviceLost,
                message: "The device session is no longer available.",
                direction: .upload
            ))
        )

        model.dismiss(jobID: id)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.isPanelVisible)
        await gate.open()
    }

    func testPanelRowExposesDurationAndTransferredBytes() async {
        let local = TestTransferPane(title: "This Mac")
        let model = TransferViewModel(localModel: local)
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let progress = TransferProgressSnapshot(progress: Self.progress(percent: 100))

        model.receive(
            .jobUpdated(
                TransferJobSnapshot(
                    id: id,
                    request: Self.uploadRequest,
                    state: .completed,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(65),
                    lastProgress: progress
                )
            )
        )

        let row = model.rows.first
        XCTAssertEqual(row?.duration, 65)
        XCTAssertEqual(row?.totalBytes, 100)
        XCTAssertEqual(row?.sentBytes, 45)

        let unfinishedId = UUID()
        model.receive(
            .jobUpdated(
                TransferJobSnapshot(id: unfinishedId, request: Self.uploadRequest, state: .cancelled)
            )
        )
        let unfinishedRow = model.rows.first { $0.id == unfinishedId }
        XCTAssertNil(unfinishedRow?.duration)
        XCTAssertNil(unfinishedRow?.totalBytes)
    }

    func testPanelRowSourceDirectoryUsesMultiSourceCommonParent() async {
        let request = TransferRequest(
            direction: .download,
            sources: [
                "/Internal shared storage/DCIM/Camera/a.jpg",
                "/Internal shared storage/DCIM/Camera/b.jpg"
            ],
            destination: "/tmp",
            storageId: 1
        )

        XCTAssertEqual(Self.panelRow(for: request).sourceDirectory, "/Internal shared storage/DCIM/Camera")
    }

    func testPanelRowSourceDirectoryUsesSingleSourceParent() async {
        let request = TransferRequest(
            direction: .upload,
            sources: ["/Users/test/Downloads/photo.jpg"],
            destination: "/DCIM",
            storageId: 1
        )

        XCTAssertEqual(Self.panelRow(for: request).sourceDirectory, "/Users/test/Downloads")
    }

    func testPanelRowSourceDirectoryUsesDeepestCommonAncestor() async {
        let request = TransferRequest(
            direction: .download,
            sources: [
                "/Internal shared storage/DCIM/a.jpg",
                "/Internal shared storage/Pictures/b.jpg"
            ],
            destination: "/tmp",
            storageId: 1
        )

        XCTAssertEqual(Self.panelRow(for: request).sourceDirectory, "/Internal shared storage")
    }

    func testPanelRowSourceDirectoryPreservesRootAndOmitsMissingSources() async {
        let rootRequest = TransferRequest(
            direction: .download,
            sources: ["/photo.jpg"],
            destination: "/tmp",
            storageId: 1
        )
        let emptyRequest = TransferRequest(
            direction: .download,
            sources: [],
            destination: "/tmp",
            storageId: 1
        )

        XCTAssertEqual(Self.panelRow(for: rootRequest).sourceDirectory, "/")
        XCTAssertNil(Self.panelRow(for: emptyRequest).sourceDirectory)
    }

    func testDropInitiationEnqueuesRequestsForPaneDestinations() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let uploadA = fixture.source.appending(path: "a.txt")
        let uploadB = fixture.source.appending(path: "b.txt")
        try Data("a".utf8).write(to: uploadA)
        try Data("b".utf8).write(to: uploadB)
        let deviceEntry = Self.entry(id: "device-photo", path: "/photo.jpg")
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/photo.jpg", objectID: 1)]
        )
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let device = TestTransferPane(
            title: "Phone",
            entries: [deviceEntry],
            currentLocation: "/",
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let uploadIDs = await model.enqueueDroppedFilesOnDevice([uploadA, uploadB])
        let downloadIDs = await model.enqueueDroppedDeviceItems(
            sources: ["/photo.jpg"],
            storageID: 7
        )
        let snapshot = await queue.snapshot
        let jobs = snapshot.jobs

        XCTAssertEqual(uploadIDs.count, 1)
        XCTAssertEqual(downloadIDs.count, 1)
        XCTAssertEqual(
            jobs.map(\.request),
            [
                TransferRequest(
                    direction: .upload,
                    sources: [uploadA.path, uploadB.path],
                    destination: "/",
                    storageId: 7
                ),
                TransferRequest(
                    direction: .download,
                    sources: ["/photo.jpg"],
                    destination: fixture.destination.path,
                    storageId: 7
                )
            ]
        )
    }

    func testDeviceDropWaitsForTransientLoadThenEnqueuesUpload() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "upload.txt")
        try Data("payload".utf8).write(to: source)
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            currentLocation: "/DCIM",
            selectedStorageID: 7
        )
        device.isLoading = true
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        XCTAssertFalse(model.canUpload)
        let drop = Task { await model.enqueueDroppedFilesOnDevice([source]) }
        await Task.yield()
        device.isLoading = false
        let ids = await drop.value
        let jobs = await queue.snapshot.jobs

        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertNil(model.operationErrorMessage)
    }

    func testDeviceDropSurfacesBusyErrorWhenLoadDoesNotFinish() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "upload.txt")
        try Data("payload".utf8).write(to: source)
        let device = TestTransferPane(title: "Phone", selectedStorageID: 7)
        device.isLoading = true
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: TestTransferPane(title: "This Mac"))
        model.attach(queue: queue, deviceModel: device)

        let ids = await model.enqueueDroppedFilesOnDevice([source])
        let jobs = await queue.snapshot.jobs

        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(model.operationErrorMessage, "The phone is busy. Try again in a moment.")
        XCTAssertTrue(model.isShowingOperationError)
    }

    func testUploadRevalidatesStorageAndPathAfterConflictPrompt() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "photo.jpg")
        try Data("payload".utf8).write(to: source)
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            currentLocation: "/",
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: TestTransferPane(title: "This Mac"))
        model.attach(queue: queue, deviceModel: device)

        let task = Task { await model.enqueueDroppedFilesOnDevice([source]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        device.selectedStorageID = 8
        device.currentLocation = "/Documents"
        model.resolveConflict(.keepBoth, appliesToAll: false)
        let ids = await task.value
        let jobs = await queue.snapshot.jobs

        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertTrue(model.operationErrorMessage?.contains("destination folder changed") == true)
    }

    func testUploadValidationWaitsForTransientRefreshWithoutAbortingBatch() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "photo.jpg")
        try Data("payload".utf8).write(to: source)
        let refreshGate = MockTransferGate()
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            currentLocation: "/",
            selectedStorageID: 7,
            refreshGate: refreshGate
        )
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: TestTransferPane(title: "This Mac"))
        model.attach(queue: queue, deviceModel: device)

        let upload = Task { await model.enqueueDroppedFilesOnDevice([source]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        let refresh = Task { await device.refresh() }
        try await eventually { device.isLoading }
        model.resolveConflict(.keepBoth, appliesToAll: false)
        try await Task.sleep(for: .milliseconds(50))
        let jobsWhileRefreshing = await queue.snapshot.jobs
        XCTAssertTrue(jobsWhileRefreshing.isEmpty)

        await refreshGate.open()
        await refresh.value
        let ids = await upload.value
        let jobs = await queue.snapshot.jobs

        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertNil(model.operationErrorMessage)
    }

    func testDeviceDropKeepBothStagesPrecomputedUploadName() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "photo.jpg")
        try Data("new-photo".utf8).write(to: source)
        let deviceEntries = [
            Self.entry(id: "photo", path: "/photo.jpg"),
            Self.entry(id: "photo-2", path: "/photo (2).jpg")
        ]
        let provider = MockMTPProvider(
            entries: [
                Self.deviceWalkEntry(path: "/photo.jpg", objectID: 1),
                Self.deviceWalkEntry(path: "/photo (2).jpg", objectID: 2)
            ]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            entries: deviceEntries,
            currentLocation: "/",
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let task = Task {
            await model.enqueueDroppedFilesOnDevice([source])
        }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.keepBoth, appliesToAll: false)
        let ids = await task.value
        let snapshot = await queue.snapshot
        let request = try XCTUnwrap(
            snapshot.jobs.first(where: { ids.contains($0.id) })?.request
        )

        XCTAssertEqual(request.direction, .upload)
        XCTAssertEqual(request.destination, "/")
        XCTAssertEqual(request.sources.count, 1)
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(request.sources.first)).lastPathComponent,
            "photo (3).jpg"
        )
        XCTAssertNotNil(request.cleanupDirectory)
    }

    func testFailedUploadStagingCopyRemovesNewDirectoryBeforeQueueOwnership() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "photo.jpg")
        try Data("new-photo".utf8).write(to: source)
        let stagingService = FailingCopyTransferStagingService()
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            currentLocation: "/",
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(
            localModel: TestTransferPane(title: "This Mac"),
            stagingService: stagingService
        )
        model.attach(queue: queue, deviceModel: device)

        let task = Task { await model.enqueueDroppedFilesOnDevice([source]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.keepBoth, appliesToAll: false)
        let ids = await task.value
        let jobs = await queue.snapshot.jobs

        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue(jobs.isEmpty)
        let createdPaths = await stagingService.createdDirectoryPaths()
        XCTAssertEqual(createdPaths.count, 1)
        XCTAssertTrue(createdPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    func testFailedReplaceDownloadLeavesOriginalFileIntact() async throws {
        let fixture = try LocalConflictFixture(names: ["photo.jpg"])
        defer { fixture.remove() }
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/photo.jpg", objectID: 1)],
            transferScripts: [
                MockTransferScript(completion: .success(false))
            ]
        )
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let task = Task {
            await model.enqueueDroppedDeviceItems(
                sources: ["/photo.jpg"],
                storageID: 7,
                sourceObjectIds: ["/photo.jpg": 1]
            )
        }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.replace, appliesToAll: false)
        let ids = await task.value
        let id = try XCTUnwrap(ids.first)
        try await eventually {
            guard let row = model.rows.first(where: { $0.id == id }) else { return false }
            if case .failed = row.state { return true }
            return false
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "photo.jpg")),
            Data("old-photo.jpg".utf8)
        )
        let snapshot = await queue.snapshot
        let request = try XCTUnwrap(snapshot.jobs.first(where: { $0.id == id })?.request)
        XCTAssertNotEqual(request.destination, fixture.destination.path)
        XCTAssertEqual(request.sourceObjectIds, ["/photo.jpg": 1])
        let cleanupDirectory = try XCTUnwrap(request.cleanupDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupDirectory))
    }

    func testKeepBothReservationsPreventDuplicateNamesAcrossSessions() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let firstDirectory = fixture.source.appending(path: "first")
        let secondDirectory = fixture.source.appending(path: "second")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstSource = firstDirectory.appending(path: "photo.jpg")
        let secondSource = secondDirectory.appending(path: "photo.jpg")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let completionGate = MockTransferGate()
        addTeardownBlock {
            await completionGate.open()
        }
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/photo.jpg", objectID: 1)],
            transferScripts: [
                MockTransferScript(completionGate: completionGate),
                MockTransferScript()
            ]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let firstTask = Task { await model.enqueueDroppedFilesOnDevice([firstSource]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.keepBoth, appliesToAll: false)
        let firstIDs = await firstTask.value
        let firstID = try XCTUnwrap(firstIDs.first)

        let secondTask = Task { await model.enqueueDroppedFilesOnDevice([secondSource]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.keepBoth, appliesToAll: false)
        let secondIDs = await secondTask.value
        let secondID = try XCTUnwrap(secondIDs.first)

        let jobs = await queue.snapshot.jobs
        let firstRequest = try XCTUnwrap(jobs.first(where: { $0.id == firstID })?.request)
        let secondRequest = try XCTUnwrap(jobs.first(where: { $0.id == secondID })?.request)
        let names = try [firstRequest, secondRequest].map {
            URL(fileURLWithPath: try XCTUnwrap($0.sources.first)).lastPathComponent
        }
        XCTAssertEqual(Set(names), ["photo (2).jpg", "photo (3).jpg"])
        await completionGate.open()
    }

    func testReplaceUploadSwapsTemporaryObjectAfterSuccessfulUpload() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "photo.jpg")
        try Data("replacement".utf8).write(to: source)
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/photo.jpg", objectID: 1)],
            transferScripts: [
                MockTransferScript(events: [.progress(Self.progress(percent: 50))])
            ]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let task = Task { await model.enqueueDroppedFilesOnDevice([source]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.replace, appliesToAll: false)
        let ids = await task.value
        let id = try XCTUnwrap(ids.first)
        try await eventually {
            model.rows.first(where: { $0.id == id })?.state == .completed
        }

        let paths = await provider.allEntries().map(\.path)
        let calls = await provider.callHistory()
        let row = try XCTUnwrap(model.rows.first(where: { $0.id == id }))
        XCTAssertEqual(paths, ["/photo.jpg"])
        XCTAssertEqual(row.sourceSummary, "photo.jpg")
        XCTAssertEqual(row.lastProgress?.currentFileName, "photo.jpg")
        XCTAssertEqual(
            calls,
            [.fileExists, .uploadFiles, .fileExists, .deleteFiles, .renameFile]
        )
    }

    func testReplaceUploadRenamesTemporaryCopyWhenFinalTargetDisappears() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "photo.jpg")
        try Data("replacement".utf8).write(to: source)
        let provider = MockMTPProvider()
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let task = Task { await model.enqueueDroppedFilesOnDevice([source]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.replace, appliesToAll: false)
        let ids = await task.value
        let id = try XCTUnwrap(ids.first)
        try await eventually {
            model.rows.first(where: { $0.id == id })?.state == .completed
        }

        let paths = await provider.allEntries().map(\.path)
        let calls = await provider.callHistory()
        XCTAssertEqual(paths, ["/photo.jpg"])
        XCTAssertEqual(calls, [.fileExists, .uploadFiles, .fileExists, .renameFile])
    }

    func testReplaceUploadDeleteFailureKeepsOriginalAndTemporaryCopy() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let source = fixture.source.appending(path: "photo.jpg")
        try Data("replacement".utf8).write(to: source)
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/photo.jpg", objectID: 1)],
            scriptedFailures: [.deleteFiles: [.general]]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "photo", path: "/photo.jpg")],
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let task = Task { await model.enqueueDroppedFilesOnDevice([source]) }
        try await eventually { model.conflictPrompt?.fileName == "photo.jpg" }
        model.resolveConflict(.replace, appliesToAll: false)
        let ids = await task.value
        let id = try XCTUnwrap(ids.first)
        try await eventually {
            guard let row = model.rows.first(where: { $0.id == id }) else { return false }
            if case .failed = row.state { return true }
            return false
        }

        let entries = await provider.allEntries()
        XCTAssertTrue(entries.contains { $0.path == "/photo.jpg" })
        XCTAssertTrue(entries.contains { $0.name.hasPrefix("\(AppIdentity.fileNamePrefix)-") })
        guard case let .failed(failure) = model.rows.first(where: { $0.id == id })?.state else {
            return XCTFail("Expected a failed swap")
        }
        XCTAssertTrue(failure.message.contains("temporary copy was kept"))
        XCTAssertEqual(failure.title, "Replace didn’t finish")
        let calls = await provider.callHistory()
        XCTAssertEqual(
            calls,
            [.fileExists, .uploadFiles, .fileExists, .deleteFiles]
        )
    }

    func testLocalDropReplaceApplyToAllReplacesEveryConflict() async throws {
        let fixture = try LocalConflictFixture(names: ["a.txt", "b.txt"])
        defer { fixture.remove() }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(localModel: local)

        let task = Task {
            await model.copyDroppedFilesOnLocalPane(fixture.sources)
        }
        try await eventually { model.conflictPrompt?.fileName == "a.txt" }
        model.resolveConflict(.replace, appliesToAll: true)
        await task.value

        XCTAssertNil(model.conflictPrompt)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "a.txt")),
            Data("new-a.txt".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "b.txt")),
            Data("new-b.txt".utf8)
        )
    }

    func testLocalDropSkipLeavesExistingItemUntouched() async throws {
        let fixture = try LocalConflictFixture(names: ["skip.txt"])
        defer { fixture.remove() }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(localModel: local)

        let task = Task {
            await model.copyDroppedFilesOnLocalPane(fixture.sources)
        }
        try await eventually { model.conflictPrompt?.fileName == "skip.txt" }
        model.resolveConflict(.skip, appliesToAll: false)
        await task.value

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "skip.txt")),
            Data("old-skip.txt".utf8)
        )
    }

    func testLocalDropKeepBothSkipsExistingNumberedNames() async throws {
        let fixture = try LocalConflictFixture(names: ["report.txt"])
        defer { fixture.remove() }
        try Data("numbered".utf8).write(
            to: fixture.destination.appending(path: "report (2).txt")
        )
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(localModel: local)

        let task = Task {
            await model.copyDroppedFilesOnLocalPane(fixture.sources)
        }
        try await eventually { model.conflictPrompt?.fileName == "report.txt" }
        model.resolveConflict(.keepBoth, appliesToAll: false)
        await task.value

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "report (3).txt")),
            Data("new-report.txt".utf8)
        )
    }

    func testAlwaysSkipPolicySkipsConflictsWithoutPrompting() async throws {
        let fixture = try LocalConflictFixture(names: ["skip.txt"])
        defer { fixture.remove() }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(
            localModel: local,
            fileConflictPolicy: { .alwaysSkip }
        )

        await model.copyDroppedFilesOnLocalPane(fixture.sources)

        // No prompt is ever shown and the existing file is left untouched.
        XCTAssertNil(model.conflictPrompt)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "skip.txt")),
            Data("old-skip.txt".utf8)
        )
    }

    func testAlwaysOverwritePolicyReplacesConflictsWithoutPrompting() async throws {
        let fixture = try LocalConflictFixture(names: ["a.txt"])
        defer { fixture.remove() }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(
            localModel: local,
            fileConflictPolicy: { .alwaysOverwrite }
        )

        await model.copyDroppedFilesOnLocalPane(fixture.sources)

        XCTAssertNil(model.conflictPrompt)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "a.txt")),
            Data("new-a.txt".utf8)
        )
    }

    func testAskEverySessionRemembersFirstDecisionAcrossSeparateOperations() async throws {
        let fixture = try LocalConflictFixture(names: ["a.txt", "b.txt"])
        defer { fixture.remove() }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(
            localModel: local,
            fileConflictPolicy: { .askEverySession }
        )

        // First operation: the first conflict prompts once.
        let first = Task { await model.copyDroppedFilesOnLocalPane([fixture.sources[0]]) }
        try await eventually { model.conflictPrompt?.fileName == "a.txt" }
        model.resolveConflict(.replace, appliesToAll: false)
        await first.value
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "a.txt")),
            Data("new-a.txt".utf8)
        )

        // Second, separate operation: the remembered decision is reused with no
        // prompt at all.
        await model.copyDroppedFilesOnLocalPane([fixture.sources[1]])
        XCTAssertNil(model.conflictPrompt)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "b.txt")),
            Data("new-b.txt".utf8)
        )
    }

    func testAskEverySessionForgetsCancelledPromptAcrossDetachAndReattach() async throws {
        // Destination already holds both files, so downloading either conflicts.
        let fixture = try LocalConflictFixture(names: ["a.jpg", "b.jpg"])
        defer { fixture.remove() }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(
            localModel: local,
            fileConflictPolicy: { .askEverySession }
        )

        // First session: a download conflict prompts, then the device is lost
        // mid-prompt (detach), which cancels the pending prompt.
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "a", path: "/a.jpg")],
            selectedStorageID: 7
        )
        model.attach(
            queue: TransferQueue(provider: MockMTPProvider(
                entries: [Self.deviceWalkEntry(path: "/a.jpg", objectID: 1)]
            )),
            deviceModel: device
        )
        let first = Task {
            await model.enqueueDroppedDeviceItems(sources: ["/a.jpg"], storageID: 7)
        }
        try await eventually { model.conflictPrompt?.fileName == "a.jpg" }
        model.detach()
        _ = await first.value
        // The cancellation skipped the file, leaving the original untouched.
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "a.jpg")),
            Data("old-a.jpg".utf8)
        )

        // A fresh device session: the earlier cancellation must NOT have been
        // remembered, so the next conflict prompts again instead of auto-skipping.
        let reattachedDevice = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "b", path: "/b.jpg")],
            selectedStorageID: 7
        )
        model.attach(
            queue: TransferQueue(provider: MockMTPProvider(
                entries: [Self.deviceWalkEntry(path: "/b.jpg", objectID: 2)]
            )),
            deviceModel: reattachedDevice
        )
        let second = Task {
            await model.enqueueDroppedDeviceItems(sources: ["/b.jpg"], storageID: 7)
        }
        try await eventually { model.conflictPrompt?.fileName == "b.jpg" }
        model.resolveConflict(.skip, appliesToAll: false)
        _ = await second.value
    }

    func testAskEveryFilePolicyPromptsForEachConflict() async throws {
        let fixture = try LocalConflictFixture(names: ["a.txt", "b.txt"])
        defer { fixture.remove() }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let model = TransferViewModel(
            localModel: local,
            fileConflictPolicy: { .askEveryFile }
        )

        let task = Task { await model.copyDroppedFilesOnLocalPane(fixture.sources) }
        // Each conflicting file is prompted for independently.
        try await eventually { model.conflictPrompt?.fileName == "a.txt" }
        model.resolveConflict(.replace, appliesToAll: false)
        try await eventually { model.conflictPrompt?.fileName == "b.txt" }
        model.resolveConflict(.skip, appliesToAll: false)
        await task.value

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "a.txt")),
            Data("new-a.txt".utf8)
        )
        // The second file was skipped, so its original content remains.
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "b.txt")),
            Data("old-b.txt".utf8)
        )
    }

    func testCompletionRefreshesCorrectDestinationPane() async throws {
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 1)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)

        model.receive(
            .jobUpdated(
                TransferJobSnapshot(id: UUID(), request: Self.downloadRequest, state: .completed)
            )
        )
        try await eventually { local.refreshCount == 1 }
        XCTAssertEqual(device.refreshCount, 0)

        model.receive(
            .jobUpdated(
                TransferJobSnapshot(id: UUID(), request: Self.uploadRequest, state: .completed)
            )
        )
        try await eventually { device.refreshCount == 1 }
        XCTAssertEqual(local.refreshCount, 1)
    }

    func testFailedTransferRefreshesDestinationPane() async throws {
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 1)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)

        model.receive(
            .jobUpdated(
                TransferJobSnapshot(
                    id: UUID(),
                    request: Self.downloadRequest,
                    state: .failed(errorType: .unknown, message: "partial download")
                )
            )
        )

        try await eventually { local.refreshCount == 1 }
        XCTAssertEqual(device.refreshCount, 0)
    }

    func testMassTerminalizationCoalescesOneRefreshPerDestination() async throws {
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 1)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)

        for _ in 0..<10 {
            model.receive(
                .jobUpdated(
                    TransferJobSnapshot(
                        id: UUID(),
                        request: Self.downloadRequest,
                        state: .cancelled
                    )
                )
            )
            model.receive(
                .jobUpdated(
                    TransferJobSnapshot(
                        id: UUID(),
                        request: Self.uploadRequest,
                        state: .failed(errorType: .unknown, message: "aborted")
                    )
                )
            )
        }

        try await eventually { local.refreshCount == 1 && device.refreshCount == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(local.refreshCount, 1)
        XCTAssertEqual(device.refreshCount, 1)
    }

    func testHundredKeepBothCompletionsProduceOneTrailingDeviceRefresh() async throws {
        let refreshGate = MockTransferGate()
        let device = TestTransferPane(
            title: "Phone",
            selectedStorageID: 1,
            refreshGate: refreshGate
        )
        let model = TransferViewModel(localModel: TestTransferPane(title: "This Mac"))
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)
        let request = TransferRequest(
            direction: .upload,
            sources: ["/tmp/item.txt"],
            destination: "/",
            storageId: 1,
            deviceUploadPreparation: .keepBoth(originalName: "item.txt"),
            reservedDevicePaths: []
        )

        model.receive(
            .jobUpdated(TransferJobSnapshot(id: UUID(), request: request, state: .completed))
        )
        try await eventually { device.refreshCount == 1 && device.isLoading }

        for _ in 1..<100 {
            model.receive(
                .jobUpdated(TransferJobSnapshot(id: UUID(), request: request, state: .completed))
            )
        }
        await refreshGate.open()

        try await eventually { device.refreshCount == 2 && !device.isLoading }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(device.refreshCount, 2)
    }

    func testDetachedSessionSkipsPendingDeviceRefresh() async throws {
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 1)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: MockMTPProvider()), deviceModel: device)

        model.receive(
            .jobUpdated(
                TransferJobSnapshot(
                    id: UUID(),
                    request: Self.uploadRequest,
                    state: .cancelled
                )
            )
        )
        model.detach()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(device.refreshCount, 0)
    }

    func testMockEndToEndDownloadAndUploadProgressAndRefresh() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/DCIM/a.jpg", objectID: 1)],
            transferScripts: [
                MockTransferScript(
                    events: [.progress(Self.progress(percent: 45))],
                    eventInterval: .milliseconds(10),
                    completionDelay: .milliseconds(100)
                ),
                MockTransferScript(
                    events: [.progress(Self.progress(percent: 70))],
                    eventInterval: .milliseconds(10),
                    completionDelay: .milliseconds(100)
                )
            ]
        )
        let local = TestTransferPane(
            title: "This Mac",
            entries: [Self.entry(id: "local", path: "/tmp/upload.txt")],
            currentLocation: "/tmp"
        )
        local.selectedEntryIDs = ["local"]
        let device = TestTransferPane(
            title: "Phone",
            entries: [Self.entry(id: "device", path: "/DCIM/a.jpg")],
            currentLocation: "/",
            selectedStorageID: 7
        )
        device.selectedEntryIDs = ["device"]
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let enqueuedDownloadID = await model.enqueueDownload()
        let downloadID = try XCTUnwrap(enqueuedDownloadID)
        XCTAssertTrue(model.isPanelVisible)
        XCTAssertFalse(model.isPanelExpanded)
        try await eventually {
            model.rows.first(where: { $0.id == downloadID })?.state.isActive == true
        }
        try await eventually {
            model.rows.first(where: { $0.id == downloadID })?.state == .completed
                && local.refreshCount == 1
        }

        let enqueuedUploadID = await model.enqueueUpload()
        let uploadID = try XCTUnwrap(enqueuedUploadID)
        try await eventually {
            model.rows.first(where: { $0.id == uploadID })?.state.isActive == true
        }
        try await eventually {
            model.rows.first(where: { $0.id == uploadID })?.state == .completed
                && device.refreshCount == 1
        }

        let snapshot = await queue.snapshot
        XCTAssertEqual(snapshot.jobs.map(\.request.direction), [.download, .upload])
        XCTAssertEqual(snapshot.jobs[0].request.sources, ["/DCIM/a.jpg"])
        XCTAssertEqual(snapshot.jobs[0].request.destination, "/tmp")
        XCTAssertEqual(snapshot.jobs[1].request.sources, ["/tmp/upload.txt"])
        XCTAssertEqual(snapshot.jobs[1].request.destination, "/")
        XCTAssertEqual(snapshot.jobs.map(\.request.storageId), [7, 7])
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.downloadFiles, .uploadFiles])
    }

    func testFinderPromiseExportWithMatchingNameDownloadsDirectlyToParent() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let entry = Self.entry(
            id: "device-album",
            path: "/DCIM/album",
            isDirectory: true
        )
        let promisedURL = fixture.destination.appending(path: entry.name)
        let provider = MockMTPProvider(
            entries: [
                Self.deviceWalkEntry(
                    path: entry.location,
                    objectID: 1,
                    isDirectory: true
                )
            ],
            transferScripts: [
                MockTransferScript(completionDelay: .milliseconds(20))
            ]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            entries: [entry],
            currentLocation: "/DCIM",
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        try await model.exportPromisedDeviceItem(
            entry,
            storageID: 7,
            to: promisedURL
        )

        let snapshot = await queue.snapshot
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertEqual(
            snapshot.jobs.first?.request,
            TransferRequest(
                direction: .download,
                sources: [entry.location],
                destination: fixture.destination.path,
                storageId: 7,
                directorySources: [entry.location]
            )
        )
        XCTAssertEqual(snapshot.jobs.first?.request.directorySources, [entry.location])
        XCTAssertNil(snapshot.jobs.first?.request.completionAction)
        XCTAssertNil(snapshot.jobs.first?.request.cleanupDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promisedURL.path))
        XCTAssertEqual(model.rows.first?.state, .completed)
        XCTAssertTrue(model.isPanelVisible)
        XCTAssertFalse(model.isPanelExpanded)
    }

    func testFinderPromiseExportWithDedupedNameMovesItemToPromisedURL() async throws {
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let entry = Self.entry(
            id: "device-album",
            path: "/DCIM/album",
            isDirectory: true
        )
        let promisedURL = fixture.destination.appending(path: "album 1")
        let provider = MockMTPProvider(
            entries: [
                Self.deviceWalkEntry(
                    path: entry.location,
                    objectID: 1,
                    isDirectory: true
                )
            ]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(
            title: "Phone",
            entries: [entry],
            currentLocation: "/DCIM",
            selectedStorageID: 7
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        try await model.exportPromisedDeviceItem(
            entry,
            storageID: 7,
            to: promisedURL
        )

        let snapshot = await queue.snapshot
        let request = try XCTUnwrap(snapshot.jobs.first?.request)
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertNotEqual(request.destination, fixture.destination.path)
        XCTAssertEqual(request.directorySources, [entry.location])
        XCTAssertEqual(
            request.completionAction,
            .moveStagedItem(
                sourcePath: URL(fileURLWithPath: request.destination)
                    .appending(path: entry.name).path,
                destinationPath: promisedURL.path,
                replaceExisting: false
            )
        )
        XCTAssertEqual(request.cleanupDirectory, request.destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promisedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: promisedURL.appending(path: entry.name).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination))
        XCTAssertEqual(model.rows.first?.state, .completed)
    }

    func testDeviceChangedMidTransferShowsFailureAndTransitionsToNoDevice() async throws {
        let provider = Self.connectionProvider(
            completion: .callFailure(.deviceChanged)
        )
        let controller = DeviceConnectionController(
            providerFactory: { provider },
            events: AsyncStream { _ in }
        )
        let local = TestTransferPane(title: "This Mac")
        let transferModel = TransferViewModel(localModel: local)
        defer { controller.stop() }

        await controller.start()
        let queue = try XCTUnwrap(controller.transferQueue)
        let deviceModel = try XCTUnwrap(controller.deviceModel)
        transferModel.attach(queue: queue, deviceModel: deviceModel)
        let id = await queue.enqueue(Self.uploadRequest)

        try await eventually {
            controller.state == .noDevice
                && transferModel.rows.first(where: { $0.id == id })?.state
                    == .failed(TransferFailureDescription(
                        type: .deviceLost,
                        message: "ErrorDeviceChanged: Scripted transfer completion failure",
                        direction: .upload
                    ))
        }
        XCTAssertFalse(transferModel.isDeviceNavigationDisabled)
        XCTAssertNil(controller.deviceModel)
    }

    func testDeviceSetupFailureMidTransferShowsFailureAndRequiresReplug() async throws {
        let provider = Self.connectionProvider(
            completion: .callFailure(.deviceSetup)
        )
        let controller = DeviceConnectionController(
            providerFactory: { provider },
            events: AsyncStream { _ in }
        )
        let local = TestTransferPane(title: "This Mac")
        let transferModel = TransferViewModel(localModel: local)
        defer { controller.stop() }

        await controller.start()
        let queue = try XCTUnwrap(controller.transferQueue)
        let deviceModel = try XCTUnwrap(controller.deviceModel)
        transferModel.attach(queue: queue, deviceModel: deviceModel)
        let id = await queue.enqueue(Self.uploadRequest)

        try await eventually {
            if case .needsReplug = controller.state,
               let row = transferModel.rows.first(where: { $0.id == id }) {
                return row.state.isTerminal
            }
            return false
        }
        XCTAssertEqual(
            controller.state,
            .needsReplug(deviceName: "Test Pixel", message: nil)
        )
        XCTAssertEqual(
            transferModel.rows.first(where: { $0.id == id })?.state,
            .failed(TransferFailureDescription(
                type: .deviceLost,
                message: "ErrorDeviceSetup: Scripted transfer completion failure",
                direction: .upload
            ))
        )
        XCTAssertFalse(transferModel.isDeviceNavigationDisabled)
        XCTAssertNil(controller.deviceModel)
    }

    func testLocalDropCopiesMultipleFilesAndRefreshes() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ART-LocalDropTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let sourceDirectory = root.appending(path: "source")
        let destinationDirectory = root.appending(path: "destination")
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let names = (1...8).map { "file\($0).txt" }
        for name in names {
            try Data("contents-\(name)".utf8).write(to: sourceDirectory.appending(path: name))
        }
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: destinationDirectory.path
        )
        let model = TransferViewModel(localModel: local)

        await model.copyDroppedFilesOnLocalPane(
            names.map { sourceDirectory.appending(path: $0) }
        )

        for name in names {
            XCTAssertEqual(
                try Data(contentsOf: destinationDirectory.appending(path: name)),
                Data("contents-\(name)".utf8)
            )
        }
        XCTAssertNil(model.conflictPrompt)
        XCTAssertEqual(local.refreshCount, 1)
    }

    func testOverallProgressAggregatesAcrossInFlightBatches() async throws {
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [
                Self.deviceWalkEntry(path: "/DCIM/a.jpg", objectID: 1),
                Self.deviceWalkEntry(path: "/DCIM/b.jpg", objectID: 2),
                Self.deviceWalkEntry(path: "/DCIM/c.jpg", objectID: 3)
            ],
            transferScripts: [
                MockTransferScript(
                    events: [
                        .progress(
                            Self.fileProgress(
                                name: "a.jpg",
                                totalBytes: 200,
                                sentBytes: 100,
                                filesSent: 1,
                                totalFiles: 1,
                                speed: 8
                            )
                        )
                    ],
                    completionGate: gate
                ),
                MockTransferScript(),
                MockTransferScript()
            ]
        )
        let local = TestTransferPane(title: "This Mac", currentLocation: "/tmp")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 7)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: provider), deviceModel: device)

        let firstIDs = await model.enqueueDroppedDeviceItems(
            sources: ["/DCIM/a.jpg", "/DCIM/b.jpg"],
            storageID: 7
        )
        XCTAssertEqual(firstIDs.count, 1)
        try await eventually {
            guard case let .transferring(progress) = model.rows.first?.state else {
                return false
            }
            return progress.sentBytes == 100
        }
        let secondIDs = await model.enqueueDroppedDeviceItems(
            sources: ["/DCIM/c.jpg"],
            storageID: 7
        )
        XCTAssertEqual(secondIDs.count, 1)
        try await eventually { model.rows.count == 2 }

        let overall = try XCTUnwrap(model.overallProgress)
        XCTAssertEqual(overall.activeJobCount, 1)
        XCTAssertEqual(overall.queuedJobCount, 1)
        // Two files from the active two-source job plus the queued job's file.
        XCTAssertEqual(overall.totalFiles, 3)
        XCTAssertEqual(overall.filesCompleted, 1)
        XCTAssertEqual(try XCTUnwrap(overall.percent), 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(overall.sentBytes, 100)
        XCTAssertEqual(overall.totalBytes, 200)
        XCTAssertEqual(overall.speed, 8, accuracy: 0.001)
        XCTAssertTrue(overall.isCancellable)

        await gate.open()
        try await eventually {
            model.rows.count == 2 && model.rows.allSatisfy { $0.state.isTerminal }
        }
        XCTAssertNil(model.overallProgress)
    }

    func testOverallProgressExcludesBatchesSettledBeforeCurrentActivity() async throws {
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/DCIM/a.jpg", objectID: 1)],
            transferScripts: [
                MockTransferScript(),
                MockTransferScript(
                    events: [
                        .progress(
                            Self.fileProgress(
                                name: "a.jpg",
                                totalBytes: 500,
                                sentBytes: 200,
                                filesSent: 0,
                                totalFiles: 1,
                                speed: 5
                            )
                        )
                    ],
                    completionGate: gate
                )
            ]
        )
        let local = TestTransferPane(title: "This Mac", currentLocation: "/tmp")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 7)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: provider), deviceModel: device)

        _ = await model.enqueueDroppedDeviceItems(sources: ["/DCIM/a.jpg"], storageID: 7)
        try await eventually { model.rows.first?.state.isTerminal == true }
        // Fully idle: no overall progress, and the session resets.
        XCTAssertNil(model.overallProgress)

        _ = await model.enqueueDroppedDeviceItems(sources: ["/DCIM/a.jpg"], storageID: 7)
        try await eventually { model.rows.count == 2 }
        try await eventually {
            guard case .transferring = model.rows.last?.state else { return false }
            return true
        }

        let overall = try XCTUnwrap(model.overallProgress)
        // Only the new batch counts; the settled job's row lingers in the
        // panel but contributes nothing.
        XCTAssertEqual(overall.activeJobCount, 1)
        XCTAssertEqual(overall.totalFiles, 1)
        XCTAssertEqual(overall.sentBytes, 200)
        XCTAssertEqual(overall.totalBytes, 500)

        await gate.open()
        try await eventually { model.rows.allSatisfy { $0.state.isTerminal } }
        XCTAssertNil(model.overallProgress)
    }

    func testStopAllCancelsQueuedAndActiveJobs() async throws {
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [
                Self.deviceWalkEntry(path: "/DCIM/a.jpg", objectID: 1),
                Self.deviceWalkEntry(path: "/DCIM/b.jpg", objectID: 2),
                Self.deviceWalkEntry(path: "/DCIM/c.jpg", objectID: 3)
            ],
            transferScripts: [MockTransferScript(completionGate: gate)]
        )
        let local = TestTransferPane(title: "This Mac", currentLocation: "/tmp")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 7)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: TransferQueue(provider: provider), deviceModel: device)

        let firstIDs = await model.enqueueDroppedDeviceItems(
            sources: ["/DCIM/a.jpg", "/DCIM/b.jpg"],
            storageID: 7
        )
        let secondIDs = await model.enqueueDroppedDeviceItems(
            sources: ["/DCIM/c.jpg"],
            storageID: 7
        )
        try await eventually { model.rows.count == 2 }
        try await eventually { model.overallProgress != nil }

        await model.stopAll()
        // The queued job terminalizes immediately; the active job stops at
        // the next source boundary once its native call returns.
        let queuedID = try XCTUnwrap(secondIDs.first)
        let activeID = try XCTUnwrap(firstIDs.first)
        try await eventually {
            model.rows.first(where: { $0.id == queuedID })?.state == .cancelled
        }
        await gate.open()
        try await eventually {
            model.rows.first(where: { $0.id == activeID })?.state == .cancelled
        }

        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.downloadFiles])
        try await eventually { model.overallProgress == nil }
        XCTAssertFalse(model.isDeviceNavigationDisabled)
    }

    func testExecuteCopyQueueWritesBatchRecordAndSettlementCompletesItems() async throws {
        let store = makeBatchStore()
        let local = TestTransferPane(title: "This Mac")
        let queuedEntry = Self.entry(id: "photo", path: "/DCIM/Camera/photo.jpg")
        let device = TestTransferPane(
            title: "Phone",
            entries: [queuedEntry],
            selectedStorageID: 7
        )
        device.selectedEntryIDs = [queuedEntry.id]
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/DCIM/Camera/photo.jpg", objectID: 1)]
        )
        let model = TransferViewModel(localModel: local, batchStore: store)
        model.attach(queue: TransferQueue(provider: provider), deviceModel: device)
        model.addSelectedDeviceEntriesToCopyQueue(
            storage: DeviceStorage(id: 7, name: "Internal Storage")
        )
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "art-batch-record-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let didEnqueue = await model.executeCopyQueue(destination: destination)
        XCTAssertTrue(didEnqueue)

        let batches = await store.loadAll()
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batch.origin, .copyQueue)
        XCTAssertEqual(batch.destinationRoot, destination.path)
        XCTAssertEqual(batch.storageID, 7)
        XCTAssertEqual(batch.deviceLabel, "Phone")
        let item = try XCTUnwrap(batch.items.first)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertEqual(item.devicePath, "/DCIM/Camera/photo.jpg")
        XCTAssertEqual(
            item.destinationDirectory,
            destination.appending(path: "DCIM/Camera", directoryHint: .isDirectory).path
        )

        // Job settlement rewrites the record: the item ends up completed.
        try await eventuallyAsync {
            await store.load(id: batch.id)?.items.first?.status == .completed
        }
        model.detach()
    }

    func testFailedDirectDownloadMarksBatchItemFailed() async throws {
        let store = makeBatchStore()
        let fixture = try LocalConflictFixture(names: [])
        defer { fixture.remove() }
        let provider = MockMTPProvider(
            entries: [Self.deviceWalkEntry(path: "/DCIM/a.jpg", objectID: 1)],
            transferScripts: [MockTransferScript(completion: .success(false))]
        )
        let local = TestTransferPane(
            title: "This Mac",
            currentLocation: fixture.destination.path
        )
        let deviceEntry = Self.entry(id: "device-a", path: "/DCIM/a.jpg")
        let device = TestTransferPane(
            title: "Phone",
            entries: [deviceEntry],
            selectedStorageID: 7
        )
        device.selectedEntryIDs = [deviceEntry.id]
        let model = TransferViewModel(localModel: local, batchStore: store)
        model.attach(queue: TransferQueue(provider: provider), deviceModel: device)

        let enqueuedID = await model.enqueueDownload()
        XCTAssertNotNil(enqueuedID)

        let batches = await store.loadAll()
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batch.origin, .directCopy)
        XCTAssertEqual(batch.items.map(\.devicePath), ["/DCIM/a.jpg"])
        try await eventuallyAsync {
            guard case .failed = await store.load(id: batch.id)?.items.first?.status else {
                return false
            }
            return true
        }
        model.detach()
    }

    func testEnqueueDateRangeCopyWritesBatchRecordWithGroupDestinations() async throws {
        let store = makeBatchStore()
        let provider = MockMTPProvider(
            entries: [
                Self.deviceWalkEntry(path: "/DCIM/Camera/a.jpg", objectID: 1),
                Self.deviceWalkEntry(path: "/b.jpg", objectID: 2)
            ]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 7)
        let model = TransferViewModel(localModel: local, batchStore: store)
        model.attach(queue: TransferQueue(provider: provider), deviceModel: device)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "art-daterange-batch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = DateRangeCopyPlan(matches: [
            DateRangeMatch(
                entry: Self.entry(id: "a", path: "/DCIM/Camera/a.jpg"),
                relativePath: "DCIM/Camera/a.jpg"
            ),
            DateRangeMatch(
                entry: Self.entry(id: "b", path: "/b.jpg"),
                relativePath: "b.jpg"
            )
        ])

        let ids = await model.enqueueDateRangeCopy(plan, destination: destination.path)
        XCTAssertFalse(ids.isEmpty)

        let batches = await store.loadAll()
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batch.origin, .dateRange)
        XCTAssertEqual(batch.items.map(\.devicePath), ["/DCIM/Camera/a.jpg", "/b.jpg"])
        XCTAssertEqual(
            batch.items.map(\.destinationDirectory),
            [destination.appending(path: "DCIM/Camera").path, destination.path]
        )
        model.detach()
    }

    func testResumeBatchReenqueuesOnlyPendingAndFailedItemsToOriginalDestinations() async throws {
        let store = makeBatchStore()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "art-resume-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraDirectory = root.appending(path: "DCIM/Camera", directoryHint: .isDirectory)
        let record = TransferBatchRecord(
            origin: .copyQueue,
            destinationRoot: root.path,
            storageID: 99,
            deviceLabel: "Old Session",
            items: [
                TransferBatchRecord.Item(
                    devicePath: "/DCIM/Camera/done.jpg",
                    displayName: "done.jpg",
                    size: 1,
                    isDirectory: false,
                    destinationDirectory: cameraDirectory.path,
                    status: .completed
                ),
                TransferBatchRecord.Item(
                    devicePath: "/DCIM/Camera/pending.jpg",
                    displayName: "pending.jpg",
                    size: 1,
                    isDirectory: false,
                    destinationDirectory: cameraDirectory.path,
                    status: .pending
                ),
                TransferBatchRecord.Item(
                    devicePath: "/failed.jpg",
                    displayName: "failed.jpg",
                    size: 1,
                    isDirectory: false,
                    destinationDirectory: root.path,
                    status: .failed(message: "Transfer failed")
                )
            ]
        )
        await store.save(record)
        let provider = MockMTPProvider(
            entries: [
                Self.deviceWalkEntry(path: "/DCIM/Camera/pending.jpg", objectID: 1),
                Self.deviceWalkEntry(path: "/failed.jpg", objectID: 2)
            ]
        )
        let local = TestTransferPane(title: "This Mac")
        let device = TestTransferPane(title: "Phone", selectedStorageID: 7)
        let model = TransferViewModel(localModel: local, batchStore: store)

        // Without a device session, resume is unavailable and does nothing.
        XCTAssertFalse(model.canResumeBatch)
        let resumedWithoutSession = await model.resumeBatch(record)
        XCTAssertFalse(resumedWithoutSession)

        let queue = TransferQueue(provider: provider)
        model.attach(queue: queue, deviceModel: device)
        XCTAssertTrue(model.canResumeBatch)
        let resumed = await model.resumeBatch(record)
        XCTAssertTrue(resumed)

        // Only the pending and failed items were re-enqueued, each to its
        // original destination directory, against the current storage.
        let jobs = await queue.snapshot.jobs
        XCTAssertEqual(
            jobs.map(\.request.sources),
            [["/DCIM/Camera/pending.jpg"], ["/failed.jpg"]]
        )
        XCTAssertEqual(
            jobs.map(\.request.destination),
            [cameraDirectory.path, root.path]
        )
        XCTAssertEqual(jobs.map(\.request.storageId), [7, 7])

        // The resumed run is auto-saved as a NEW batch; the old record keeps
        // its statuses untouched.
        let batches = await store.loadAll()
        XCTAssertEqual(batches.count, 2)
        let resumedRecord = try XCTUnwrap(batches.first { $0.id != record.id })
        XCTAssertEqual(
            Set(resumedRecord.items.map(\.devicePath)),
            ["/DCIM/Camera/pending.jpg", "/failed.jpg"]
        )
        try await eventuallyAsync {
            await store.load(id: resumedRecord.id)?.items.allSatisfy {
                $0.status == .completed
            } == true
        }
        let reloadedOriginal = await store.load(id: record.id)
        let originalRecord = try XCTUnwrap(reloadedOriginal)
        XCTAssertEqual(originalRecord.items.map(\.status), record.items.map(\.status))
        model.detach()
    }

    private func makeBatchStore() -> TransferBatchStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ART-VMBatchStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return TransferBatchStore(directoryURL: directory)
    }

    private func eventuallyAsync(
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                return XCTFail("Condition was not met before timeout")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("Condition was not met before timeout")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func entry(
        id: String,
        path: String,
        isDirectory: Bool = false
    ) -> BrowserEntry {
        BrowserEntry(
            id: id,
            name: URL(fileURLWithPath: path).lastPathComponent,
            size: isDirectory ? 0 : 1,
            modified: nil,
            isDirectory: isDirectory,
            location: path
        )
    }

    private static func deviceWalkEntry(
        path: String,
        objectID: UInt32,
        isDirectory: Bool = false
    ) -> WalkEntry {
        WalkEntry(
            size: isDirectory ? 0 : 1,
            isFolder: isDirectory,
            modified: wallClockDate("2026-01-01T00:00:00Z"),
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            parentPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            extension: isDirectory ? "" : URL(fileURLWithPath: path).pathExtension,
            parentId: 0,
            objectId: objectID
        )
    }

    private static func fileProgress(
        name: String,
        totalBytes: Int64,
        sentBytes: Int64,
        filesSent: Int64,
        totalFiles: Int64,
        speed: Double
    ) -> TransferProgressInfo {
        TransferProgressInfo(
            fullPath: "/DCIM/\(name)",
            name: name,
            elapsedTime: 1_000,
            speed: speed,
            totalFiles: totalFiles,
            totalDirectories: 0,
            filesSent: filesSent,
            filesSentProgress: totalFiles > 0
                ? Float(filesSent) / Float(totalFiles) * 100
                : 0,
            activeFileSize: TransferSizeInfo(total: totalBytes, sent: sentBytes, progress: 0),
            bulkFileSize: TransferSizeInfo(total: totalBytes, sent: sentBytes, progress: 0)
        )
    }

    private static func progress(percent: Float) -> TransferProgressInfo {
        TransferProgressInfo(
            fullPath: "/DCIM/a.jpg",
            name: "a.jpg",
            elapsedTime: 1_000,
            speed: 4.5,
            totalFiles: 1,
            totalDirectories: 0,
            filesSent: 0,
            filesSentProgress: percent,
            activeFileSize: TransferSizeInfo(total: 100, sent: 45, progress: percent),
            bulkFileSize: TransferSizeInfo(total: 100, sent: 45, progress: percent)
        )
    }

    private static func connectionProvider(
        completion: MockTransferCompletion
    ) -> MockMTPProvider {
        MockMTPProvider(
            deviceInfo: DeviceInfo(model: "Test Pixel"),
            storages: [
                StorageInfo(id: 1, storageDescription: "Internal storage")
            ],
            transferScripts: [
                MockTransferScript(
                    completionDelay: .milliseconds(30),
                    completion: completion
                )
            ]
        )
    }

    private static let downloadRequest = TransferRequest(
        direction: .download,
        sources: ["/DCIM/a.jpg"],
        destination: "/tmp",
        storageId: 1
    )

    private static let uploadRequest = TransferRequest(
        direction: .upload,
        sources: ["/tmp/upload.txt"],
        destination: "/",
        storageId: 1
    )

    private static func panelRow(for request: TransferRequest) -> TransferPanelRow {
        TransferPanelRow(
            job: TransferJobSnapshot(id: UUID(), request: request, state: .queued)
        )
    }
}

@MainActor
@Observable
private final class TestTransferPane: DeviceTransferPaneModel {
    let title: String
    var entries: [BrowserEntry]
    var breadcrumbs: [BreadcrumbSegment] = []
    var currentLocation: String
    var sortDescriptor = BrowserSortDescriptor()
    var tableSortOrder = [KeyPathComparator(\BrowserEntry.name)]
    var selectedEntryIDs: Set<BrowserEntry.ID> = []
    var viewMode: BrowserViewMode = .list
    var showsHiddenFiles = false
    var capacity: BrowserCapacity?
    var isLoading = false
    var hasLoaded = true
    var error: BrowserPaneError?
    var canGoBack = false
    var canGoUp = false
    var selectedStorageID: UInt32?
    private(set) var refreshCount = 0
    private let refreshGate: MockTransferGate?

    init(
        title: String,
        entries: [BrowserEntry] = [],
        currentLocation: String = "/",
        selectedStorageID: UInt32? = nil,
        refreshGate: MockTransferGate? = nil
    ) {
        self.title = title
        self.entries = entries
        self.currentLocation = currentLocation
        self.selectedStorageID = selectedStorageID
        self.refreshGate = refreshGate
    }

    func load() async {}
    func refresh() async {
        refreshCount += 1
        guard let refreshGate else { return }
        isLoading = true
        await refreshGate.wait()
        isLoading = false
    }
    func navigate(to entry: BrowserEntry) async {}
    func navigate(to breadcrumb: BreadcrumbSegment) async {}
    func goBack() async {}
    func goUp() async {}
    func setShowsHiddenFiles(_ showsHiddenFiles: Bool) async {
        self.showsHiddenFiles = showsHiddenFiles
    }
    func selectEntry(id: BrowserEntry.ID, extending: Bool, toggling: Bool) {
        selectedEntryIDs.insert(id)
    }
    func selectAll() { selectedEntryIDs = Set(entries.map(\.id)) }
    func clearSelection() { selectedEntryIDs.removeAll() }
    func moveSelection(by offset: Int, extending: Bool) {}
    func openSelection() async {}
    func toggleSort(_ column: BrowserSortColumn) {}
    func dismissError() { error = nil }
}

private struct LocalConflictFixture {
    let root: URL
    let source: URL
    let destination: URL
    let sources: [URL]

    init(names: [String]) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ART-ConflictTests-\(UUID().uuidString)")
        let sourceURL = rootURL.appending(path: "source")
        let destinationURL = rootURL.appending(path: "destination")
        root = rootURL
        source = sourceURL
        destination = destinationURL
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        for name in names {
            try Data("new-\(name)".utf8).write(to: sourceURL.appending(path: name))
            try Data("old-\(name)".utf8).write(to: destinationURL.appending(path: name))
        }
        sources = names.map { sourceURL.appending(path: $0) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FailingCopyTransferStagingService: TransferStagingService {
    private var directoryPaths: [String] = []

    func makeDirectory(appropriateFor destination: URL) throws -> URL {
        let directory = try TransferStaging.makeDirectory(appropriateFor: destination)
        directoryPaths.append(directory.path)
        return directory
    }

    func copyForUpload(source: URL, named name: String, in directory: URL) throws -> URL {
        throw FailingCopyError()
    }

    func removeDirectory(at path: String) throws {
        try TransferStaging.removeDirectory(at: path)
    }

    func createdDirectoryPaths() -> [String] {
        directoryPaths
    }
}

private struct FailingCopyError: Error {}
