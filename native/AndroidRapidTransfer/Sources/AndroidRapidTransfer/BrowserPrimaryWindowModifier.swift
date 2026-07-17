import AndroidRapidTransferCore
import SwiftUI

struct BrowserPrimaryWindowModifier<Model: BrowserPaneModel, Accessory: View>: ViewModifier {
    let isEnabled: Bool
    @Bindable var model: Model
    @Binding var searchText: String
    let navigationDisabled: Bool
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    let createFolder: () -> Void
    let accessory: Accessory
    @State private var refreshes = 0
    @State private var folderCreations = 0
    @State private var copies = 0
    @State private var queueAdds = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(
                    text: $searchText,
                    placement: .toolbar,
                    prompt: Text("Search Phone")
                )
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left", action: goBack)
                            .disabled(!model.canGoBack || model.isLoading || navigationDisabled)
                        Button("Up", systemImage: "arrow.up", action: goUp)
                            .disabled(!model.canGoUp || model.isLoading || navigationDisabled)
                        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                            .motionSpin(value: refreshes)
                            .disabled(model.isLoading || navigationDisabled)
                    }

                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            Text(model.title)
                                .bold()
                                .lineLimit(1)
                            accessory
                        }
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("New Folder", systemImage: "folder.badge.plus") {
                            folderCreations += 1
                            createFolder()
                        }
                        .motionBounce(value: folderCreations)
                        .disabled(
                            model.isLoading
                                || model.fileOperationsDisabled
                                || navigationDisabled
                        )

                        if let copyAction {
                            Button(copyAction.title, systemImage: "square.and.arrow.down") {
                                copies += 1
                                copyAction.perform()
                            }
                            .motionBounce(value: copies)
                            .disabled(!copyAction.isEnabled)
                            .help("Copy the selection to the Downloads folder")
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
                            .disabled(!dateRangeAction.isEnabled || !selectionHasFolder)
                            .help(dateRangeAction.isEnabled && selectionHasFolder
                                ? dateRangeAction.title
                                : dateRangeAction.disabledReason ?? dateRangeAction.title)
                        }

                        Picker("View", selection: $model.viewMode) {
                            Label("List", systemImage: "list.bullet")
                                .tag(BrowserViewMode.list)
                            Label("Grid", systemImage: "square.grid.2x2")
                                .tag(BrowserViewMode.grid)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
        } else {
            content
        }
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
}
