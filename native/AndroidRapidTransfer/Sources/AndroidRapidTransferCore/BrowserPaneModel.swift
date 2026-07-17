import Foundation
import Observation

@MainActor
public protocol BrowserPaneModel: AnyObject, Observable {
    var title: String { get }
    var entries: [BrowserEntry] { get }
    var breadcrumbs: [BreadcrumbSegment] { get }
    var currentLocation: String { get }
    /// ``currentLocation`` as the toolbar shows it, e.g. with the home
    /// folder abbreviated to `~`.
    var displayLocation: String { get }
    var sortDescriptor: BrowserSortDescriptor { get }
    var tableSortOrder: [KeyPathComparator<BrowserEntry>] { get set }
    var selectedEntryIDs: Set<BrowserEntry.ID> { get set }
    var viewMode: BrowserViewMode { get set }
    var showsHiddenFiles: Bool { get }
    var capacity: BrowserCapacity? { get }
    var isLoading: Bool { get }
    /// What is being opened while ``isLoading``, for the loading indicator.
    var loadingProgress: BrowserLoadingProgress? { get }
    var hasLoaded: Bool { get }
    var error: BrowserPaneError? { get }
    var canGoBack: Bool { get }
    var canGoUp: Bool { get }
    var fileOperationsDisabled: Bool { get }

    func load() async
    func refresh() async
    func navigate(to entry: BrowserEntry) async
    func navigate(to breadcrumb: BreadcrumbSegment) async
    func goBack() async
    func goUp() async
    func setShowsHiddenFiles(_ showsHiddenFiles: Bool) async
    func selectEntry(id: BrowserEntry.ID, extending: Bool, toggling: Bool)
    func selectAll()
    func clearSelection()
    func moveSelection(by offset: Int, extending: Bool)
    func openSelection() async
    /// Opens one entry: folders are entered; what a file does is pane-specific.
    func openEntry(_ entry: BrowserEntry) async
    /// Whether entries in this pane exist on the Mac's filesystem, so Finder can reveal them.
    var supportsRevealInFinder: Bool { get }
    /// Finder-revealable URLs for the given entries, empty when the pane has none.
    func revealableURLs(for ids: Set<BrowserEntry.ID>) -> [URL]
    func filteredEntries(matching query: String) -> [BrowserEntry]
    func toggleSort(_ column: BrowserSortColumn)
    func dismissError()
    func suggestedNewFolderName() -> String
    func nameValidationMessage(_ name: String, renaming entry: BrowserEntry?) -> String?
    func makeDirectory(named name: String) async -> Bool
    func renameSelectedEntry(to name: String) async -> Bool
    func deleteSelectedEntries() async -> Bool
    func deletionConfirmation() -> FileDeletionConfirmation?
}

public extension BrowserPaneModel {
    var fileOperationsDisabled: Bool { false }

    var displayLocation: String { currentLocation }

    var loadingProgress: BrowserLoadingProgress? { nil }

    var selectedEntries: [BrowserEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }

    var supportsRevealInFinder: Bool { false }

    func revealableURLs(for ids: Set<BrowserEntry.ID>) -> [URL] { [] }

    func openEntry(_ entry: BrowserEntry) async {
        guard entry.isDirectory else { return }
        await navigate(to: entry)
    }

    /// The paths "Copy Path" places on the pasteboard, in listing order: an
    /// absolute POSIX path on the Mac, the device path string on the phone.
    func copyablePaths(for ids: Set<BrowserEntry.ID>) -> [String] {
        entries.filter { ids.contains($0.id) }.map(\.location)
    }

    var statusText: String {
        let itemSummary = "\(entries.count) items (\(selectedEntryIDs.count) selected)"
        guard let capacity else {
            return "\(itemSummary), free space unavailable"
        }
        return "\(itemSummary), free space \(capacity.formattedFreeBytes) of \(capacity.formattedTotalBytes)"
    }

    func suggestedNewFolderName() -> String {
        NewFolderNameSuggestion.availableName(existingNames: entries.map(\.name))
    }

    func filteredEntries(matching query: String) -> [BrowserEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(query) }
    }

    func nameValidationMessage(_ name: String, renaming entry: BrowserEntry?) -> String? {
        FileNameValidator.validationMessage(
            for: name,
            existingNames: entries.map(\.name),
            originalName: entry?.name
        )
    }

    func makeDirectory(named name: String) async -> Bool { false }
    func renameSelectedEntry(to name: String) async -> Bool { false }
    func deleteSelectedEntries() async -> Bool { false }
    func deletionConfirmation() -> FileDeletionConfirmation? { nil }
}
