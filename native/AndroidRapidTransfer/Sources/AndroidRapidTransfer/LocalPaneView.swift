import AndroidRapidTransferCore
import SwiftUI

struct LocalPaneView: View {
    let model: LocalBrowserViewModel
    @Bindable var transferModel: TransferViewModel
    let settings: AppSettings
    let focusCoordinator: PaneFocusCoordinator

    var body: some View {
        BrowserPaneView(
            model: model,
            paneKind: .local,
            settings: settings,
            focusCoordinator: focusCoordinator,
            copyAction: BrowserCopyAction(
                title: "Copy to Phone",
                systemImage: "arrow.right",
                isEnabled: !model.selectedEntryIDs.isEmpty && transferModel.canUpload,
                perform: copyToPhone
            ),
            queueAction: BrowserCopyAction(
                title: "Add to Copy Queue",
                systemImage: "text.badge.plus",
                isEnabled: true,
                perform: { copySelection(replacing: false) }
            ),
            clipboardCopyAction: BrowserCopyAction(
                title: "Copy",
                systemImage: "doc.on.doc",
                isEnabled: true,
                perform: { copySelection(replacing: true) }
            ),
            pasteAction: BrowserCopyAction(
                title: "Paste",
                systemImage: "doc.on.clipboard",
                isEnabled: transferModel.canPaste(into: .local),
                perform: { Task { await transferModel.paste(into: .local) } }
            ),
            dragWriter: dragPasteboardWriter
        ) {
            LocalFavoritesMenu(model: model)
        }
        .modifier(
            BrowserDropDestinationModifier<DeviceDragPayload>(
                title: BrowserDropTitle(destination: model.currentLocation, rootName: "This Mac"),
                acceptFiles: acceptFinderDrop,
                acceptPayloads: acceptDeviceDrop
            )
        )
    }

    private func copyToPhone() {
        Task { await transferModel.enqueueUpload() }
    }

    private func copySelection(replacing: Bool) {
        transferModel.copySelectionToQueue(from: .local, replacing: replacing)
    }

    /// Dragging onto the device pane uploads, exactly like dropping from
    /// Finder. The whole selection travels in one payload item.
    private func dragPasteboardWriter(for entry: BrowserEntry) -> NSPasteboardWriting? {
        let paths = model.selectedEntryIDs.contains(entry.id)
            ? model.selectedEntries.map(\.location)
            : [entry.location]
        return LocalDragPayload.makePasteboardItem(paths: paths)
    }

    private func acceptFinderDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        Task { await transferModel.copyDroppedFilesOnLocalPane(urls) }
        return true
    }

    private func acceptDeviceDrop(_ payloads: [DeviceDragPayload]) -> Bool {
        guard let accepted = DeviceDragPayload.acceptedItems(
            from: payloads,
            activeSessionID: transferModel.transferSessionID
        ) else { return false }
        Task {
            await transferModel.enqueueDroppedDeviceItems(
                sources: accepted.sources,
                storageID: accepted.storageID,
                sourceObjectIds: accepted.sourceObjectIds
            )
        }
        return true
    }
}
