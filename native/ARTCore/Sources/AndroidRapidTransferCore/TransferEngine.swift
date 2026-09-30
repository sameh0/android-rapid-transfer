import Foundation
import MTPKit
#if canImport(OSLog)
import OSLog
#endif

public enum TransferDirection: Equatable, Sendable {
    case download
    case upload
}

enum DeviceUploadPreparation: Equatable, Sendable {
    case keepBoth(originalName: String)
    case replacement(finalPath: String)
}

public struct TransferRequest: Equatable, Sendable {
    public let direction: TransferDirection
    public let sources: [String]
    public let destination: String
    public let storageId: UInt32
    public let preprocessFiles: Bool
    public let completionAction: TransferCompletionAction?
    public let cleanupDirectory: String?
    /// Per-session device path → MTP handle hints. These are deliberately not
    /// part of `TransferBatchStore`; resumed transfers resolve their paths.
    public let sourceObjectIds: [String: UInt32]
    let deviceUploadPreparation: DeviceUploadPreparation?
    let reservedDevicePaths: Set<String>
    /// The subset of ``sources`` that are directories. Download callers supply
    /// this because directory detection would otherwise need a device round-trip;
    /// uploads leave it empty and let the queue detect directories locally with
    /// `FileManager`. A directory source is expanded into per-file native calls
    /// so cancellation can land at file boundaries within the tree.
    public let directorySources: Set<String>

    var displayNameOverride: String? {
        guard case let .replacement(finalPath) = deviceUploadPreparation else { return nil }
        return URL(fileURLWithPath: finalPath).lastPathComponent
    }

    public init(
        direction: TransferDirection,
        sources: [String],
        destination: String,
        storageId: UInt32,
        preprocessFiles: Bool = true,
        completionAction: TransferCompletionAction? = nil,
        cleanupDirectory: String? = nil,
        directorySources: Set<String> = [],
        sourceObjectIds: [String: UInt32] = [:]
    ) {
        self.direction = direction
        self.sources = sources
        self.destination = destination
        self.storageId = storageId
        self.preprocessFiles = preprocessFiles
        self.completionAction = completionAction
        self.cleanupDirectory = cleanupDirectory
        self.directorySources = directorySources
        self.sourceObjectIds = sourceObjectIds
        deviceUploadPreparation = nil
        reservedDevicePaths = []
    }

    init(
        direction: TransferDirection,
        sources: [String],
        destination: String,
        storageId: UInt32,
        preprocessFiles: Bool = true,
        completionAction: TransferCompletionAction? = nil,
        cleanupDirectory: String? = nil,
        directorySources: Set<String> = [],
        sourceObjectIds: [String: UInt32] = [:],
        deviceUploadPreparation: DeviceUploadPreparation?,
        reservedDevicePaths: Set<String>
    ) {
        self.direction = direction
        self.sources = sources
        self.destination = destination
        self.storageId = storageId
        self.preprocessFiles = preprocessFiles
        self.completionAction = completionAction
        self.cleanupDirectory = cleanupDirectory
        self.directorySources = directorySources
        self.sourceObjectIds = sourceObjectIds
        self.deviceUploadPreparation = deviceUploadPreparation
        self.reservedDevicePaths = reservedDevicePaths
    }

    func replacingUploadSource(
        _ source: String,
        reservedDevicePaths: Set<String>
    ) -> TransferRequest {
        TransferRequest(
            direction: direction,
            sources: [source],
            destination: destination,
            storageId: storageId,
            preprocessFiles: preprocessFiles,
            completionAction: completionAction,
            cleanupDirectory: cleanupDirectory,
            directorySources: directorySources,
            sourceObjectIds: sourceObjectIds,
            deviceUploadPreparation: deviceUploadPreparation,
            reservedDevicePaths: reservedDevicePaths
        )
    }

    /// A copy that preprocesses (or not) according to the user's per-direction
    /// "Display overall progress" setting, applied where requests are enqueued.
    func settingPreprocessFiles(_ preprocessFiles: Bool) -> TransferRequest {
        guard preprocessFiles != self.preprocessFiles else { return self }
        return TransferRequest(
            direction: direction,
            sources: sources,
            destination: destination,
            storageId: storageId,
            preprocessFiles: preprocessFiles,
            completionAction: completionAction,
            cleanupDirectory: cleanupDirectory,
            directorySources: directorySources,
            sourceObjectIds: sourceObjectIds,
            deviceUploadPreparation: deviceUploadPreparation,
            reservedDevicePaths: reservedDevicePaths
        )
    }

    public static func == (lhs: TransferRequest, rhs: TransferRequest) -> Bool {
        lhs.direction == rhs.direction
            && lhs.sources == rhs.sources
            && lhs.destination == rhs.destination
            && lhs.storageId == rhs.storageId
            && lhs.preprocessFiles == rhs.preprocessFiles
            && lhs.completionAction == rhs.completionAction
            && lhs.cleanupDirectory == rhs.cleanupDirectory
            && lhs.sourceObjectIds == rhs.sourceObjectIds
    }
}

public struct TransferProgressSnapshot: Equatable, Sendable {
    public let percent: Double
    public let speed: Double
    public let eta: TimeInterval?
    public let currentFileName: String
    public let filesSent: Int64
    public let totalFiles: Int64
    public let totalBytes: Int64
    public let sentBytes: Int64
    /// How far through its bytes the file being copied is (0...1), when
    /// known and not yet counted in `filesSent`.
    public let currentFileFraction: Double?

    /// Completion as 0...1 for progress bars: finished files plus the share
    /// of the current one, so a single large file fills smoothly instead of
    /// jumping from 0 to 100% (``percent`` is file-based). Stays monotone
    /// while a file finishes, because the file's fraction becomes a whole
    /// file in `filesSent` at the same time.
    public var fraction: Double {
        guard totalFiles > 0 else { return currentFileFraction ?? percent / 100 }
        let done = Double(filesSent) + (currentFileFraction ?? 0)
        return min(max(done / Double(totalFiles), 0), 1)
    }

    public init(
        percent: Double,
        speed: Double,
        currentFileName: String,
        filesSent: Int64,
        totalFiles: Int64,
        totalBytes: Int64,
        sentBytes: Int64,
        currentFileFraction: Double? = nil
    ) {
        self.percent = percent.isFinite ? min(max(percent, 0), 100) : 0
        self.speed = speed
        eta = Self.eta(
            totalBytes: totalBytes,
            sentBytes: sentBytes,
            speedMegabytesPerSecond: speed
        )
        self.currentFileName = currentFileName
        self.filesSent = filesSent
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.sentBytes = sentBytes
        self.currentFileFraction = currentFileFraction.map { min(max($0, 0), 1) }
    }

