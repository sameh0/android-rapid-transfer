import Foundation
import Observation

@MainActor
@Observable
public final class TransferViewModel {
    public private(set) var rows: [TransferPanelRow] = []
    public private(set) var isPanelVisible = false
    public private(set) var isTransferSessionAvailable = false
    public private(set) var transferSessionID: UUID?
    public let copyQueue: CopyQueue
    public private(set) var isDeviceNavigationDisabled = false
    public var isPanelExpanded = false
    public var conflictPrompt: FileConflictPrompt?
    /// How the most recent activity session ended — every batch that ran
    /// together until the panel went idle. Set the moment the last job
    /// settles, cleared when new work starts; drives the panel's completion
    /// summary and the Dock's "finished" signal.
    public private(set) var lastSessionSummary: TransferSessionSummary?
    /// Called once each time an activity session settles, with its summary,
    /// whether or not a window is open: the Dock and notifications hang off it.
    @ObservationIgnored public var onSessionFinished: (@MainActor (TransferSessionSummary) -> Void)?
    public var operationErrorMessage: String?
    public var isShowingOperationError = false

    @ObservationIgnored private let localModel: any BrowserPaneModel
    @ObservationIgnored private let localCopyService: LocalFileCopyService
    @ObservationIgnored private let stagingService: any TransferStagingService
    /// Reads the current conflict policy at decision time so a settings change
    /// takes effect on the next conflict without re-wiring the view model.
    @ObservationIgnored private let fileConflictPolicy: @MainActor () -> FileConflictPolicy
    /// Reads the per-direction preprocessing setting at enqueue time.
    @ObservationIgnored private let preprocessesFiles: @MainActor (TransferDirection) -> Bool
    /// The decision remembered for ``FileConflictPolicy/askEverySession``, reused
    /// across every conflict (and every operation) until the app relaunches.
    @ObservationIgnored private var sessionConflictResolution: FileConflictResolution?
    @ObservationIgnored private var deviceModel: (any DeviceTransferPaneModel)?
    @ObservationIgnored private var queue: TransferQueue?
    @ObservationIgnored private var queuesByJobID: [UUID: TransferQueue] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var localRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var deviceRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var deviceRefreshTaskID: UUID?
    @ObservationIgnored private var localRefreshPending = false
    @ObservationIgnored private var deviceRefreshPending = false
    @ObservationIgnored private var conflictWaiters: [ConflictWaiter] = []
    @ObservationIgnored private var exportWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var activeJobIDs: Set<UUID> = []
    /// Maps every enqueued job to the batch it was enqueued with, so the
    /// panel's overall progress covers the in-flight batch (and its finished
    /// siblings) without being skewed by older, fully settled batches whose
    /// rows are still visible.
    @ObservationIgnored private var batchIDByJobID: [UUID: UUID] = [:]
    /// Batches that belong to the current activity session: any batch that had
    /// in-flight work since the panel was last fully idle. Back-to-back drops
    /// merge into one monotone overall bar; a batch enqueued after everything
    /// settled starts a fresh session instead of inheriting stale totals.
    @ObservationIgnored private var activeSessionBatches: Set<UUID> = []
    /// Persists batch copies for the resume window; `nil` disables recording
    /// (the default for tests and embedded uses that inject no store).
    @ObservationIgnored public let batchStore: TransferBatchStore?
    /// Maps enqueued jobs to the persisted batch record they update on
    /// settlement. Distinct from `batchIDByJobID`, which tracks the in-memory
    /// progress-session grouping and covers jobs no record was written for.
    @ObservationIgnored private var batchRecordIDByJobID: [UUID: UUID] = [:]

    var retainedQueueCount: Int {
        queuesByJobID.count
    }

    public init(
        localModel: any BrowserPaneModel,
        localCopyService: LocalFileCopyService = LocalFileCopyService(),
        stagingService: any TransferStagingService = FileManagerTransferStagingService(),
        copyQueue: CopyQueue = CopyQueue(),
        batchStore: TransferBatchStore? = nil,
        fileConflictPolicy: @escaping @MainActor () -> FileConflictPolicy = { .askEveryFile },
        preprocessesFiles: @escaping @MainActor (TransferDirection) -> Bool = { _ in true }
    ) {
        self.localModel = localModel
        self.localCopyService = localCopyService
        self.stagingService = stagingService
        self.copyQueue = copyQueue
        self.batchStore = batchStore
        self.fileConflictPolicy = fileConflictPolicy
        self.preprocessesFiles = preprocessesFiles
    }

    deinit {
        observationTask?.cancel()
        localRefreshTask?.cancel()
        deviceRefreshTask?.cancel()
    }

    /// Where a download lands when the caller does not name a destination.
    /// Exposed so a confirmation UI can show the target before committing.
    public var defaultDownloadDestination: String {
        localModel.currentLocation
    }

    public var canDownload: Bool {
        isTransferSessionAvailable
            && queue != nil
            && deviceModel?.selectedStorageID != nil
            && deviceModel?.selectedEntryIDs.isEmpty == false
    }

    public var canUpload: Bool {
        isTransferSessionAvailable
            && queue != nil
            && deviceModel?.selectedStorageID != nil
            && deviceModel?.isLoading == false
            && !localModel.selectedEntryIDs.isEmpty
    }

    /// The transfer panel's structure-preserving batch copy, which only applies
    /// to device items.
    public var canExecuteCopyQueue: Bool {
        guard let deviceModel else { return false }
        return !copyQueue.isEmpty
            && copyQueue.source == .device
            && isTransferSessionAvailable
            && queue != nil
            && copyQueue.sessionID == transferSessionID
            && copyQueue.storageID == deviceModel.selectedStorageID
    }

