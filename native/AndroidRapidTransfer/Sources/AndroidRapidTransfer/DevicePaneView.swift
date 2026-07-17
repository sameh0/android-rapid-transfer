import AndroidRapidTransferCore
import SwiftUI

struct DevicePaneView: View {
    @Bindable var controller: DeviceConnectionController
    @Bindable var transferModel: TransferViewModel
    let settings: AppSettings
    let focusCoordinator: PaneFocusCoordinator
    let onboarding: OnboardingCoordinator
    @State private var dateRangeCopy: DateRangeCopyViewModel?
    /// Bumped each time a connection attempt fails, to shake the illustration.
    @State private var failureCount = 0
    @State private var arrival: ConnectionArrival?
    @State private var announcedSessionID: UUID?
    @State private var arrivalIsReconnect = false

    var body: some View {
        ZStack {
            if phase == .connected, let model = controller.deviceModel {
                browser(model: model)
                    .overlay(alignment: .bottom) { arrivalToast }
                    .onChange(of: model.hasLoaded, initial: true) { _, _ in
                        announceArrivalIfReady(model: model)
                    }
                    .motionTransition(.opacity)
            } else {
                stage
                    .motionTransition(.opacity)
            }
        }
        .motion(Motion.gentle, value: phase.kind == .connected)
        .onChange(of: phase.kind) { oldKind, newKind in
            if newKind == .failed {
                failureCount += 1
            }
            if newKind == .connected {
                arrivalIsReconnect = oldKind == .reconnecting
            }
            // The screen swaps silently otherwise; the arrival toast
            // announces a connection itself.
            if let announcement = Self.announcement(for: newKind) {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        .sheet(item: $dateRangeCopy) { copyModel in
            DateRangeCopySheet(model: copyModel) {
                dateRangeCopy = nil
            }
        }
    }

    private var phase: ConnectionPanePhase {
        ConnectionPanePhase(
            state: controller.state,
            isReconnecting: controller.isReconnecting,
            hasDeviceModel: controller.deviceModel != nil,
            notice: controller.connectionNotice,
            reconnectProgress: ConnectionReconnectProgress(controller: controller)
        )
    }

    // MARK: - Connection screens

    private var stage: some View {
        VStack(spacing: 0) {
            if case let .waiting(notice?) = phase {
                ErrorBannerView(
                    message: notice,
                    tone: .notice,
                    actionTitle: "Dismiss",
                    actionSystemImage: "xmark",
                    action: { withMotion(Motion.snappy, controller.dismissConnectionNotice) }
                )
                Divider()
            }
            ConnectionStageView(
                illustration: illustrationMode,
                phase: phase.kind,
                failureCount: failureCount
            ) {
                stageContent
            }
        }
        .motion(Motion.snappy, value: controller.connectionNotice)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch phase {
        case .waiting, .connected:
            NoDeviceView(retry: retry, showConnectionHelp: showConnectionHelp)
        case .detecting:
            DetectingDeviceView()
        case let .reconnecting(progress):
            DetectingDeviceView(reconnect: progress)
        case let .needsReplug(deviceName, message):
            NeedsReplugView(
                deviceName: deviceName,
                message: message,
                allowsManualRetry: controller.canManuallyRetryReplug,
                retry: retry,
                showConnectionHelp: showConnectionHelp
            )
        case let .failed(message, retryable):
            DeviceConnectionErrorView(
                message: message,
                retryable: retryable,
                retry: retry,
                showConnectionHelp: showConnectionHelp
            )
        }
    }

    private var illustrationMode: ConnectionIllustrationView.Mode {
        switch phase {
        case .waiting, .connected: .waiting
        case .detecting: .handshake
        case let .reconnecting(progress):
            .reconnecting(
                attempt: progress.attempt,
                limit: progress.limit,
                isAttempting: progress.isAttempting
            )
        case .needsReplug: .replug
        case .failed: .failed
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private var arrivalToast: some View {
        if let arrival {
            ConnectionArrivalToast(arrival: arrival)
                .padding(.bottom, 44)
                .motionTransition(
                    .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9))
                )
                .task(id: arrival) {
                    guard (try? await Task.sleep(for: Self.arrivalDuration)) != nil else { return }
                    withMotion(Motion.gentle) { self.arrival = nil }
                }
        }
    }

    private static let arrivalDuration: Duration = .milliseconds(2600)

    /// What VoiceOver hears when the pane changes screen on its own.
    private static func announcement(for kind: ConnectionPanePhase.Kind) -> String? {
        switch kind {
        case .detecting: String(localized: "Connecting to your phone")
        case .reconnecting: String(localized: "Connection lost. Reconnecting")
        case .needsReplug: String(localized: "Unplug and reconnect your phone")
        case .failed: String(localized: "Couldn’t connect to the phone")
        case .waiting, .connected: nil
        }
    }

    /// Marks a new session's files being ready, once per session.
    private func announceArrivalIfReady(model: DeviceBrowserViewModel) {
        guard model.hasLoaded, model.error == nil,
              let sessionID = controller.transferSessionID,
              announcedSessionID != sessionID else { return }
        announcedSessionID = sessionID
        let storage = model.storages.first { $0.id == model.selectedStorageID }
        let next = ConnectionArrival(
            deviceName: model.title,
            freeBytes: storage?.freeBytes,
            isReconnect: arrivalIsReconnect
        )
        withMotion(Motion.celebrate) { arrival = next }
        AccessibilityNotification.Announcement(next.title).post()
    }

    private func browser(model: DeviceBrowserViewModel) -> some View {
        BrowserPaneView(
            model: model,
            paneKind: .device,
            settings: settings,
            focusCoordinator: focusCoordinator,
            isPrimary: !settings.showLocalPane,
            copyAction: BrowserCopyAction(
                title: "Copy to Computer",
                systemImage: "arrow.left",
                isEnabled: !model.selectedEntryIDs.isEmpty
                    && model.selectedStorageID != nil
                    && !transferModel.isDeviceNavigationDisabled,
                perform: copyToComputer
            ),
            queueAction: BrowserCopyAction(
                title: "Add to Copy Queue",
                systemImage: "text.badge.plus",
                isEnabled: transferModel.isTransferSessionAvailable
                    && model.selectedStorageID != nil
                    && !transferModel.isDeviceNavigationDisabled,
                perform: { addSelectionToQueue(model: model) }
            ),
            dateRangeAction: dateRangeAction(for: model),
            clipboardCopyAction: BrowserCopyAction(
                title: "Copy",
                systemImage: "doc.on.doc",
                isEnabled: transferModel.isTransferSessionAvailable
                    && model.selectedStorageID != nil
                    && !transferModel.isDeviceNavigationDisabled,
                perform: { copySelection(model: model, replacing: true) }
            ),
            pasteAction: BrowserCopyAction(
                title: "Paste",
                systemImage: "doc.on.clipboard",
                isEnabled: transferModel.canPaste(into: .device),
                perform: { Task { await transferModel.paste(into: .device) } }
            ),
            navigationDisabled: transferModel.isDeviceNavigationDisabled,
            filePromiseExporter: settings.showLocalPane ? nil : { entry, destination in
                try await transferModel.exportPromisedDeviceItem(
                    entry,
                    storageID: model.selectedStorageID,
                    to: destination
                )
            },
            dragWriter: settings.showLocalPane ? { entry in
                dragPasteboardWriter(for: entry, model: model)
            } : nil
        ) {
            DeviceStoragePickerView(
                model: model,
                navigationDisabled: transferModel.isDeviceNavigationDisabled
            )
        }
        .modifier(
            DeviceDropDestinationModifier(
                destinationName: model.currentLocation,
                accept: acceptFinderDrop,
                acceptLocalItems: acceptFinderDrop
            )
        )
        .onChange(
            of: transferModel.isDeviceNavigationDisabled,
            initial: true
        ) { _, disabled in
            model.setFileOperationsDisabled(disabled)
        }
        .onChange(of: model.selectedStorageID, initial: true) { _, storageID in
            transferModel.bindCopyQueue(storageID: storageID)
        }
    }

    /// The date-range action's own preconditions. Whether the *selection*
    /// contains a folder is decided by each surface, because the context menu
    /// acts on the right-clicked rows rather than the pane's stored selection.
    private func dateRangeAction(for model: DeviceBrowserViewModel) -> BrowserCopyAction {
        let isTransferring = transferModel.isDeviceNavigationDisabled
        let hasStorage = model.selectedStorageID != nil
        let reason: String? = if isTransferring {
            "Wait for the current copy to finish."
        } else if !hasStorage {
            "Select a storage volume first."
        } else {
            "Select one or more folders to scan."
        }
        return BrowserCopyAction(
            title: "Copy by Date Range…",
            systemImage: "calendar.badge.clock",
            isEnabled: hasStorage && !isTransferring,
            disabledReason: reason,
            perform: presentDateRangeCopy
        )
    }

    private func presentDateRangeCopy() {
        guard let model = controller.deviceModel,
              let storageID = model.selectedStorageID else { return }
        let roots = model.selectedEntries.filter(\.isDirectory).map(\.location)
        guard !roots.isEmpty else { return }

        // Mirrors `copyToComputer`: the local pane's folder when it is visible,
        // otherwise Downloads. The sheet shows the resolved path so the user is
        // never guessing where the files land.
        let destination = settings.showLocalPane
            ? transferModel.defaultDownloadDestination
            : URL.downloadsDirectory.path
        let scanner = DeviceFolderScanner { path, objectId, onProgress in
            try await model.listDirectoryForScan(
                path,
                objectId: objectId,
                storageID: storageID,
                onProgress: onProgress
            )
        }

        dateRangeCopy = DateRangeCopyViewModel(
            roots: roots,
            destination: destination,
            scanner: scanner
        ) { plan, selectedDestination in
            dateRangeCopy = nil
            Task {
                await transferModel.enqueueDateRangeCopy(
                    plan,
                    destination: selectedDestination,
                    storageID: storageID
                )
            }
        }
    }

    private func retry() {
        Task { await controller.retry() }
    }

    private func showConnectionHelp() {
        onboarding.show(page: .connect)
    }

    private func copyToComputer() {
        let destination = settings.showLocalPane ? nil : URL.downloadsDirectory.path
        Task { await transferModel.enqueueDownload(destination: destination) }
    }

    private func addSelectionToQueue(model: DeviceBrowserViewModel) {
        copySelection(model: model, replacing: false)
    }

    private func copySelection(model: DeviceBrowserViewModel, replacing: Bool) {
        guard let storageID = model.selectedStorageID,
              let storage = model.storages.first(where: { $0.id == storageID }) else { return }
        transferModel.copySelectionToQueue(from: .device, storage: storage, replacing: replacing)
    }

    private func acceptFinderDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        Task { await transferModel.enqueueDroppedFilesOnDevice(urls) }
        return true
    }

    private func dragPasteboardWriter(
        for entry: BrowserEntry,
        model: DeviceBrowserViewModel
    ) -> NSPasteboardWriting? {
        guard let storageID = model.selectedStorageID,
              let sessionID = controller.transferSessionID,
              let sources = dragSources(for: entry, model: model) else { return nil }
        return DeviceDragItemProvider.makePasteboardItem(
            sources: sources,
            storageID: storageID,
            sessionID: sessionID,
            sourceObjectIds: Dictionary(
                model.entries.compactMap { candidate in
                    guard sources.contains(candidate.location),
                          let objectId = candidate.objectId else { return nil }
                    return (candidate.location, objectId)
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    private func dragSources(
        for entry: BrowserEntry,
        model: DeviceBrowserViewModel
    ) -> [String]? {
        if model.selectedEntryIDs.contains(entry.id) {
            return model.entries.compactMap { candidate in
                model.selectedEntryIDs.contains(candidate.id) ? candidate.location : nil
            }
        }
        return [entry.location]
    }
}
