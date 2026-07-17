import AndroidRapidTransferCore
import SwiftUI

struct BrowserEntryContextMenu<Model: BrowserPaneModel>: View {
    @Bindable var model: Model
    let selection: Set<BrowserEntry.ID>
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    let operationsDisabled: Bool
    let createFolder: () -> Void
    let rename: (Set<BrowserEntry.ID>) -> Void
    let delete: (Set<BrowserEntry.ID>) -> Void
    let showInfo: (Set<BrowserEntry.ID>) -> Void
    var clipboard: BrowserClipboardCommands = .unavailable

    var body: some View {
        Button("New Folder", systemImage: "folder.badge.plus", action: createFolder)
            .disabled(operationsDisabled)
        Button("Rename", systemImage: "pencil") {
            rename(selection)
        }
        .disabled(operationsDisabled || selection.count != 1)
        Button("Delete", systemImage: "trash", role: .destructive) {
            delete(selection)
        }
        .disabled(operationsDisabled || selection.isEmpty)

        if copyAction != nil || queueAction != nil || dateRangeAction != nil {
            Divider()
        }
        if let copyAction {
            Button(
                copyAction.title,
                systemImage: copyAction.systemImage
            ) {
                model.selectedEntryIDs = selection
                copyAction.perform()
            }
            .disabled(operationsDisabled || selection.isEmpty || !copyAction.isEnabled)
        }
        if let queueAction {
            Button(
                queueAction.title,
                systemImage: queueAction.systemImage
            ) {
                model.selectedEntryIDs = selection
                queueAction.perform()
            }
            .disabled(operationsDisabled || selection.isEmpty || !queueAction.isEnabled)
        }

        clipboardItems

        if let dateRangeAction {
            Button(
                dateRangeAction.title,
                systemImage: dateRangeAction.systemImage
            ) {
                model.selectedEntryIDs = selection
                dateRangeAction.perform()
            }
            .disabled(operationsDisabled || !dateRangeAction.isEnabled || !selectionHasFolder)
            .help(dateRangeAction.disabledReason ?? "")
        }

        Divider()
        if model.supportsRevealInFinder {
            Button("Show in Finder", systemImage: "finder") {
                model.revealInFinder(selection)
            }
            .disabled(selection.isEmpty)
        }
        Button("Copy Path", systemImage: "doc.on.clipboard") {
            model.copyPaths(selection)
        }
        .disabled(selection.isEmpty)
        Button("Get Info", systemImage: "info.circle") {
            showInfo(selection)
        }
        .disabled(selection.count != 1)
    }

    /// Copy acts on the right-clicked rows; Paste targets the pane's folder.
    @ViewBuilder
    private var clipboardItems: some View {
        if clipboard.isCopyAvailable || clipboard.canPaste {
            Button("Copy", systemImage: "doc.on.doc") {
                model.selectedEntryIDs = selection
                clipboard.copy()
            }
            .disabled(selection.isEmpty || !clipboard.isCopyAvailable)
            Button("Paste", systemImage: "doc.on.clipboard", action: clipboard.paste)
                .disabled(!clipboard.canPaste)
        }
    }

    /// Gates the date-range action on the *right-clicked* selection rather than
    /// the pane's stored selection, so the item is honest when the user
    /// right-clicks a row that was not already selected.
    private var selectionHasFolder: Bool {
        model.entries.contains { $0.isDirectory && selection.contains($0.id) }
    }
}
