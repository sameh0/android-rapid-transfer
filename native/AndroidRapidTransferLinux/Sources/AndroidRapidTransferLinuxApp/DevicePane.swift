import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// What the device pane asks of the app (help and dialogs it opens).
@MainActor
protocol DevicePaneDelegate: AnyObject {
    func showConnectionHelp()
    func showTroubleshooting()
    func presentDateRangeCopy(model: DeviceBrowserViewModel)
}

/// The phone side: connection screens until a phone is ready, then a
/// browser over the session's ``DeviceBrowserViewModel``.
@MainActor
final class DevicePane {
    let root = Stack(transition: .crossfade, duration: Motion.Duration.standard)
    private let controller: DeviceConnectionController
    private let transferModel: TransferViewModel
    private let settings: AppSettings
    private weak var services: (any WindowServices)?
    private weak var delegate: (any DevicePaneDelegate)?
    private let stage: ConnectionStageView
    private let noticeBanner = Banner("", buttonLabel: "Dismiss")
    private(set) var browser: BrowserPane<DeviceBrowserViewModel>?
    private var browserModelID: ObjectIdentifier?
    private var announcedSessionID: UUID?
    private var lastKind: ConnectionPanePhase.Kind?
    private var wasReconnecting = false
    private let bag = ObserverBag()
    private var browserBag = ObserverBag()

    init(controller: DeviceConnectionController, transferModel: TransferViewModel, settings: AppSettings,
         services: any WindowServices, delegate: any DevicePaneDelegate) {
        self.controller = controller
        self.transferModel = transferModel
        self.settings = settings
        self.services = services
        self.delegate = delegate
        stage = ConnectionStageView(controller: controller)
        stage.onShowConnectionHelp = { [weak delegate] in delegate?.showConnectionHelp() }
        stage.onShowTroubleshooting = { [weak delegate] in delegate?.showTroubleshooting() }
        stage.parentWindow = { [weak services] in services?.window }

        let stagePage = Box(.vertical)
        noticeBanner.onButtonClicked { controller.dismissConnectionNotice() }
        stagePage.append(noticeBanner)
        stagePage.append(stage.root)
        root.add(stagePage, name: "stage")
        root.css("device-pane")
        root.expand(h: true, v: true)

        bag.onChange(initial: true, { [weak self] in self?.phase ?? .detecting }) { [weak self] phase in
            self?.phaseChanged(phase)
        }
        bag.onChange(initial: true, { controller.deviceModel.map(ObjectIdentifier.init) }) { [weak self] _ in
            self?.deviceModelChanged()
        }
        noticeBanner.bind { banner in
            if case let .waiting(notice?) = ConnectionPanePhase(controller: controller) {
                banner.title = notice
                banner.isRevealed = true
            } else {
                banner.isRevealed = false
            }
        }
    }

    var phase: ConnectionPanePhase { ConnectionPanePhase(controller: controller) }

    private func phaseChanged(_ phase: ConnectionPanePhase) {
        stage.show(phase)
        let showBrowser = phase == .connected && browser != nil
        root.visibleChildName = showBrowser ? "browser" : "stage"
        if phase.kind == .reconnecting { wasReconnecting = true }
        lastKind = phase.kind
    }

    private func deviceModelChanged() {
        guard let model = controller.deviceModel else {
            root.visibleChildName = "stage"
            if let old = root.child(named: "browser") { root.remove(old) }
            browser = nil
            browserModelID = nil
            browserBag = ObserverBag()
            phaseChanged(phase)
            return
        }
        guard browserModelID != ObjectIdentifier(model), let services else { return }
        if let old = root.child(named: "browser") { root.remove(old) }
        browserModelID = ObjectIdentifier(model)
        browserBag = ObserverBag()
        let pane = makeBrowser(model: model, services: services)
        browser = pane
        root.add(pane.root, name: "browser")
        phaseChanged(phase)
        let transferModel = transferModel
        browserBag.onChange(initial: true, { transferModel.isDeviceNavigationDisabled }) { disabled in
            model.setFileOperationsDisabled(disabled)
        }
        browserBag.onChange(initial: true, { model.selectedStorageID }) { storageID in
            transferModel.bindCopyQueue(storageID: storageID)
        }
        browserBag.onChange(initial: true, { model.hasLoaded && model.error == nil }) { [weak self] ready in
            if ready { self?.announceArrival(model: model) }
        }
    }

