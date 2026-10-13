import Foundation
import MTPKit
import Observation
#if canImport(os)
import os
#endif
import USBWatcher

@MainActor
@Observable
public final class DeviceConnectionController {
    public enum State: Equatable, Sendable {
        case noDevice
        case detecting
        case connected(DeviceInfo, [StorageInfo])
        case needsReplug(deviceName: String?, message: String?)
        case error(message: String, retryable: Bool)
    }

    public typealias ProviderFactory = @Sendable () async throws -> any MTPDeviceProvider

    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "DeviceConnection"
    )

    public private(set) var state: State = .noDevice
    public private(set) var deviceModel: DeviceBrowserViewModel?
    public private(set) var transferQueue: TransferQueue?
    public private(set) var transferSessionID: UUID?
    /// True while the controller is reconnecting on its own after the device
    /// changed or vanished mid-session (see ``DeviceReconnectPolicy``).
    public private(set) var isReconnecting = false
    /// The automatic reconnect attempt that is running, or last ran, in the
    /// current sequence: 1 for the first, up to ``reconnectAttemptLimit``.
    /// 0 while waiting out the delay before the first attempt, and whenever
    /// the controller is not reconnecting.
    public private(set) var reconnectAttempt = 0
    /// The most attempts one reconnect sequence makes (the policy's budget).
    public var reconnectAttemptLimit: Int { reconnectBudget.policy.delays.count }
    /// Why the device pane is showing "no device" when that was not the user's
    /// doing, shown as a pane banner. Cleared by the next connection, a manual
    /// Retry, or a physical unplug.
    public private(set) var connectionNotice: String?
    /// The last connection failure in full (the provider's error text), kept
    /// for bug reports after the pane has moved on to a friendlier screen.
    public private(set) var lastConnectionError: String?
    /// True while "Release the Phone" is stopping macOS's Image Capture agent.
    public private(set) var isReleasingHolder = false
    /// Why the last "Release the Phone" did not work, shown on the next
    /// failure screen. Cleared by Retry and by a connection.
    public private(set) var holderReleaseFailure: String?

    public var canManuallyRetryReplug: Bool {
        state.needsReplug
    }

    @ObservationIgnored private let providerFactory: ProviderFactory
    @ObservationIgnored private let events: AsyncStream<USBDeviceEvent>
    @ObservationIgnored private let startWatching: @Sendable () throws -> Void
    @ObservationIgnored private let stopWatching: @Sendable () -> Void
    @ObservationIgnored private let attachDebounce: Duration
    @ObservationIgnored private var provider: (any MTPDeviceProvider)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var attachDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDisposal: PendingDisposal?
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var connectionAttemptID: UUID?
    @ObservationIgnored private var connectionAttemptTarget: USBDeviceIdentity?
    @ObservationIgnored private var pendingAttachDuringAttempt: PendingAttach?
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var attachedDevice: USBDeviceIdentity?
    @ObservationIgnored private var activeDevice: USBDeviceIdentity?
    @ObservationIgnored private var replugTarget: USBDeviceIdentity?
    @ObservationIgnored private var observedRequiredDetach = false
    @ObservationIgnored private var connectedDeviceName: String?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isWatchingUSB = false
    @ObservationIgnored private var deviceViewMode: BrowserViewMode
    @ObservationIgnored private var deviceShowsHiddenFiles: Bool
    @ObservationIgnored private var deviceDirectoriesFirst: Bool
    @ObservationIgnored private var reconnectBudget: DeviceReconnectBudget
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectToken: UUID?
    @ObservationIgnored private var rememberedLocation: RememberedLocation?
    /// MTP model names of phones seen this run, by serial number, so a phone
    /// that fails before reporting its model is still called by its name.
    @ObservationIgnored private var rememberedDeviceNames: [String: String] = [:]
    @ObservationIgnored private let imageCaptureAgentRelease: ImageCaptureAgentRelease
    @ObservationIgnored private var visiblePaneCount = 0

    public init(
        providerFactory: @escaping ProviderFactory,
        events: AsyncStream<USBDeviceEvent>,
        attachDebounce: Duration = .milliseconds(250),
        deviceViewMode: BrowserViewMode = .list,
        deviceShowsHiddenFiles: Bool = false,
        deviceDirectoriesFirst: Bool = true,
        reconnectPolicy: DeviceReconnectPolicy = .standard,
        imageCaptureAgentRelease: ImageCaptureAgentRelease = .live,
        startWatching: @escaping @Sendable () throws -> Void = {},
        stopWatching: @escaping @Sendable () -> Void = {}
    ) {
        reconnectBudget = DeviceReconnectBudget(policy: reconnectPolicy)
        self.imageCaptureAgentRelease = imageCaptureAgentRelease
        self.providerFactory = providerFactory
        self.events = events
        self.attachDebounce = attachDebounce
        self.deviceViewMode = deviceViewMode
        self.deviceShowsHiddenFiles = deviceShowsHiddenFiles
        self.deviceDirectoriesFirst = deviceDirectoriesFirst
        self.startWatching = startWatching
        self.stopWatching = stopWatching
    }

    public func start(hotplugEnabled: Bool = true) async {
        guard !isStarted else { return }
        isStarted = true
        Self.logger.info("Connection started, hotplug \(hotplugEnabled ? "on" : "off", privacy: .public)")

        if hotplugEnabled {
            do {
                try startEventMonitoring()
            } catch {
                isStarted = false
                state = .error(message: ErrorDescription.message(for: error), retryable: true)
                return
            }
        }

        await attemptConnection()
    }

    public func setUsbHotplugEnabled(_ enabled: Bool) async {
        guard isStarted, enabled != isWatchingUSB else { return }
        if enabled {
            do {
                try startEventMonitoring()
            } catch {
                state = .error(message: ErrorDescription.message(for: error), retryable: true)
            }
        } else {
            stopEventMonitoring()
        }
    }

    public func updateDevicePreferences(
        viewMode: BrowserViewMode,
        showsHiddenFiles: Bool,
        directoriesFirst: Bool
    ) async {
        deviceViewMode = viewMode
        deviceShowsHiddenFiles = showsHiddenFiles
        deviceDirectoriesFirst = directoriesFirst
        deviceModel?.viewMode = viewMode
        deviceModel?.setDirectoriesFirst(directoriesFirst)
        await deviceModel?.setShowsHiddenFiles(showsHiddenFiles)
    }

    public func retry() async {
        // Single flight: a Retry while an attempt is running (a double
        // click, say) would only queue another claim of the same interface.
        guard connectionAttemptID == nil, !isReleasingHolder else {
            Self.logger.info("Retry ignored: a connection attempt is already running")
            return
        }
        holderReleaseFailure = nil
        await retryNow()
    }

    private func retryNow() async {
        cancelReconnect()
        reconnectBudget.reset()
        connectionNotice = nil
        if state.needsReplug {
            replugTarget = nil
            observedRequiredDetach = false
        }
        attachDebounceTask?.cancel()
        attachDebounceTask = nil
        await attemptConnection(ignoringDisposalFailure: true)
    }

    /// The Image Capture agent named by the current failure, when the app
    /// may offer to stop it.
    public var releasableHolder: DeviceHolder? {
        guard case let .error(message, _) = state,
              let holder = DeviceAccessProblem(message: message)?.holder,
              holder.isImageCaptureAgent else { return nil }
        return holder
    }

    /// "Release the Phone": stops macOS's Image Capture agent when it holds
    /// the phone (see ``ImageCaptureAgentRelease`` for the checks), then
    /// retries at once, because launchd starts the agent again on demand.
    /// The connection is retried whatever the outcome; a release that did not
    /// work is reported in ``holderReleaseFailure``.
    public func releaseHolderAndRetry() async {
        guard connectionAttemptID == nil, !isReleasingHolder else { return }
        guard let pid = releasableHolder?.processID else {
            await retry()
            return
        }
        isReleasingHolder = true
        let release = imageCaptureAgentRelease
        let outcome = await Task.detached { release.release(pid: pid) }.value
        isReleasingHolder = false
        Self.logger.notice(
            "Release of the Image Capture agent (pid \(pid, privacy: .public)): \(String(describing: outcome), privacy: .public)"
        )
        holderReleaseFailure = outcome.failureMessage
        await retryNow()
    }

    public func dismissConnectionNotice() {
        connectionNotice = nil
    }

    /// Called when a view that shows the device appears. The session is shared
    /// by every window, so it starts with the first one.
    public func paneAppeared(hotplugEnabled: Bool = true) async {
        visiblePaneCount += 1
        await start(hotplugEnabled: hotplugEnabled)
    }

    /// Called when a view that shows the device goes away. The last one to go
    /// releases the device session, so a window-less app does not keep the
    /// phone's USB interface claimed from other apps. Active transfers are left
    /// to finish instead: tearing the session down would abort them, and a
    /// transfer the user started is not something closing a window cancels.
    public func paneDisappeared(hasActiveTransfers: Bool) {
        visiblePaneCount = max(0, visiblePaneCount - 1)
        guard visiblePaneCount == 0, !hasActiveTransfers else { return }
        stop()
    }

    /// Stops the connection and returns only once the device session has been
    /// disposed, so another process can claim the device's USB interface.
    /// ``stop()`` alone schedules disposal and returns immediately.
    /// Returns whether the controller was running, i.e. whether the caller
    /// should ``start(hotplugEnabled:)`` it again afterwards.
    @discardableResult
    public func releaseDevice() async -> Bool {
        let wasStarted = isStarted
        stop()
        _ = await waitForPendingDisposal(reconnecting: nil, ignoringFailure: true)
        return wasStarted
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        cancelReconnect()
        attachDebounceTask?.cancel()
        attachDebounceTask = nil
        stopEventMonitoring()
        rememberLocation()
        let queue = transferQueue
        let currentProvider = provider
        let currentIdentity = activeDevice ?? attachedDevice
        provider = nil
        clearSession(state: .noDevice)
        let invalidationTask = scheduleQueueInvalidation(
            queue,
            message: "The device connection was closed."
        )
        if let currentProvider {
            scheduleDisposal(
                of: currentProvider,
                identity: currentIdentity,
                after: invalidationTask
            )
        }
    }

    private func receive(_ event: USBDeviceEvent) {
        guard event.isLikelyMTPDevice != false else { return }
        let device = String(format: "%04x:%04x", event.vendorId, event.productId)
        Self.logger.info(
            "USB \(String(describing: event.kind), privacy: .public) \(device, privacy: .public) while \(self.state.logDescription, privacy: .public)"
        )
        let identity = USBDeviceIdentity(event: event)
        switch event.kind {
        case .attached:
            if state.needsReplug {
                adoptReplugTargetIfNeeded(identity)
                guard replugTarget?.positivelyIdentifiesDifferentDevice(from: identity) != true
                else { return }
                attachedDevice = identity
                guard observedRequiredDetach else { return }
                observedRequiredDetach = false
                replugTarget = nil
                coalesceAttach(identity: identity, afterReplug: true)
            } else {
                if case .connected = state {
                    if activeDevice?.positivelyIdentifiesDifferentDevice(from: identity) != true {
                        attachedDevice = identity
                        activeDevice = identity.merging(activeDevice)
                    }
                    return
                }
                attachedDevice = identity
                if let attemptID = connectionAttemptID,
                   connectionAttemptTarget?
                    .positivelyIdentifiesDifferentDevice(from: identity) != true {
                    connectionAttemptTarget = identity.merging(connectionAttemptTarget)
                    pendingAttachDuringAttempt = PendingAttach(
                        attemptID: attemptID,
                        identity: identity
                    )
                    return
                }
                coalesceAttach(identity: identity)
            }
        case .detached:
            if state.needsReplug {
                adoptReplugTargetIfNeeded(identity)
                guard replugTarget?.positivelyIdentifiesDifferentDevice(from: identity) != true
                else { return }
                attachedDevice = nil
                observedRequiredDetach = true
            } else {
                // Unknown or partial identities fail open. Only a positive
                // mismatch is enough to suppress a detach.
                guard activeDevice?.positivelyIdentifiesDifferentDevice(from: identity) != true
                else { return }
                attachDebounceTask?.cancel()
                attachDebounceTask = nil
                attachedDevice = nil
                connectionNotice = nil
                disconnect()
            }
        }
    }

    /// - Parameter afterReplug: the attach is the replug the replug screen
    ///   asked for; if that attempt needs a replug again, the controller
    ///   reports an error instead of asking a second time.
    private func coalesceAttach(identity: USBDeviceIdentity, afterReplug: Bool = false) {
        attachDebounceTask?.cancel()
        attachDebounceTask = Task { [weak self, attachDebounce, identity] in
            do {
                try await Task.sleep(for: attachDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            if self.connectionAttemptID != nil,
               self.connectionAttemptTarget?
                .positivelyIdentifiesDifferentDevice(from: identity) != true {
                return
            }
            if case .connected = self.state { return }
            await self.attemptConnection(targeting: identity, afterReplug: afterReplug)
        }
    }

    private func attemptConnection(
        targeting target: USBDeviceIdentity? = nil,
        ignoringDisposalFailure: Bool = false,
        isReconnect: Bool = false,
        afterReplug: Bool = false
    ) async {
        connectionGeneration += 1
        let generation = connectionGeneration
        let attemptID = UUID()
        connectionAttemptID = attemptID
        connectionAttemptTarget = target ?? attachedDevice ?? activeDevice
        defer {
            let pendingAttach = pendingAttachDuringAttempt?.attemptID == attemptID
                ? pendingAttachDuringAttempt?.identity
                : nil
            if pendingAttach != nil {
                pendingAttachDuringAttempt = nil
            }
            if connectionAttemptID == attemptID {
                connectionAttemptID = nil
                connectionAttemptTarget = nil
            }
            if let pendingAttach {
                switch state {
                case .connected:
                    // A completed connection has already consumed the attach.
                    break
                case .needsReplug:
                    // The replug screen waits for a detach and an attach. An
                    // attach seen during the attempt is the same phone
                    // announced once more (the watcher reports a device once
                    // per matching service class), not that replug, and
                    // claiming again at once would only repeat the failure.
                    break
                case .noDevice, .detecting, .error:
                    coalesceAttach(identity: pendingAttach)
                }
            }
        }

        await invalidateTransferQueue(message: "The previous device session was replaced.")
        guard generation == connectionGeneration else { return }
        rememberLocation()
        activeSessionID = nil
        deviceModel = nil
        transferSessionID = nil

        if let previousProvider = provider {
            let previousIdentity = activeDevice ?? attachedDevice ?? connectionAttemptTarget
            provider = nil
            scheduleDisposal(of: previousProvider, identity: previousIdentity)
        }

        state = .detecting
        if let disposalFailure = await waitForPendingDisposal(
            reconnecting: connectionAttemptTarget,
            ignoringFailure: ignoringDisposalFailure
        ) {
            guard generation == connectionGeneration else { return }
            recordConnectionError(disposalFailure, context: "Closing the previous device session failed")
            transitionToNeedsReplug(
                message: "\(AppIdentity.name) could not close the previous device session. \(disposalFailure)"
            )
            return
        }
        guard generation == connectionGeneration else { return }
        connectedDeviceName = nil
        activeDevice = nil

        do {
            let candidate = try await providerFactory()
            guard generation == connectionGeneration else {
                scheduleDisposal(
                    of: candidate,
                    identity: connectionAttemptTarget ?? attachedDevice ?? activeDevice
                )
                return
            }

            provider = candidate
            let deviceInfo = try await candidate.deviceInfo()
            guard generation == connectionGeneration else { return }
            let infoIdentity = USBDeviceIdentity(deviceInfo: deviceInfo)
            activeDevice = (connectionAttemptTarget ?? attachedDevice)?.merging(infoIdentity)
                ?? infoIdentity
            connectedDeviceName = deviceName(for: activeDevice, deviceInfo: deviceInfo)
            let storages = try await candidate.storages()
            guard generation == connectionGeneration else { return }

            let sessionID = UUID()
            let monitoredProvider = ConnectionMonitoringProvider(
                provider: candidate
            ) { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.connectionLost(error, sessionID: sessionID)
                }
            }
            provider = monitoredProvider
            activeSessionID = sessionID
            deviceModel = DeviceBrowserViewModel(
                provider: monitoredProvider,
                viewMode: deviceViewMode,
                showsHiddenFiles: deviceShowsHiddenFiles,
                directoriesFirst: deviceDirectoriesFirst,
                initialLocation: consumeRememberedLocation(for: activeDevice)
            )
            transferQueue = TransferQueue(provider: monitoredProvider, sessionID: sessionID)
            transferSessionID = sessionID
            state = .connected(deviceInfo, storages)
            Self.logger.info("Connected to \(self.connectedDeviceName ?? "a device", privacy: .public)")
            if let serialNumber = activeDevice?.serialNumber,
               !DeviceFriendlyName.isGeneric(deviceInfo.model),
               !deviceInfo.model.trimmingCharacters(in: .whitespaces).isEmpty {
                rememberedDeviceNames[serialNumber] = deviceInfo.model
            }
            connectionNotice = nil
            holderReleaseFailure = nil
            reconnectBudget.recordSuccess()
            endReconnecting()
            if pendingAttachDuringAttempt?.attemptID == attemptID {
                pendingAttachDuringAttempt = nil
            }
        } catch {
            guard generation == connectionGeneration else { return }
            let failedProvider = provider
            provider = nil
            activeSessionID = nil
            deviceModel = nil
            await invalidateTransferQueue(message: "The device connection attempt failed.")
            transferSessionID = nil
            if let failedProvider {
                scheduleDisposal(
                    of: failedProvider,
                    identity: activeDevice ?? connectionAttemptTarget ?? attachedDevice
                )
            }

            let detail = ErrorDescription.message(for: error)
            recordConnectionError(detail, context: "Connection attempt failed")
            switch ConnectionFatalClassifier.disposition(for: error) {
            case .requiresReplug where afterReplug:
                // The phone was just unplugged and plugged back in as asked,
                // and it failed the same way: asking again would loop.
                endReconnecting()
                state = .error(
                    message: String(localized: "The phone still couldn’t be opened after it was plugged back in.") + " " + detail,
                    retryable: true
                )
            case .requiresReplug:
                endReconnecting()
                transitionToNeedsReplug()
            case .accessBlocked:
                // Another program holding the phone, a device node this user
                // may not open, or (macOS) a refused claim is not cured by a
                // replug: report it as an error the device pane can explain,
                // with the transport's detail.
                endReconnecting()
                state = .error(message: detail, retryable: true)
            case .deviceUnavailable:
                state = .noDevice
                // Mid-sequence, "no device" usually means the phone is still
                // re-enumerating, so keep going until the budget is spent.
                // Outside one, only a device-changed error starts a sequence;
                // a plain "no device found" waits for hotplug or Retry — and
                // does not cancel a sequence another path already started.
                if isReconnect || ConnectionFatalClassifier.triggersReconnect(error) {
                    scheduleReconnect()
                }
            case nil:
                endReconnecting()
                state = .error(message: detail, retryable: true)
            }
        }
    }

    /// Logs a connection failure and keeps it for bug reports.
    private func recordConnectionError(_ detail: String, context: String) {
        lastConnectionError = detail
        Self.logger.error("\(context, privacy: .public): \(detail, privacy: .public)")
    }

    private func connectionLost(_ error: any Error, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        let disposition = ConnectionFatalClassifier.disposition(for: error)
        if disposition != nil {
            recordConnectionError(ErrorDescription.message(for: error), context: "Connection lost")
        }
        switch disposition {
        case .requiresReplug:
            transitionToNeedsReplug()
        case .accessBlocked:
            // The provider reopens the phone on demand (after the Samsung
            // storage-access prompt, say), and another program can take it
            // in between: same rule as a failed connection attempt.
            transitionToError(message: ErrorDescription.message(for: error))
        case .deviceUnavailable:
            disconnect()
            if ConnectionFatalClassifier.triggersReconnect(error) {
                scheduleReconnect()
            } else {
                connectionNotice = Self.connectionLostNotice
            }
        case nil:
            break
        }
    }

    private func transitionToNeedsReplug(message: String? = nil) {
        cancelReconnect()
        rememberLocation()
        connectionGeneration += 1
        let queue = transferQueue
        let currentProvider = provider
        let target = activeDevice ?? attachedDevice ?? connectionAttemptTarget
        let deviceName = connectedDeviceName ?? self.deviceName(for: target)

        provider = nil
        activeSessionID = nil
        deviceModel = nil
        transferQueue = nil
        transferSessionID = nil
        activeDevice = nil
        replugTarget = target
        observedRequiredDetach = false
        state = .needsReplug(
            deviceName: deviceName,
            message: message
        )

        let invalidationTask = scheduleQueueInvalidation(
            queue,
            message: "The device session is no longer available."
        )
        if let currentProvider {
            scheduleDisposal(
                of: currentProvider,
                identity: target,
                after: invalidationTask
            )
        }
    }

    /// Ends the session and shows a retryable error (a failure the device
    /// pane explains, such as another program taking the phone).
    private func transitionToError(message: String) {
        cancelReconnect()
        rememberLocation()
        connectionGeneration += 1
        let queue = transferQueue
        let currentProvider = provider
        let currentIdentity = activeDevice ?? attachedDevice
        provider = nil
        clearSession(state: .error(message: message, retryable: true))

        let invalidationTask = scheduleQueueInvalidation(
            queue,
            message: "The device session is no longer available."
        )
        if let currentProvider {
            scheduleDisposal(
                of: currentProvider,
                identity: currentIdentity,
                after: invalidationTask
            )
        }
    }

    private func disconnect() {
        // The watcher reports each detach once per matching USB service
        // class, so only the first of them ends a session worth logging.
        if state != .noDevice {
            Self.logger.info("Device disconnected")
        }
        cancelReconnect()
        rememberLocation()
        connectionGeneration += 1
        let queue = transferQueue
        let currentProvider = provider
        let currentIdentity = activeDevice ?? attachedDevice
        provider = nil
        clearSession(state: .noDevice)

        let invalidationTask = scheduleQueueInvalidation(
            queue,
            message: "The device was disconnected."
        )
        if let currentProvider {
            scheduleDisposal(
                of: currentProvider,
                identity: currentIdentity,
                after: invalidationTask
            )
        }
    }

    // MARK: - Automatic reconnection

    static let connectionLostNotice = "The connection to the phone was lost."
    static let reconnectExhaustedNotice =
        "\(AppIdentity.name) couldn’t reconnect to the phone. Unlock it, choose File transfer, then click Retry."

    private func scheduleReconnect() {
        guard isStarted else { return }
        guard let delay = reconnectBudget.nextDelay(now: ContinuousClock.now) else {
            reconnectBudget.reset()
            endReconnecting()
            connectionNotice = Self.reconnectExhaustedNotice
            return
        }
        isReconnecting = true
        let token = UUID()
        reconnectToken = token
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.reconnectToken == token else { return }
            if case .connected = self.state {
                self.endReconnecting()
                return
            }
            self.reconnectAttempt = min(self.reconnectBudget.attemptsUsed, self.reconnectAttemptLimit)
            await self.attemptConnection(isReconnect: true)
            // A failed attempt schedules its successor (a new token) and a
            // successful or terminal one ends the sequence (no token). An
            // attempt superseded by another path does neither, so continue
            // the sequence here rather than leave "reconnecting" stuck on.
            guard self.reconnectToken == token, !Task.isCancelled else { return }
            if case .connected = self.state {
                self.endReconnecting()
            } else {
                self.scheduleReconnect()
            }
        }
    }

    private func endReconnecting() {
        isReconnecting = false
        reconnectAttempt = 0
        reconnectToken = nil
        reconnectTask = nil
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        endReconnecting()
    }

    /// Remembers where the user was so the same phone reopens there.
    private func rememberLocation() {
        guard let deviceModel,
              let storageID = deviceModel.selectedStorageID,
              let serialNumber = activeDevice?.serialNumber else { return }
        rememberedLocation = RememberedLocation(
            serialNumber: serialNumber,
            location: DeviceBrowserLocation(
                storageID: storageID,
                path: deviceModel.currentLocation
            )
        )
    }

    /// The remembered location, but only for the same phone: a different
    /// serial means a different device, which opens at its storage root.
    private func consumeRememberedLocation(for identity: USBDeviceIdentity?) -> DeviceBrowserLocation? {
        defer { rememberedLocation = nil }
        guard let rememberedLocation,
              let serialNumber = identity?.serialNumber,
              rememberedLocation.serialNumber == serialNumber else { return nil }
        return rememberedLocation.location
    }

    private func invalidateTransferQueue(message: String) async {
        guard let transferQueue else { return }
        await transferQueue.invalidateSession(message: message)
        if self.transferQueue === transferQueue {
            self.transferQueue = nil
        }
    }

    private func clearSession(state: State) {
        activeSessionID = nil
        deviceModel = nil
        transferQueue = nil
        transferSessionID = nil
        connectedDeviceName = nil
        activeDevice = nil
        replugTarget = nil
        observedRequiredDetach = false
        self.state = state
    }

    private func adoptReplugTargetIfNeeded(_ identity: USBDeviceIdentity) {
        guard replugTarget == nil else { return }
        replugTarget = identity
        guard case let .needsReplug(currentName, message) = state,
              currentName == nil,
              let name = deviceName(for: identity) else { return }
        state = .needsReplug(deviceName: name, message: message)
    }

    /// The name to show for a phone: its MTP model when known (and not
    /// generic), else the model remembered for its serial number this run,
    /// else its USB product string unless generic, else its maker
    /// ("Samsung phone"); nil leaves the UI's generic wording.
    private func deviceName(for identity: USBDeviceIdentity?, deviceInfo: DeviceInfo? = nil) -> String? {
        if let model = deviceInfo?.model.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty, !DeviceFriendlyName.isGeneric(model) {
            return model
        }
        if let serialNumber = identity?.serialNumber, let remembered = rememberedDeviceNames[serialNumber] {
            return remembered
        }
        let products = [deviceInfo?.usb.product, identity?.productName].compactMap { $0 }
        let vendorID = identity?.vendorID ?? deviceInfo.flatMap { $0.usb.vendorID == 0 ? nil : $0.usb.vendorID }
        return DeviceFriendlyName.resolve(
            model: nil,
            productName: products.first { !$0.isEmpty && !DeviceFriendlyName.isGeneric($0) },
            vendorID: vendorID
        )
    }

    private func scheduleQueueInvalidation(
        _ queue: TransferQueue?,
        message: String
    ) -> Task<Void, Never>? {
        guard let queue else { return nil }
        // The queue must drain native I/O before disposal, but that wait must
        // not retain main-actor state or block subsequent USB events.
        return Task.detached {
            await queue.invalidateSession(message: message)
        }
    }

    private func scheduleDisposal(
        of provider: any MTPDeviceProvider,
        identity: USBDeviceIdentity?,
        after prerequisite: Task<Void, Never>? = nil
    ) {
        let previousTask = pendingDisposal?.task
        let id = UUID()
        let task = Task.detached { () -> DisposalFailure? in
            let previousFailure = await previousTask?.value
            if let prerequisite {
                await prerequisite.value
            }
            do {
                guard try await provider.dispose() else {
                    return DisposalFailure(
                        identity: identity,
                        message: "The provider returned an unsuccessful disposal result."
                    )
                }
                return previousFailure
            } catch {
                return DisposalFailure(
                    identity: identity,
                    message: ErrorDescription.message(for: error)
                )
            }
        }
        pendingDisposal = PendingDisposal(id: id, task: task)
    }

    private func waitForPendingDisposal(
        reconnecting identity: USBDeviceIdentity?,
        ignoringFailure: Bool
    ) async -> String? {
        guard let pendingDisposal else { return nil }
        let result = await pendingDisposal.task.value
        if self.pendingDisposal?.id == pendingDisposal.id {
            self.pendingDisposal = nil
        }
        guard !ignoringFailure,
              let result,
              let failedIdentity = result.identity,
              let identity,
              failedIdentity.matches(identity) else { return nil }
        return result.message
    }

    private func startEventMonitoring() throws {
        guard !isWatchingUSB else { return }
        try startWatching()
        isWatchingUSB = true
        Self.logger.info("USB hotplug watching started")
        // One consumer for the controller's lifetime, never cancelled:
        // cancelling a task that iterates an AsyncStream terminates the stream
        // for good, so after a stop and start (the bug report, the last window
        // closing, the hotplug setting toggled) no event would arrive again.
        // While not watching, events are dropped instead.
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, events] in
            for await event in events {
                guard let self else { return }
                guard self.isWatchingUSB else { continue }
                self.receive(event)
            }
        }
    }

    private func stopEventMonitoring() {
        guard isWatchingUSB else { return }
        isWatchingUSB = false
        stopWatching()
        Self.logger.info("USB hotplug watching stopped")
    }
}

private struct PendingDisposal {
    let id: UUID
    let task: Task<DisposalFailure?, Never>
}

private struct DisposalFailure: Sendable {
    let identity: USBDeviceIdentity?
    let message: String
}

private struct RememberedLocation {
    let serialNumber: String
    let location: DeviceBrowserLocation
}

private struct PendingAttach: Sendable {
    let attemptID: UUID
    let identity: USBDeviceIdentity
}

private extension DeviceConnectionController.State {
    var logDescription: String {
        switch self {
        case .noDevice: "no device"
        case .detecting: "detecting"
        case .connected: "connected"
        case .needsReplug: "needs replug"
        case .error: "error"
        }
    }

    var needsReplug: Bool {
        if case .needsReplug = self {
            true
        } else {
            false
        }
    }
}
