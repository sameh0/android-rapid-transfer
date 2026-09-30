import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

/// The transfer panel's words and recovery paths: friendly failure copy,
/// time-left phrasing, the end-of-session summary, Retry, and the conflict
/// dialog's comparison details.
@MainActor
final class TransferPanelPresentationTests: XCTestCase {
    // MARK: - Failure copy

    func testFailuresGetHumanTitlesAndKeepTheirTechnicalDetail() async {
        let cases: [(TransferQueueFailureType, String, TransferDirection, String)] = [
            (.deviceLost, "LIBUSB_ERROR_NO_DEVICE: the MTP session ended (timeout)", .download, "Phone disconnected"),
            (.device(.storageFull), "ErrorStorageFull: StoreFull", .upload, "Not enough space on the phone"),
            (.device(.fileTransfer), "ErrorFileTransfer: an error occured while uploading files. StoreFull", .upload,
             "Not enough space on the phone"),
            (.device(.localFileRead), "ErrorLocalFileRead: /Users/me/a.mov: no space left on device", .download,
             "Not enough space on this Mac"),
            (.device(.fileTransfer), "ErrorFileTransfer: an error occured while uploading files. string too long", .upload,
             "File name too long"),
            (.device(.invalidPath), "ErrorInvalidPath: disallowed file .thumbnails", .download, "File name not allowed"),
            (.device(.invalidPath), "ErrorInvalidPath: path not found: /DCIM/a.jpg", .download, "File no longer on the phone"),
            (.device(.fileTransfer), "ErrorFileTransfer: an error occured while uploading files. MTP_ObjectTooLarge", .upload,
             "File too large for the phone"),
            (.device(.deviceLocked), "ErrorDeviceLocked: device is not open", .upload, "Phone is locked"),
            (.device(.allowStorageAccess), "ErrorAllowStorageAccess: error allow storage access", .download,
             "Allow access on the phone"),
            (.device(.fileTransfer), "ErrorFileTransfer: an error occured while downloading files. DeviceBusy", .download,
             "Phone is busy"),
            (.device(.fileTransfer), "ErrorFileTransfer: an error occured while downloading files. IncompleteTransfer", .download,
             "Copy didn’t finish"),
            (.unknown, "All 3 files failed to transfer. First failure: ErrorFileTransfer: x", .download,
             "None of the files copied")
        ]
        for (type, message, direction, title) in cases {
            let failure = TransferFailureDescription(type: type, message: message, direction: direction)
            XCTAssertEqual(failure.title, title, message)
            XCTAssertFalse(failure.guidance.isEmpty, message)
            XCTAssertFalse(failure.title.hasPrefix("Error"), "no raw codes in titles: \(message)")
            XCTAssertTrue(failure.technicalDetail.contains(message) || message.contains(failure.technicalDetail),
                          "the raw message survives for bug reports: \(message)")
            XCTAssertEqual(failure.message, message)
        }
    }

    func testTechnicalDetailNamesTheErrorTypeOnce() async {
        let prefixed = TransferFailureDescription(
            type: .device(.fileTransfer),
            message: "ErrorFileTransfer: boom",
            direction: .upload
        )
        XCTAssertEqual(prefixed.technicalDetail, "ErrorFileTransfer: boom")
        let bare = TransferFailureDescription(type: .device(.sendObject), message: "boom", direction: .upload)
        XCTAssertEqual(bare.technicalDetail, "ErrorSendObject: boom")
        let lost = TransferFailureDescription(type: .deviceLost, message: "gone", direction: .upload)
        XCTAssertEqual(lost.technicalDetail, "Device lost: gone")
    }

    func testPerFileFailureCopyIsInferredFromTheMessage() async {
        let full = TransferFailureDescription(
            fileFailureMessage: "ErrorStorageFull: StoreFull",
            direction: .upload
        )
        XCTAssertEqual(full.kind, .phoneStorageFull)
        let missing = TransferFailureDescription(
            fileFailureMessage: "ErrorInvalidPath: path not found: /DCIM/a.jpg",
            direction: .download
        )
        XCTAssertEqual(missing.kind, .itemMissing)
    }

    // MARK: - Time left