    private func announceArrival(model: DeviceBrowserViewModel) {
        guard let sessionID = controller.transferSessionID, announcedSessionID != sessionID else { return }
        announcedSessionID = sessionID
        let storage = model.storages.first { $0.id == model.selectedStorageID }
        let arrival = ConnectionArrival(deviceName: model.title, freeBytes: storage?.freeBytes, isReconnect: wasReconnecting)
        wasReconnecting = false
        let free = arrival.freeBytes.map { " · \(Format.bytes($0)) free" } ?? ""
        services?.toast(arrival.title + free)
    }

    private func makeBrowser(model: DeviceBrowserViewModel, services: any WindowServices) -> BrowserPane<DeviceBrowserViewModel> {
        let transferModel = transferModel
        let settings = settings
        let navigationDisabled = { transferModel.isDeviceNavigationDisabled }
        let hasStorage = { model.selectedStorageID != nil }
        weak let weakDelegate = delegate
        let actions = PaneActions(
            copyTitle: "Copy to Computer",
            copyIcon: "go-previous-symbolic",
            copyTooltip: "Copy the selected items to this computer",
            canCopyToOther: { hasStorage() && !navigationDisabled() },
            copyToOther: {
                let destination = settings.showLocalPane ? nil : DefaultDestinations.downloads
                Task { await transferModel.enqueueDownload(destination: destination) }
            },
            canAddToQueue: { transferModel.isTransferSessionAvailable && hasStorage() && !navigationDisabled() },
            addToQueue: { Self.copySelection(model: model, transferModel: transferModel, replacing: false) },
            canClipboardCopy: { transferModel.isTransferSessionAvailable && hasStorage() && !navigationDisabled() },
            clipboardCopy: { Self.copySelection(model: model, transferModel: transferModel, replacing: true) },
            canPaste: { transferModel.canPaste(into: .device) },
            paste: { Task { await transferModel.paste(into: .device) } },
            navigationDisabled: navigationDisabled,
            dateRange: { weakDelegate?.presentDateRangeCopy(model: model) },
            canDateRange: { hasStorage() && !navigationDisabled() },
            emptyMessage: "Drag files or folders here to copy them to your phone.",
            trashLabel: "Delete from Phone…",
            rootLabel: { model.storages.first { $0.id == model.selectedStorageID }?.name }
        )
        let picker = StoragePicker(model: model, navigationDisabled: navigationDisabled)
        let pane = BrowserPane(model: model, kind: .device, settings: settings, actions: actions,
                               services: services, accessory: picker.root)

        // Drag phone items to the computer pane.
        let controller = controller
        let drag = InAppDragSource(mimeType: DeviceDragPayload.mimeType)
        drag.onPrepare { x, y in
            let entries = pane.targetEntries(atX: x, y: y)
            guard !entries.isEmpty, !navigationDisabled(),
                  let storageID = model.selectedStorageID,
                  let sessionID = controller.transferSessionID else { return nil }
            var objectIds: [String: UInt32] = [:]
            for entry in entries { if let id = entry.objectId { objectIds[entry.location] = id } }
            return DeviceDragPayload(sessionID: sessionID, storageID: storageID,
                                     sources: entries.map(\.location), objectIds: objectIds)
        }
        pane.contentArea.add(drag)

        // Files from the computer pane or the file manager.
        let drop = FileDropTarget()
        drop.onDrop { paths, _, _ in
            let urls = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty, transferModel.isTransferSessionAvailable, model.selectedStorageID != nil else { return false }
            Task { await transferModel.enqueueDroppedFilesOnDevice(urls) }
            return true
        }
        drop.onHoverChanged { hovering in pane.contentArea.setCSSClass("drop-active", hovering) }
        pane.contentArea.add(drop)
        return pane
    }

    private static func copySelection(model: DeviceBrowserViewModel, transferModel: TransferViewModel, replacing: Bool) {
        guard let storageID = model.selectedStorageID,
              let storage = model.storages.first(where: { $0.id == storageID }) else { return }
        transferModel.copySelectionToQueue(from: .device, storage: storage, replacing: replacing)
    }
}

