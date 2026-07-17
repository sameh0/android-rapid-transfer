import AndroidRapidTransferCore
import SwiftUI

struct BrowserToolbarView<Model: BrowserPaneModel>: View {
    @Bindable var model: Model
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    let navigationDisabled: Bool
    let createFolder: () -> Void
    @State private var refreshes = 0
    @State private var folderCreations = 0
    @State private var copies = 0
    @State private var queueAdds = 0

    var body: some View {
        HStack(spacing: 4) {
            Button("Back", systemImage: "chevron.left", action: goBack)
                .labelStyle(.iconOnly)
                .help("Go back to the previous folder")
                .disabled(!model.canGoBack || model.isLoading || navigationDisabled)
            Button("Up", systemImage: "arrow.up", action: goUp)
                .labelStyle(.iconOnly)
                .help("Go to the enclosing folder")
                .disabled(!model.canGoUp || model.isLoading || navigationDisabled)
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .help("Refresh this folder")
                .motionSpin(value: refreshes)
                .disabled(model.isLoading || navigationDisabled)
            Button("New Folder", systemImage: "folder.badge.plus") {
                folderCreations += 1
                createFolder()
            }
            .labelStyle(.iconOnly)
            .help("New folder")
            .motionBounce(value: folderCreations)
            .disabled(model.isLoading || model.fileOperationsDisabled || navigationDisabled)
            Button(
                model.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
                systemImage: model.showsHiddenFiles ? "eye.slash" : "eye"
            ) {
                toggleHiddenFiles()
            }
            .labelStyle(.iconOnly)
            .help(model.showsHiddenFiles ? "Hide hidden files" : "Show hidden files")
            .contentTransition(.symbolEffect(.replace))
            .disabled(model.isLoading || navigationDisabled)
            Picker("View", selection: $model.viewMode) {
                Label("List", systemImage: "list.bullet")
                    .tag(BrowserViewMode.list)
                Label("Grid", systemImage: "square.grid.2x2")
                    .tag(BrowserViewMode.grid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if copyAction != nil || queueAction != nil || dateRangeAction != nil {
                Divider()
                    .frame(height: 18)
            }
            if let copyAction {
                Button(copyAction.title, systemImage: copyAction.systemImage) {
                    copies += 1
                    copyAction.perform()
                }
                .motionBounce(value: copies)
                .disabled(!copyAction.isEnabled)
            }
            if let queueAction {
                Button(queueAction.title, systemImage: queueAction.systemImage) {
                    queueAdds += 1
                    queueAction.perform()
                }
                .motionBounce(value: queueAdds)
                .disabled(!queueAction.isEnabled || model.selectedEntryIDs.isEmpty)
                .help(
                    queueAction.isEnabled && !model.selectedEntryIDs.isEmpty
                        ? "Add the selected items to the copy queue, to copy them later in one go."
                        : "Select items on the phone to add them to the copy queue."
                )
            }
            if let dateRangeAction {
                Button(
                    dateRangeAction.title,
                    systemImage: dateRangeAction.systemImage,
                    action: dateRangeAction.perform
                )
                .labelStyle(.iconOnly)
                .disabled(!dateRangeAction.isEnabled || !selectionHasFolder)
                .help(dateRangeAction.isEnabled && selectionHasFolder
                    ? dateRangeAction.title
                    : dateRangeAction.disabledReason ?? dateRangeAction.title)
            }
            Spacer()
            if navigationDisabled {
                Label("Copying…", systemImage: "arrow.left.arrow.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .help("Browsing the phone is paused until the current copy finishes.")
                    .motionTransition(.move(edge: .trailing).combined(with: .opacity))
            }
            Text(model.displayLocation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.currentLocation)
        }
        .buttonStyle(.borderless)
        .motion(Motion.snappy, value: navigationDisabled)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var selectionHasFolder: Bool {
        model.selectedEntries.contains(where: \.isDirectory)
    }

    private func goBack() {
        Task { await model.goBack() }
    }

    private func goUp() {
        Task { await model.goUp() }
    }

    private func refresh() {
        refreshes += 1
        Task { await model.refresh() }
    }

    private func toggleHiddenFiles() {
        Task { await model.setShowsHiddenFiles(!model.showsHiddenFiles) }
    }
}