    public init(
        progress: TransferProgressInfo,
        currentFileNameOverride: String? = nil
    ) {
        let reportedPercent = Double(progress.filesSentProgress)
        percent = reportedPercent.isFinite ? min(max(reportedPercent, 0), 100) : 0
        speed = progress.speed
        eta = Self.eta(
            totalBytes: progress.bulkFileSize.total,
            sentBytes: progress.bulkFileSize.sent,
            speedMegabytesPerSecond: progress.speed
        )
        currentFileName = currentFileNameOverride ?? (
            progress.name.isEmpty
                ? URL(fileURLWithPath: progress.fullPath).lastPathComponent
                : progress.name
        )
        filesSent = progress.filesSent
        totalFiles = progress.totalFiles
        totalBytes = progress.bulkFileSize.total
        sentBytes = progress.bulkFileSize.sent
        let active = progress.activeFileSize
        // Once the provider counts the file as sent, its bytes are no longer
        // "in progress".
        let isCounted = progress.totalFiles > 0 && progress.filesSent >= progress.totalFiles
        currentFileFraction = active.total > 0 && !isCounted
            ? min(max(Double(active.sent) / Double(active.total), 0), 1)
            : nil
    }

    private static func eta(
        totalBytes: Int64,
        sentBytes: Int64,
        speedMegabytesPerSecond: Double
    ) -> TimeInterval? {
        guard totalBytes > 0,
              sentBytes >= 0,
              speedMegabytesPerSecond > 0,
              speedMegabytesPerSecond.isFinite else { return nil }

        let remainingBytes = max(totalBytes - sentBytes, 0)
        // The provider reports decimal MB/s. Transfer size values are treated as bytes,
        // matching the existing native browser's byte-based size model.
        return Double(remainingBytes) / (speedMegabytesPerSecond * 1_000_000)
    }
}

public enum TransferQueueFailureType: Equatable, Sendable {
    case deviceLost
    case device(MTPErrorType)
    case unknown
}

public enum TransferJobState: Equatable, Sendable {
    case queued
    case preprocessing
    case transferring(TransferProgressSnapshot)
    case completed
    case failed(errorType: TransferQueueFailureType, message: String)
    case cancelled
}

/// One file that failed inside an otherwise surviving expanded job.
///
/// Kept as a separate record instead of an associated value on
/// ``TransferJobState`` so a partially failed job still settles through the
/// existing `.completed` / `.failed` paths and every state comparison in the
/// app keeps working unchanged.
public struct TransferFileFailure: Equatable, Sendable {
    /// Absolute source path of the file that failed (device path for
    /// downloads, local path for uploads).
    public let source: String
    /// The directory the file was being copied into.
    public let destinationDirectory: String
    /// Human-readable reason for the failure.
    public let message: String

    public init(source: String, destinationDirectory: String, message: String) {
        self.source = source
        self.destinationDirectory = destinationDirectory
        self.message = message
    }
}

public struct TransferJobSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let request: TransferRequest
    public let state: TransferJobState
    /// When the job left the queue and started touching the device.
    /// Stays `nil` for jobs cancelled or aborted while still queued.
    public let startedAt: Date?
    /// When the job reached a terminal state.
    public let endedAt: Date?
    /// Most recent progress report, retained after completion so finished
    /// jobs can still report how much data moved.
    public let lastProgress: TransferProgressSnapshot?
    /// Set once the user asked to stop this job. Queued jobs terminate
    /// immediately; the active job aborts the file in flight (see
    /// ``TransferQueue/cancel(jobId:)``) and settles as cancelled.
    public let cancelRequested: Bool
    /// Files that failed while the rest of the job kept going. Non-empty only
    /// for expanded jobs: with at least one success the job settles as
    /// `.completed` carrying these failures; with none it settles as `.failed`.
    public let fileFailures: [TransferFileFailure]

    public init(
        id: UUID,
        request: TransferRequest,
        state: TransferJobState,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastProgress: TransferProgressSnapshot? = nil,
        cancelRequested: Bool = false,
        fileFailures: [TransferFileFailure] = []
    ) {
        self.id = id
        self.request = request
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastProgress = lastProgress
        self.cancelRequested = cancelRequested
        self.fileFailures = fileFailures
    }
}

public struct TransferQueueSnapshot: Equatable, Sendable {
    public let jobs: [TransferJobSnapshot]
    public let activeJobId: UUID?

    public init(jobs: [TransferJobSnapshot], activeJobId: UUID?) {
        self.jobs = jobs
        self.activeJobId = activeJobId
    }
}

public enum TransferQueueEvent: Equatable, Sendable {
    case jobUpdated(TransferJobSnapshot)
}