    public func attach(queue: TransferQueue, deviceModel: any DeviceTransferPaneModel) {
        // A reconnect can replace the session so quickly that the view never
        // observes the nil session in between, so detach() would never run:
        // settle the old session's rows and release its busy lock here.
        if let current = self.queue, current !== queue {
            detach()
        }
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
        deviceRefreshTaskID = nil
        deviceRefreshPending = false
        self.queue = queue
        self.deviceModel = deviceModel
        isTransferSessionAvailable = true
        transferSessionID = queue.sessionID
        copyQueue.bind(sessionID: queue.sessionID, storageID: deviceModel.selectedStorageID)
        observationTask?.cancel()

        observationTask = Task { [weak self, events = queue.events] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                if case let .jobUpdated(job) = event {
                    self.queuesByJobID[job.id] = queue
                }
                self.receive(event)
            }
        }
    }

    public func detach() {
        observationTask?.cancel()
        observationTask = nil
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
        deviceRefreshTaskID = nil
        deviceRefreshPending = false
        queue = nil
        deviceModel = nil
        isTransferSessionAvailable = false
        transferSessionID = nil
        copyQueue.bind(sessionID: nil, storageID: nil)
        let message = "The device session is no longer available."
        rows = rows.map { row in
            guard !row.state.isTerminal else { return row }
            return TransferPanelRow(
                job: TransferJobSnapshot(
                    id: row.id,
                    request: row.request,
                    state: .failed(errorType: .deviceLost, message: message),
                    startedAt: row.startedAt,
                    endedAt: .now,
                    lastProgress: row.lastProgress,
                    cancelRequested: row.cancelRequested,
                    fileFailures: row.fileFailures
                )
            )
        }
        activeJobIDs.removeAll()
        isDeviceNavigationDisabled = false
        queuesByJobID.removeAll()
        batchIDByJobID.removeAll()
        activeSessionBatches.removeAll()
        // Jobs the lost session never settled keep their recorded items
        // pending, which is exactly what makes them resumable later.
        batchRecordIDByJobID.removeAll()
        cancelConflictPrompts()
        failExportWaiters(with: TransferExportError.deviceUnavailable)
    }

    /// Aggregate progress of the current activity session: every batch that
    /// overlapped with the in-flight work, including its finished jobs, so a
    /// bulk copy reads as one overall operation. `nil` when nothing is
    /// transferring; batches that settled before the current activity are
    /// excluded even while their rows linger in the panel.
    public var overallProgress: TransferOverallProgress? {
        guard !activeSessionBatches.isEmpty else { return nil }
        let sessionRows = rows.filter { row in
            guard let batchID = batchIDByJobID[row.id] else {
                return !row.state.isTerminal
            }
            return activeSessionBatches.contains(batchID)
        }
        return TransferOverallProgress(rows: sessionRows)
    }

    /// Whether any job is queued or running. Anything that releases the device
    /// session must wait until this is false, or it aborts those copies.
    public var hasActiveTransfers: Bool {
        rows.contains { !$0.state.isTerminal }
    }

    /// Stops everything in flight: queued jobs are cancelled immediately and
    /// the active job aborts the file it is copying (no partial file is left).
    public func stopAll() async {
        var stopped: Set<ObjectIdentifier> = []
        if let queue {
            stopped.insert(ObjectIdentifier(queue))
            await queue.cancelAll()
        }
        for queue in queuesByJobID.values
        where !stopped.contains(ObjectIdentifier(queue)) {
            stopped.insert(ObjectIdentifier(queue))
            await queue.cancelAll()
        }
    }

    public func downloadRequest() -> TransferRequest? {
        guard let deviceModel else { return nil }
        return downloadRequest(
            sources: selectedSources(in: deviceModel),
            destination: localModel.currentLocation,
            storageID: deviceModel.selectedStorageID
        )
    }

    public func downloadRequest(
        sources: [String],
        destination: String? = nil,
        storageID: UInt32? = nil
    ) -> TransferRequest? {
        guard let resolvedStorageID = storageID ?? deviceModel?.selectedStorageID,
              !sources.isEmpty else { return nil }
        return TransferRequest(
            direction: .download,
            sources: sources,
            destination: destination ?? localModel.currentLocation,
            storageId: resolvedStorageID,
            directorySources: directorySources(among: sources),
            sourceObjectIds: sourceObjectIds(among: sources)
        )
    }

    public func uploadRequest() -> TransferRequest? {
        uploadRequest(sources: selectedSources(in: localModel))
    }

    public func uploadRequest(
        sources: [String],
        destination: String? = nil,
        storageID: UInt32? = nil
    ) -> TransferRequest? {
        guard let deviceModel,
              let resolvedStorageID = storageID ?? deviceModel.selectedStorageID,
              !sources.isEmpty else { return nil }
        return TransferRequest(
            direction: .upload,
            sources: sources,
            destination: destination ?? deviceModel.currentLocation,
            storageId: resolvedStorageID
        )
    }

    @discardableResult
    public func enqueueDownload(destination: String? = nil) async -> UUID? {
        guard let deviceModel, let storageID = deviceModel.selectedStorageID else { return nil }
        let resolvedDestination = destination ?? localModel.currentLocation
        let entries = deviceModel.selectedEntries
        // The selection listing knows names, sizes, and directory flags, so a
        // plain "Copy to Computer" records a resumable batch too.
        let record = await saveBatchRecord(
            origin: .directCopy,
            destinationRoot: resolvedDestination,
            storageID: storageID,
            items: entries.map { entry in
                TransferBatchRecord.Item(
                    devicePath: entry.location,
                    displayName: entry.name,
                    size: entry.isDirectory ? nil : entry.size,
                    isDirectory: entry.isDirectory,
                    destinationDirectory: resolvedDestination
                )
            }
        )
        let ids = await enqueueDownloads(
            sources: entries.map(\.location),
            destination: resolvedDestination,
            storageID: storageID,
            sourceObjectIds: Dictionary(
                entries.compactMap { entry in
                    entry.objectId.map { (entry.location, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
        if ids.isEmpty {
            discardBatchRecord(record)
        } else {
            registerBatchRecord(record, forJobIDs: ids)
        }
        return ids.first
    }

    public func bindCopyQueue(storageID: UInt32?) {
        copyQueue.bind(sessionID: transferSessionID, storageID: storageID)
    }

    public func addSelectedDeviceEntriesToCopyQueue(storage: DeviceStorage) {
        copySelectionToQueue(from: .device, storage: storage, replacing: false)
    }

    /// Copy (`replacing`) or Copy to Queue (appending, deduplicated) for the
    /// selection of `pane`, then clears that pane's selection.
    /// Device items need the storage they are listed from.
    @discardableResult
    public func copySelectionToQueue(
        from pane: BrowserPaneKind,
        storage: DeviceStorage? = nil,
        replacing: Bool
    ) -> Bool {
        let sourceModel: any BrowserPaneModel
        let items: [CopyQueueItem]
        switch pane {
        case .local:
            sourceModel = localModel
            items = localModel.selectedEntries.map(CopyQueueItem.init(localEntry:))
        case .device:
            guard let deviceModel,
                  let storage,
                  transferSessionID != nil,
                  deviceModel.selectedStorageID == storage.id else { return false }
            sourceModel = deviceModel
            items = deviceModel.selectedEntries.map { CopyQueueItem(entry: $0, storage: storage) }
            copyQueue.bind(sessionID: transferSessionID, storageID: storage.id)
        }
        guard !items.isEmpty else { return false }

        if replacing {
            copyQueue.replace(with: items)
        } else {
            copyQueue.add(items)
        }
        sourceModel.clearSelection()
        guard !copyQueue.isEmpty else { return false }
        showPanel()
        return true
    }

    /// Paste is available only into the pane opposite the one the queued items
    /// were copied from, and only while that transfer direction could start.
    public func canPaste(into pane: BrowserPaneKind) -> Bool {
        guard let source = copyQueue.source,
              source != pane,
              isTransferSessionAvailable,
              queue != nil,
              let deviceModel,
              let storageID = deviceModel.selectedStorageID else { return false }
        switch source {
        case .device:
            // Mirrors Copy to Computer: device paths are valid only in the
            // session and storage that listed them, and the busy lock applies.
            return !isDeviceNavigationDisabled
                && copyQueue.sessionID == transferSessionID
                && copyQueue.storageID == storageID
        case .local:
            // Mirrors Copy to Phone.
            return !deviceModel.isLoading
        }
    }

    /// Pastes the queue into `pane`'s current folder: each item lands there
    /// under its own name, like Finder's paste. The queue is
    /// emptied once the transfer is enqueued, as the batch copy does.
    @discardableResult
    public func paste(into pane: BrowserPaneKind) async -> Bool {
        guard canPaste(into: pane), let source = copyQueue.source else { return false }
        let items = copyQueue.items
        let ids: [UUID]
        switch source {
        case .local:
            ids = await enqueueUploads(items.map { URL(fileURLWithPath: $0.path) })
        case .device:
            ids = await enqueuePastedDeviceItems(items)
        }
        guard !ids.isEmpty else { return false }
        if copyQueue.items == items {
            copyQueue.removeAll()
        }
        return true
    }

    @discardableResult
    public func executeCopyQueue(destination: URL) async -> Bool {
        guard let transferQueue = queue,
              let sessionID = transferSessionID,
              let storageID = copyQueue.storageID,
              canExecuteCopyQueue else { return false }
        let items = copyQueue.items
        if let message = items.lazy.compactMap({ item in
            TransferPathValidator.validationMessage(
                destinationDirectory: copyQueueItemDestinationPath(for: item, under: destination),
                names: [item.displayName]
            )
        }).first {
            presentOperationError(message)
            return false
        }
        let requests = copyQueueTransferRequests(
            items: items,
            destination: destination
        )
        guard !requests.isEmpty else { return false }

        // Persist the batch before the transfer starts so a crash or device
        // loss mid-copy still leaves a resumable record on disk.
        let record = await saveBatchRecord(
            origin: .copyQueue,
            destinationRoot: destination.path,
            storageID: storageID,
            items: items.map { item in
                TransferBatchRecord.Item(
                    devicePath: item.path,
                    displayName: item.displayName,
                    size: item.size,
                    isDirectory: item.isDirectory,
                    destinationDirectory: copyQueueItemDestinationPath(
                        for: item,
                        under: destination
                    )
                )
            }
        )
        let ids = await prepareAndEnqueueDownloads(
            requests,
            on: transferQueue
        ) { [weak self, weak transferQueue] in
            guard let self, let transferQueue else { return false }
            return self.queue === transferQueue
                && self.transferSessionID == sessionID
                && self.deviceModel?.selectedStorageID == storageID
                && self.copyQueue.sessionID == sessionID
                && self.copyQueue.storageID == storageID
        }
        guard let ids, !ids.isEmpty else {
            discardBatchRecord(record)
            return false
        }
        registerBatchRecord(record, forJobIDs: ids)
        if copyQueue.sessionID == sessionID, copyQueue.storageID == storageID {
            copyQueue.removeAll()
        }
        return true
    }

    @discardableResult
    public func enqueueUpload() async -> UUID? {
        let sourceURLs = selectedSources(in: localModel).map(URL.init(fileURLWithPath:))
        return await enqueueUploads(sourceURLs).first
    }

    @discardableResult
    public func enqueueDroppedFilesOnDevice(_ urls: [URL]) async -> [UUID] {
        await enqueueUploads(urls)
    }

    /// Enqueues the result of a date-range scan, rebuilding the device folder
    /// structure under `destination`.
    ///
    /// The destination subdirectories are created up front because the download
    /// engine writes into a directory that already exists — it does not build
    /// intermediate ones. A directory that cannot be created is surfaced and its
    /// group skipped, so one unwritable folder does not sink the whole copy.
    @discardableResult
    public func enqueueDateRangeCopy(
        _ plan: DateRangeCopyPlan,
        destination: String? = nil,
        storageID: UInt32? = nil
    ) async -> [UUID] {
        guard let queue,
              let resolvedStorageID = storageID ?? deviceModel?.selectedStorageID,
              !plan.isEmpty else { return [] }
        let root = URL(fileURLWithPath: destination ?? localModel.currentLocation)
        let requests = plan.groups.map { group in
            let directory = group.relativeDirectory.isEmpty
                ? root
                : root.appending(path: group.relativeDirectory)
            return TransferRequest(
                direction: .download,
                sources: group.sources,
                destination: directory.path,
                storageId: resolvedStorageID,
                directorySources: directorySources(among: group.sources),
                sourceObjectIds: group.sourceObjectIds
            )
        }

        // Recorded before the transfer starts; date-range matches are always
        // files, and the plan carries no per-file sizes, so items store `nil`.
        let record = await saveBatchRecord(
            origin: .dateRange,
            destinationRoot: root.path,
            storageID: resolvedStorageID,
            items: zip(plan.groups, requests).flatMap { group, request in
                group.sources.map { source in
                    TransferBatchRecord.Item(
                        devicePath: source,
                        displayName: URL(fileURLWithPath: source).lastPathComponent,
                        size: nil,
                        isDirectory: false,
                        destinationDirectory: request.destination
                    )
                }
            }
        )
        let ids = await prepareAndEnqueueDownloads(requests, on: queue) ?? []
        if ids.isEmpty {
            discardBatchRecord(record)
        } else {
            registerBatchRecord(record, forJobIDs: ids)
        }
        return ids
    }

    @discardableResult
    public func enqueueDroppedDeviceItems(
        sources: [String],
        storageID: UInt32,
        sourceObjectIds: [String: UInt32] = [:]
    ) async -> [UUID] {
        await enqueueDownloads(
            sources: sources,
            destination: localModel.currentLocation,
            storageID: storageID,
            sourceObjectIds: sourceObjectIds
        )
    }

    public func exportPromisedDeviceItem(
        _ entry: BrowserEntry,
        storageID: UInt32?,
        to promisedURL: URL
    ) async throws {
        guard let queue, let storageID else {
            throw TransferExportError.deviceUnavailable
        }

        let directorySources: Set<String> = entry.isDirectory ? [entry.location] : []
        let request: TransferRequest
        if promisedURL.lastPathComponent == entry.name {
            request = TransferRequest(
                direction: .download,
                sources: [entry.location],
                destination: promisedURL.deletingLastPathComponent().path,
                storageId: storageID,
                directorySources: directorySources,
                sourceObjectIds: entry.objectId.map { [entry.location: $0] } ?? [:]
            )
        } else {
            var stagingDirectory: URL?
            do {
                let directory = try await stagingService.makeDirectory(
                    appropriateFor: promisedURL.deletingLastPathComponent()
                )
                stagingDirectory = directory
                try Task.checkCancellation()
                request = TransferRequest(
                    direction: .download,
                    sources: [entry.location],
                    destination: directory.path,
                    storageId: storageID,
                    completionAction: .moveStagedItem(
                        sourcePath: directory.appending(path: entry.name).path,
                        destinationPath: promisedURL.path,
                        replaceExisting: false
                    ),
                    cleanupDirectory: directory.path,
                    directorySources: directorySources,
                    sourceObjectIds: entry.objectId.map { [entry.location: $0] } ?? [:]
                )
            } catch {
                if let stagingDirectory {
                    try? await stagingService.removeDirectory(at: stagingDirectory.path)
                }
                throw error
            }
        }
        showPanel()
        let id = await queue.enqueue(
            request.settingPreprocessFiles(preprocessesFiles(request.direction))
        )
        queuesByJobID[id] = queue
        assignBatch(UUID(), toJob: id)

        try await withCheckedThrowingContinuation { continuation in
            exportWaiters[id] = continuation
            resolveExportWaiterIfNeeded(jobID: id)
        }
    }

    public func copyDroppedFilesOnLocalPane(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let destinationDirectory = URL(fileURLWithPath: localModel.currentLocation)
        var conflictSession = ConflictSession()
        var reservedPaths = Set<String>()
        var plans: [(source: URL, destination: URL, replaceExisting: Bool)] = []

        do {
            // Planning stays serial: conflict prompts and keep-both name
            // reservations must observe earlier decisions in order.
            for source in urls {
                let originalDestination = destinationDirectory.appending(path: source.lastPathComponent)
                let originalPath = originalDestination.standardizedFileURL.path
                let hasConflict = FileManager.default.fileExists(atPath: originalPath)
                    || reservedPaths.contains(originalPath)
                var resolution: FileConflictResolution = .replace
                if hasConflict {
                    resolution = await conflictSession.resolve(
                        prompt: FileConflictPrompt(
                            fileName: source.lastPathComponent,
                            destination: destinationDirectory.path,
                            incoming: FileConflictItem(localURL: source),
                            existing: FileConflictItem(localURL: originalDestination)
                        ),
                        asking: resolveConflictDecision
                    )
                }

                switch resolution {
                case .skip:
                    continue
                case .replace:
                    plans.append((source, originalDestination, hasConflict))
                    reservedPaths.insert(originalPath)
                case .keepBoth:
                    let availableName = await KeepBothNameGenerator.availableName(
                        for: source.lastPathComponent
                    ) { candidate in
                        let path = destinationDirectory.appending(path: candidate)
                            .standardizedFileURL.path
                        return reservedPaths.contains(path)
                            || FileManager.default.fileExists(atPath: path)
                    }
                    let destination = destinationDirectory.appending(path: availableName)
                    plans.append((source, destination, false))
                    reservedPaths.insert(destination.standardizedFileURL.path)
                }
            }

            // Local-to-local copies never touch the single-flight device ABI,
            // so they run in parallel with bounded concurrency.
            let copyService = localCopyService
            try await withThrowingTaskGroup(of: Void.self) { group in
                var pending = plans.makeIterator()
                var inFlight = 0
                while let plan = pending.next() {
                    if inFlight >= Self.maxConcurrentLocalCopies {
                        _ = try await group.next()
                        inFlight -= 1
                    }
                    group.addTask {
                        try copyService.copy(
                            source: plan.source,
                            to: plan.destination,
                            replaceExisting: plan.replaceExisting
                        )
                    }
                    inFlight += 1
                }
                while try await group.next() != nil {}
            }
            await localModel.refresh()
        } catch {
            present(error)
        }
    }

    public func resolveConflict(
        _ resolution: FileConflictResolution,
        appliesToAll: Bool
    ) {
        guard !conflictWaiters.isEmpty else { return }
        let waiter = conflictWaiters.removeFirst()
        conflictPrompt = conflictWaiters.first?.prompt
        waiter.continuation.resume(
            returning: FileConflictDecision(
                resolution: resolution,
                appliesToAll: appliesToAll
            )
        )
    }

    private func cancelConflictPrompts() {
        let waiters = conflictWaiters
        conflictWaiters.removeAll()
        conflictPrompt = nil
        for waiter in waiters {
            // Resume with nil so a session-scoped policy never remembers this as
            // the user's decision; callers map nil to a skip for the current file.
            waiter.continuation.resume(returning: nil)
        }
    }

    public func receive(_ event: TransferQueueEvent) {
        guard case let .jobUpdated(job) = event else { return }
        let row = TransferPanelRow(job: job)
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        updateDeviceNavigationState(for: row)
        updateActivitySession(for: job)
        isPanelVisible = true

        resolveExportWaiterIfNeeded(jobID: job.id)

        switch job.state {
        case .completed, .failed, .cancelled:
            recordBatchSettlement(for: row)
            refreshDestination(for: job.request)
        case .queued, .preprocessing, .transferring:
            break
        }
    }

    private func updateActivitySession(for job: TransferJobSnapshot) {
        if let batchID = batchIDByJobID[job.id], !job.state.isTerminal {
            joinActivitySession(batchID)
        }
        if rows.allSatisfy({ $0.state.isTerminal }) {
            endActivitySession()
        }
    }

    /// Records the batch an enqueued job belongs to. The queue publishes the
    /// job's first update before `enqueue` returns, and that update can be
    /// received first: a job whose row is already showing joins the session
    /// here, or a job that stays queued would be left out of the overall
    /// progress until its next update.
    private func assignBatch(_ batchID: UUID, toJob jobID: UUID) {
        batchIDByJobID[jobID] = batchID
        if let row = rows.first(where: { $0.id == jobID }), !row.state.isTerminal {
            joinActivitySession(batchID)
        }
    }

    private func joinActivitySession(_ batchID: UUID) {
        if activeSessionBatches.isEmpty {
            lastSessionSummary = nil
        }
        activeSessionBatches.insert(batchID)
    }

    /// Summarizes the session that just went idle, then forgets its batches.
    private func endActivitySession() {
        guard !activeSessionBatches.isEmpty else { return }
        let sessionRows = rows.filter { row in
            batchIDByJobID[row.id].map(activeSessionBatches.contains) ?? false
        }
        lastSessionSummary = TransferSessionSummary(rows: sessionRows)
        activeSessionBatches.removeAll()
        if let lastSessionSummary {
            onSessionFinished?(lastSessionSummary)
        }
    }

    public func cancel(jobID: UUID) async {
        guard let queue = queuesByJobID[jobID] else { return }
        _ = await queue.cancel(jobId: jobID)
    }

    public func dismiss(jobID: UUID) {
        guard let row = rows.first(where: { $0.id == jobID }),
              row.state.isTerminal else { return }
        removeRow(jobID)
        if rows.isEmpty {
            isPanelVisible = false
            isPanelExpanded = false
            lastSessionSummary = nil
        }
    }

    private func removeRow(_ jobID: UUID) {
        rows.removeAll { $0.id == jobID }
        queuesByJobID.removeValue(forKey: jobID)
        batchIDByJobID.removeValue(forKey: jobID)
        if rows.allSatisfy({ $0.state.isTerminal }) {
            activeSessionBatches.removeAll()
        }
    }

    /// Clears every settled row at once (the panel's "Clear" action).
    public func dismissSettled() {
        for row in rows where row.state.isTerminal {
            dismiss(jobID: row.id)
        }
    }

    /// Whether ``retry(jobID:)`` can act on this row right now: it failed,
    /// was stopped, or finished with some files failing; a device session is
    /// available; and the job carries no one-shot staging work (a conflict
    /// resolved by Replace or Keep Both stages files that are cleaned up once
    /// the job settles, so those are copied again from the browser instead).
    public func canRetry(_ row: TransferPanelRow) -> Bool {
        guard isTransferSessionAvailable, queue != nil,
              deviceModel?.selectedStorageID != nil else { return false }
        let request = row.request
        guard request.completionAction == nil,
              request.cleanupDirectory == nil,
              request.deviceUploadPreparation == nil else { return false }
        switch row.state {
        case .failed, .cancelled:
            return true
        case .completed:
            return !row.fileFailures.isEmpty
        case .queued, .preprocessing, .transferring:
            return false
        }
    }

    /// Copies a settled row's unfinished work again and removes the row, so
    /// the retry takes its place at the end of the queue. Only the files that
    /// failed are retried when the job recorded them; otherwise the whole
    /// request is. Retries go through the normal enqueue paths, so an item
    /// that already made it to the destination raises the usual conflict
    /// prompt (Skip resumes, Replace starts over). A retry after a reconnect
    /// targets the phone's currently selected storage, because MTP storage IDs
    /// do not survive a new session.
    @discardableResult
    public func retry(jobID: UUID) async -> Bool {
        guard let row = rows.first(where: { $0.id == jobID }),
              canRetry(row),
              let queue,
              let selectedStorageID = deviceModel?.selectedStorageID else { return false }
        let request = row.request
        let isSameSession = queuesByJobID[jobID] === queue
        let storageID = isSameSession ? request.storageId : selectedStorageID

        // (destination directory, sources) in first-encounter order.
        var groups: [(destination: String, sources: [String])] = []
        if row.fileFailures.isEmpty {
            groups = [(request.destination, request.sources)]
        } else {
            for failure in row.fileFailures {
                if let index = groups.firstIndex(where: { $0.destination == failure.destinationDirectory }) {
                    groups[index].sources.append(failure.source)
                } else {
                    groups.append((failure.destinationDirectory, [failure.source]))
                }
            }
        }

        let ids: [UUID]
        switch request.direction {
        case .download:
            let requests = groups.map { group in
                TransferRequest(
                    direction: .download,
                    sources: group.sources,
                    destination: group.destination,
                    storageId: storageID,
                    directorySources: request.directorySources.intersection(group.sources),
                    // Handle hints are per session.
                    sourceObjectIds: isSameSession
                        ? request.sourceObjectIds.filter { group.sources.contains($0.key) }
                        : [:]
                )
            }
            ids = await prepareAndEnqueueDownloads(requests, on: queue) ?? []
        case .upload:
            var enqueued: [UUID] = []
            for group in groups {
                enqueued += await enqueueUploads(
                    group.sources.map(URL.init(fileURLWithPath:)),
                    into: group.destination,
                    storageID: storageID
                )
            }
            ids = enqueued
        }
        guard !ids.isEmpty else { return false }
        // Not `dismiss`: the retry's own rows may not have arrived yet, and
        // the panel must not blink closed in between.
        removeRow(jobID)
        return true
    }

    public func togglePanel() {
        isPanelExpanded.toggle()
    }

    /// Whether the resume window's "Resume Copying" button can act right now.
    /// Mirrors the copy queue's session gating: a live transfer session with a
    /// selected storage, because stored batches only carry stale storage IDs.
    public var canResumeBatch: Bool {
        isTransferSessionAvailable
            && queue != nil
            && deviceModel?.selectedStorageID != nil
    }

    /// Re-enqueues a saved batch's pending and failed items (never the
    /// completed ones) to their original destination directories, through the
    /// same preparation path as any other download batch: one conflict
    /// session, one progress batch.
    ///
    /// The resumed run is recorded as a NEW batch — it is itself auto-saved
    /// like any other batch copy — and the old record is left untouched so the
    /// user keeps an accurate history of what each run achieved. Items are
    /// re-requested against the currently selected storage: MTP storage IDs
    /// are not stable across device sessions, so the stored ID is only a hint.
    /// A file that no longer exists on the device simply fails per-file.
    @discardableResult
    public func resumeBatch(_ record: TransferBatchRecord) async -> Bool {
        guard let queue,
              let storageID = deviceModel?.selectedStorageID,
              canResumeBatch else { return false }
        let itemsToResume = record.resumableItems
        guard !itemsToResume.isEmpty else { return false }

        // Group by destination directory, preserving first-encounter order,
        // so the engine receives the same shaped requests the original run
        // built and the destination layout is reproduced exactly.
        var orderedDirectories: [String] = []
        var itemsByDirectory: [String: [TransferBatchRecord.Item]] = [:]
        for item in itemsToResume {
            if itemsByDirectory[item.destinationDirectory] == nil {
                orderedDirectories.append(item.destinationDirectory)
            }
            itemsByDirectory[item.destinationDirectory, default: []].append(item)
        }
        let requests = orderedDirectories.compactMap { directory -> TransferRequest? in
            guard let items = itemsByDirectory[directory] else { return nil }
            // Object handles are session-scoped and are intentionally absent
            // from persisted batches; resume correctly resolves these paths.
            return TransferRequest(
                direction: .download,
                sources: items.map(\.devicePath),
                destination: directory,
                storageId: storageID,
                directorySources: Set(items.filter(\.isDirectory).map(\.devicePath))
            )
        }

        let resumedRecord = await saveBatchRecord(
            origin: record.origin,
            destinationRoot: record.destinationRoot,
            storageID: storageID,
            items: itemsToResume.map { item in
                TransferBatchRecord.Item(
                    devicePath: item.devicePath,
                    displayName: item.displayName,
                    size: item.size,
                    isDirectory: item.isDirectory,
                    destinationDirectory: item.destinationDirectory
                )
            }
        )
        let ids = await prepareAndEnqueueDownloads(requests, on: queue) ?? []
        guard !ids.isEmpty else {
            discardBatchRecord(resumedRecord)
            return false
        }
        registerBatchRecord(resumedRecord, forJobIDs: ids)
        return true
    }

    /// Builds and persists a batch record before its transfer starts. Returns
    /// `nil` when no store is configured or there is nothing to record, so
    /// every recording site can stay a single optional-aware call.
    private func saveBatchRecord(
        origin: TransferBatchRecord.Origin,
        destinationRoot: String,
        storageID: UInt32,
        items: [TransferBatchRecord.Item]
    ) async -> TransferBatchRecord? {
        guard let batchStore, !items.isEmpty else { return nil }
        let record = TransferBatchRecord(
            origin: origin,
            destinationRoot: destinationRoot,
            storageID: storageID,
            deviceLabel: deviceModel?.title,
            items: items
        )
        await batchStore.save(record)
        return record
    }

    /// Removes a record whose transfer never started (enqueue produced no
    /// jobs), so the resume list is not littered with batches that did nothing.
    private func discardBatchRecord(_ record: TransferBatchRecord?) {
        guard let batchStore, let record else { return }
        Task { await batchStore.delete(batchID: record.id) }
    }

    /// Links enqueued jobs to their persisted record so settlement events can
    /// update item statuses. A job that settled before this mapping existed
    /// (events race enqueue return on fast transfers) is recorded immediately
    /// from its already-terminal row.
    private func registerBatchRecord(_ record: TransferBatchRecord?, forJobIDs ids: [UUID]) {
        guard let record else { return }
        for id in ids {
            batchRecordIDByJobID[id] = record.id
            if let row = rows.first(where: { $0.id == id }), row.state.isTerminal {
                recordBatchSettlement(for: row)
            }
        }
    }

    /// Translates one settled job into per-item status updates on its batch
    /// record and rewrites the file off the main actor. Cancelled jobs leave
    /// their items pending — a cancel is a user choice, not a failure, and
    /// pending items remain resumable.
    private func recordBatchSettlement(for row: TransferPanelRow) {
        guard let batchStore,
              row.state.isTerminal,
              let recordID = batchRecordIDByJobID.removeValue(forKey: row.id) else { return }

        var statuses: [String: TransferBatchRecord.Item.Status] = [:]
        switch row.state {
        case .completed:
            for source in row.request.sources {
                if let failure = row.fileFailures.first(where: {
                    $0.source == source || $0.source.hasPrefix(source + "/")
                }) {
                    // A loose file that failed, or a directory item with at
                    // least one failed file inside: mark it failed so resume
                    // re-copies it (per-file resilience makes re-copying the
                    // already-complete parts safe).
                    statuses[source] = .failed(message: failure.message)
                } else {
                    statuses[source] = .completed
                }
            }
        case let .failed(failure):
            for source in row.request.sources {
                statuses[source] = .failed(message: failure.message)
            }
        case .cancelled, .queued, .preprocessing, .transferring:
            return
        }
        Task {
            await batchStore.updateItemStatuses(
                batchID: recordID,
                statusesByDevicePath: statuses
            )
        }
    }

    /// Uploads `sources` into the device pane's current folder, or into
    /// `explicitDestination` on `explicitStorageID` (a retry of an earlier
    /// copy, which may target a folder that is not on screen).
    private func enqueueUploads(
        _ sources: [URL],
        into explicitDestination: String? = nil,
        storageID explicitStorageID: UInt32? = nil
    ) async -> [UUID] {
        guard !sources.isEmpty,
              let expectedDeviceModel = deviceModel,
              let expectedQueue = queue else { return [] }
        if let message = TransferPathValidator.validationMessage(
            destinationDirectory: explicitDestination ?? expectedDeviceModel.currentLocation,
            sources: sources.map(\.path)
        ) {
            presentOperationError(message)
            return []
        }
        var conflictSession = ConflictSession()
        var reservedPaths: [String] = []
        var directSources: [String] = []
        var directDestinationPaths = Set<String>()
        var stagedRequests: [TransferRequest] = []

        do {
            try await waitForDeviceToBecomeIdle(expectedDeviceModel)
            guard let currentDeviceModel = deviceModel,
                  currentDeviceModel === expectedDeviceModel,
                  let currentQueue = queue,
                  currentQueue === expectedQueue,
                  let storageID = explicitStorageID ?? currentDeviceModel.selectedStorageID else {
                throw UploadInitiationError.destinationChanged
            }
            let deviceModel = currentDeviceModel
            let queue = currentQueue
            let destination = explicitDestination ?? currentDeviceModel.currentLocation
            let desiredPaths = sources.map {
                Self.devicePath(directory: destination, name: $0.lastPathComponent)
            }
            let initiallyExisting = try await deviceModel.existingPaths(
                desiredPaths,
                storageID: storageID
            )

            for source in sources {
                let originalName = source.lastPathComponent
                let originalPath = Self.devicePath(directory: destination, name: originalName)
                if !initiallyExisting.contains(originalPath),
                   await queue.reserveDevicePathIfAvailable(originalPath) {
                    directSources.append(source.path)
                    directDestinationPaths.insert(originalPath)
                    reservedPaths.append(originalPath)
                    continue
                }

                let resolution = await conflictSession.resolve(
                    prompt: FileConflictPrompt(
                        fileName: originalName,
                        destination: destination,
                        incoming: FileConflictItem(localURL: source),
                        existing: deviceModel.entries
                            .first { $0.location == originalPath }
                            .map(FileConflictItem.init(deviceEntry:))
                    ),
                    asking: resolveConflictDecision
                )

                switch resolution {
                case .skip:
                    continue
                case .replace:
                    await queue.reserveDevicePath(originalPath)
                    reservedPaths.append(originalPath)
                    let temporary = try await reserveTemporaryDeviceName(
                        for: originalName,
                        destination: destination,
                        storageID: storageID,
                        deviceModel: deviceModel,
                        queue: queue
                    )
                    reservedPaths.append(temporary.path)
                    stagedRequests.append(
                        try await stagedUploadRequest(
                            source: source,
                            named: temporary.name,
                            destination: destination,
                            storageID: storageID,
                            preparation: .replacement(finalPath: originalPath),
                            reservedPaths: [originalPath, temporary.path]
                        )
                    )
                case .keepBoth:
                    let available = try await reserveKeepBothDeviceName(
                        for: originalName,
                        destination: destination,
                        storageID: storageID,
                        deviceModel: deviceModel,
                        queue: queue
                    )
                    reservedPaths.append(available.path)
                    stagedRequests.append(
                        try await stagedUploadRequest(
                            source: source,
                            named: available.name,
                            destination: destination,
                            storageID: storageID,
                            preparation: .keepBoth(originalName: originalName),
                            reservedPaths: [available.path]
                        )
                    )
                }
            }

            var requests: [TransferRequest] = []
            if !directSources.isEmpty {
                requests.append(
                    TransferRequest(
                        direction: .upload,
                        sources: directSources,
                        destination: destination,
                        storageId: storageID,
                        deviceUploadPreparation: nil,
                        reservedDevicePaths: directDestinationPaths
                    )
                )
            }
            requests.append(contentsOf: stagedRequests)
            try await validateUploadDestination(
                deviceModel,
                storageID: explicitStorageID == nil ? storageID : nil,
                destination: explicitDestination == nil ? destination : nil
            )
            return await enqueueRequests(requests, on: queue)
        } catch {
            await removeStagingDirectories(for: stagedRequests)
            await expectedQueue.releaseDevicePaths(reservedPaths)
            if !(error is CancellationError) {
                present(error)
            }
            return []
        }
    }

    /// Downloads queued device items into the local pane's current folder.
    /// Directory flags and handle hints come from the queue items themselves:
    /// they may have been copied from folders other than the one on screen.
    private func enqueuePastedDeviceItems(_ items: [CopyQueueItem]) async -> [UUID] {
        guard let transferQueue = queue,
              let sessionID = transferSessionID,
              let storageID = copyQueue.storageID,
              !items.isEmpty else { return [] }
        let destination = localModel.currentLocation
        let request = TransferRequest(
            direction: .download,
            sources: items.map(\.path),
            destination: destination,
            storageId: storageID,
            directorySources: Set(items.filter(\.isDirectory).map(\.path)),
            sourceObjectIds: Dictionary(
                items.compactMap { item in item.objectId.map { (item.path, $0) } },
                uniquingKeysWith: { _, latest in latest }
            )
        )
        let record = await saveBatchRecord(
            origin: .copyQueue,
            destinationRoot: destination,
            storageID: storageID,
            items: items.map { item in
                TransferBatchRecord.Item(
                    devicePath: item.path,
                    displayName: item.displayName,
                    size: item.size,
                    isDirectory: item.isDirectory,
                    destinationDirectory: destination
                )
            }
        )
        let ids = await prepareAndEnqueueDownloads(
            [request],
            on: transferQueue
        ) { [weak self, weak transferQueue] in
            guard let self, let transferQueue else { return false }
            return self.queue === transferQueue
                && self.transferSessionID == sessionID
                && self.deviceModel?.selectedStorageID == storageID
        } ?? []
        if ids.isEmpty {
            discardBatchRecord(record)
        } else {
            registerBatchRecord(record, forJobIDs: ids)
        }
        return ids
    }

    private func enqueueDownloads(
        sources: [String],
        destination: String,
        storageID: UInt32?,
        sourceObjectIds: [String: UInt32] = [:]
    ) async -> [UUID] {
        guard let queue, let storageID, !sources.isEmpty else { return [] }
        if let message = TransferPathValidator.validationMessage(
            destinationDirectory: destination,
            sources: sources
        ) {
            presentOperationError(message)
            return []
        }
        let request = TransferRequest(
            direction: .download,
            sources: sources,
            destination: destination,
            storageId: storageID,
            directorySources: directorySources(among: sources),
            sourceObjectIds: sourceObjectIds
        )
        return await prepareAndEnqueueDownloads([request], on: queue) ?? []
    }

    /// Enqueues downloads that may target several destination directories as a
    /// single batch.
    ///
    /// One ``ConflictSession`` and one reserved-path set span every planned
    /// request, while the single enqueue call keeps overall progress attached
    /// to one batch.
    private func prepareAndEnqueueDownloads(
        _ plannedRequests: [TransferRequest],
        on queue: TransferQueue,
        isValid: () -> Bool = { true }
    ) async -> [UUID]? {
        let populatedRequests = plannedRequests.filter {
            $0.direction == .download && !$0.sources.isEmpty
        }
        guard !populatedRequests.isEmpty else { return [] }

        var conflictSession = ConflictSession()
        var reservedPaths = Set<String>()
        var directRequests: [TransferRequest] = []
        var stagedRequests: [TransferRequest] = []

        do {
            for plannedRequest in populatedRequests {
                let destinationDirectory = URL(fileURLWithPath: plannedRequest.destination)
                    .standardizedFileURL
                do {
                    try FileManager.default.createDirectory(
                        at: destinationDirectory,
                        withIntermediateDirectories: true
                    )
                } catch {
                    present(error)
                    continue
                }

                var directSources: [String] = []
                for source in plannedRequest.sources {
                    let sourceName = URL(fileURLWithPath: source).lastPathComponent
                    let originalDestination = destinationDirectory.appending(path: sourceName)
                    let originalPath = originalDestination.standardizedFileURL.path
                    let hasConflict = FileManager.default.fileExists(atPath: originalPath)
                        || reservedPaths.contains(originalPath)
                    if !hasConflict {
                        directSources.append(source)
                        reservedPaths.insert(originalPath)
                        continue
                    }

                    let resolution = await conflictSession.resolve(
                        prompt: FileConflictPrompt(
                            fileName: sourceName,
                            destination: plannedRequest.destination,
                            incoming: knownDeviceEntry(at: source)
                                .map(FileConflictItem.init(deviceEntry:)),
                            existing: FileConflictItem(localURL: originalDestination)
                        ),
                        asking: resolveConflictDecision
                    )
                    let sourceDirectories = plannedRequest.directorySources.intersection([source])

                    switch resolution {
                    case .skip:
                        continue
                    case .replace:
                        let stagingDirectory = try await stagingService.makeDirectory(
                            appropriateFor: destinationDirectory
                        )
                        let stagedItem = stagingDirectory.appending(path: sourceName)
                        stagedRequests.append(
                            TransferRequest(
                                direction: .download,
                                sources: [source],
                                destination: stagingDirectory.path,
                                storageId: plannedRequest.storageId,
                                preprocessFiles: plannedRequest.preprocessFiles,
                                completionAction: .moveStagedItem(
                                    sourcePath: stagedItem.path,
                                    destinationPath: originalDestination.path,
                                    replaceExisting: true
                                ),
                                cleanupDirectory: stagingDirectory.path,
                                directorySources: sourceDirectories,
                                sourceObjectIds: plannedRequest.sourceObjectIds.filter {
                                    $0.key == source
                                }
                            )
                        )
                        reservedPaths.insert(originalPath)
                    case .keepBoth:
                        let availableName = await KeepBothNameGenerator.availableName(
                            for: sourceName
                        ) { candidate in
                            let candidatePath = destinationDirectory.appending(path: candidate)
                                .standardizedFileURL.path
                            return reservedPaths.contains(candidatePath)
                                || FileManager.default.fileExists(atPath: candidatePath)
                        }
                        let stagingDirectory = try await stagingService.makeDirectory(
                            appropriateFor: destinationDirectory
                        )
                        let stagedItem = stagingDirectory.appending(path: sourceName)
                        let finalItem = destinationDirectory.appending(path: availableName)
                        stagedRequests.append(
                            TransferRequest(
                                direction: .download,
                                sources: [source],
                                destination: stagingDirectory.path,
                                storageId: plannedRequest.storageId,
                                preprocessFiles: plannedRequest.preprocessFiles,
                                completionAction: .moveStagedItem(
                                    sourcePath: stagedItem.path,
                                    destinationPath: finalItem.path,
                                    replaceExisting: false
                                ),
                                cleanupDirectory: stagingDirectory.path,
                                directorySources: sourceDirectories,
                                sourceObjectIds: plannedRequest.sourceObjectIds.filter {
                                    $0.key == source
                                }
                            )
                        )
                        reservedPaths.insert(finalItem.standardizedFileURL.path)
                    }
                }

                if !directSources.isEmpty {
                    directRequests.append(
                        TransferRequest(
                            direction: .download,
                            sources: directSources,
                            destination: plannedRequest.destination,
                            storageId: plannedRequest.storageId,
                            preprocessFiles: plannedRequest.preprocessFiles,
                            completionAction: plannedRequest.completionAction,
                            cleanupDirectory: plannedRequest.cleanupDirectory,
                            directorySources: plannedRequest.directorySources.intersection(
                                Set(directSources)
                            ),
                            sourceObjectIds: plannedRequest.sourceObjectIds.filter {
                                directSources.contains($0.key)
                            }
                        )
                    )
                }
            }

            guard isValid() else {
                await removeStagingDirectories(for: stagedRequests)
                return nil
            }
            return await enqueueRequests(directRequests + stagedRequests, on: queue)
        } catch {
            await removeStagingDirectories(for: stagedRequests)
            if !(error is CancellationError) {
                present(error)
            }
            return nil
        }
    }

    private func enqueueRequests(
        _ requests: [TransferRequest],
        on queue: TransferQueue
    ) async -> [UUID] {
        guard !requests.isEmpty else { return [] }
        showPanel()
        let batchID = UUID()
        var ids: [UUID] = []
        for request in requests {
            let id = await queue.enqueue(
                request.settingPreprocessFiles(preprocessesFiles(request.direction))
            )
            queuesByJobID[id] = queue
            assignBatch(batchID, toJob: id)
            ids.append(id)
        }
        return ids
    }

    /// Resolves a conflict according to the current ``FileConflictPolicy``:
    /// forced policies answer without prompting, `askEverySession` prompts once
    /// and reuses that answer, and `askEveryFile` prompts every time.
    private func resolveConflictDecision(
        _ prompt: FileConflictPrompt
    ) async -> FileConflictDecision {
        let policy = fileConflictPolicy()
        // The remembered decision only applies while the session policy is
        // active; any other policy drops it so it cannot leak back later.
        if policy != .askEverySession {
            sessionConflictResolution = nil
        }

        switch policy {
        case .alwaysSkip:
            return FileConflictDecision(resolution: .skip, appliesToAll: false)
        case .alwaysOverwrite:
            return FileConflictDecision(resolution: .replace, appliesToAll: false)
        case .askEveryFile:
            return await requestConflictDecision(prompt) ?? Self.cancelledDecision
        case .askEverySession:
            if let remembered = sessionConflictResolution {
                return FileConflictDecision(resolution: remembered, appliesToAll: false)
            }
            guard let decision = await requestConflictDecision(prompt) else {
                // A cancellation (detach/device loss) is not a choice the user
                // made, so it skips the current file and short-circuits the
                // in-flight operation but is never remembered at session scope.
                return Self.cancelledDecision
            }
            sessionConflictResolution = decision.resolution
            return decision
        }
    }

    /// The resolution applied when a pending prompt is cancelled: skip this file
    /// and, via `appliesToAll`, short-circuit the rest of the in-flight operation.
    private static let cancelledDecision = FileConflictDecision(
        resolution: .skip,
        appliesToAll: true
    )

    /// Returns the user's decision, or `nil` when the prompt was cancelled (for
    /// example by `detach()` on device loss) rather than answered.
    private func requestConflictDecision(
        _ prompt: FileConflictPrompt
    ) async -> FileConflictDecision? {
        await withCheckedContinuation { continuation in
            conflictWaiters.append(
                ConflictWaiter(prompt: prompt, continuation: continuation)
            )
            if conflictWaiters.count == 1 {
                conflictPrompt = prompt
            }
        }
    }

    private func showPanel() {
        isPanelVisible = true
        isPanelExpanded = false
    }

    /// The device pane's listing entry for `path`, if the pane has it loaded.
    private func knownDeviceEntry(at path: String) -> BrowserEntry? {
        guard let deviceModel else { return nil }
        return deviceModel.selectedEntries.first { $0.location == path }
            ?? deviceModel.entries.first { $0.location == path }
    }

    private func updateDeviceNavigationState(for row: TransferPanelRow) {
        if row.state.isActive {
            activeJobIDs.insert(row.id)
        } else {
            activeJobIDs.remove(row.id)
        }
        let shouldDisableNavigation = !activeJobIDs.isEmpty
        if isDeviceNavigationDisabled != shouldDisableNavigation {
            isDeviceNavigationDisabled = shouldDisableNavigation
        }
    }

    private func selectedSources(in model: any BrowserPaneModel) -> [String] {
        model.entries.compactMap { entry in
            model.selectedEntryIDs.contains(entry.id) ? entry.location : nil
        }
    }

    /// The subset of device `sources` that are directories, resolved from the
    /// device pane's current listing. The queue expands these into per-file
    /// downloads so a folder can be cancelled at file boundaries; supplying the
    /// flags here avoids a device round-trip to detect directories for the
    /// common loose-file case.
    private func directorySources(among sources: [String]) -> Set<String> {
        guard let deviceModel else { return [] }
        let folderLocations = Set(
            deviceModel.entries.filter(\.isDirectory).map(\.location)
        )
        return Set(sources).intersection(folderLocations)
    }

    /// Returns only live handle hints visible in the current device listing.
    /// Callers with paths from persistence correctly receive an empty map.
    private func sourceObjectIds(among sources: [String]) -> [String: UInt32] {
        guard let deviceModel else { return [:] }
        let sourceSet = Set(sources)
        return Dictionary(
            deviceModel.entries.compactMap { entry in
                guard sourceSet.contains(entry.location), let objectId = entry.objectId else {
                    return nil
                }
                return (entry.location, objectId)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func refreshDestination(for request: TransferRequest) {
        switch request.direction {
        case .download:
            scheduleLocalRefresh()
        case .upload:
            guard isTransferSessionAvailable, let deviceModel else { return }
            scheduleDeviceRefresh(deviceModel)
        }
    }

    private func scheduleLocalRefresh() {
        guard localRefreshTask == nil else {
            localRefreshPending = true
            return
        }
        localRefreshPending = false
        localRefreshTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.performLocalRefreshes()
        }
    }

    private func performLocalRefreshes() async {
        localRefreshPending = false
        await localModel.refresh()
        if !Task.isCancelled, localRefreshPending {
            localRefreshPending = false
            await localModel.refresh()
        }
        localRefreshPending = false
        localRefreshTask = nil
    }

    private func scheduleDeviceRefresh(_ expectedDeviceModel: any DeviceTransferPaneModel) {
        guard let sessionID = transferSessionID else { return }
        guard deviceRefreshTask == nil else {
            deviceRefreshPending = true
            return
        }
        let taskID = UUID()
        deviceRefreshPending = false
        deviceRefreshTaskID = taskID
        deviceRefreshTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.performDeviceRefreshes(
                expectedDeviceModel: expectedDeviceModel,
                sessionID: sessionID,
                taskID: taskID
            )
        }
    }

    private func performDeviceRefreshes(
        expectedDeviceModel: any DeviceTransferPaneModel,
        sessionID: UUID,
        taskID: UUID
    ) async {
        guard deviceRefreshTaskID == taskID else { return }
        guard isCurrentDeviceSession(expectedDeviceModel, sessionID: sessionID) else {
            deviceRefreshPending = false
            deviceRefreshTask = nil
            deviceRefreshTaskID = nil
            return
        }
        deviceRefreshPending = false
        await expectedDeviceModel.refresh()
        guard deviceRefreshTaskID == taskID else { return }
        if !Task.isCancelled,
           deviceRefreshPending,
           isCurrentDeviceSession(expectedDeviceModel, sessionID: sessionID) {
            deviceRefreshPending = false
            await expectedDeviceModel.refresh()
            guard deviceRefreshTaskID == taskID else { return }
        }
        deviceRefreshPending = false
        deviceRefreshTask = nil
        deviceRefreshTaskID = nil
    }

    private func isCurrentDeviceSession(
        _ expectedDeviceModel: any DeviceTransferPaneModel,
        sessionID: UUID
    ) -> Bool {
        isTransferSessionAvailable
            && transferSessionID == sessionID
            && deviceModel === expectedDeviceModel
    }

    private func present(_ error: any Error) {
        presentOperationError(ErrorDescription.message(for: error))
    }

    private func presentOperationError(_ message: String) {
        operationErrorMessage = message
        isShowingOperationError = true
    }

    private static func devicePath(directory: String, name: String) -> String {
        if directory == "/" {
            return "/\(name)"
        }
        let trimmedDirectory = directory.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return "/\(trimmedDirectory)/\(name)"
    }

    private func reserveKeepBothDeviceName(
        for originalName: String,
        destination: String,
        storageID: UInt32,
        deviceModel: any DeviceTransferPaneModel,
        queue: TransferQueue
    ) async throws -> (name: String, path: String) {
        var reservedPath: String?
        let name = try await KeepBothNameGenerator.availableName(for: originalName) { candidate in
            let path = Self.devicePath(directory: destination, name: candidate)
            let existing = try await deviceModel.existingPaths([path], storageID: storageID)
            guard !existing.contains(path) else { return true }
            guard await queue.reserveDevicePathIfAvailable(path) else { return true }
            reservedPath = path
            return false
        }
        return (name, reservedPath ?? Self.devicePath(directory: destination, name: name))
    }

    private func reserveTemporaryDeviceName(
        for originalName: String,
        destination: String,
        storageID: UInt32,
        deviceModel: any DeviceTransferPaneModel,
        queue: TransferQueue
    ) async throws -> (name: String, path: String) {
        let pathExtension = URL(fileURLWithPath: originalName).pathExtension
        while true {
            let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
            let name = "\(AppIdentity.fileNamePrefix)-\(UUID().uuidString)\(suffix)"
            let path = Self.devicePath(directory: destination, name: name)
            let existing = try await deviceModel.existingPaths([path], storageID: storageID)
            if !existing.contains(path), await queue.reserveDevicePathIfAvailable(path) {
                return (name, path)
            }
        }
    }

    private func stagedUploadRequest(
        source: URL,
        named name: String,
        destination: String,
        storageID: UInt32,
        preparation: DeviceUploadPreparation,
        reservedPaths: Set<String>
    ) async throws -> TransferRequest {
        let stagingDirectory = try await stagingService.makeDirectory(appropriateFor: source)
        do {
            let stagedSource = try await stagingService.copyForUpload(
                source: source,
                named: name,
                in: stagingDirectory
            )
            return TransferRequest(
                direction: .upload,
                sources: [stagedSource.path],
                destination: destination,
                storageId: storageID,
                cleanupDirectory: stagingDirectory.path,
                deviceUploadPreparation: preparation,
                reservedDevicePaths: reservedPaths
            )
        } catch {
            try? await stagingService.removeDirectory(at: stagingDirectory.path)
            throw error
        }
    }

    /// Confirms the device pane is still the one the upload was planned
    /// against and, for uploads into the folder on screen (`storageID` and
    /// `destination` given), that the user has not navigated away meanwhile.
    private func validateUploadDestination(
        _ expectedDeviceModel: any DeviceTransferPaneModel,
        storageID: UInt32?,
        destination: String?
    ) async throws {
        try await waitForDeviceToBecomeIdle(expectedDeviceModel)
        guard let currentDeviceModel = deviceModel,
              currentDeviceModel === expectedDeviceModel,
              storageID == nil || currentDeviceModel.selectedStorageID == storageID,
              destination == nil || currentDeviceModel.currentLocation == destination else {
            throw UploadInitiationError.destinationChanged
        }
    }

    private func waitForDeviceToBecomeIdle(
        _ expectedDeviceModel: any DeviceTransferPaneModel
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.deviceLoadingTimeout)
        while expectedDeviceModel.isLoading {
            guard isTransferSessionAvailable,
                  let currentDeviceModel = deviceModel,
                  currentDeviceModel === expectedDeviceModel else {
                throw UploadInitiationError.destinationChanged
            }
            guard clock.now < deadline else {
                throw UploadInitiationError.deviceBusy
            }
            try await Task.sleep(for: Self.deviceLoadingPollInterval)
        }
    }

    private func removeStagingDirectories(for requests: [TransferRequest]) async {
        for request in requests {
            if let cleanupDirectory = request.cleanupDirectory {
                try? await stagingService.removeDirectory(at: cleanupDirectory)
            }
        }
    }

    private static let deviceLoadingTimeout: Duration = .seconds(1)
    private static let deviceLoadingPollInterval: Duration = .milliseconds(25)
    private static let maxConcurrentLocalCopies = 4

    private func resolveExportWaiterIfNeeded(jobID: UUID) {
        guard let waiter = exportWaiters[jobID],
              let row = rows.first(where: { $0.id == jobID }),
              row.state.isTerminal else { return }

        exportWaiters.removeValue(forKey: jobID)
        switch row.state {
        case .completed:
            waiter.resume()
        case let .failed(failure):
            waiter.resume(throwing: TransferExportError.transferFailed(failure.message))
        case .cancelled:
            waiter.resume(throwing: TransferExportError.cancelled)
        case .queued, .preprocessing, .transferring:
            break
        }
    }

    private func failExportWaiters(with error: TransferExportError) {
        let waiters = exportWaiters.values
        exportWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

private struct ConflictWaiter {
    let prompt: FileConflictPrompt
    /// Resumed with the user's decision, or `nil` when the prompt is cancelled.
    let continuation: CheckedContinuation<FileConflictDecision?, Never>
}

private enum UploadInitiationError: LocalizedError {
    case deviceBusy
    case destinationChanged

    var errorDescription: String? {
        switch self {
        case .deviceBusy:
            "The phone is busy. Try again in a moment."
        case .destinationChanged:
            "The phone’s storage or the destination folder changed before the copy could start. Try again."
        }
    }
}

/// A set of device sources bound for one local directory.

private struct ConflictSession {
    private var resolutionForAll: FileConflictResolution?

    mutating func resolve(
        prompt: FileConflictPrompt,
        asking: (FileConflictPrompt) async -> FileConflictDecision
    ) async -> FileConflictResolution {
        if let resolutionForAll {
            return resolutionForAll
        }
        let decision = await asking(prompt)
        if decision.appliesToAll {
            resolutionForAll = decision.resolution
        }
        return decision.resolution
    }
}
