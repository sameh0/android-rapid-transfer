import Foundation
import Observation

@MainActor
@Observable
public final class LocalBrowserViewModel: BrowserPaneModel {
    public let title = "This Mac"
    public private(set) var entries: [BrowserEntry] = [] {
        didSet {
            selection.updateOrderedIDs(entries.map(\.id))
            filterCache.updateEntries(entries)
        }
    }
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: BrowserPaneError?
    public private(set) var sortDescriptor = BrowserSortDescriptor()
    public var viewMode: BrowserViewMode = .list
    public private(set) var showsHiddenFiles = false
    /// Groups folders ahead of files ("Show directories first").
    public private(set) var directoriesFirst = true
    public private(set) var capacity: BrowserCapacity?
    public var tableSortOrder = [KeyPathComparator(\BrowserEntry.name)] {
        didSet {
            entries = BrowserEntrySorter.sorted(
                entries,
                using: tableSortOrder,
                directoriesFirst: directoriesFirst
            )
        }
    }
    public var selectedEntryIDs: Set<BrowserEntry.ID> {
        get { selection.selectedIDs }
        set { selection.replaceSelection(with: newValue) }
    }

    /// Quick-access destinations offered by the pane's Favorites menu.
    public let favorites: [LocalFavorite]

    /// The navigation boundary. The app uses the filesystem root, so Up reaches
    /// `/`; tests confine the browser to a fixture directory.
    private let rootURL: URL
    private let reader: LocalDirectoryReader
    private let fileOperations: any LocalFileOperationService
    private let fileOpener: (any LocalFileOpening)?
    private var currentURL: URL
    private var history: [URL] = []
    private var loadGeneration = 0
    private var selection = BrowserSelectionState()
    @ObservationIgnored private var filterCache = BrowserEntryFilterCache()

    /// - Parameters:
    ///   - rootURL: How far Up and breadcrumbs may climb.
    ///   - startURL: Where the pane opens. A start outside `rootURL` falls back
    ///     to `rootURL` itself.
    ///   - fileOpener: Opens local files with their default application. `nil`
    ///     makes opening a file a no-op.
    public init(
        rootURL: URL = URL(fileURLWithPath: "/"),
        startURL: URL = .homeDirectory,
        favorites: [LocalFavorite] = LocalFavorite.standard,
        fileOperations: any LocalFileOperationService = FileManagerLocalFileOperationService(),
        fileOpener: (any LocalFileOpening)? = nil,
        viewMode: BrowserViewMode = .list,
        showsHiddenFiles: Bool = false,
        directoriesFirst: Bool = true
    ) {
        let normalizedRoot = rootURL.standardizedFileURL
        let normalizedStart = startURL.standardizedFileURL
        self.rootURL = normalizedRoot
        currentURL = Self.isWithin(normalizedStart, root: normalizedRoot)
            ? normalizedStart
            : normalizedRoot
        self.favorites = favorites
        reader = LocalDirectoryReader()
        self.fileOperations = fileOperations
        self.fileOpener = fileOpener
        self.viewMode = viewMode
        self.showsHiddenFiles = showsHiddenFiles
        self.directoriesFirst = directoriesFirst
    }

    public var currentLocation: String {
        currentURL.path
    }

    /// The path with the home folder shown as `~`, as Finder's Go menu does.
    public var displayLocation: String {
        (currentURL.path as NSString).abbreviatingWithTildeInPath
    }

    public let supportsRevealInFinder = true