/// Owns the native app's transfer pipeline and serializes every transfer through
/// one `MTPDeviceProvider`.
///
/// This engine intentionally lives in `AndroidRapidTransferCore` rather than a separate SPM
/// target: it is a small application-domain layer directly coupled to the
/// provider's transfer payloads, so another module boundary would not isolate an
/// independently reusable dependency.
///
/// An MTP session runs one operation at a time, so device transfers can never run
/// in parallel. Jobs therefore execute strictly serially. A job that is a single
/// non-directory source keeps the provider's raw progress stream; every other job (multiple sources, or a directory source) is
/// expanded into per-file native transfers, aggregating cumulative job-level
/// progress across those calls. Directory sources are enumerated into their
/// constituent files — local trees via `FileManager` for uploads, recursive
/// `walk` for downloads — so a folder no longer copies as one uninterruptible
/// native call. Local-to-local copies do not touch the device;
/// `TransferViewModel` parallelizes those instead.
///
/// `cancel(jobId:)` terminates queued jobs immediately. For the active job it
/// also aborts the file in flight by cancelling its `TransferOperation.result`:
/// the provider stops the MTP data phase, keeps the session usable, and leaves
/// no partial file behind (a download's temporary file is removed; a partial
/// upload is deleted from the device). The queue then stops before the next
/// file and skips completion actions. Files already copied stay in place. A
/// file whose native call finished before the abort landed counts as copied.
public actor TransferQueue {
    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "TransferQueue"
    )
    public nonisolated let events: AsyncStream<TransferQueueEvent>
    public nonisolated let sessionID: UUID

    private let provider: any MTPDeviceProvider
    private let eventContinuation: AsyncStream<TransferQueueEvent>.Continuation
    private let progressPublicationInterval: Duration
    private let progressClock = ContinuousClock()
    private var jobsById: [UUID: TransferJobSnapshot] = [:]
    private var jobOrder: [UUID] = []
    private var pendingJobIds: [UUID] = []
    private var activeJobId: UUID?
    private var activeCancelRequests: Set<UUID> = []
    /// The native transfer currently in flight, so a stop request can abort it
    /// mid-file instead of waiting for the file to finish.
    private var inFlightTransfer: (jobId: UUID, result: Task<Bool, Error>)?
    private var processingTask: Task<Void, Never>?
    private var terminalDeviceLossMessage: String?
    private var devicePathReservationCounts: [String: Int] = [:]
    private var lastProgressPublicationInstant: [UUID: ContinuousClock.Instant] = [:]
    private var pendingProgressPublicationTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        provider: any MTPDeviceProvider,
        sessionID: UUID = UUID(),
        progressPublicationInterval: Duration = .milliseconds(100)
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.progressPublicationInterval = progressPublicationInterval
        let (events, continuation) = AsyncStream<TransferQueueEvent>.makeStream()
        self.events = events
        eventContinuation = continuation
    }

    public var snapshot: TransferQueueSnapshot {
        TransferQueueSnapshot(
            jobs: jobOrder.compactMap { jobsById[$0] },
            activeJobId: activeJobId
        )
    }

    func reserveDevicePathIfAvailable(_ path: String) -> Bool {
        guard devicePathReservationCounts[path, default: 0] == 0 else { return false }
        devicePathReservationCounts[path] = 1
        return true
    }

    func reserveDevicePath(_ path: String) {
        devicePathReservationCounts[path, default: 0] += 1
    }

    func releaseDevicePaths(_ paths: [String]) {
        for path in paths {
            releaseDevicePath(path)
        }
    }

    @discardableResult
    public func enqueue(_ request: TransferRequest) -> UUID {
        let id = UUID()
        let job = TransferJobSnapshot(id: id, request: request, state: .queued)
        jobsById[id] = job
        jobOrder.append(id)
        publish(job)

        if let terminalDeviceLossMessage {
            update(
                id,
                state: .failed(errorType: .deviceLost, message: terminalDeviceLossMessage)
            )
        } else {
            pendingJobIds.append(id)
            startProcessingIfNeeded()
        }
        return id
    }

    /// Cancels a queued job immediately, or stops the active job: the file in
    /// flight is aborted and no further file starts (see the type-level
    /// documentation). Requesting cancellation twice or targeting a terminal
    /// job returns `false`.
    @discardableResult
    public func cancel(jobId: UUID) -> Bool {
        if let index = pendingJobIds.firstIndex(of: jobId) {
            pendingJobIds.remove(at: index)
            update(jobId, state: .cancelled)
            return true
        }
        guard activeJobId == jobId,
              let job = jobsById[jobId],
              !job.cancelRequested else { return false }
        activeCancelRequests.insert(jobId)
        publishCancelRequested(jobId)
        if let inFlightTransfer, inFlightTransfer.jobId == jobId {
            inFlightTransfer.result.cancel()
        }
        return true
    }

    /// Cancels every queued job and requests cancellation of the active job.
    /// Returns the number of jobs the request affected.
    @discardableResult
    public func cancelAll() -> Int {
        var affected = 0
        let queued = pendingJobIds
        pendingJobIds.removeAll()
        for id in queued {
            update(id, state: .cancelled)
            affected += 1
        }
        if let activeJobId, cancel(jobId: activeJobId) {
            affected += 1
        }
        return affected
    }

    private func publishCancelRequested(_ id: UUID) {
        guard let previous = jobsById[id], !previous.cancelRequested else { return }
        let updated = TransferJobSnapshot(
            id: previous.id,
            request: previous.request,
            state: previous.state,
            startedAt: previous.startedAt,
            endedAt: previous.endedAt,
            lastProgress: previous.lastProgress,
            cancelRequested: true,
            fileFailures: previous.fileFailures
        )
        jobsById[id] = updated
        // Bypass the progress throttle so the UI reflects the stop request now.
        publish(updated)
    }

    private func throwIfCancelRequested(_ id: UUID) throws {
        if activeCancelRequests.contains(id) {
            throw TransferCancellationRequested()
        }
    }

    /// Registers `operation` as the job's in-flight native transfer so
    /// ``cancel(jobId:)`` can abort it. A stop that arrived while the provider
    /// was still starting the transfer is applied straight away.
    private func adoptInFlightTransfer(_ operation: TransferOperation, for id: UUID) {
        inFlightTransfer = (id, operation.result)
        if activeCancelRequests.contains(id) {
            operation.result.cancel()
        }
    }

    /// Waits for the in-flight transfer's result. An abort the user asked for
    /// surfaces as ``TransferCancellationRequested``; any other failure is
    /// rethrown unchanged.
    private func awaitInFlightTransfer(
        _ operation: TransferOperation,
        for id: UUID
    ) async throws -> Bool {
        defer { inFlightTransfer = nil }
        do {
            return try await operation.result.value
        } catch is CancellationError where activeCancelRequests.contains(id) {
            throw TransferCancellationRequested()
        }
    }

    /// Invalidates the provider session without abandoning active native I/O.
    /// Queued jobs are terminalized immediately, new work is rejected, and this
    /// method returns only after the active operation has drained.
    public func invalidateSession(
        message: String = "The device session is no longer available."
    ) async {
        if terminalDeviceLossMessage == nil {
            abortPendingJobs(message: message)
        }
        let task = processingTask
        if activeJobId != nil {
            await task?.value
        }
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil, !pendingJobIds.isEmpty else { return }
        processingTask = Task { [weak self] in
            await self?.processPendingJobs()
        }
    }

    private func processPendingJobs() async {
        while !pendingJobIds.isEmpty, terminalDeviceLossMessage == nil {
            let id = pendingJobIds.removeFirst()
            guard let job = jobsById[id], job.state == .queued else { continue }

            activeJobId = id
            update(id, state: .preprocessing)
            do {
                try ensureSessionIsValid()
                let request = try await prepareDeviceUploadIfNeeded(job.request)
                try ensureSessionIsValid()
                if request != job.request {
                    replaceRequest(id, with: request)
                }
                let outcome = try await runTransfer(id: id, request: request)
                // Every file was attempted. A cancel requested along the way
                // only changes the outcome when post-transfer work remains
                // (staging moves or replacement finalization); with nothing
                // left to skip, the job is reported as completed.
                if activeCancelRequests.contains(id), Self.hasPostTransferWork(request) {
                    throw TransferCancellationRequested()
                }
                if let completionAction = request.completionAction {
                    try TransferStaging.finish(completionAction)
                }
                try await finishDeviceUploadIfNeeded(request)
                if outcome.failures.isEmpty || outcome.transferredCount > 0 {
                    // At least one file made it (or there was nothing to do):
                    // the job settles as completed, carrying any per-file
                    // failures so callers can surface and retry them.
                    update(id, state: .completed, fileFailures: outcome.failures)
                } else {
                    update(
                        id,
                        state: .failed(
                            errorType: .unknown,
                            message: Self.allFilesFailedMessage(outcome.failures)
                        ),
                        fileFailures: outcome.failures
                    )
                }
            } catch is TransferCancellationRequested {
                update(id, state: .cancelled)
            } catch {
                let failure = Self.classify(error)
                update(id, state: .failed(errorType: failure.type, message: failure.message))
                if failure.type == .deviceLost {
                    abortPendingJobs(message: failure.message)
                }
            }
            activeCancelRequests.remove(id)
            activeJobId = nil
        }

        activeJobId = nil
        processingTask = nil
        if terminalDeviceLossMessage == nil, !pendingJobIds.isEmpty {
            startProcessingIfNeeded()
        }
    }

    /// Runs one job, checking the cancellation flag before every native call
    /// (a stop also aborts the call in flight). A job that is a single non-directory source keeps the
    /// provider's raw progress stream. Every other job — multiple sources, or a
    /// directory source — is expanded into per-file native transfers so cancel
    /// lands at file boundaries within a folder tree, and reports cumulative
    /// job-level progress from ``TransferJobProgressAggregator``.
    private func runTransfer(
        id: UUID,
        request: TransferRequest
    ) async throws -> TransferFileOutcomes {
        let sources = request.sources
        guard !sources.isEmpty else { return TransferFileOutcomes() }

        let directorySources = expandableDirectorySources(in: request)
        if sources.count == 1, !directorySources.contains(sources[0]) {
            try throwIfCancelRequested(id)
            try await runSingleSourceTransfer(id: id, request: request)
            return TransferFileOutcomes(failures: [], transferredCount: 1)
        }

        let plan = try await buildTransferPlan(
            id: id,
            request: request,
            directorySources: directorySources
        )
        return try await runExpandedTransfer(id: id, request: request, plan: plan)
    }

    /// The single-source fast path: forwards the provider's raw progress stream
    /// unaltered, preserving the byte-accurate percentage the provider reports for
    /// an atomic file (or empty-directory) copy.
    private func runSingleSourceTransfer(id: UUID, request: TransferRequest) async throws {
        let operation = try await startTransfer(request)
        adoptInFlightTransfer(operation, for: id)
        for await event in operation.progress {
            switch event {
            case .preprocess:
                update(id, state: .preprocessing)
            case let .progress(progress):
                update(
                    id,
                    state: .transferring(
                        TransferProgressSnapshot(
                            progress: progress,
                            currentFileNameOverride: request.displayNameOverride
                        )
                    )
                )
            }
        }
        guard try await awaitInFlightTransfer(operation, for: id) else {
            throw TransferResultError.unsuccessful
        }
    }

    /// Creates the expanded job's directories (top-down so parents exist first),
    /// then transfers its files one native call at a time. A stop request aborts
    /// the file in flight, leaves the files already copied in place and skips
    /// the rest.
    ///
    /// A file that fails is recorded and skipped so one bad file cannot sink a
    /// large folder copy, with two deliberate exceptions that keep failing the
    /// whole job: device-lost errors (every later file would fail against a
    /// dead session anyway) and jobs with post-transfer work (a staged move or
    /// replacement swap must never run against a partial result).
    private func runExpandedTransfer(
        id: UUID,
        request: TransferRequest,
        plan: TransferPlan
    ) async throws -> TransferFileOutcomes {
        for directory in plan.directories {
            try throwIfCancelRequested(id)
            switch directory {
            case let .device(path):
                try ensureSessionIsValid()
                guard try await provider.makeDirectory(
                    input: MakeDirectoryInput(storageId: request.storageId, fullPath: path)
                ) else {
                    throw DirectoryCreationError(path: path)
                }
            case let .local(url):
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            }
        }

        guard !plan.files.isEmpty else { return TransferFileOutcomes() }
        let isMultiFilePlan = plan.files.count > 1
        // Jobs with post-transfer work stay all-or-nothing: skipping a failed
        // file and then moving a staged item or swapping a replacement would
        // publish a partial result as if it were complete.
        let skipsFailedFiles = !Self.hasPostTransferWork(request)
        var outcomes = TransferFileOutcomes()
        var aggregator = TransferJobProgressAggregator(
            plannedBytes: plan.files.map(\.plannedBytes)
        )
        for (index, item) in plan.files.enumerated() {
            try throwIfCancelRequested(id)
            let currentFileName = request.displayNameOverride
                ?? URL(fileURLWithPath: item.source).lastPathComponent
            aggregator.beginItem(at: index, currentFileName: currentFileName)
            update(
                id,
                state: .transferring(
                    aggregator.snapshot(currentFileNameOverride: currentFileName)
                )
            )
            do {
                let operation = try await startFileTransfer(
                    direction: request.direction,
                    source: item.source,
                    destinationDirectory: item.destinationDirectory,
                    storageId: request.storageId,
                    preprocessFiles: request.preprocessFiles,
                    sourceObjectId: item.sourceObjectId
                )
                adoptInFlightTransfer(operation, for: id)
                for await event in operation.progress {
                    switch event {
                    case .preprocess:
                        if isMultiFilePlan {
                            update(
                                id,
                                state: .transferring(
                                    aggregator.snapshot(
                                        currentFileNameOverride: currentFileName
                                    )
                                )
                            )
                        } else {
                            update(id, state: .preprocessing)
                        }
                    case let .progress(progress):
                        aggregator.advance(with: progress)
                        update(
                            id,
                            state: .transferring(
                                aggregator.snapshot(
                                    currentFileNameOverride: currentFileName
                                )
                            )
                        )
                    }
                }
                guard try await awaitInFlightTransfer(operation, for: id) else {
                    throw TransferResultError.unsuccessful
                }
                outcomes.transferredCount += 1
            } catch is TransferCancellationRequested {
                // A stop aborted this file: it is neither copied nor failed.
                throw TransferCancellationRequested()
            } catch {
                let failure = Self.classify(error)
                // A lost device is not a per-file condition; rethrow so the
                // job fails and the queue aborts as before.
                guard skipsFailedFiles, failure.type != .deviceLost else { throw error }
                outcomes.failures.append(
                    TransferFileFailure(
                        source: item.source,
                        destinationDirectory: item.destinationDirectory,
                        message: failure.message
                    )
                )
            }
            // Both success and skip settle the item: its planned bytes move to
            // the completed side so the job-level bar stays monotone instead
            // of stalling on the failed file.
            aggregator.finishCurrentItem()
            update(
                id,
                state: .transferring(
                    aggregator.snapshot(currentFileNameOverride: currentFileName)
                )
            )
        }
        return outcomes
    }

    /// The sources the queue expands into per-file work items. Uploads detect
    /// directories locally with `FileManager`; downloads trust the caller-supplied
    /// ``TransferRequest/directorySources`` to avoid a device round-trip for the
    /// common loose-file case.
    private func expandableDirectorySources(in request: TransferRequest) -> Set<String> {
        switch request.direction {
        case .upload:
            Set(request.sources.filter(Self.isLocalDirectory))
        case .download:
            request.directorySources.intersection(request.sources)
        }
    }

    /// Enumerates every directory source into the directories to create and the
    /// files to transfer, with per-file planned byte totals for progress. Runs
    /// while the job is preprocessing; download expansion walks the device tree
    /// and honours the cancellation flag between walks.
    private func buildTransferPlan(
        id: UUID,
        request: TransferRequest,
        directorySources: Set<String>
    ) async throws -> TransferPlan {
        update(id, state: .preprocessing)
        var directories: [DirectoryCreation] = []
        var files: [FileWorkItem] = []
        for source in request.sources {
            try throwIfCancelRequested(id)
            guard directorySources.contains(source) else {
                files.append(
                    FileWorkItem(
                        source: source,
                        destinationDirectory: request.destination,
                        // Local sizes are known up front; device sizes for a
                        // loose file are only discovered as the provider runs.
                        plannedBytes: request.direction == .upload
                            ? Self.localFileSize(source)
                            : nil,
                        sourceObjectId: request.sourceObjectIds[source]
                    )
                )
                continue
            }
            switch request.direction {
            case .upload:
                Self.expandLocalDirectory(
                    source: source,
                    destination: request.destination,
                    into: &directories,
                    files: &files
                )
            case .download:
                try await expandDeviceDirectory(
                    id: id,
                    source: source,
                    request: request,
                    into: &directories,
                    files: &files
                )
            }
        }
        // Create shallow directories before deep ones so every parent exists
        // before its children.
        directories.sort { $0.depth < $1.depth }
        return TransferPlan(directories: directories, files: files)
    }

    /// Walks a device directory recursively (``walk`` is single-level), recording
    /// each subdirectory to recreate locally and each file to download into its
    /// corresponding local subdirectory.
    private func expandDeviceDirectory(
        id: UUID,
        source: String,
        request: TransferRequest,
        into directories: inout [DirectoryCreation],
        files: inout [FileWorkItem]
    ) async throws {
        let sourceURL = URL(fileURLWithPath: source)
        let parentComponents = sourceURL.deletingLastPathComponent()
            .standardizedFileURL.pathComponents
        let destination = URL(fileURLWithPath: request.destination)
        directories.append(
            .local(url: Self.appending(
                components: Self.relativeComponents(of: sourceURL, after: parentComponents),
                to: destination
            ))
        )
        try await walkDeviceTree(
            id: id,
            directoryPath: source,
            objectId: request.sourceObjectIds[source],
            storageId: request.storageId,
            parentComponents: parentComponents,
            destination: destination,
            into: &directories,
            files: &files
        )
    }

    private func walkDeviceTree(
        id: UUID,
        directoryPath: String,
        objectId: UInt32?,
        storageId: UInt32,
        parentComponents: [String],
        destination: URL,
        into directories: inout [DirectoryCreation],
        files: inout [FileWorkItem]
    ) async throws {
        try throwIfCancelRequested(id)
        try ensureSessionIsValid()
        let entries = try await provider.walk(
            input: DirectoryWalkInput(
                storageId: storageId,
                fullPath: directoryPath,
                objectId: objectId,
                skipDisallowedFiles: true,
                skipHiddenFiles: false
            )
        )
        for entry in entries {
            let entryURL = URL(fileURLWithPath: entry.path)
            let components = Self.relativeComponents(of: entryURL, after: parentComponents)
            if entry.isFolder {
                directories.append(
                    .local(url: Self.appending(components: components, to: destination))
                )
                try await walkDeviceTree(
                    id: id,
                    directoryPath: entry.path,
                    objectId: entry.objectId,
                    storageId: storageId,
                    parentComponents: parentComponents,
                    destination: destination,
                    into: &directories,
                    files: &files
                )
            } else {
                files.append(
                    FileWorkItem(
                        source: entry.path,
                        destinationDirectory: Self.appending(
                            components: components.dropLast(),
                            to: destination
                        ).path,
                        plannedBytes: entry.size,
                        sourceObjectId: entry.objectId
                    )
                )
            }
        }
    }

    /// Enumerates a local directory tree into the device directories to create
    /// and the files to upload, preserving empty directories.
    private static func expandLocalDirectory(
        source: String,
        destination: String,
        into directories: inout [DirectoryCreation],
        files: inout [FileWorkItem]
    ) {
        let sourceURL = URL(fileURLWithPath: source)
        let parentComponents = sourceURL.deletingLastPathComponent()
            .standardizedFileURL.pathComponents
        directories.append(
            .device(path: Self.devicePath(
                directory: destination,
                relativeComponents: Self.relativeComponents(of: sourceURL, after: parentComponents)
            ))
        )
        guard let enumerator = FileManager.default.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        ) else { return }
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
            ) else { continue }
            let components = Self.relativeComponents(of: itemURL, after: parentComponents)
            if values.isDirectory == true {
                directories.append(
                    .device(path: Self.devicePath(
                        directory: destination,
                        relativeComponents: components
                    ))
                )
            } else if values.isRegularFile == true {
                files.append(
                    FileWorkItem(
                        source: itemURL.path,
                        destinationDirectory: Self.devicePath(
                            directory: destination,
                            relativeComponents: Array(components.dropLast())
                        ),
                        plannedBytes: Int64(values.fileSize ?? 0),
                        sourceObjectId: nil
                    )
                )
            }
        }
    }

    private func startTransfer(_ request: TransferRequest) async throws -> TransferOperation {
        try await startFileTransfer(
            direction: request.direction,
            source: request.sources[0],
            destinationDirectory: request.destination,
            storageId: request.storageId,
            preprocessFiles: request.preprocessFiles,
            sources: request.sources,
            sourceObjectIds: request.sourceObjectIds
        )
    }

    /// Starts one native transfer. Expanded jobs pass a single file; the raw
    /// single-source fast path passes the request's whole `sources` array
    /// (still exactly one element) unchanged.
    private func startFileTransfer(
        direction: TransferDirection,
        source: String,
        destinationDirectory: String,
        storageId: UInt32,
        preprocessFiles: Bool,
        sources: [String]? = nil,
        sourceObjectId: UInt32? = nil,
        sourceObjectIds: [String: UInt32] = [:]
    ) async throws -> TransferOperation {
        try ensureSessionIsValid()
        let sources = sources ?? [source]
        var resolvedObjectIds = sourceObjectIds
        if let sourceObjectId {
            resolvedObjectIds[source] = sourceObjectId
        }
        return switch direction {
        case .download:
            try await provider.downloadFiles(
                input: DownloadFilesInput(
                    storageId: storageId,
                    sources: sources,
                    sourceProps: sources.compactMap { path in
                        resolvedObjectIds[path].map { SourceProp(fullPath: path, objectId: $0) }
                    },
                    destination: destinationDirectory,
                    preprocessFiles: preprocessFiles
                )
            )
        case .upload:
            try await provider.uploadFiles(
                input: UploadFilesInput(
                    storageId: storageId,
                    sources: sources,
                    destination: destinationDirectory,
                    preprocessFiles: preprocessFiles
                )
            )
        }
    }

    private func prepareDeviceUploadIfNeeded(
        _ request: TransferRequest
    ) async throws -> TransferRequest {
        guard request.direction == .upload,
              let preparation = request.deviceUploadPreparation,
              let sourcePath = request.sources.first,
              request.sources.count == 1 else { return request }

        let currentName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let currentDevicePath = Self.devicePath(
            directory: request.destination,
            name: currentName
        )
        guard try await deviceItemExists(currentDevicePath, storageID: request.storageId) else {
            return request
        }

        let replacementName: String
        switch preparation {
        case let .keepBoth(originalName):
            replacementName = try await availableKeepBothName(
                for: originalName,
                destination: request.destination,
                storageID: request.storageId
            )
        case let .replacement(finalPath):
            replacementName = try await availableTemporaryName(
                finalName: URL(fileURLWithPath: finalPath).lastPathComponent,
                destination: request.destination,
                storageID: request.storageId
            )
        }

        let replacementSource = URL(fileURLWithPath: sourcePath)
            .deletingLastPathComponent()
            .appending(path: replacementName)
        try FileManager.default.moveItem(
            at: URL(fileURLWithPath: sourcePath),
            to: replacementSource
        )
        let replacementDevicePath = Self.devicePath(
            directory: request.destination,
            name: replacementName
        )
        moveReservation(from: currentDevicePath, to: replacementDevicePath)
        var reservations = request.reservedDevicePaths
        reservations.remove(currentDevicePath)
        reservations.insert(replacementDevicePath)
        return request.replacingUploadSource(
            replacementSource.path,
            reservedDevicePaths: reservations
        )
    }

    private func finishDeviceUploadIfNeeded(_ request: TransferRequest) async throws {
        guard case let .replacement(finalPath) = request.deviceUploadPreparation,
              let sourcePath = request.sources.first else { return }
        let temporaryPath = Self.devicePath(
            directory: request.destination,
            name: URL(fileURLWithPath: sourcePath).lastPathComponent
        )

        do {
            if try await deviceItemExists(finalPath, storageID: request.storageId) {
                try ensureSessionIsValid()
                let deleted = try await provider.deleteFiles(
                    input: DeleteFileInput(storageId: request.storageId, files: [finalPath])
                )
                guard deleted else {
                    throw DeviceReplacementError(
                        failureType: .unknown,
                        message: "Uploaded the replacement as \(temporaryPath), but the device did not delete \(finalPath). The original and temporary copy were kept."
                    )
                }
            }
        } catch let error as DeviceReplacementError {
            throw error
        } catch {
            let failure = Self.classify(error)
            throw DeviceReplacementError(
                failureType: failure.type,
                message: "Uploaded the replacement as \(temporaryPath), but could not delete \(finalPath). The temporary copy was kept on the device. \(failure.message)"
            )
        }

        do {
            try ensureSessionIsValid()
            let renamed = try await provider.renameFile(
                input: RenameFileInput(
                    storageId: request.storageId,
                    fullPath: temporaryPath,
                    newFileName: URL(fileURLWithPath: finalPath).lastPathComponent
                )
            )
            guard renamed else {
                throw DeviceReplacementError(
                    failureType: .unknown,
                    message: "Deleted \(finalPath), but the device did not rename \(temporaryPath). The uploaded temporary copy was kept on the device."
                )
            }
        } catch let error as DeviceReplacementError {
            throw error
        } catch {
            let failure = Self.classify(error)
            throw DeviceReplacementError(
                failureType: failure.type,
                message: "Deleted \(finalPath), but could not rename \(temporaryPath) to its final name. The uploaded temporary copy was kept on the device. \(failure.message)"
            )
        }
    }

    private func availableKeepBothName(
        for originalName: String,
        destination: String,
        storageID: UInt32
    ) async throws -> String {
        let parts = Self.nameParts(of: originalName)
        var suffix = 2
        while true {
            let candidate = "\(parts.stem) (\(suffix))\(parts.extensionSuffix)"
            let path = Self.devicePath(directory: destination, name: candidate)
            if try await !deviceItemExists(path, storageID: storageID),
               devicePathReservationCounts[path, default: 0] == 0 {
                return candidate
            }
            suffix += 1
        }
    }

    private func availableTemporaryName(
        finalName: String,
        destination: String,
        storageID: UInt32
    ) async throws -> String {
        let pathExtension = URL(fileURLWithPath: finalName).pathExtension
        while true {
            let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
            let candidate = "\(AppIdentity.fileNamePrefix)-\(UUID().uuidString)\(suffix)"
            let path = Self.devicePath(directory: destination, name: candidate)
            if try await !deviceItemExists(path, storageID: storageID),
               devicePathReservationCounts[path, default: 0] == 0 {
                return candidate
            }
        }
    }

    private func deviceItemExists(_ path: String, storageID: UInt32) async throws -> Bool {
        try ensureSessionIsValid()
        let results = try await provider.fileExists(
            input: FileExistsInput(storageId: storageID, files: [path])
        )
        return results.contains(where: \.exists)
    }

    private func ensureSessionIsValid() throws {
        if let terminalDeviceLossMessage {
            throw TransferSessionInvalidatedError(message: terminalDeviceLossMessage)
        }
    }

    /// The whole-job failure message for an expanded job in which every single
    /// file failed; the per-file details ride along in the snapshot's
    /// `fileFailures`.
    private static func allFilesFailedMessage(_ failures: [TransferFileFailure]) -> String {
        guard let first = failures.first else {
            return "The transfer failed."
        }
        guard failures.count > 1 else { return first.message }
        return "All \(failures.count) files failed to transfer. First failure: \(first.message)"
    }

    /// Post-transfer work that a cancellation can still meaningfully skip.
    private static func hasPostTransferWork(_ request: TransferRequest) -> Bool {
        if request.completionAction != nil { return true }
        if case .replacement = request.deviceUploadPreparation { return true }
        return false
    }

    private func moveReservation(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        releaseDevicePath(oldPath)
        devicePathReservationCounts[newPath, default: 0] += 1
    }

    private func releaseDevicePath(_ path: String) {
        guard let count = devicePathReservationCounts[path] else { return }
        if count <= 1 {
            devicePathReservationCounts.removeValue(forKey: path)
        } else {
            devicePathReservationCounts[path] = count - 1
        }
    }

    private static func devicePath(directory: String, name: String) -> String {
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/\(name)" : "/\(trimmed)/\(name)"
    }

    /// Joins a device directory with a relative path expressed as components,
    /// e.g. `["foo", "bar"]` under `/DCIM` becomes `/DCIM/foo/bar`.
    private static func devicePath(
        directory: String,
        relativeComponents components: some Sequence<String>
    ) -> String {
        Self.devicePath(directory: directory, name: components.joined(separator: "/"))
    }

    /// The path components of `url` beneath a base directory identified by its
    /// own components, so `/a/b/foo/bar` under base `/a/b` yields `["foo", "bar"]`.
    private static func relativeComponents(
        of url: URL,
        after baseComponents: [String]
    ) -> [String] {
        Array(url.standardizedFileURL.pathComponents.dropFirst(baseComponents.count))
    }

    private static func appending(
        components: some Sequence<String>,
        to base: URL
    ) -> URL {
        var url = base
        for component in components {
            url.append(path: component)
        }
        return url
    }

    private static func isLocalDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func localFileSize(_ path: String) -> Int64 {
        let size = (try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }

    private static func nameParts(of name: String) -> (stem: String, extensionSuffix: String) {
        let pathExtension = URL(fileURLWithPath: name).pathExtension
        guard !pathExtension.isEmpty, !name.hasPrefix(".") else { return (name, "") }
        let extensionSuffix = ".\(pathExtension)"
        return (String(name.dropLast(extensionSuffix.count)), extensionSuffix)
    }

    private func abortPendingJobs(message: String) {
        terminalDeviceLossMessage = message
        let abortedIds = pendingJobIds
        pendingJobIds.removeAll()
        for id in abortedIds {
            update(id, state: .failed(errorType: .deviceLost, message: message))
        }
    }

    private func update(
        _ id: UUID,
        state: TransferJobState,
        fileFailures: [TransferFileFailure]? = nil
    ) {
        guard let previous = jobsById[id] else { return }
        let now = Date.now
        let startedAt: Date?
        switch (previous.state, state) {
        case (.queued, .preprocessing), (.queued, .transferring):
            startedAt = now
        default:
            startedAt = previous.startedAt
        }
        let endedAt = state.isTerminal ? previous.endedAt ?? now : previous.endedAt
        let lastProgress: TransferProgressSnapshot?
        if case let .transferring(progress) = state {
            lastProgress = progress
        } else {
            lastProgress = previous.lastProgress
        }
        let updated = TransferJobSnapshot(
            id: id,
            request: previous.request,
            state: state,
            startedAt: startedAt,
            endedAt: endedAt,
            lastProgress: lastProgress,
            cancelRequested: previous.cancelRequested,
            fileFailures: fileFailures ?? previous.fileFailures
        )
        jobsById[id] = updated
        if case .transferring = state {
            publishProgress(updated)
        } else {
            cancelPendingProgressPublication(for: id)
            publish(updated)
        }
        if state.isTerminal {
            releaseDevicePaths(Array(updated.request.reservedDevicePaths))
            if let cleanupDirectory = updated.request.cleanupDirectory {
                removeStagingDirectory(at: cleanupDirectory)
            }
        }
    }

    private func removeStagingDirectory(at path: String) {
        do {
            try TransferStaging.removeDirectory(at: path)
        } catch {
            let errorDescription = String(describing: error)
            Self.logger.error(
                "Staging cleanup failed at \(path, privacy: .public): \(errorDescription, privacy: .public). Retrying once."
            )
            do {
                try TransferStaging.removeDirectory(at: path)
            } catch {
                let retryErrorDescription = String(describing: error)
                Self.logger.error(
                    "Staging cleanup retry failed at \(path, privacy: .public): \(retryErrorDescription, privacy: .public)"
                )
            }
        }
    }

    private func replaceRequest(_ id: UUID, with request: TransferRequest) {
        guard let previous = jobsById[id] else { return }
        let updated = TransferJobSnapshot(
            id: previous.id,
            request: request,
            state: previous.state,
            startedAt: previous.startedAt,
            endedAt: previous.endedAt,
            lastProgress: previous.lastProgress,
            cancelRequested: previous.cancelRequested,
            fileFailures: previous.fileFailures
        )
        jobsById[id] = updated
        publish(updated)
    }

    private func publish(_ job: TransferJobSnapshot) {
        eventContinuation.yield(.jobUpdated(job))
    }

    private func publishProgress(_ job: TransferJobSnapshot) {
        let now = progressClock.now
        guard let lastPublication = lastProgressPublicationInstant[job.id] else {
            lastProgressPublicationInstant[job.id] = now
            publish(job)
            return
        }

        let elapsed = lastPublication.duration(to: now)
        guard elapsed < progressPublicationInterval else {
            pendingProgressPublicationTasks.removeValue(forKey: job.id)?.cancel()
            lastProgressPublicationInstant[job.id] = now
            publish(job)
            return
        }
        guard pendingProgressPublicationTasks[job.id] == nil else { return }

        let delay = progressPublicationInterval - elapsed
        pendingProgressPublicationTasks[job.id] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.publishPendingProgress(for: job.id)
        }
    }

    private func publishPendingProgress(for id: UUID) {
        pendingProgressPublicationTasks[id] = nil
        guard let job = jobsById[id], case .transferring = job.state else { return }
        lastProgressPublicationInstant[id] = progressClock.now
        publish(job)
    }

    private func cancelPendingProgressPublication(for id: UUID) {
        pendingProgressPublicationTasks.removeValue(forKey: id)?.cancel()
        lastProgressPublicationInstant.removeValue(forKey: id)
    }

    private static func classify(
        _ error: any Error
    ) -> (type: TransferQueueFailureType, message: String) {
        if ConnectionFatalClassifier.disposition(for: error) != nil {
            return (.deviceLost, ErrorDescription.message(for: error))
        }
        if let callError = error as? MTPCallError {
            return (.device(callError.type), callError.description)
        }
        if let resultError = error as? TransferResultError {
            return (.unknown, resultError.description)
        }
        if let replacementError = error as? DeviceReplacementError {
            return (replacementError.failureType, replacementError.message)
        }
        if let invalidatedError = error as? TransferSessionInvalidatedError {
            return (.deviceLost, invalidatedError.message)
        }
        return (.unknown, String(describing: error))
    }
}

