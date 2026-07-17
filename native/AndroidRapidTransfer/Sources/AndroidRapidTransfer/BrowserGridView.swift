import AndroidRapidTransferCore
import SwiftUI

struct BrowserGridView<Model: BrowserPaneModel>: View {
    @Bindable var model: Model
    let entries: [BrowserEntry]
    let location: String
    /// Same-folder changes (new folder, delete, search) animate item by item.
    let animatesChanges: Bool
    let highlight: BrowserEntryHighlight?
    let navigationDisabled: Bool
    let filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    let paneFocus: () -> Void
    let createFolder: () -> Void
    let rename: (Set<BrowserEntry.ID>) -> Void
    let delete: (Set<BrowserEntry.ID>) -> Void
    let showInfo: (Set<BrowserEntry.ID>) -> Void
    var clipboard: BrowserClipboardCommands = .unavailable

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                BrowserGridListing(
                    model: model,
                    entries: entries,
                    animatesChanges: animatesChanges,
                    highlight: highlight,
                    navigationDisabled: navigationDisabled,
                    filePromiseExporter: filePromiseExporter,
                    dragWriter: dragWriter,
                    copyAction: copyAction,
                    queueAction: queueAction,
                    dateRangeAction: dateRangeAction,
                    paneFocus: paneFocus,
                    createFolder: createFolder,
                    rename: rename,
                    delete: delete,
                    showInfo: showInfo,
                    clipboard: clipboard
                )
            }
            // A new folder (or the first listing) starts at the top with a
            // fresh cascade clock, instead of inheriting the old scroll offset.
            .id(GridListingIdentity(location: location, isEmpty: entries.isEmpty))
            // The same surface the list view draws on, so switching views
            // changes only the layout.
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: highlight) { _, highlight in
                guard let highlight else { return }
                withMotion(Motion.gentle) {
                    proxy.scrollTo(highlight.entryID)
                }
            }
        }
    }
}

private struct GridListingIdentity: Hashable {
    let location: String
    let isEmpty: Bool
}

private struct BrowserGridListing<Model: BrowserPaneModel>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: Model
    let entries: [BrowserEntry]
    let animatesChanges: Bool
    let highlight: BrowserEntryHighlight?
    let navigationDisabled: Bool
    let filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    let paneFocus: () -> Void
    let createFolder: () -> Void
    let rename: (Set<BrowserEntry.ID>) -> Void
    let delete: (Set<BrowserEntry.ID>) -> Void
    let showInfo: (Set<BrowserEntry.ID>) -> Void
    let clipboard: BrowserClipboardCommands
    /// When this listing arrived; items created shortly after cascade in.
    @State private var appearedAt = Date()

    var body: some View {
        let elapsed = Date().timeIntervalSince(appearedAt)
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                BrowserGridItem(
                    model: model,
                    entry: entry,
                    isSelected: model.selectedEntryIDs.contains(entry.id),
                    cascadeDelay: BrowserCascade.delay(
                        forIndex: index,
                        elapsedSinceListing: elapsed,
                        reduceMotion: reduceMotion
                    ),
                    popTrigger: highlight?.entryID == entry.id ? highlight?.revision : nil,
                    navigationDisabled: navigationDisabled,
                    filePromiseExporter: filePromiseExporter,
                    dragWriter: dragWriter,
                    paneFocus: paneFocus
                )
                .motionTransition(.scale(scale: 0.6).combined(with: .opacity))
                .contextMenu {
                    BrowserEntryContextMenu(
                        model: model,
                        selection: contextSelection(for: entry),
                        copyAction: copyAction,
                        queueAction: queueAction,
                        dateRangeAction: dateRangeAction,
                        operationsDisabled: navigationDisabled || model.fileOperationsDisabled,
                        createFolder: createFolder,
                        rename: rename,
                        delete: delete,
                        showInfo: showInfo,
                        clipboard: clipboard
                    )
                }
            }
        }
        .padding()
        .motion(animatesChanges ? Motion.snappy : nil, value: entries.map(\.id))
    }

    private func contextSelection(for entry: BrowserEntry) -> Set<BrowserEntry.ID> {
        model.selectedEntryIDs.contains(entry.id) ? model.selectedEntryIDs : [entry.id]
    }
}

/// One grid item: the cell, its hover state, and its entrance in the cascade.
private struct BrowserGridItem<Model: BrowserPaneModel>: View {
    let model: Model
    let entry: BrowserEntry
    let isSelected: Bool
    let cascadeDelay: TimeInterval?
    let popTrigger: Int?
    let navigationDisabled: Bool
    let filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    let paneFocus: () -> Void
    @State private var isHovered = false
    @State private var isRevealed: Bool

    init(
        model: Model,
        entry: BrowserEntry,
        isSelected: Bool,
        cascadeDelay: TimeInterval?,
        popTrigger: Int?,
        navigationDisabled: Bool,
        filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)?,
        dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?,
        paneFocus: @escaping () -> Void
    ) {
        self.model = model
        self.entry = entry
        self.isSelected = isSelected
        self.cascadeDelay = cascadeDelay
        self.popTrigger = popTrigger
        self.navigationDisabled = navigationDisabled
        self.filePromiseExporter = filePromiseExporter
        self.dragWriter = dragWriter
        self.paneFocus = paneFocus
        _isRevealed = State(initialValue: cascadeDelay == nil)
    }

    var body: some View {
        BrowserGridCell(
            entry: entry,
            isSelected: isSelected,
            isHovered: isHovered,
            popTrigger: popTrigger,
            select: {
                model.selectBrowserEntry(entry, modifiers: NSEvent.modifierFlags)
            },
            open: {
                model.openBrowserEntry(entry, navigationDisabled: navigationDisabled)
            }
        )
        .opacity(isRevealed ? 1 : 0)
        .scaleEffect(isRevealed ? 1 : 0.92)
        .offset(y: isRevealed ? 0 : 6)
        .modifier(
            BrowserCellMouseModifier(
                entry: entry,
                isSelected: isSelected,
                selectionCount: model.selectedEntryIDs.count,
                selectedEntriesProvider: { model.selectedEntries },
                paneFocus: paneFocus,
                select: { model.selectBrowserEntry(entry, modifiers: $0) },
                open: {
                    model.openBrowserEntry(entry, navigationDisabled: navigationDisabled)
                },
                exporter: filePromiseExporter,
                dragWriter: dragWriter,
                hoverChanged: { isHovered = $0 }
            )
        )
        .onAppear(perform: reveal)
    }

    private func reveal() {
        guard !isRevealed else { return }
        withMotion(Motion.snappy.delay(cascadeDelay ?? 0)) {
            isRevealed = true
        }
    }
}
