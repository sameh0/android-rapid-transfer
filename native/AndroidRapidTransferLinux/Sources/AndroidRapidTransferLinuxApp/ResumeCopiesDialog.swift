import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// Resume Copies: saved batch copies that did not finish, each resumable
/// into its original folders once the phone is connected.
@MainActor
final class ResumeCopiesDialog {
    let dialog = Dialog(title: "Resume Copies", width: 640, height: 520)
    private let transferModel: TransferViewModel
    private let batchStore: TransferBatchStore
    private let list = ListBox()
    private let stack = Stack(transition: .crossfade, duration: Motion.Duration.quick)
    private let note = Label().css("caption", "dim-label")

    init(transferModel: TransferViewModel, batchStore: TransferBatchStore) {
        self.transferModel = transferModel
        self.batchStore = batchStore
        let toolbar = ToolbarView()
        let header = HeaderBar()
        let cleanup = Button("Remove Finished").css("flat")
        cleanup.tooltip = "Forget saved copies that completed"
        cleanup.onClicked { [weak self] in
            guard let self else { return }
            Task {
                await self.batchStore.deleteFullyCompleted()
                await self.reload()
            }
        }
        header.packStart(cleanup)
        toolbar.addTopBar(header)
        let empty = StatusPage(title: "No Copies to Resume",
                               description: "Copies that stop before they finish — because the phone was unplugged or went to sleep — appear here.",
                               iconName: "folder-download-symbolic")
        note.wraps = true
        note.align(h: .start)
        note.bind { $0.text = transferModel.canResumeBatch ? "Resuming copies what is missing into the original folders." : "Connect the phone to resume a copy." }
        let content = Box(.vertical, spacing: 12, [note, list]).margins(top: 12, bottom: 24, start: 18, end: 18)
        let scroller = ScrolledWindow(content)
        scroller.setPolicy(h: .never, v: .automatic)
        stack.add(empty, name: "empty")
        stack.add(scroller, name: "list")
        toolbar.content = stack
        dialog.child = toolbar
    }

    func present(parent: Widget?) {
        OpenDialogs.keep(self, while: dialog)
        dialog.present(parent: parent)
        Task { await reload() }
    }

    private func reload() async {
        let records = await batchStore.loadAll().filter { !$0.resumableItems.isEmpty }
        list.removeAll()
        stack.visibleChildName = records.isEmpty ? "empty" : "list"
        for record in records {
            let title = "\(record.origin.displayLabel) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))"
            var parts = ["\(record.completedCount) of \(record.items.count) copied"]
            if record.pendingCount > 0 { parts.append("\(record.pendingCount) not copied yet") }
            if record.failedCount > 0 { parts.append("\(record.failedCount) failed") }
            parts.append("to \(record.destinationRoot)")
            if let device = record.deviceLabel { parts.append("from \(device)") }
            let row = ActionRow(title: title, subtitle: parts.joined(separator: " · "))
            let resume = Button("Resume").css("suggested-action").align(v: .center)
            let transferModel = transferModel
            resume.bind { $0.isSensitive = transferModel.canResumeBatch }
            resume.onClicked { [weak self] in
                Task {
                    if await transferModel.resumeBatch(record) { self?.dialog.close() }
                }
            }
            let delete = Button(iconName: "user-trash-symbolic", tooltip: "Forget this copy").css("flat").align(v: .center)
            delete.onClicked { [weak self] in
                guard let self else { return }
                Task {
                    await self.batchStore.delete(batchID: record.id)
                    await self.reload()
                }
            }
            row.addSuffix(resume)
            row.addSuffix(delete)
            list.append(row)
        }
    }
}