private struct TransferSessionInvalidatedError: Error, Sendable {
    let message: String
}

private struct TransferCancellationRequested: Error, Sendable {}

/// What one job's file-level work amounted to: how many files actually
/// transferred, and which ones were recorded as failed and skipped.
private struct TransferFileOutcomes: Sendable {
    var failures: [TransferFileFailure] = []
    var transferredCount = 0
}

/// One file-level native transfer within an expanded job.
private struct FileWorkItem: Sendable {
    let source: String
    let destinationDirectory: String
    /// Bytes known up front, or `nil` when the size is only discovered as the
    /// provider runs (a loose device file whose size lives on the device).
    let plannedBytes: Int64?
    let sourceObjectId: UInt32?
}

/// A directory to create before an expanded job's files: on the device for
/// uploads, on the local disk for downloads.
private enum DirectoryCreation: Sendable {
    case device(path: String)
    case local(url: URL)

    /// Number of path components, so shallower directories sort ahead of deeper
    /// ones and every parent is created before its children.
    var depth: Int {
        switch self {
        case let .device(path):
            path.split(separator: "/").count
        case let .local(url):
            url.standardizedFileURL.pathComponents.count
        }
    }
}

/// The directories to create and the files to transfer for one expanded job.
private struct TransferPlan: Sendable {
    var directories: [DirectoryCreation]
    var files: [FileWorkItem]
}

