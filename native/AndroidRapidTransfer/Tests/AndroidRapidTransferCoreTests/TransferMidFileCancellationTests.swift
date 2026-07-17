import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

/// Stop, Stop All and quit abort the file in flight instead of waiting for it
/// to finish. The mock's gate is never opened in these tests, so a transfer
/// only ends if the queue really cancels it.
@MainActor
final class TransferMidFileCancellationTests: XCTestCase {
    func testStopAbortsASingleFileMidTransferAndTheQueueKeepsWorking() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [
                MockTransferScript(events: [.progress(Self.halfway)], completionGate: MockTransferGate()),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.downloadRequest)
        try await waitUntil { await Self.isTransferring(id, in: queue) }

        let accepted = await queue.cancel(jobId: id)
        XCTAssertTrue(accepted)
        try await waitUntil { await Self.state(of: id, in: queue) == .cancelled }
        let cancelledTransfers = await provider.cancelledTransferCount()
        XCTAssertEqual(cancelledTransfers, 1, "the native transfer was aborted, not awaited")
        let job = await queue.snapshot.jobs.first { $0.id == id }
        XCTAssertEqual(job?.cancelRequested, true)
        XCTAssertEqual(job?.fileFailures, [], "an aborted file is not a failure")

        // The session stayed usable: the next job runs normally.
        let nextId = await queue.enqueue(Self.downloadRequest)
        try await waitUntil { await Self.state(of: nextId, in: queue) == .completed }
    }

    func testStopAbortsTheFileInFlightAndSkipsTheRestOfAnExpandedJob() async throws {
        let provider = MockMTPProvider(
            entries: [Self.fileA, Self.fileB],
            transferScripts: [
                MockTransferScript(completionGate: MockTransferGate()),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.twoFileDownloadRequest)
        try await waitUntil { await provider.callHistory() == [.downloadFiles] }

        await queue.cancel(jobId: id)
        try await waitUntil { await Self.state(of: id, in: queue) == .cancelled }
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.downloadFiles], "the second file never started")
        let job = await queue.snapshot.jobs.first { $0.id == id }
        XCTAssertEqual(job?.fileFailures, [])
    }

    func testCancelledUploadLeavesNoPartialObjectOnThePhone() async throws {
        let provider = MockMTPProvider(
            transferScripts: [MockTransferScript(completionGate: MockTransferGate())]
        )
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.uploadRequest)
        try await waitUntil { await provider.callHistory() == [.uploadFiles] }
        let during = await provider.allEntries().map(\.path)
        XCTAssertEqual(during, ["/upload.txt"], "the upload created its object")

        await queue.cancelAll()
        try await waitUntil { await Self.state(of: id, in: queue) == .cancelled }
        let after = await provider.allEntries()
        XCTAssertEqual(after, [], "the partial object was removed")
    }

    func testStopAllSettlesRowsAndReleasesTheBusyLock() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [MockTransferScript(completionGate: MockTransferGate())]
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(localModel: CancellationTestPane(title: "This Mac"))
        model.attach(
            queue: queue,
            deviceModel: CancellationTestPane(title: "Phone", selectedStorageID: 1)
        )
        let active = await queue.enqueue(Self.downloadRequest)
        let waiting = await queue.enqueue(Self.downloadRequest)
        try await eventually { model.isDeviceNavigationDisabled }

        await model.stopAll()

        try await eventually { !model.hasActiveTransfers }
        XCTAssertEqual(model.rows.first { $0.id == active }?.state, .cancelled)
        XCTAssertEqual(model.rows.first { $0.id == waiting }?.state, .cancelled)
        XCTAssertFalse(model.isDeviceNavigationDisabled)
        XCTAssertNil(model.overallProgress)
    }

    /// Quitting stops transfers and then waits for the queue to drain before
    /// releasing the phone. With a file that would never finish on its own,
    /// that release must still happen well inside the 3 s bound.
    func testQuitDuringALargeFileReleasesWithinItsBound() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [MockTransferScript(completionGate: MockTransferGate())]
        )
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.downloadRequest)
        try await waitUntil { await provider.callHistory() == [.downloadFiles] }

        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await DeviceSessionShutdown.run(
            stopTransfers: { await queue.cancelAll() },
            releaseDevice: { await queue.invalidateSession(message: "The app quit.") }
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(outcome, .completed)
        XCTAssertLessThan(elapsed, .seconds(1))
        let finalState = await Self.state(of: id, in: queue)
        XCTAssertEqual(finalState, .cancelled)
    }

    /// The controller hands the queue a `ConnectionMonitoringProvider`, which
    /// wraps each transfer's result in a task of its own. Stop must reach
    /// through that wrapper to the provider (found on the phone: without it
    /// the file kept copying to the end and the job settled as completed).
    func testStopReachesTheProviderThroughTheConnectionMonitor() async throws {
        let base = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [
                MockTransferScript(events: [.progress(Self.halfway)], completionGate: MockTransferGate())
            ]
        )
        let provider = ConnectionMonitoringProvider(provider: base, connectionLost: { _ in })
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.downloadRequest)
        try await waitUntil { await Self.isTransferring(id, in: queue) }

        await queue.cancel(jobId: id)

        try await waitUntil { await Self.state(of: id, in: queue) == .cancelled }
        let cancelledTransfers = await base.cancelledTransferCount()
        XCTAssertEqual(cancelledTransfers, 1, "the provider's transfer was aborted")
    }

    func testCancellingAMonitoredTransferDoesNotReportAConnectionLoss() async throws {
        let base = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [MockTransferScript(completionGate: MockTransferGate())]
        )
        let losses = LockedErrors()
        let provider = ConnectionMonitoringProvider(provider: base, connectionLost: { losses.append($0) })
        let operation = try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: 1, sources: ["/DCIM/photo.jpg"], destination: "/tmp/downloads", preprocessFiles: false
        ))

        operation.result.cancel()

        // Bounded: without the fix the gated transfer would never end.
        try await waitUntil { await base.cancelledTransferCount() == 1 }
        guard await base.cancelledTransferCount() == 1 else { return }
        do {
            _ = try await operation.result.value
            XCTFail("a cancelled transfer must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        for error in losses.all {
            XCTAssertNil(ConnectionFatalClassifier.disposition(for: error), "a stop is not a lost connection: \(error)")
        }
    }

    // MARK: - Helpers

    private static func state(of id: UUID, in queue: TransferQueue) async -> TransferJobState? {
        await queue.snapshot.jobs.first { $0.id == id }?.state
    }

    private static func isTransferring(_ id: UUID, in queue: TransferQueue) async -> Bool {
        if case .transferring = await state(of: id, in: queue) { return true }
        return false
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the transfer queue")
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

    private static let downloadRequest = TransferRequest(
        direction: .download,
        sources: ["/DCIM/photo.jpg"],
        destination: "/tmp/downloads",
        storageId: 1
    )

    private static let twoFileDownloadRequest = TransferRequest(
        direction: .download,
        sources: ["/DCIM/a.jpg", "/DCIM/b.jpg"],
        destination: "/tmp/downloads",
        storageId: 1
    )

    private static let uploadRequest = TransferRequest(
        direction: .upload,
        sources: ["/tmp/upload.txt"],
        destination: "/",
        storageId: 1
    )

    private static let deviceFile = walkEntry("/DCIM/photo.jpg", size: 4_000_000_000, objectId: 2)
    private static let fileA = walkEntry("/DCIM/a.jpg", size: 1_000, objectId: 3)
    private static let fileB = walkEntry("/DCIM/b.jpg", size: 3_000, objectId: 4)

    private static let halfway = TransferProgressInfo(
        fullPath: "/DCIM/photo.jpg",
        name: "photo.jpg",
        elapsedTime: 1_000,
        speed: 40,
        totalFiles: 1,
        totalDirectories: 0,
        filesSent: 0,
        filesSentProgress: 50,
        activeFileSize: TransferSizeInfo(total: 4_000_000_000, sent: 2_000_000_000, progress: 50),
        bulkFileSize: TransferSizeInfo(total: 4_000_000_000, sent: 2_000_000_000, progress: 50)
    )

    private static func walkEntry(_ path: String, size: Int64, objectId: UInt32) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: size,
            isFolder: false,
            modified: wallClockDate("2026-01-01T00:00:00Z"),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: url.pathExtension,
            parentId: 1,
            objectId: objectId
        )
    }
}

/// A minimal pane for view-model tests in this file.
@MainActor
@Observable
final class CancellationTestPane: DeviceTransferPaneModel {
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

    init(
        title: String,
        entries: [BrowserEntry] = [],
        currentLocation: String = "/",
        selectedStorageID: UInt32? = nil
    ) {
        self.title = title
        self.entries = entries
        self.currentLocation = currentLocation
        self.selectedStorageID = selectedStorageID
    }

    func load() async {}
    func refresh() async {}
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

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []

    func append(_ error: any Error) { lock.withLock { errors.append(error) } }
    var all: [any Error] { lock.withLock { errors } }
}
