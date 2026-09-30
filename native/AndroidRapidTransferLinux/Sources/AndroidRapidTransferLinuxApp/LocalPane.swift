import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// Phone items being dragged inside the app (to the computer pane).
final class DeviceDragPayload {
    let sessionID: UUID
    let storageID: UInt32
    let sources: [String]
    let objectIds: [String: UInt32]

    init(sessionID: UUID, storageID: UInt32, sources: [String], objectIds: [String: UInt32]) {
        self.sessionID = sessionID
        self.storageID = storageID
        self.sources = sources
        self.objectIds = objectIds
    }

    static let mimeType = "application/x-android-rapid-transfer-device-items"
}

/// The computer side: a browser over ``LocalBrowserViewModel`` with the
/// favourites menu, copying to the phone and drops from the phone pane and
/// the file manager.
@MainActor
final class LocalPane {
    let model: LocalBrowserViewModel
    let pane: BrowserPane<LocalBrowserViewModel>
    private let transferModel: TransferViewModel
    /// True while a drag started in this pane, so dropping it back here is ignored.
    private var isDraggingOut = false

    var root: Widget { pane.root }

    init(model: LocalBrowserViewModel, transferModel: TransferViewModel, settings: AppSettings, services: any WindowServices) {
        self.model = model
        self.transferModel = transferModel
        let actions = PaneActions(
            copyTitle: "Copy to Phone",
            copyIcon: "go-next-symbolic",
            copyTooltip: "Copy the selected items to the phone’s open folder",
            canCopyToOther: { transferModel.canUpload },
            copyToOther: { Task { await transferModel.enqueueUpload() } },
            canAddToQueue: { true },
            addToQueue: { transferModel.copySelectionToQueue(from: .local, replacing: false) },
            canClipboardCopy: { true },
            clipboardCopy: { transferModel.copySelectionToQueue(from: .local, replacing: true) },
            canPaste: { transferModel.canPaste(into: .local) },
            paste: { Task { await transferModel.paste(into: .local) } },
            emptyMessage: "Drag items here from your phone to copy them to this computer.",
            trashLabel: "Move to Trash"
        )
        pane = BrowserPane(model: model, kind: .local, settings: settings, actions: actions,
                           services: services, accessory: Self.makeFavoritesMenu(model: model))
        installDragAndDrop()
    }

    private static func makeFavoritesMenu(model: LocalBrowserViewModel) -> Widget {
        let list = Box(.vertical, spacing: 2).margins(6)
        let popover = Popover(list)
        popover.css("menu", "favorites-popover")
        for favorite in model.favorites {
            let icon = Image(iconName: favorite.iconName)
            let label = Label(favorite.label).align(h: .start).expand(h: true)
            let check = Image(iconName: "object-select-symbolic")
            let button = Button(child: Box(.horizontal, spacing: 10, [icon, label, check])).css("flat")
            button.tooltip = favorite.path
            check.bind { $0.opacity = model.isCurrent(favorite) ? 1 : 0 }
            button.onClicked { [weak popover] in
                popover?.popdown()
                Task { await model.navigate(to: favorite) }
            }
            list.append(button)
        }
        let icon = Image(iconName: "computer-symbolic")
        let title = Label(model.title).css("heading")
        let face = Box(.horizontal, spacing: 8, [icon, title])
        let button = MenuButton(popover: popover)
        button.setChild(face)
        button.alwaysShowsArrow = true
        button.css("flat", "pane-title-button")
        button.tooltip = "Favorites"
        return button
    }

    private func installDragAndDrop() {
        let pane = pane
        let model = model
        let transferModel = transferModel

        // Drag rows out: to the phone pane, or to other apps as files.
        let drag = FileDragSource(actions: [.copy])
        drag.onPrepare { [weak self] x, y in
            let entries = pane.targetEntries(atX: x, y: y)
            guard !entries.isEmpty else { return nil }
            self?.isDraggingOut = true
            return entries.map(\.location)
        }
        drag.onDragEnd { [weak self] _ in self?.isDraggingOut = false }
        pane.contentArea.add(drag)

        // Files from the file manager.
        let fileDrop = FileDropTarget()
        fileDrop.onDrop { [weak self] paths, _, _ in
            guard let self, !self.isDraggingOut else { return false }
            let urls = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return false }
            Task { await transferModel.copyDroppedFilesOnLocalPane(urls) }
            return true
        }
        fileDrop.onHoverChanged { [weak self] hovering in
            pane.contentArea.setCSSClass("drop-active", hovering && self?.isDraggingOut == false)
        }
        pane.contentArea.add(fileDrop)

        // Phone items from the phone pane.
        let deviceDrop = InAppDropTarget(mimeType: DeviceDragPayload.mimeType)
        deviceDrop.onDrop { payload, _, _ in
            guard let payload = payload as? DeviceDragPayload,
                  payload.sessionID == transferModel.transferSessionID else { return false }
            Task {
                await transferModel.enqueueDroppedDeviceItems(
                    sources: payload.sources,
                    storageID: payload.storageID,
                    sourceObjectIds: payload.objectIds
                )
            }
            return true
        }
        deviceDrop.onHoverChanged { hovering in pane.contentArea.setCSSClass("drop-active", hovering) }
        pane.contentArea.add(deviceDrop)
        _ = model
    }
}