/// Cumulative, job-level progress across the sequential per-file native
/// transfers of one expanded job.
///
/// Every work item is a single file, so file counts are known once the plan is
/// built. Byte totals are known up front for uploads and for files enumerated
/// from a device directory walk; a loose device file's size stays `nil` until
/// the provider reports it, so download byte totals can grow as the job advances.
///
/// The percentage is file-based (`filesSent / totalFiles`), mirroring the
/// provider's own `filesSentProgress` semantics that single-source jobs report,
/// and stays monotone because `filesSent` only rises as items complete.
private struct TransferJobProgressAggregator {
    private let plannedBytes: [Int64?]
    private let pendingBytesByIndex: [Int64]
    private var activeIndex = 0
    private var hasActiveItem = false
    private var completedBytes: Int64 = 0
    private var completedFiles: Int64 = 0
    private var activeTotalBytes: Int64 = 0
    private var activeSentBytes: Int64 = 0
    private var activeTotalFiles: Int64 = 0
    private var activeFilesSent: Int64 = 0
    private var speed: Double = 0
    private var currentFileName = ""

    init(plannedBytes: [Int64?]) {
        self.plannedBytes = plannedBytes

        var pendingBytesByIndex = Array(repeating: Int64(0), count: plannedBytes.count)
        var suffixSum: Int64 = 0
        for index in plannedBytes.indices.reversed() {
            pendingBytesByIndex[index] = suffixSum
            suffixSum += plannedBytes[index] ?? 0
        }
        self.pendingBytesByIndex = pendingBytesByIndex
    }

