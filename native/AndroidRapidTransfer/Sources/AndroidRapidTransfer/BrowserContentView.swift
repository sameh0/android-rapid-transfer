import AndroidRapidTransferCore
import SwiftUI

struct BrowserContentView<Model: BrowserPaneModel>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: Model
    let entries: [BrowserEntry]
    let searchText: String
    let navigationDisabled: Bool
    let filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    let clipboard: BrowserClipboardCommands
    let paneKind: BrowserPaneKind
    let focusCoordinator: PaneFocusCoordinator
    let highlight: BrowserEntryHighlight?
    let paneFocus: () -> Void
    let createFolder: () -> Void
    let rename: (Set<BrowserEntry.ID>) -> Void
    let delete: (Set<BrowserEntry.ID>) -> Void
    let showInfo: (Set<BrowserEntry.ID>) -> Void

    /// The folder the listing showed last time it was drawn. A render where
    /// this differs from the model's location is a folder switch, not a
    /// change within the folder.
    @State private var displayedLocation: String?
    /// Raised a moment after a load starts, so quick loads never flash an
    /// indicator.
    @State private var showsLoadingIndicator = false

    var body: some View {
        ZStack {
            listing
                .opacity(dimsListing ? 0.45 : 1)
                .motion(Motion.fade, value: dimsListing)
                .allowsHitTesting(!model.isLoading)
                .browserNavigationSlide(location: model.currentLocation, direction: direction)

            if showsSkeleton {
                BrowserSkeletonView(viewMode: model.viewMode)
                    .motionTransition(.opacity)
            } else if entries.isEmpty, model.hasLoaded, !model.isLoading {
                BrowserEmptyStateView(
                    kind: searchText.isEmpty ? .emptyFolder(paneKind) : .noResults(searchText)
                )
                .motionTransition(.scale(scale: 0.94).combined(with: .opacity))
            }

            if showsLoadingIndicator {
                BrowserLoadingIndicator(progress: model.loadingProgress)
                    .motionTransition(
                        .scale(scale: 0.9).combined(with: .opacity)
                    )
            }
        }
        // The navigation slide must not spill into the neighbouring pane.
        .clipped()
        .motion(Motion.fade, value: model.viewMode)
        .motion(Motion.snappy, value: showsLoadingIndicator)
        .motion(Motion.snappy, value: showsEmptyState)
        .task(id: model.isLoading) {
            await updateLoadingIndicator(isLoading: model.isLoading)
        }
        .onChange(of: model.currentLocation, initial: true) { _, location in
            displayedLocation = location
        }
    }

    @ViewBuilder
    private var listing: some View {
        switch model.viewMode {
        case .list:
            NativeBrowserTableView(
                model: model,
                entries: entries,
                location: model.currentLocation,
                animatesChanges: animatesChanges,
                highlight: highlight,
                navigationDisabled: navigationDisabled,
                filePromiseExporter: filePromiseExporter,
                dragWriter: dragWriter,
                copyAction: copyAction,
                queueAction: queueAction,
                dateRangeAction: dateRangeAction,
                paneKind: paneKind,
                focusCoordinator: focusCoordinator,
                createFolder: createFolder,
                rename: rename,
                delete: delete,
                showInfo: showInfo,
                clipboard: clipboard
            )
        case .grid:
            BrowserGridView(
                model: model,
                entries: entries,
                location: model.currentLocation,
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
    }

    private var direction: BrowserNavigationDirection {
        BrowserNavigationDirection.resolve(
            from: displayedLocation ?? model.currentLocation,
            to: model.currentLocation
        )
    }

    private var animatesChanges: Bool {
        BrowserListingAnimation.animatesChanges(
            displayedLocation: displayedLocation ?? "",
            location: model.currentLocation,
            itemCount: entries.count,
            reduceMotion: reduceMotion
        )
    }

    /// Placeholder rows stand in only before anything has been listed; a
    /// reload keeps the old listing on screen, dimmed.
    private var showsSkeleton: Bool {
        showsLoadingIndicator && !model.hasLoaded && entries.isEmpty
    }

    private var dimsListing: Bool {
        showsLoadingIndicator && !entries.isEmpty
    }

    private var showsEmptyState: Bool {
        entries.isEmpty && model.hasLoaded && !model.isLoading
    }

    private func updateLoadingIndicator(isLoading: Bool) async {
        guard isLoading else {
            showsLoadingIndicator = false
            return
        }
        try? await Task.sleep(for: BrowserLoadingIndicator.appearanceDelay)
        guard !Task.isCancelled else { return }
        showsLoadingIndicator = true
    }
}