    func testRemainingTimeIsRoundedIntoFriendlyPhrases() async {
        XCTAssertNil(TransferRemainingTime.phrase(nil))
        XCTAssertNil(TransferRemainingTime.phrase(.infinity))
        XCTAssertEqual(TransferRemainingTime.phrase(2), "Almost done")
        XCTAssertEqual(TransferRemainingTime.phrase(22), "About 20 sec left")
        XCTAssertEqual(TransferRemainingTime.phrase(58), "About 1 min left")
        XCTAssertEqual(TransferRemainingTime.phrase(61), "About 2 min left")
        XCTAssertEqual(TransferRemainingTime.phrase(3_600), "About 1 hr left")
        XCTAssertEqual(TransferRemainingTime.phrase(3_900), "About 1 hr 5 min left")
        XCTAssertEqual(TransferRemainingTime.speedText(megabytesPerSecond: 18.46), "18.5 MB/s")
    }

    // MARK: - Progress fraction

    /// A single large file fills its bar by bytes; `percent` alone is
    /// file-based and would sit at 0% until the file finished.
    func testProgressFractionCountsTheBytesOfTheFileInFlight() async {
        func info(filesSent: Int64, totalFiles: Int64, sent: Int64) -> TransferProgressInfo {
            TransferProgressInfo(
                fullPath: "/DCIM/big.mov", name: "big.mov", elapsedTime: 0, speed: 40,
                totalFiles: totalFiles, totalDirectories: 0, filesSent: filesSent,
                filesSentProgress: totalFiles > 0 ? Float(filesSent) / Float(totalFiles) * 100 : 0,
                activeFileSize: TransferSizeInfo(total: 1_000, sent: sent, progress: 0),
                bulkFileSize: TransferSizeInfo(total: 1_000, sent: sent, progress: 0)
            )
        }
        let halfway = TransferProgressSnapshot(progress: info(filesSent: 0, totalFiles: 1, sent: 500))
        XCTAssertEqual(halfway.percent, 0)
        XCTAssertEqual(halfway.fraction, 0.5, accuracy: 0.0001)
        let done = TransferProgressSnapshot(progress: info(filesSent: 1, totalFiles: 1, sent: 1_000))
        XCTAssertEqual(done.fraction, 1)
        let unplanned = TransferProgressSnapshot(progress: info(filesSent: 0, totalFiles: 0, sent: 250))
        XCTAssertEqual(unplanned.fraction, 0.25, accuracy: 0.0001)

        let second = TransferProgressSnapshot(
            percent: 50, speed: 1, currentFileName: "b", filesSent: 1, totalFiles: 2,
            totalBytes: 2_000, sentBytes: 1_500, currentFileFraction: 0.5
        )
        XCTAssertEqual(second.fraction, 0.75, accuracy: 0.0001)
        let overall = TransferOverallProgress(rows: [Self.row(.transferring(second), sources: 2)])
        XCTAssertEqual(overall?.percent ?? 0, 0.75, accuracy: 0.0001)
    }

