import AndroidRapidTransferCore
import SwiftUI

/// The "Resume Copies" window: saved batch copies newest first, each
/// inspectable file by file before any action, with resume, delete, and
/// clear-completed affordances.
struct ResumeCopiesView: View {
    let transferModel: TransferViewModel

    @State private var batches: [TransferBatchRecord] = []
    @State private var selectedBatchID: TransferBatchRecord.ID?
    @State private var hasLoaded = false
    @State private var isResuming = false

    var body: some View {
        NavigationSplitView {
            batchList
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let batch = selectedBatch {
                BatchDetailView(
                    batch: batch,
                    canResume: transferModel.canResumeBatch && !isResuming,
                    resume: { resume(batch) },
                    delete: { delete(batch) }
                )
            } else {
                ContentUnavailableView(
                    "No Saved Copy Selected",
                    systemImage: "square.and.arrow.down.on.square",
                    description: Text("Select a saved copy on the left to inspect its files.")
                )
            }
        }
        .task { await reload() }
        .toolbar {
            ToolbarItem {
                Button("Clear Completed", systemImage: "checkmark.circle.badge.xmark") {
                    clearCompleted()
                }
                .help("Remove every saved copy whose files all completed.")
                .disabled(!batches.contains { !$0.items.isEmpty && $0.resumableItems.isEmpty })
            }
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    @ViewBuilder
    private var batchList: some View {
        if hasLoaded, batches.isEmpty {
            ContentUnavailableView(
                "No Saved Copies",
                systemImage: "tray",
                description: Text("Copies from the phone are saved here as they start, so an interrupted one can pick up where it stopped.")
            )
        } else {
            List(batches, selection: $selectedBatchID) { batch in
                BatchRowView(batch: batch)
            }
            .motion(Motion.snappy, value: batches.map(\.id))
        }
    }

    private var selectedBatch: TransferBatchRecord? {
        batches.first { $0.id == selectedBatchID }
    }

    private func reload() async {
        guard let store = transferModel.batchStore else {
            hasLoaded = true
            return
        }
        batches = await store.loadAll()
        hasLoaded = true
        if let selectedBatchID, !batches.contains(where: { $0.id == selectedBatchID }) {
            self.selectedBatchID = nil
        }
    }

    private func resume(_ batch: TransferBatchRecord) {
        isResuming = true
        Task {
            _ = await transferModel.resumeBatch(batch)
            await reload()
            isResuming = false
        }
    }

    private func delete(_ batch: TransferBatchRecord) {
        Task {
            await transferModel.batchStore?.delete(batchID: batch.id)
            await reloadAnimated()
        }
    }

    private func clearCompleted() {
        Task {
            await transferModel.batchStore?.deleteFullyCompleted()
            await reloadAnimated()
        }
    }

    /// Reloads so removed batches slide out of the list instead of vanishing.
    private func reloadAnimated() async {
        guard let store = transferModel.batchStore else { return }
        let loaded = await store.loadAll()
        withMotion(Motion.snappy) {
            batches = loaded
            if let selectedBatchID, !loaded.contains(where: { $0.id == selectedBatchID }) {
                self.selectedBatchID = nil
            }
        }
    }
}

/// One saved batch in the sidebar: origin, relative age, destination, a
/// completion bar, and an at-a-glance status count line.
private struct BatchRowView: View {
    let batch: TransferBatchRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(batch.origin.displayLabel)
                    .bold()
                Spacer()
                Text(batch.createdAt, format: .relative(presentation: .named))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(batch.destinationRoot)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !batch.items.isEmpty {
                TransferProgressBar(
                    value: Double(batch.completedCount) / Double(batch.items.count),
                    tint: batch.failedCount > 0 ? .orange : .green,
                    height: 4
                )
                .accessibilityLabel("Completed files")
            }
            Text(countsSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    /// e.g. "142 files · 3 failed · 12 pending"; settled-only parts drop out.
    private var countsSummary: String {
        let total = batch.items.count
        var parts = [total == 1 ? "1 file" : "\(total) files"]
        if batch.failedCount > 0 {
            parts.append("\(batch.failedCount) failed")
        }
        if batch.pendingCount > 0 {
            parts.append("\(batch.pendingCount) pending")
        }
        if batch.failedCount == 0, batch.pendingCount == 0, total > 0 {
            parts.append("all completed")
        }
        return parts.joined(separator: " · ")
    }
}

/// Full item listing for one batch — the user inspects names, device paths,
/// sizes, and statuses here before committing to a resume.
private struct BatchDetailView: View {
    let batch: TransferBatchRecord
    let canResume: Bool
    let resume: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Table(batch.items) {
                TableColumn("Name") { item in
                    Text(item.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Path on Phone") { item in
                    Text(item.devicePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Size") { item in
                    Text(sizeText(item.size))
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Status") { item in
                    statusView(item.status)
                }
                .width(min: 90, ideal: 110)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(batch.origin.displayLabel)
                    .font(.headline)
                if let deviceLabel = batch.deviceLabel {
                    Text(deviceLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(batch.createdAt, format: .dateTime)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Destination: \(batch.destinationRoot)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("Delete Saved Copy", role: .destructive, action: delete)
            Spacer()
            Button("Resume Copying", action: resume)
                .keyboardShortcut(.defaultAction)
                .disabled(!canResume || batch.resumableItems.isEmpty)
                .help(resumeHelp)
        }
        .padding()
    }

    private var resumeHelp: String {
        if batch.resumableItems.isEmpty {
            return "Every file in this copy already arrived."
        }
        if !canResume {
            return "Connect your phone to resume copying."
        }
        let count = batch.resumableItems.count
        return count == 1
            ? "Copy the 1 pending or failed file again."
            : "Copy the \(count) pending or failed files again."
    }

    @ViewBuilder
    private func statusView(_ status: TransferBatchRecord.Item.Status) -> some View {
        switch status {
        case .pending:
            Label("Pending", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            // The stored message is the engine's; show the friendly reason
            // and keep the raw text in the tooltip.
            Label(
                TransferFailureDescription(fileFailureMessage: message, direction: .download).title,
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
            .help(message)
        }
    }

    private func sizeText(_ size: Int64?) -> String {
        guard let size else { return "—" }
        return size.formatted(.byteCount(style: .file))
    }
}
