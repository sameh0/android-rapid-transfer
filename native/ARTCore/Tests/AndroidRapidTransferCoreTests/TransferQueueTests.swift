import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class TransferQueueTests: XCTestCase {
    func testTransfersExecuteStrictlySerially() async throws {
        // The first transfer stays active until the gate opens, so the check
        // below does not depend on how fast the runner is.
        let firstTransferGate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [
                MockTransferScript(completionGate: firstTransferGate),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider)
        let downloadId = await queue.enqueue(Self.downloadRequest)
        let uploadId = await queue.enqueue(Self.uploadRequest)

        try await waitUntil {
            await provider.callHistory() == [.downloadFiles]
        }
        try await Task.sleep(for: .milliseconds(30))
        let callsWhileFirstActive = await provider.callHistory()
        let secondStateWhileFirstActive = await state(of: uploadId, in: queue)
        XCTAssertEqual(callsWhileFirstActive, [.downloadFiles])
        XCTAssertEqual(secondStateWhileFirstActive, .queued)

        await firstTransferGate.open()
        try await waitUntil {
            let downloadState = await self.state(of: downloadId, in: queue)
            let uploadState = await self.state(of: uploadId, in: queue)
            return downloadState == .completed && uploadState == .completed
        }
        let finalCalls = await provider.callHistory()
        XCTAssertEqual(finalCalls, [.downloadFiles, .uploadFiles])
    }

    func testProgressSnapshotMathAndETAEdgeCases() async throws {
        let progress = Self.progress(
            speed: 5,
            totalBytes: 30_000_000,
            sentBytes: 10_000_000,
            percent: 42.5
        )
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [
                MockTransferScript(
                    events: [.progress(progress)],
                    completionDelay: .milliseconds(50)
                )
            ]
        )
        let queue = TransferQueue(provider: provider)
        let progressEvent = Task { () -> TransferProgressSnapshot? in
            for await event in queue.events {
                if case let .jobUpdated(job) = event,
                   case let .transferring(snapshot) = job.state {
                    return snapshot
                }
            }
            return nil
        }

        _ = await queue.enqueue(Self.downloadRequest)
        let receivedProgress = await progressEvent.value
        let snapshot = try XCTUnwrap(receivedProgress)
        XCTAssertEqual(snapshot.percent, 42.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.speed, 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.eta), 4, accuracy: 0.001)
        XCTAssertEqual(snapshot.currentFileName, "photo.jpg")
        XCTAssertEqual(snapshot.filesSent, 2)
        XCTAssertEqual(snapshot.totalFiles, 5)
        XCTAssertEqual(snapshot.totalBytes, 30_000_000)
        XCTAssertEqual(snapshot.sentBytes, 10_000_000)

        let zeroSpeed = TransferProgressSnapshot(
            progress: Self.progress(
                speed: 0,
                totalBytes: 30_000_000,
                sentBytes: 10_000_000,
                percent: 42.5
            )
        )
        XCTAssertNil(zeroSpeed.eta)

        let unknownTotals = TransferProgressSnapshot(
            progress: Self.progress(speed: 5, totalBytes: 0, sentBytes: 0, percent: 0)
        )
        XCTAssertNil(unknownTotals.eta)
    }

    func testProgressPublicationIsThrottledAndCompletionBypassesTrailingDelay() async throws {
        let progressEvents = (0..<100).map { index in
            TransferEvent.progress(
                Self.progress(
                    speed: 5,
                    totalBytes: 100,
                    sentBytes: Int64(index),
                    percent: Float(index)
                )
            )
        }
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [MockTransferScript(events: progressEvents)]
        )
        let queue = TransferQueue(
            provider: provider,
            progressPublicationInterval: .seconds(10)
        )
        let terminalEvent = Task { () -> (progressCount: Int, job: TransferJobSnapshot)? in
            var progressCount = 0
            for await event in queue.events {
                guard case let .jobUpdated(job) = event else { continue }
                if case .transferring = job.state {
                    progressCount += 1
                }
                if case .completed = job.state {
                    return (progressCount, job)
                }
            }
            return nil
        }

        let clock = ContinuousClock()
        let start = clock.now
        _ = await queue.enqueue(Self.downloadRequest)
        let terminalValue = await terminalEvent.value
        let observed = try XCTUnwrap(terminalValue)
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(observed.progressCount, 1)
        XCTAssertEqual(observed.job.state, .completed)
        XCTAssertEqual(observed.job.lastProgress?.percent, 99)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testQueuedCancellationRemovesJobWithoutCallingProvider() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [MockTransferScript(completionDelay: .milliseconds(100))]
        )
        let queue = TransferQueue(provider: provider)
        let activeId = await queue.enqueue(Self.downloadRequest)
        let queuedId = await queue.enqueue(Self.uploadRequest)
        let followingId = await queue.enqueue(Self.uploadRequest)

        try await waitUntil {
            let snapshot = await queue.snapshot
            return snapshot.activeJobId == activeId
                && snapshot.jobs.first(where: { $0.id == queuedId })?.state == .queued
        }

        let activeCancelAccepted = await queue.cancel(jobId: activeId)
        let queuedCancelAccepted = await queue.cancel(jobId: queuedId)
        let cancelledState = await state(of: queuedId, in: queue)
        // Stopping the active job aborts its file mid-copy (below); the
        // queued job is cancelled without ever reaching the provider.
        XCTAssertTrue(activeCancelAccepted)
        XCTAssertTrue(queuedCancelAccepted)
        XCTAssertEqual(cancelledState, .cancelled)
        let cancelledJob = await queue.snapshot.jobs.first { $0.id == queuedId }
        XCTAssertNil(cancelledJob?.startedAt)
        XCTAssertNil(cancelledJob?.lastProgress)

        try await waitUntil {
            let activeState = await self.state(of: activeId, in: queue)
            let followingState = await self.state(of: followingId, in: queue)
            return activeState == .cancelled && followingState == .completed
        }
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.downloadFiles, .uploadFiles])
    }

    func testMultiSourceDownloadAggregatesCumulativeProgressAcrossSources() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFileA, Self.deviceFileB],
            transferScripts: [
                MockTransferScript(events: [
                    .progress(
                        Self.fileProgress(
                            name: "a.jpg",
                            totalBytes: 1_000,
                            sentBytes: 500,
                            filesSent: 0,
                            totalFiles: 1,
                            speed: 10
                        )
                    )
                ]),
                MockTransferScript(events: [
                    .progress(
                        Self.fileProgress(
                            name: "b.jpg",
                            totalBytes: 3_000,
                            sentBytes: 900,
                            filesSent: 0,
                            totalFiles: 1,
                            speed: 20
                        )
                    )
                ])
            ]
        )
        let queue = TransferQueue(
            provider: provider,
            progressPublicationInterval: .zero
        )
        let collect = Task { () -> [TransferProgressSnapshot] in
            var snapshots: [TransferProgressSnapshot] = []
            for await event in queue.events {
                guard case let .jobUpdated(job) = event else { continue }
                if case let .transferring(snapshot) = job.state {
                    snapshots.append(snapshot)
                }
                if job.state == .completed {
                    return snapshots
                }
            }
            return snapshots
        }

        let id = await queue.enqueue(Self.twoSourceDownloadRequest)
        let snapshots = await collect.value

        let finalState = await state(of: id, in: queue)
        XCTAssertEqual(finalState, .completed)
        let progressSnapshots = snapshots.filter { $0.speed > 0 }
        XCTAssertEqual(progressSnapshots.count, 2)
        // First source: only its own totals are known; the pending source
        // still counts as one file.
        XCTAssertEqual(progressSnapshots[0].sentBytes, 500)
        XCTAssertEqual(progressSnapshots[0].totalBytes, 1_000)
        XCTAssertEqual(progressSnapshots[0].filesSent, 0)
        XCTAssertEqual(progressSnapshots[0].totalFiles, 2)
        XCTAssertEqual(progressSnapshots[0].currentFileName, "a.jpg")
        // Second source: totals accumulate across the per-source operations.
        XCTAssertEqual(progressSnapshots[1].sentBytes, 1_900)
        XCTAssertEqual(progressSnapshots[1].totalBytes, 4_000)
        XCTAssertEqual(progressSnapshots[1].filesSent, 1)
        XCTAssertEqual(progressSnapshots[1].totalFiles, 2)
        XCTAssertEqual(progressSnapshots[1].percent, 50, accuracy: 0.001)
        XCTAssertEqual(progressSnapshots[1].speed, 20, accuracy: 0.001)
        XCTAssertEqual(progressSnapshots[1].currentFileName, "b.jpg")
    }

    func testMultiSourceUploadPlansJobTotalsFromLocalFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ART-QueueUploadTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let fileA = root.appending(path: "a.bin")
        let fileB = root.appending(path: "b.bin")
        try Data(count: 100).write(to: fileA)
        try Data(count: 300).write(to: fileB)

        let provider = MockMTPProvider(
            transferScripts: [
                MockTransferScript(events: [
                    .progress(
                        Self.fileProgress(
                            name: "a.bin",
                            totalBytes: 100,
                            sentBytes: 50,
                            filesSent: 0,
                            totalFiles: 1,
                            speed: 10
                        )
                    )
                ]),
                MockTransferScript(events: [
                    .progress(
                        Self.fileProgress(
                            name: "b.bin",
                            totalBytes: 300,
                            sentBytes: 120,
                            filesSent: 0,
                            totalFiles: 1,
                            speed: 10
                        )
                    )
                ])
            ]
        )
        let queue = TransferQueue(
            provider: provider,
            progressPublicationInterval: .zero
        )
        let collect = Task { () -> [TransferProgressSnapshot] in
            var snapshots: [TransferProgressSnapshot] = []
            for await event in queue.events {
                guard case let .jobUpdated(job) = event else { continue }
                if case let .transferring(snapshot) = job.state {
                    snapshots.append(snapshot)
                }
                if job.state == .completed {
                    return snapshots
                }
            }
            return snapshots
        }
        let request = TransferRequest(
            direction: .upload,
            sources: [fileA.path, fileB.path],
            destination: "/",
            storageId: 1
        )
        let id = await queue.enqueue(request)
        let snapshots = await collect.value

        let finalState = await state(of: id, in: queue)
        XCTAssertEqual(finalState, .completed)
        let progressSnapshots = snapshots.filter { $0.speed > 0 }
        XCTAssertEqual(progressSnapshots.count, 2)
        // Local sizes are known up front, so the very first progress event
        // already reports the job's full totals.
        XCTAssertEqual(progressSnapshots[0].totalBytes, 400)
        XCTAssertEqual(progressSnapshots[0].totalFiles, 2)
        XCTAssertEqual(progressSnapshots[0].sentBytes, 50)
        XCTAssertEqual(progressSnapshots[1].totalBytes, 400)
        XCTAssertEqual(progressSnapshots[1].sentBytes, 220)
        XCTAssertEqual(progressSnapshots[1].filesSent, 1)
        XCTAssertEqual(progressSnapshots[1].percent, 50, accuracy: 0.001)
    }

    func testActiveCancellationStopsMultiSourceJobAtSourceBoundary() async throws {
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceFileA, Self.deviceFileB],
            transferScripts: [
                MockTransferScript(completionGate: gate),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.twoSourceDownloadRequest)

        try await waitUntil {
            await provider.callHistory() == [.downloadFiles]
        }
        let accepted = await queue.cancel(jobId: id)
        XCTAssertTrue(accepted)
        // A repeated stop request is rejected, and the first request is
        // published immediately so the UI can show the job is stopping.
        let repeated = await queue.cancel(jobId: id)
        XCTAssertFalse(repeated)
        try await waitUntil {
            await queue.snapshot.jobs.first { $0.id == id }?.cancelRequested == true
        }

        await gate.open()
        try await waitUntil {
            await self.state(of: id, in: queue) == .cancelled
        }
        // The second source never reached the provider.
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.downloadFiles])
        let job = await queue.snapshot.jobs.first { $0.id == id }
        XCTAssertEqual(job?.state, .cancelled)
        XCTAssertEqual(job?.cancelRequested, true)
    }

    func testCancelAllCancelsQueuedJobsAndStopsActiveJob() async throws {
        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceFileA, Self.deviceFileB],
            transferScripts: [MockTransferScript(completionGate: gate)]
        )
        let queue = TransferQueue(provider: provider)
        let activeId = await queue.enqueue(Self.twoSourceDownloadRequest)
        let queuedId = await queue.enqueue(Self.downloadRequest)

        try await waitUntil {
            await provider.callHistory() == [.downloadFiles]
        }
        let affected = await queue.cancelAll()
        XCTAssertEqual(affected, 2)
        // Queued jobs terminate immediately.
        let queuedState = await state(of: queuedId, in: queue)
        XCTAssertEqual(queuedState, .cancelled)
        let queuedStartedAt = await queue.snapshot.jobs.first { $0.id == queuedId }?.startedAt
        XCTAssertNil(queuedStartedAt)

        await gate.open()
        try await waitUntil {
            await self.state(of: activeId, in: queue) == .cancelled
        }
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.downloadFiles])
        let affectedAfterTerminal = await queue.cancelAll()
        XCTAssertEqual(affectedAfterTerminal, 0)
    }

    func testCancelledStagedJobSkipsCompletionActionAndCleansUpStaging() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ART-QueueStagingTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let staging = root.appending(path: "AndroidRapidTransfer-Staging-staging")
        let finalDirectory = root.appending(path: "final")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let stagedItem = staging.appending(path: "photo.jpg")
        let finalItem = finalDirectory.appending(path: "photo.jpg")

        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [MockTransferScript(completionGate: gate)]
        )
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/photo.jpg"],
            destination: staging.path,
            storageId: 1,
            completionAction: .moveStagedItem(
                sourcePath: stagedItem.path,
                destinationPath: finalItem.path,
                replaceExisting: true
            ),
            cleanupDirectory: staging.path
        )
        let id = await queue.enqueue(request)

        try await waitUntil {
            await provider.callHistory() == [.downloadFiles]
        }
        // The mock materialized the staged download before the stop request.
        XCTAssertTrue(fileManager.fileExists(atPath: stagedItem.path))
        let accepted = await queue.cancel(jobId: id)
        XCTAssertTrue(accepted)
        await gate.open()

        try await waitUntil {
            await self.state(of: id, in: queue) == .cancelled
        }
        let finalState = await state(of: id, in: queue)
        XCTAssertEqual(finalState, .cancelled)
        // The completion action never ran and the staging area was cleaned up.
        XCTAssertFalse(fileManager.fileExists(atPath: finalItem.path))
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
    }

    func testCompletedJobRecordsDurationAndTransferredBytes() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [
                MockTransferScript(
                    events: [
                        .progress(
                            Self.progress(
                                speed: 5,
                                totalBytes: 30_000_000,
                                sentBytes: 10_000_000,
                                percent: 33
                            )
                        ),
                        .progress(
                            Self.progress(
                                speed: 5,
                                totalBytes: 30_000_000,
                                sentBytes: 30_000_000,
                                percent: 100
                            )
                        )
                    ],
                    completionDelay: .milliseconds(50)
                )
            ]
        )
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.downloadRequest)

        try await waitUntil {
            await self.state(of: id, in: queue) == .completed
        }

        let jobs = await queue.snapshot.jobs
        let job = try XCTUnwrap(jobs.first { $0.id == id })
        let startedAt = try XCTUnwrap(job.startedAt)
        let endedAt = try XCTUnwrap(job.endedAt)
        XCTAssertGreaterThanOrEqual(endedAt, startedAt)
        XCTAssertEqual(job.lastProgress?.totalBytes, 30_000_000)
        XCTAssertEqual(job.lastProgress?.sentBytes, 30_000_000)
    }

    func testFailureDoesNotBlockFollowingJob() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            scriptedFailures: [.downloadFiles: [.fileTransfer]]
        )
        let queue = TransferQueue(provider: provider)
        let failedId = await queue.enqueue(Self.downloadRequest)
        let successfulId = await queue.enqueue(Self.uploadRequest)

        try await waitUntil {
            let firstIsTerminal = await self.isTerminal(failedId, in: queue)
            let secondState = await self.state(of: successfulId, in: queue)
            return firstIsTerminal && secondState == .completed
        }

        guard case let .failed(errorType, message) = await state(of: failedId, in: queue) else {
            return XCTFail("Expected the first transfer to fail")
        }
        XCTAssertEqual(errorType, .device(.fileTransfer))
        XCTAssertTrue(message.contains("ErrorFileTransfer"))
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.downloadFiles, .uploadFiles])
    }

    func testDeviceLostAbortsAllQueuedJobs() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [
                MockTransferScript(
                    completionDelay: .milliseconds(80),
                    completion: .callFailure(.deviceChanged)
                )
            ]
        )
        let queue = TransferQueue(provider: provider)
        let activeId = await queue.enqueue(Self.downloadRequest)
        let queuedUploadId = await queue.enqueue(Self.uploadRequest)
        let queuedDownloadId = await queue.enqueue(Self.downloadRequest)

        try await waitUntil {
            let activeIsTerminal = await self.isTerminal(activeId, in: queue)
            let uploadIsTerminal = await self.isTerminal(queuedUploadId, in: queue)
            let downloadIsTerminal = await self.isTerminal(queuedDownloadId, in: queue)
            return activeIsTerminal && uploadIsTerminal && downloadIsTerminal
        }

        for id in [activeId, queuedUploadId, queuedDownloadId] {
            guard case let .failed(errorType, _) = await state(of: id, in: queue) else {
                return XCTFail("Expected job \(id) to fail")
            }
            XCTAssertEqual(errorType, .deviceLost)
        }
        let calls = await provider.callHistory()
        let finalSnapshot = await queue.snapshot
        XCTAssertEqual(calls, [.downloadFiles])
        XCTAssertNil(finalSnapshot.activeJobId)
    }

    func testCompletedDownloadSurvivesDetachRace() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ART-CompletionRace-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staging = root
            .appending(path: "AndroidRapidTransfer-Staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stagedFile = staging.appending(path: "photo.jpg")
        let finalFile = root.appending(path: "photo.jpg")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [MockTransferScript(completionGate: gate)]
        )
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: [Self.deviceFile.path],
            destination: staging.path,
            storageId: 1,
            completionAction: .moveStagedItem(
                sourcePath: stagedFile.path,
                destinationPath: finalFile.path,
                replaceExisting: false
            ),
            cleanupDirectory: staging.path
        )
        let activeID = await queue.enqueue(request)
        let queuedID = await queue.enqueue(Self.uploadRequest)
        try await waitUntil { await queue.snapshot.activeJobId == activeID }

        let invalidation = Task {
            await queue.invalidateSession(message: "The device was disconnected.")
        }
        try await waitUntil {
            guard case .failed(errorType: .deviceLost, _) = await self.state(
                of: queuedID,
                in: queue
            ) else { return false }
            return true
        }
        await gate.open()
        await invalidation.value

        let activeState = await state(of: activeID, in: queue)
        XCTAssertEqual(activeState, .completed)
        XCTAssertTrue(fileManager.fileExists(atPath: finalFile.path))
        XCTAssertEqual(
            try Data(contentsOf: finalFile),
            Data("Mock download".utf8)
        )
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
    }

    func testControllerFatalClassifierAndTransferEngineStayInParity() async throws {
        let fatalErrors: [(MTPErrorType, ConnectionFatalDisposition)] = [
            (.deviceChanged, .deviceUnavailable),
            (.mtpDetectFailed, .deviceUnavailable),
            (.deviceSetup, .requiresReplug)
        ]

        for (errorType, expectedDisposition) in fatalErrors {
            let error = MTPCallError(message: "fatal", type: errorType)
            XCTAssertEqual(
                ConnectionFatalClassifier.disposition(for: error),
                expectedDisposition
            )

            let provider = MockMTPProvider(
                entries: [Self.deviceFile],
                transferScripts: [
                    MockTransferScript(completion: .callFailure(errorType))
                ]
            )
            let queue = TransferQueue(provider: provider)
            let activeID = await queue.enqueue(Self.downloadRequest)
            let queuedID = await queue.enqueue(Self.uploadRequest)

            try await waitUntil {
                let activeIsTerminal = await self.isTerminal(activeID, in: queue)
                let queuedIsTerminal = await self.isTerminal(queuedID, in: queue)
                return activeIsTerminal && queuedIsTerminal
            }

            for id in [activeID, queuedID] {
                guard case let .failed(failureType, _) = await state(of: id, in: queue) else {
                    return XCTFail("Expected fatal error \(errorType) to terminalize job \(id)")
                }
                XCTAssertEqual(failureType, .deviceLost)
            }
            let calls = await provider.callHistory()
            XCTAssertEqual(calls, [.downloadFiles])
        }
    }

    func testFolderDownloadWalksCreatesLocalDirectoriesAndDownloadsEachFile() async throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appending(path: "ART-FolderDownload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: destination) }

        let provider = MockMTPProvider(entries: Self.albumDeviceTree)
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        let id = await queue.enqueue(request)

        try await waitUntil {
            await self.state(of: id, in: queue) == .completed
        }

        // The tree is walked (root plus each subdirectory), then every file is
        // downloaded with its own native call.
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.walk, .walk, .walk, .downloadFiles, .downloadFiles])
        // The device tree is recreated locally, including the empty directory.
        XCTAssertTrue(isDirectory(destination.appending(path: "album"), fileManager))
        XCTAssertTrue(isDirectory(destination.appending(path: "album/empty"), fileManager))
        XCTAssertTrue(isDirectory(destination.appending(path: "album/sub"), fileManager))
    }

    func testExpandedDownloadThreadsDirectoryAndPerFileObjectIds() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ART-HandleExpansion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let provider = MockMTPProvider(entries: Self.albumDeviceTree)
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"],
            sourceObjectIds: ["/DCIM/album": 777]
        )
        let id = await queue.enqueue(request)

        try await waitUntil { await self.state(of: id, in: queue) == .completed }

        let walks = await provider.walkInputs()
        XCTAssertEqual(walks.first?.objectId, 777)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: walks.dropFirst().map { ($0.fullPath, $0.objectId) }),
            Dictionary(uniqueKeysWithValues: Self.albumDeviceTree.filter(\.isFolder).dropFirst().map {
                ($0.path, Optional($0.objectId))
            })
        )
        let downloads = await provider.downloadInputs()
        XCTAssertEqual(
            downloads.flatMap { $0.sourceProps ?? [] },
            Self.albumDeviceTree.filter { !$0.isFolder }.map {
                SourceProp(fullPath: $0.path, objectId: $0.objectId)
            }
        )
    }

    func testLooseDownloadWithHintPassesSourceProp() async throws {
        let provider = MockMTPProvider(entries: [Self.deviceFile])
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: [Self.deviceFile.path],
            destination: "/tmp/downloads",
            storageId: 1,
            sourceObjectIds: [Self.deviceFile.path: Self.deviceFile.objectId]
        )
        let id = await queue.enqueue(request)

        try await waitUntil { await self.state(of: id, in: queue) == .completed }

        let inputs = await provider.downloadInputs()
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(
            input.sourceProps,
            [SourceProp(fullPath: Self.deviceFile.path, objectId: Self.deviceFile.objectId)]
        )
    }

    func testLooseDownloadWithoutHintUsesPathOnlyInput() async throws {
        let provider = MockMTPProvider(entries: [Self.deviceFile])
        let queue = TransferQueue(provider: provider)
        let id = await queue.enqueue(Self.downloadRequest)

        try await waitUntil { await self.state(of: id, in: queue) == .completed }

        let inputs = await provider.downloadInputs()
        let input = try XCTUnwrap(inputs.first)
        XCTAssertNil(input.sourceProps)
        XCTAssertEqual(input.sources, [Self.deviceFile.path])
    }

    func testFolderUploadCreatesDeviceDirectoriesThenUploadsEachFile() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ART-FolderUpload-\(UUID().uuidString)", directoryHint: .isDirectory)
        let album = root.appending(path: "album")
        let sub = album.appending(path: "sub")
        let empty = album.appending(path: "empty")
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(count: 100).write(to: album.appending(path: "a.bin"))
        try Data(count: 300).write(to: sub.appending(path: "b.bin"))
        defer { try? fileManager.removeItem(at: root) }

        let provider = MockMTPProvider()
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .upload,
            sources: [album.path],
            destination: "/",
            storageId: 1
        )
        let id = await queue.enqueue(request)

        try await waitUntil {
            await self.state(of: id, in: queue) == .completed
        }

        let calls = await provider.callHistory()
        // Three directories are created before any file is uploaded, then each
        // file is uploaded one native call at a time.
        XCTAssertEqual(calls.filter { $0 == .makeDirectory }.count, 3)
        XCTAssertEqual(calls.filter { $0 == .uploadFiles }.count, 2)
        let firstUpload = try XCTUnwrap(calls.firstIndex(of: .uploadFiles))
        let lastDirectory = try XCTUnwrap(calls.lastIndex(of: .makeDirectory))
        XCTAssertLessThan(lastDirectory, firstUpload)
        // The folder tree, empty directory included, is recreated on the device.
        let devicePaths = Set(await provider.allEntries().map(\.path))
        XCTAssertTrue(devicePaths.isSuperset(of: [
            "/album",
            "/album/empty",
            "/album/sub",
            "/album/a.bin",
            "/album/sub/b.bin"
        ]))
    }

    func testActiveCancellationStopsFolderDownloadBeforeNextFile() async throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appending(path: "ART-FolderCancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: destination) }

        let gate = MockTransferGate()
        let provider = MockMTPProvider(
            entries: Self.flatAlbumDeviceTree,
            transferScripts: [
                MockTransferScript(completionGate: gate),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        let id = await queue.enqueue(request)

        // The single-level walk finishes and the first file's download is in
        // flight, blocked on the gate.
        try await waitUntil {
            await provider.callHistory() == [.walk, .downloadFiles]
        }
        let accepted = await queue.cancel(jobId: id)
        XCTAssertTrue(accepted)
        try await waitUntil {
            await queue.snapshot.jobs.first { $0.id == id }?.cancelRequested == true
        }

        await gate.open()
        try await waitUntil {
            await self.state(of: id, in: queue) == .cancelled
        }
        // The second file never reached the provider.
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.walk, .downloadFiles])
    }

    func testExpandedFolderDownloadReportsMonotoneAggregatedProgress() async throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appending(path: "ART-FolderProgress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: destination) }

        let provider = MockMTPProvider(
            entries: Self.flatAlbumDeviceTree,
            transferScripts: [
                MockTransferScript(events: [
                    .progress(
                        Self.fileProgress(
                            name: "a.jpg",
                            totalBytes: 1_000,
                            sentBytes: 500,
                            filesSent: 0,
                            totalFiles: 1,
                            speed: 10
                        )
                    )
                ]),
                MockTransferScript(events: [
                    .progress(
                        Self.fileProgress(
                            name: "b.jpg",
                            totalBytes: 2_000,
                            sentBytes: 1_000,
                            filesSent: 0,
                            totalFiles: 1,
                            speed: 20
                        )
                    )
                ])
            ]
        )
        let queue = TransferQueue(provider: provider, progressPublicationInterval: .zero)
        let collect = Task { () -> [TransferProgressSnapshot] in
            var snapshots: [TransferProgressSnapshot] = []
            for await event in queue.events {
                guard case let .jobUpdated(job) = event else { continue }
                if case let .transferring(snapshot) = job.state {
                    snapshots.append(snapshot)
                }
                if job.state == .completed {
                    return snapshots
                }
            }
            return snapshots
        }

        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        let id = await queue.enqueue(request)
        let snapshots = await collect.value

        let finalState = await state(of: id, in: queue)
        XCTAssertEqual(finalState, .completed)
        XCTAssertGreaterThanOrEqual(snapshots.count, 4)
        // Percent and the completed-file count never regress across the
        // expanded per-file transfers.
        for (previous, next) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.percent, previous.percent)
            XCTAssertGreaterThanOrEqual(next.filesSent, previous.filesSent)
        }
        // Walk sizes are known up front, so the two-file totals are stable
        // even in the snapshot emitted before the first progress event.
        XCTAssertTrue(snapshots.allSatisfy { $0.totalFiles == 2 })
        XCTAssertTrue(snapshots.allSatisfy { $0.totalBytes == 3_000 })
        XCTAssertEqual(snapshots.last?.filesSent, 2)
        XCTAssertEqual(snapshots.last?.percent, 100)
    }

    func testExpandedFolderPreprocessEventsKeepTransferringStateAndAdvanceFileCounter() async throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appending(path: "ART-FolderPreprocess-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: destination) }

        let provider = MockMTPProvider(
            entries: Self.flatAlbumDeviceTree,
            transferScripts: [
                MockTransferScript(events: [
                    .preprocess(
                        TransferPreprocessData(
                            fullPath: "/DCIM/album/a.jpg",
                            name: "a.jpg",
                            size: 1_000
                        )
                    )
                ]),
                MockTransferScript(events: [
                    .preprocess(
                        TransferPreprocessData(
                            fullPath: "/DCIM/album/b.jpg",
                            name: "b.jpg",
                            size: 2_000
                        )
                    ),
                    .progress(
                        Self.fileProgress(
                            name: "b.jpg",
                            totalBytes: 2_000,
                            sentBytes: 2_000,
                            filesSent: 1,
                            totalFiles: 1,
                            speed: 20
                        )
                    )
                ])
            ]
        )
        let queue = TransferQueue(provider: provider, progressPublicationInterval: .zero)
        let collect = Task { () -> [TransferJobState] in
            var states: [TransferJobState] = []
            for await event in queue.events {
                guard case let .jobUpdated(job) = event else { continue }
                states.append(job.state)
                switch job.state {
                case .completed, .cancelled, .failed:
                    return states
                case .queued, .preprocessing, .transferring:
                    break
                }
            }
            return states
        }

        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        let id = await queue.enqueue(request)
        let states = await collect.value

        let finalState = await state(of: id, in: queue)
        XCTAssertEqual(finalState, .completed)
        let firstTransferIndex = try XCTUnwrap(states.firstIndex { state in
            if case .transferring = state { return true }
            return false
        })
        XCTAssertFalse(states[firstTransferIndex...].contains { state in
            if case .preprocessing = state { return true }
            return false
        })

        let snapshots = states.compactMap { state -> TransferProgressSnapshot? in
            guard case let .transferring(snapshot) = state else { return nil }
            return snapshot
        }
        XCTAssertFalse(snapshots.isEmpty)
        for (previous, next) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.filesSent, previous.filesSent)
        }
        XCTAssertEqual(snapshots.last?.filesSent, snapshots.last?.totalFiles)
        XCTAssertEqual(snapshots.last?.totalFiles, 2)
        XCTAssertTrue(snapshots.contains {
            $0.currentFileName == "a.jpg" && $0.filesSent == 0
        })
        XCTAssertTrue(snapshots.contains {
            $0.currentFileName == "b.jpg" && $0.filesSent == 1
        })
    }

    func testSingleLooseFileStillReportsPreprocessingBeforeTransferProgress() async throws {
        let provider = MockMTPProvider(
            entries: [Self.deviceFile],
            transferScripts: [
                MockTransferScript(events: [
                    .preprocess(
                        TransferPreprocessData(
                            fullPath: "/DCIM/photo.jpg",
                            name: "photo.jpg",
                            size: 1_000
                        )
                    ),
                    .progress(
                        Self.fileProgress(
                            name: "photo.jpg",
                            totalBytes: 1_000,
                            sentBytes: 1_000,
                            filesSent: 1,
                            totalFiles: 1,
                            speed: 10
                        )
                    )
                ])
            ]
        )
        let queue = TransferQueue(provider: provider, progressPublicationInterval: .zero)
        let collect = Task { () -> [TransferJobState] in
            var states: [TransferJobState] = []
            for await event in queue.events {
                guard case let .jobUpdated(job) = event else { continue }
                states.append(job.state)
                switch job.state {
                case .completed, .cancelled, .failed:
                    return states
                case .queued, .preprocessing, .transferring:
                    break
                }
            }
            return states
        }

        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/photo.jpg"],
            destination: "/tmp/downloads",
            storageId: 1
        )
        let id = await queue.enqueue(request)
        let states = await collect.value

        let finalState = await state(of: id, in: queue)
        XCTAssertEqual(finalState, .completed)
        let preprocessingIndices = states.indices.filter { index in
            if case .preprocessing = states[index] { return true }
            return false
        }
        let firstTransferIndex = try XCTUnwrap(states.firstIndex { state in
            if case .transferring = state { return true }
            return false
        })
        XCTAssertGreaterThanOrEqual(preprocessingIndices.count, 2)
        XCTAssertLessThan(try XCTUnwrap(preprocessingIndices.last), firstTransferIndex)
    }

    func testFailedFileMidPlanIsSkippedAndJobCompletesWithFailure() async throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appending(path: "ART-FileFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: destination) }

        let provider = MockMTPProvider(
            entries: Self.threeFileAlbumDeviceTree,
            transferScripts: [
                MockTransferScript(),
                MockTransferScript(completion: .success(false)),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider, progressPublicationInterval: .zero)
        let collect = Task { () -> (snapshots: [TransferProgressSnapshot], job: TransferJobSnapshot)? in
            var snapshots: [TransferProgressSnapshot] = []
            for await event in queue.events {
                guard case let .jobUpdated(job) = event else { continue }
                if case let .transferring(snapshot) = job.state {
                    snapshots.append(snapshot)
                }
                if job.state.isTerminal {
                    return (snapshots, job)
                }
            }
            return nil
        }

        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        _ = await queue.enqueue(request)
        let collected = await collect.value
        let observed = try XCTUnwrap(collected)

        // The failed second file was recorded and skipped: the job still
        // settles as completed, and the third file's download did happen.
        XCTAssertEqual(observed.job.state, .completed)
        XCTAssertEqual(observed.job.fileFailures.count, 1)
        let failure = try XCTUnwrap(observed.job.fileFailures.first)
        XCTAssertEqual(failure.source, "/DCIM/album/b.jpg")
        XCTAssertEqual(failure.destinationDirectory, destination.appending(path: "album").path)
        XCTAssertFalse(failure.message.isEmpty)
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.walk, .downloadFiles, .downloadFiles, .downloadFiles])

        // Aggregated progress stays monotone across the failed file: its
        // planned bytes settle instead of stalling or regressing the bar.
        for (previous, next) in zip(observed.snapshots, observed.snapshots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.percent, previous.percent)
            XCTAssertGreaterThanOrEqual(next.filesSent, previous.filesSent)
            XCTAssertGreaterThanOrEqual(next.sentBytes, previous.sentBytes)
        }
        let finalSnapshot = try XCTUnwrap(observed.snapshots.last)
        XCTAssertEqual(finalSnapshot.filesSent, 3)
        XCTAssertEqual(finalSnapshot.totalFiles, 3)
        XCTAssertEqual(finalSnapshot.percent, 100)
    }

    func testEveryFileFailingSettlesJobAsFailedWithPerFileFailures() async throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appending(path: "ART-AllFailed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: destination) }

        let provider = MockMTPProvider(
            entries: Self.flatAlbumDeviceTree,
            transferScripts: [
                MockTransferScript(completion: .success(false)),
                MockTransferScript(completion: .success(false))
            ]
        )
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        let id = await queue.enqueue(request)

        try await waitUntil {
            await self.isTerminal(id, in: queue)
        }

        let settledJob = await queue.snapshot.jobs.first { $0.id == id }
        let job = try XCTUnwrap(settledJob)
        guard case let .failed(errorType, message) = job.state else {
            return XCTFail("Expected the job to fail when every file failed")
        }
        XCTAssertEqual(errorType, .unknown)
        XCTAssertTrue(message.contains("All 2 files failed"))
        XCTAssertEqual(
            job.fileFailures.map(\.source),
            ["/DCIM/album/a.jpg", "/DCIM/album/b.jpg"]
        )
        // Both files were still attempted before the job settled.
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.walk, .downloadFiles, .downloadFiles])
    }

    func testDeviceLostMidPlanStillFailsWholeJobImmediately() async throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appending(path: "ART-DeviceLostPlan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: destination) }

        let provider = MockMTPProvider(
            entries: Self.threeFileAlbumDeviceTree,
            transferScripts: [
                MockTransferScript(),
                MockTransferScript(completion: .callFailure(.deviceChanged)),
                MockTransferScript()
            ]
        )
        let queue = TransferQueue(provider: provider)
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/album"],
            destination: destination.path,
            storageId: 1,
            directorySources: ["/DCIM/album"]
        )
        let id = await queue.enqueue(request)

        try await waitUntil {
            await self.isTerminal(id, in: queue)
        }

        // A lost device is never treated as a skippable per-file failure: the
        // job fails at once and the third file is never attempted.
        guard case let .failed(errorType, _) = await state(of: id, in: queue) else {
            return XCTFail("Expected a device-lost failure")
        }
        XCTAssertEqual(errorType, .deviceLost)
        let calls = await provider.callHistory()
        XCTAssertEqual(calls, [.walk, .downloadFiles, .downloadFiles])
    }

    private func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func state(of id: UUID, in queue: TransferQueue) async -> TransferJobState? {
        await queue.snapshot.jobs.first(where: { $0.id == id })?.state
    }

    private func isTerminal(_ id: UUID, in queue: TransferQueue) async -> Bool {
        guard let state = await state(of: id, in: queue) else { return false }
        switch state {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .preprocessing, .transferring:
            return false
        }
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
        XCTFail("Timed out waiting for transfer queue state")
    }

    private static let downloadRequest = TransferRequest(
        direction: .download,
        sources: ["/DCIM/photo.jpg"],
        destination: "/tmp/downloads",
        storageId: 1
    )

    private static let twoSourceDownloadRequest = TransferRequest(
        direction: .download,
        sources: ["/DCIM/a.jpg", "/DCIM/b.jpg"],
        destination: "/tmp/downloads",
        storageId: 1
    )

    private static func folderEntry(path: String) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: 0,
            isFolder: true,
            modified: wallClockDate("2026-01-01T00:00:00Z"),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: "",
            parentId: 1,
            objectId: UInt32(abs(path.hashValue % 100_000)) + 100
        )
    }

    private static func deviceFile(path: String, size: Int64) -> WalkEntry {
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
            objectId: UInt32(abs(path.hashValue % 100_000)) + 100
        )
    }

    /// A nested device tree: `/DCIM/album` holds a file, an empty subdirectory,
    /// and a subdirectory containing a second file.
    private static let albumDeviceTree = [
        folderEntry(path: "/DCIM/album"),
        deviceFile(path: "/DCIM/album/a.jpg", size: 1_000),
        folderEntry(path: "/DCIM/album/empty"),
        folderEntry(path: "/DCIM/album/sub"),
        deviceFile(path: "/DCIM/album/sub/b.jpg", size: 2_000)
    ]

    /// A single-level device folder holding two files.
    private static let flatAlbumDeviceTree = [
        folderEntry(path: "/DCIM/album"),
        deviceFile(path: "/DCIM/album/a.jpg", size: 1_000),
        deviceFile(path: "/DCIM/album/b.jpg", size: 2_000)
    ]

    /// A single-level device folder holding three files, so a mid-plan file
    /// (neither first nor last) can fail while its siblings succeed.
    private static let threeFileAlbumDeviceTree = [
        folderEntry(path: "/DCIM/album"),
        deviceFile(path: "/DCIM/album/a.jpg", size: 1_000),
        deviceFile(path: "/DCIM/album/b.jpg", size: 2_000),
        deviceFile(path: "/DCIM/album/c.jpg", size: 4_000)
    ]

    private static let deviceFileA = WalkEntry(
        size: 1_000,
        isFolder: false,
        modified: wallClockDate("2026-01-01T00:00:00Z"),
        name: "a.jpg",
        path: "/DCIM/a.jpg",
        parentPath: "/DCIM",
        extension: "jpg",
        parentId: 1,
        objectId: 3
    )

    private static let deviceFileB = WalkEntry(
        size: 3_000,
        isFolder: false,
        modified: wallClockDate("2026-01-01T00:00:00Z"),
        name: "b.jpg",
        path: "/DCIM/b.jpg",
        parentPath: "/DCIM",
        extension: "jpg",
        parentId: 1,
        objectId: 4
    )

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

    private static let uploadRequest = TransferRequest(
        direction: .upload,
        sources: ["/tmp/upload.txt"],
        destination: "/",
        storageId: 1
    )

    private static let deviceFile = WalkEntry(
        size: 30_000_000,
        isFolder: false,
        modified: wallClockDate("2026-01-01T00:00:00Z"),
        name: "photo.jpg",
        path: "/DCIM/photo.jpg",
        parentPath: "/DCIM",
        extension: "jpg",
        parentId: 1,
        objectId: 2
    )

    private static func progress(
        speed: Double,
        totalBytes: Int64,
        sentBytes: Int64,
        percent: Float
    ) -> TransferProgressInfo {
        TransferProgressInfo(
            fullPath: "/DCIM/photo.jpg",
            name: "photo.jpg",
            elapsedTime: 1_000,
            speed: speed,
            totalFiles: 5,
            totalDirectories: 0,
            filesSent: 2,
            filesSentProgress: percent,
            activeFileSize: TransferSizeInfo(
                total: totalBytes,
                sent: sentBytes,
                progress: percent
            ),
            bulkFileSize: TransferSizeInfo(
                total: totalBytes,
                sent: sentBytes,
                progress: percent
            )
        )
    }
}