    func testExpandedJobsReportTheActiveFilesByteShare() async throws {
        let halfOfB = TransferProgressInfo(
            fullPath: "/DCIM/b.jpg", name: "b.jpg", elapsedTime: 0, speed: 5,
            totalFiles: 1, totalDirectories: 0, filesSent: 0, filesSentProgress: 0,
            activeFileSize: TransferSizeInfo(total: 1_000, sent: 500, progress: 50),
            bulkFileSize: TransferSizeInfo(total: 1_000, sent: 500, progress: 50)
        )
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceFile("/DCIM/a.jpg"), Self.deviceFile("/DCIM/b.jpg")],
            transferScripts: [
                MockTransferScript(),
                MockTransferScript(events: [.progress(halfOfB)], completionGate: gate)
            ]
        )
        let queue = TransferQueue(provider: provider, progressPublicationInterval: .zero)
        let id = await queue.enqueue(TransferRequest(
            direction: .download, sources: ["/DCIM/a.jpg", "/DCIM/b.jpg"], destination: "/tmp", storageId: 1
        ))
        var fraction = 0.0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if case let .transferring(progress) = await queue.snapshot.jobs.first(where: { $0.id == id })?.state,
               progress.currentFileFraction != nil {
                fraction = progress.fraction
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fraction, 0.75, accuracy: 0.0001, "one of two files done, the second half way")
        await gate.open()
    }

    // MARK: - Session summary

    func testSummaryCelebratesACleanFinish() async throws {
        let many = try XCTUnwrap(TransferSessionSummary(rows: [
            Self.row(.completed, sources: 1, progress: Self.snapshot(files: 128, sent: 128, bytes: 1_000))
        ]))
        XCTAssertTrue(many.isCleanSuccess)
        XCTAssertEqual(many.headline, "All 128 files copied")
        XCTAssertEqual(many.destinationPhrase, "to this Mac")
        XCTAssertEqual(many.bytesCopied, 1_000)

        let single = try XCTUnwrap(TransferSessionSummary(rows: [Self.row(.completed, sources: 1)]))
        XCTAssertEqual(single.headline, "Copied a0.jpg")
    }

    func testSummaryReportsFailuresAndStops() async throws {
        let failure = TransferFileFailure(source: "/DCIM/x.jpg", destinationDirectory: "/tmp", message: "boom")
        let mixed = try XCTUnwrap(TransferSessionSummary(rows: [
            Self.row(.completed, sources: 1, progress: Self.snapshot(files: 10, sent: 10, bytes: 10),
                     fileFailures: [failure, failure]),
            Self.row(.failed(errorType: .unknown, message: "x"), sources: 1)
        ]))
        XCTAssertFalse(mixed.isCleanSuccess)
        XCTAssertEqual(mixed.itemsFailed, 3)
        XCTAssertEqual(mixed.headline, "8 files copied, 3 need attention")

        let stopped = try XCTUnwrap(TransferSessionSummary(rows: [
            Self.row(.cancelled, sources: 1, progress: Self.snapshot(files: 50, sent: 40, bytes: 10))
        ]))
        XCTAssertEqual(stopped.headline, "Stopped after 40 files")

        XCTAssertNil(TransferSessionSummary(rows: [Self.row(.queued, sources: 1)]))
        XCTAssertNil(TransferSessionSummary(rows: []))
    }

    func testViewModelSummarizesTheSessionWhenTheLastJobSettles() async throws {
        let fixture = try LocalFolderFixture()
        defer { fixture.remove() }
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceFile("/DCIM/a.jpg"), Self.deviceFile("/DCIM/b.jpg")],
            transferScripts: [MockTransferScript(completionGate: gate), MockTransferScript()]
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(
            localModel: CancellationTestPane(title: "This Mac", currentLocation: fixture.root.path)
        )
        model.attach(queue: queue, deviceModel: CancellationTestPane(title: "Phone", selectedStorageID: 1))
        var finished: [TransferSessionSummary] = []
        model.onSessionFinished = { finished.append($0) }

        let ids = await model.enqueueDroppedDeviceItems(sources: ["/DCIM/a.jpg", "/DCIM/b.jpg"], storageID: 1)
        XCTAssertEqual(ids.count, 1)
        try await eventually { model.overallProgress != nil }
        XCTAssertNil(model.lastSessionSummary, "no summary while work is in flight")
        XCTAssertTrue(finished.isEmpty)

        await gate.open()
        try await eventually { model.lastSessionSummary != nil }
        let summary = try XCTUnwrap(model.lastSessionSummary)
        XCTAssertTrue(summary.isCleanSuccess)
        XCTAssertEqual(summary.filesCopied, 2)
        XCTAssertEqual(finished.map(\.id), [summary.id], "The hook fires once per settled session")

        // New work starts a new session and clears the old summary.
        _ = await model.enqueueDroppedDeviceItems(sources: ["/DCIM/a.jpg"], storageID: 1)
        try await eventually { model.lastSessionSummary?.id != summary.id }
    }

    // MARK: - Retry

    func testRetryRequeuesAFailedCopyInPlaceOfItsRow() async throws {
        let fixture = try LocalFolderFixture()
        defer { fixture.remove() }
        let provider = MockMTPProvider(
            entries: [Self.deviceFile("/DCIM/a.jpg")],
            transferScripts: [
                MockTransferScript(completion: .callFailure(.fileTransfer)),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(
            localModel: CancellationTestPane(title: "This Mac", currentLocation: fixture.root.path)
        )
        model.attach(queue: queue, deviceModel: CancellationTestPane(title: "Phone", selectedStorageID: 1))
        let enqueued = await model.enqueueDroppedDeviceItems(sources: ["/DCIM/a.jpg"], storageID: 1)
        let failedID = try XCTUnwrap(enqueued.first)
        try await eventually { model.rows.first?.state.isTerminal == true }
        let failedRow = try XCTUnwrap(model.rows.first { $0.id == failedID })
        XCTAssertTrue(model.canRetry(failedRow))

        let retried = await model.retry(jobID: failedID)
        XCTAssertTrue(retried)
        XCTAssertNil(model.rows.first { $0.id == failedID }, "the failed row made way for its retry")
        XCTAssertTrue(model.isPanelVisible, "the panel does not blink closed while the retry arrives")
        try await eventually { model.rows.count == 1 && model.rows.first?.state == .completed }
        let inputs = await provider.downloadInputs()
        XCTAssertEqual(inputs.map(\.sources), [["/DCIM/a.jpg"], ["/DCIM/a.jpg"]])
        XCTAssertEqual(inputs.last?.destination, fixture.root.path)
    }

    func testRetryOfAPartlyFailedFolderCopiesOnlyTheFailedFiles() async throws {
        let fixture = try LocalFolderFixture()
        defer { fixture.remove() }
        let provider = MockMTPProvider(
            entries: [Self.deviceFile("/DCIM/album/b.jpg"), Self.deviceFile("/DCIM/album/sub/c.jpg")],
            transferScripts: [MockTransferScript(), MockTransferScript()]
        )
        let queue = TransferQueue(provider: provider)
        let model = TransferViewModel(
            localModel: CancellationTestPane(title: "This Mac", currentLocation: fixture.root.path)
        )
        model.attach(queue: queue, deviceModel: CancellationTestPane(title: "Phone", selectedStorageID: 1))
        let album = fixture.root.appending(path: "album")
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: fixture.root.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        let id = UUID()
        model.receive(.jobUpdated(TransferJobSnapshot(
            id: id,
            request: request,
            state: .completed,
            fileFailures: [
                TransferFileFailure(source: "/DCIM/album/b.jpg", destinationDirectory: album.path, message: "x"),
                TransferFileFailure(
                    source: "/DCIM/album/sub/c.jpg",
                    destinationDirectory: album.appending(path: "sub").path,
                    message: "y"
                )
            ]
        )))
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertTrue(model.canRetry(row))

        let retried = await model.retry(jobID: id)
        XCTAssertTrue(retried)
        try await eventually { model.rows.count == 2 && model.rows.allSatisfy { $0.state == .completed } }
        let inputs = await provider.downloadInputs()
        XCTAssertEqual(Set(inputs.map(\.sources)), [["/DCIM/album/b.jpg"], ["/DCIM/album/sub/c.jpg"]])
        XCTAssertEqual(Set(inputs.map(\.destination)), [album.path, album.appending(path: "sub").path])
    }

    func testStagedAndFinishedCopiesAreNotRetryable() async throws {
        let model = TransferViewModel(localModel: CancellationTestPane(title: "This Mac"))
        let queue = TransferQueue(provider: MockMTPProvider())
        model.attach(queue: queue, deviceModel: CancellationTestPane(title: "Phone", selectedStorageID: 1))
        let staged = TransferRequest(
            direction: .download,
            sources: ["/DCIM/a.jpg"],
            destination: "/tmp/staging",
            storageId: 1,
            completionAction: .moveStagedItem(sourcePath: "/tmp/staging/a.jpg", destinationPath: "/tmp/a.jpg", replaceExisting: true),
            cleanupDirectory: "/tmp/staging"
        )
        let failedStaged = TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(), request: staged, state: .failed(errorType: .unknown, message: "x")
        ))
        XCTAssertFalse(model.canRetry(failedStaged))
        let clean = TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(), request: Self.plainDownload, state: .completed
        ))
        XCTAssertFalse(model.canRetry(clean))
        let stopped = TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(), request: Self.plainDownload, state: .cancelled
        ))
        XCTAssertTrue(model.canRetry(stopped))
        model.detach()
        XCTAssertFalse(model.canRetry(stopped), "nothing to retry against without a phone")
    }

    func testDismissSettledClearsOnlyFinishedRows() async {
        let model = TransferViewModel(localModel: CancellationTestPane(title: "This Mac"))
        let done = UUID()
        let waiting = UUID()
        model.receive(.jobUpdated(TransferJobSnapshot(id: done, request: Self.plainDownload, state: .completed)))
        model.receive(.jobUpdated(TransferJobSnapshot(id: waiting, request: Self.plainDownload, state: .queued)))
        model.dismissSettled()
        XCTAssertEqual(model.rows.map(\.id), [waiting])
    }

    // MARK: - Rows and conflicts

    func testLocalResultPathsPointAtWhereDownloadsLand() async {
        let loose = TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(),
            request: TransferRequest(
                direction: .download, sources: ["/DCIM/a.jpg", "/DCIM/b"], destination: "/Users/me/Pictures", storageId: 1
            ),
            state: .completed
        ))
        XCTAssertEqual(loose.localResultPaths, ["/Users/me/Pictures/a.jpg", "/Users/me/Pictures/b"])
        let staged = TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(),
            request: TransferRequest(
                direction: .download,
                sources: ["/DCIM/a.jpg"],
                destination: "/tmp/staging",
                storageId: 1,
                completionAction: .moveStagedItem(
                    sourcePath: "/tmp/staging/a.jpg", destinationPath: "/Users/me/a (2).jpg", replaceExisting: false
                )
            ),
            state: .completed
        ))
        XCTAssertEqual(staged.localResultPaths, ["/Users/me/a (2).jpg"])
        let upload = TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(),
            request: TransferRequest(direction: .upload, sources: ["/tmp/a.jpg"], destination: "/", storageId: 1),
            state: .completed
        ))
        XCTAssertEqual(upload.localResultPaths, [])
    }

    func testConflictComparisonPrefersDatesThenSizes() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let newer = FileConflictItem(location: .phone, isDirectory: false, size: 10, modified: now)
        let older = FileConflictItem(location: .mac, isDirectory: false, size: 20, modified: now.addingTimeInterval(-60))
        XCTAssertEqual(newer.comparison(to: older), .newer)
        XCTAssertEqual(older.comparison(to: newer), .older)
        let sameTimeLarger = FileConflictItem(location: .mac, isDirectory: false, size: 20, modified: now)
        XCTAssertEqual(sameTimeLarger.comparison(to: newer), .larger)
        XCTAssertEqual(newer.comparison(to: sameTimeLarger), .smaller)
        let undated = FileConflictItem(location: .mac, isDirectory: false, size: 10, modified: nil)
        XCTAssertEqual(undated.comparison(to: newer), .sameSize)
        let folder = FileConflictItem(location: .mac, isDirectory: true, size: nil, modified: nil)
        XCTAssertEqual(folder.comparison(to: undated), .unknown)
    }

    func testLocalConflictPromptDescribesBothItems() async throws {
        let fixture = try LocalFolderFixture()
        defer { fixture.remove() }
        let source = fixture.root.appending(path: "incoming")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new and longer".utf8).write(to: source.appending(path: "a.txt"))
        try Data("old".utf8).write(to: fixture.root.appending(path: "a.txt"))
        let model = TransferViewModel(
            localModel: CancellationTestPane(title: "This Mac", currentLocation: fixture.root.path)
        )

        let copy = Task { await model.copyDroppedFilesOnLocalPane([source.appending(path: "a.txt")]) }
        try await eventually { model.conflictPrompt != nil }
        let prompt = try XCTUnwrap(model.conflictPrompt)
        XCTAssertEqual(prompt.incoming?.size, 14)
        XCTAssertEqual(prompt.existing?.size, 3)
        XCTAssertEqual(prompt.incoming?.location, .mac)
        XCTAssertNotNil(prompt.existing?.modified)
        model.resolveConflict(.skip, appliesToAll: false)
        await copy.value
    }

    // MARK: - Fixtures

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

    private static let plainDownload = TransferRequest(
        direction: .download,
        sources: ["/DCIM/a.jpg"],
        destination: "/tmp",
        storageId: 1
    )

    private static func row(
        _ state: TransferJobState,
        sources: Int,
        progress: TransferProgressSnapshot? = nil,
        fileFailures: [TransferFileFailure] = []
    ) -> TransferPanelRow {
        TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(),
            request: TransferRequest(
                direction: .download,
                sources: (0 ..< sources).map { "/DCIM/a\($0).jpg" },
                destination: "/tmp",
                storageId: 1
            ),
            state: state,
            lastProgress: progress,
            fileFailures: fileFailures
        ))
    }

    private static func snapshot(files: Int64, sent: Int64, bytes: Int64) -> TransferProgressSnapshot {
        TransferProgressSnapshot(
            percent: Double(sent) / Double(max(files, 1)) * 100,
            speed: 10,
            currentFileName: "a.jpg",
            filesSent: sent,
            totalFiles: files,
            totalBytes: bytes,
            sentBytes: bytes
        )
    }

    private static func deviceFile(_ path: String) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: 1_000,
            isFolder: false,
            modified: wallClockDate("2026-01-01T00:00:00Z"),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: url.pathExtension,
            parentId: 1,
            objectId: 7
        )
    }
}

private struct LocalFolderFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ART-TransferPresentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