    public func revealableURLs(for ids: Set<BrowserEntry.ID>) -> [URL] {
        entries.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.location) }
    }

    public func isCurrent(_ favorite: LocalFavorite) -> Bool {
        favorite.path == currentURL.path
    }

    public func navigate(to favorite: LocalFavorite) async {
        guard !isCurrent(favorite) else { return }
        await navigate(toPath: favorite.path, addingCurrentToHistory: true)
    }

    public var breadcrumbs: [BreadcrumbSegment] {
        let rootLabel = if rootURL.path == "/" {
            "Root"
        } else if rootURL == .homeDirectory {
            "Home"
        } else {
            rootURL.lastPathComponent
        }
        var segments = [
            BreadcrumbSegment(id: rootURL.path, label: rootLabel, location: rootURL.path)
        ]
        guard currentURL.path != rootURL.path else { return segments }

        let relativePath = currentURL.path.dropFirst(rootURL.path.count)
        var accumulated = rootURL
        for component in relativePath.split(separator: "/") {
            accumulated.append(path: String(component))
            segments.append(
                BreadcrumbSegment(
                    id: accumulated.path,
                    label: String(component),
                    location: accumulated.path
                )
            )
        }
        return segments
    }

    public var canGoBack: Bool {
        !history.isEmpty
    }

    public var canGoUp: Bool {
        currentURL.path != rootURL.path
    }

    public func load() async {
        await loadDirectory(currentURL, addingCurrentToHistory: false, clearsSelection: true)
    }

    public func refresh() async {
        await loadDirectory(currentURL, addingCurrentToHistory: false, clearsSelection: false)
    }

    public func navigate(to entry: BrowserEntry) async {
        guard entry.isDirectory else { return }
        await navigate(toPath: entry.location, addingCurrentToHistory: true)
    }

    public func navigate(to breadcrumb: BreadcrumbSegment) async {
        guard breadcrumb.location != currentURL.path else { return }
        await navigate(toPath: breadcrumb.location, addingCurrentToHistory: true)
    }

    public func goBack() async {
        guard let destination = history.last else { return }
        history.removeLast()
        let previousLocation = currentURL
        let succeeded = await loadDirectory(
            destination,
            addingCurrentToHistory: false,
            clearsSelection: true
        )
        if !succeeded {
            history.append(destination)
            currentURL = previousLocation
        }
    }

    public func goUp() async {
        guard canGoUp else { return }
        let parent = currentURL.deletingLastPathComponent().standardizedFileURL
        await loadDirectory(parent, addingCurrentToHistory: true, clearsSelection: true)
    }

    public func setShowsHiddenFiles(_ showsHiddenFiles: Bool) async {
        guard self.showsHiddenFiles != showsHiddenFiles else { return }
        self.showsHiddenFiles = showsHiddenFiles
        await loadDirectory(currentURL, addingCurrentToHistory: false, clearsSelection: false)
    }

    public func setDirectoriesFirst(_ directoriesFirst: Bool) {
        guard self.directoriesFirst != directoriesFirst else { return }
        self.directoriesFirst = directoriesFirst
        entries = BrowserEntrySorter.sorted(
            entries,
            using: tableSortOrder,
            directoriesFirst: directoriesFirst
        )
    }

    public func selectEntry(id: BrowserEntry.ID, extending: Bool, toggling: Bool) {
        selection.select(
            id,
            extending: extending,
            toggling: toggling
        )
    }

    public func selectAll() {
        selection.selectAll()
    }

    public func clearSelection() {
        selection.clear()
    }

    public func moveSelection(by offset: Int, extending: Bool) {
        selection.move(by: offset, extending: extending)
    }

    public func filteredEntries(matching query: String) -> [BrowserEntry] {
        filterCache.entries(matching: query)
    }

    public func openSelection() async {
        guard selectedEntryIDs.count == 1,
              let selectedID = selectedEntryIDs.first,
              let entry = entries.first(where: { $0.id == selectedID }) else {
            return
        }
        await openEntry(entry)
    }

    /// Folders open in place; files open in their default application.
    public func openEntry(_ entry: BrowserEntry) async {
        guard !entry.isDirectory else {
            await navigate(to: entry)
            return
        }
        fileOpener?.open(URL(fileURLWithPath: entry.location))
    }

    public func toggleSort(_ column: BrowserSortColumn) {
        sortDescriptor.toggle(column)
        entries = BrowserEntrySorter.sorted(
            entries,
            by: sortDescriptor,
            directoriesFirst: directoriesFirst
        )
        tableSortOrder = Self.comparators(for: sortDescriptor)
    }

    public func dismissError() {
        error = nil
    }

    public func makeDirectory(named name: String) async -> Bool {
        guard !isLoading,
              let destination = validatedDestination(for: name, renaming: nil) else {
            return false
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await fileOperations.createDirectory(at: destination)
            await refresh()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func renameSelectedEntry(to name: String) async -> Bool {
        guard !isLoading, selectedEntries.count == 1, let entry = selectedEntries.first else {
            return false
        }
        guard name != entry.name else { return true }
        guard let destination = validatedDestination(for: name, renaming: entry) else {
            return false
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await fileOperations.renameItem(
                at: URL(fileURLWithPath: entry.location),
                to: destination
            )
            await refresh()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func deleteSelectedEntries() async -> Bool {
        let entriesToDelete = selectedEntries
        guard !isLoading, !entriesToDelete.isEmpty else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            for entry in entriesToDelete {
                try await fileOperations.trashItem(at: URL(fileURLWithPath: entry.location))
            }
            await refresh()
            return true
        } catch {
            present(error)
            await refresh()
            return false
        }
    }

    public func deletionConfirmation() -> FileDeletionConfirmation? {
        let names = selectedEntries.map(\.name)
        guard !names.isEmpty else { return nil }
        return FileDeletionConfirmation(destination: .trash, names: names)
    }

    private func navigate(toPath path: String, addingCurrentToHistory: Bool) async {
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        guard isWithinRoot(destination) else {
            error = BrowserPaneError(message: "The selected folder is outside the browser root.")
            return
        }
        await loadDirectory(
            destination,
            addingCurrentToHistory: addingCurrentToHistory,
            clearsSelection: true
        )
    }

    @discardableResult
    private func loadDirectory(
        _ destination: URL,
        addingCurrentToHistory: Bool,
        clearsSelection: Bool
    ) async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                hasLoaded = true
            }
        }

        do {
            let snapshot = try await reader.snapshot(
                at: destination,
                showsHiddenFiles: showsHiddenFiles
            )
            guard generation == loadGeneration else { return false }
            if addingCurrentToHistory, destination != currentURL {
                history.append(currentURL)
            }
            currentURL = destination
            entries = BrowserEntrySorter.sorted(
                snapshot.entries,
                by: sortDescriptor,
                directoriesFirst: directoriesFirst
            )
            capacity = snapshot.capacity
            if clearsSelection {
                selection.clear()
            }
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            self.error = BrowserPaneError(message: ErrorDescription.message(for: error))
            return false
        }
    }

    private func isWithinRoot(_ url: URL) -> Bool {
        Self.isWithin(url, root: rootURL)
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = url.path
        // "/" + "/" would be "//", which no standardized path starts with.
        guard rootPath != "/" else { return candidatePath.hasPrefix("/") }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func validatedDestination(
        for name: String,
        renaming entry: BrowserEntry?
    ) -> URL? {
        // The listing hides dot-files unless the user shows them, so collisions
        // are checked against the directory on disk, not the visible entries —
        // otherwise a hidden sibling reaches the filesystem as a raw error.
        let existingNames = (try? FileManager.default.contentsOfDirectory(
            atPath: currentURL.path
        )) ?? entries.map(\.name)
        if let validationMessage = FileNameValidator.validationMessage(
            for: name,
            existingNames: existingNames,
            originalName: entry?.name
        ) {
            error = BrowserPaneError(message: validationMessage)
            return nil
        }
        return currentURL.appending(path: name)
    }

    private func present(_ error: any Error) {
        self.error = BrowserPaneError(message: ErrorDescription.message(for: error))
    }

    private static func comparators(
        for descriptor: BrowserSortDescriptor
    ) -> [KeyPathComparator<BrowserEntry>] {
        let order: SortOrder = descriptor.direction == .ascending ? .forward : .reverse
        return switch descriptor.column {
        case .name:
            [KeyPathComparator(\BrowserEntry.name, order: order)]
        case .size:
            [KeyPathComparator(\BrowserEntry.sortableSize, order: order)]
        case .modified:
            [KeyPathComparator(\BrowserEntry.sortableModifiedDate, order: order)]
        }
    }
}