extension ConnectionPanePhase {
    @MainActor
    init(controller: DeviceConnectionController) {
        self.init(
            state: controller.state,
            isReconnecting: controller.isReconnecting,
            hasDeviceModel: controller.deviceModel != nil,
            notice: controller.connectionNotice,
            reconnectProgress: ConnectionReconnectProgress(controller: controller)
        )
    }
}

// MARK: - Storage picker

/// The storage switcher in the phone pane's header: the storage's name and
/// how full it is, opening a list of storages to switch between.
@MainActor
final class StoragePicker {
    let root: MenuButton
    private let model: DeviceBrowserViewModel

    init(model: DeviceBrowserViewModel, navigationDisabled: @escaping () -> Bool) {
        self.model = model
        let list = Box(.vertical, spacing: 6).margins(8)
        let heading = Label("Storage").css("heading").align(h: .start).margins(start: 4, end: 4)
        list.append(heading)
        let cards = Box(.vertical, spacing: 6)
        list.append(cards)
        let popover = Popover(list)
        popover.css("storage-popover")

        let icon = Image(iconName: "phone-symbolic")
        let name = Label("Storage").css("heading")
        name.ellipsis = .end
        name.maxWidthChars = 22
        let bar = LevelBar(offsets: [("normal", 0.9), ("nearly-full", 0.98), ("full", 1.0)]).sizeRequest(width: 56)
        bar.align(v: .center)
        let face = Box(.horizontal, spacing: 8, [icon, name, bar])
        root = MenuButton(popover: popover)
        root.setChild(face)
        root.css("flat", "pane-title-button")
        root.alwaysShowsArrow = true

        let deviceTitle = model.title
        face.bind { _ in
            let storage = model.storages.first { $0.id == model.selectedStorageID }
            name.text = storage?.name ?? deviceTitle
            icon.iconName = storage?.isRemovable == true ? "media-flash-symbolic" : "phone-symbolic"
            bar.isVisible = storage?.usedFraction != nil
            bar.value = storage?.usedFraction ?? 0
        }
        root.bind { button in
            let storage = model.storages.first { $0.id == model.selectedStorageID }
            button.tooltip = [deviceTitle, storage?.capacitySummary].compactMap { $0 }.joined(separator: " · ")
            // One storage: a plain title, not a greyed-out button.
            let switchable = model.storages.count > 1
            button.setProperty("can-target", switchable)
            button.canFocus = switchable
            button.isSensitive = !switchable || (!model.isLoading && !navigationDisabled())
            button.alwaysShowsArrow = model.storages.count > 1
        }
        cards.bind { box in
            box.removeAllChildren()
            for storage in model.storages {
                box.append(Self.card(storage, selected: storage.id == model.selectedStorageID) { [weak popover] in
                    popover?.popdown()
                    Task { await model.selectStorage(id: storage.id) }
                })
            }
        }
    }

    private static func card(_ storage: DeviceStorage, selected: Bool, action: @escaping @MainActor () -> Void) -> Widget {
        let icon = Image(iconName: storage.isRemovable ? "media-flash-symbolic" : "drive-harddisk-symbolic", pixelSize: 32)
        let name = Label(storage.name).css("heading").align(h: .start)
        let bar = LevelBar(offsets: [("normal", 0.9), ("nearly-full", 0.98), ("full", 1.0)])
        bar.value = storage.usedFraction ?? 0
        bar.isVisible = storage.usedFraction != nil
        let summary = Label(storage.capacitySummary ?? "Capacity unknown").css("caption", "dim-label", "numeric").align(h: .start)
        let text = Box(.vertical, spacing: 4, [name, bar, summary]).expand(h: true)
        let check = Image(iconName: "object-select-symbolic")
        check.opacity = selected ? 1 : 0
        let content = Box(.horizontal, spacing: 12, [icon, text, check]).margins(8)
        let button = Button(child: content).css("flat", "storage-card")
        if selected { button.addCSSClass("selected") }
        button.sizeRequest(width: 280)
        button.onClicked(action)
        return button
    }
}