    mutating func beginItem(at index: Int, currentFileName: String) {
        activeIndex = index
        hasActiveItem = true
        activeTotalBytes = 0
        activeSentBytes = 0
        activeTotalFiles = 0
        activeFilesSent = 0
        speed = 0
        self.currentFileName = currentFileName
    }

    mutating func advance(with progress: TransferProgressInfo) {
        activeTotalBytes = progress.bulkFileSize.total
        activeSentBytes = progress.bulkFileSize.sent
        activeTotalFiles = progress.totalFiles
        activeFilesSent = progress.filesSent
        speed = progress.speed
        currentFileName = progress.name.isEmpty
            ? URL(fileURLWithPath: progress.fullPath).lastPathComponent
            : progress.name
    }

    mutating func finishCurrentItem() {
        let knownPlannedBytes = plannedBytes[activeIndex] ?? 0
        completedBytes += activeTotalBytes > 0 ? activeTotalBytes : knownPlannedBytes
        completedFiles += max(activeTotalFiles, 1)
        hasActiveItem = false
        activeTotalBytes = 0
        activeSentBytes = 0
        activeTotalFiles = 0
        activeFilesSent = 0
        speed = 0
    }

    func snapshot(currentFileNameOverride: String?) -> TransferProgressSnapshot {
        let plannedActiveFiles: Int64 = hasActiveItem ? max(activeTotalFiles, 1) : 0
        let plannedActiveBytes = hasActiveItem && activeTotalBytes == 0
            ? plannedBytes[activeIndex] ?? 0
            : activeTotalBytes
        let totalFiles = completedFiles + plannedActiveFiles + pendingFiles
        let filesSent = completedFiles + activeFilesSent
        let percent = totalFiles > 0
            ? Double(filesSent) / Double(totalFiles) * 100
            : 0
        // The active file's byte share, until the provider counts it as sent.
        let currentFileFraction = hasActiveItem && activeTotalBytes > 0 && activeFilesSent == 0
            ? Double(activeSentBytes) / Double(activeTotalBytes)
            : nil
        return TransferProgressSnapshot(
            percent: percent,
            speed: speed,
            currentFileName: currentFileNameOverride ?? currentFileName,
            filesSent: filesSent,
            totalFiles: totalFiles,
            totalBytes: completedBytes + plannedActiveBytes + pendingBytes,
            sentBytes: completedBytes + activeSentBytes,
            currentFileFraction: currentFileFraction
        )
    }

    private var pendingIndices: Range<Int> {
        min(activeIndex + 1, plannedBytes.count) ..< plannedBytes.count
    }

    private var pendingBytes: Int64 {
        guard pendingBytesByIndex.indices.contains(activeIndex) else { return 0 }
        return pendingBytesByIndex[activeIndex]
    }

    private var pendingFiles: Int64 {
        Int64(pendingIndices.count)
    }
}

private struct DeviceReplacementError: Error, Sendable {
    let failureType: TransferQueueFailureType
    let message: String
}

private enum TransferResultError: Error, CustomStringConvertible {
    case unsuccessful

    var description: String {
        "The transfer provider reported an unsuccessful result"
    }
}

private struct DirectoryCreationError: Error, CustomStringConvertible {
    let path: String

    var description: String {
        "The device did not create the directory \(path)"
    }
}

extension TransferJobState {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .preprocessing, .transferring:
            false
        }
    }
}
