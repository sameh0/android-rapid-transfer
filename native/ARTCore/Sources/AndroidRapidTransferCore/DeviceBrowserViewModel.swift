import Foundation
import MTPKit
import Observation

@MainActor
@Observable
public final class DeviceBrowserViewModel: DeviceTransferPaneModel {
    public private(set) var title = "Android Phone"
    public private(set) var entries: [BrowserEntry] = [] {
        didSet {
            selection.updateOrderedIDs(entries.map(\.id))
            filterCache.updateEntries(entries)
        }
    }
    public private(set) var storages: [DeviceStorage] = []
    public private(set) var isLoading = false
    public private(set) var loadingProgress: BrowserLoadingProgress?
    public private(set) var hasLoaded = false
    public private(set) var error: BrowserPaneError?
    public private(set) var sortDescriptor = BrowserSortDescriptor()
    public var viewMode: BrowserViewMode = .list
    public private(set) var showsHiddenFiles = false
    /// Groups folders ahead of files ("Show directories first").
    public private(set) var directoriesFirst = true
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
    public private(set) var selectedStorageID: UInt32?
    public private(set) var fileOperationsDisabled = false

    private let provider: any MTPDeviceProvider
    /// Where the first load should try to open, consumed by that load. Used to
    /// put the user back where they were after the same phone reconnects.
    @ObservationIgnored private var pendingInitialLocation: DeviceBrowserLocation?
    private var currentPath = "/"
    private var history: [String] = []
    private var loadGeneration = 0
    /// The folder load in flight, if any. A refresh that lands while it is
    /// still walking re-reads *its* destination: walking `currentPath` instead
    /// would supersede the navigation and silently keep the old folder.
    @ObservationIgnored private var pendingLoad: PendingDirectoryLoad?
    private var selection = BrowserSelectionState()
    @ObservationIgnored private var filterCache = BrowserEntryFilterCache()

    public init(
        provider: any MTPDeviceProvider,
        viewMode: BrowserViewMode = .list,
        showsHiddenFiles: Bool = false,
        directoriesFirst: Bool = true,
        initialLocation: DeviceBrowserLocation? = nil
    ) {
        self.provider = provider
        self.viewMode = viewMode
        self.showsHiddenFiles = showsHiddenFiles
        self.directoriesFirst = directoriesFirst
        pendingInitialLocation = initialLocation
    }

    public var currentLocation: String {
        currentPath
    }

    public var capacity: BrowserCapacity? {
        guard let storage = storages.first(where: { $0.id == selectedStorageID }),
              let freeBytes = storage.freeBytes,
              let totalBytes = storage.totalBytes else {
            return nil
        }
        return BrowserCapacity(freeBytes: freeBytes, totalBytes: totalBytes)
    }

    public var breadcrumbs: [BreadcrumbSegment] {
        var segments = [BreadcrumbSegment(id: "/", label: "Device", location: "/")]
        var path = ""
        for component in currentPath.split(separator: "/") {
            path += "/\(component)"
            segments.append(
                BreadcrumbSegment(id: path, label: String(component), location: path)
            )
        }
        return segments
    }

    public var canGoBack: Bool {
        !history.isEmpty
    }

    public var canGoUp: Bool {
        currentPath != "/"
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                loadingProgress = nil
                hasLoaded = true
            }
        }

        do {
            async let deviceInfoRequest = provider.deviceInfo()
            async let storagesRequest = provider.storages()
            let (deviceInfo, rawStorages) = try await (deviceInfoRequest, storagesRequest)
            let availableStorages = rawStorages.enumerated().map {
                DeviceStorage(storage: $0.element, index: $0.offset)
            }
            guard let firstStorage = availableStorages.first else {
                throw DeviceBrowserError.noUsableStorage
            }
            let restore = pendingInitialLocation
            pendingInitialLocation = nil
            var targetStorageID = firstStorage.id
            var targetPath = "/"
            var restoredEntries: [BrowserEntry]?
            if let restore,
               availableStorages.contains(where: { $0.id == restore.storageID }) {
                // Best effort: a folder that no longer exists, or any other
                // failure, falls back to the storage root below.
                if let entries = try? await walkReportingProgress(
                    path: restore.path,
                    storageID: restore.storageID,
                    generation: generation
                ) {
                    restoredEntries = entries
                    targetStorageID = restore.storageID
                    targetPath = restore.path
                }
            }
            let loadedEntries: [BrowserEntry]
            if let restoredEntries {
                loadedEntries = restoredEntries
            } else {
                loadedEntries = try await walkReportingProgress(
                    path: "/",
                    storageID: firstStorage.id,
                    generation: generation
                )
            }
            guard generation == loadGeneration else { return }

            title = Self.deviceName(from: deviceInfo) ?? "Android Phone"
            storages = availableStorages
            selectedStorageID = targetStorageID
            currentPath = targetPath
            history = []
            selection.clear()
            entries = BrowserEntrySorter.sorted(
                loadedEntries,
                by: sortDescriptor,
                directoriesFirst: directoriesFirst
            )
        } catch {
            guard generation == loadGeneration else { return }
            entries = []
            selection.clear()
            self.error = BrowserPaneError(message: ErrorDescription.message(for: error))
        }
    }

    public func refresh() async {
        guard selectedStorageID != nil else {
            await load()
            return
        }
        await reloadLatestDestination()
    }

    public func navigate(to entry: BrowserEntry) async {
        guard entry.isDirectory, let selectedStorageID else { return }
        await loadDirectory(
            entry.location,
            storageID: selectedStorageID,
            addingCurrentToHistory: true,
            clearsSelection: true
        )
    }

    public func navigate(to breadcrumb: BreadcrumbSegment) async {
        guard breadcrumb.location != currentPath, let selectedStorageID else { return }
        await loadDirectory(
            breadcrumb.location,
            storageID: selectedStorageID,
            addingCurrentToHistory: true,
            clearsSelection: true
        )
    }

    public func goBack() async {
        guard let selectedStorageID, let destination = history.last else { return }
        history.removeLast()
        let result = await loadDirectory(
            destination,
            storageID: selectedStorageID,
            addingCurrentToHistory: false,
            clearsSelection: true
        )
        if case .failed = result {
            history.append(destination)
        }
    }

    public func goUp() async {
        guard canGoUp, let selectedStorageID else { return }
        let parent = Self.parentPath(of: currentPath)
        await loadDirectory(
            parent,
            storageID: selectedStorageID,
            addingCurrentToHistory: true,
            clearsSelection: true
        )
    }

    public func selectStorage(id: UInt32) async {
        guard storages.contains(where: { $0.id == id }), id != selectedStorageID else { return }
        let previousState = StorageSelectionSnapshot(
            storageID: selectedStorageID,
            path: currentPath,
            history: history,
            entries: entries,
            selection: selection
        )
        let result = await loadDirectory(
            "/",
            storageID: id,
            addingCurrentToHistory: false,
            clearsSelection: true
        )
        switch result {
        case .loaded:
            selectedStorageID = id
            history = []
        case let .failed(generation) where generation == loadGeneration:
            selectedStorageID = previousState.storageID
            currentPath = previousState.path
            history = previousState.history
            entries = previousState.entries
            selection = previousState.selection
        case .failed, .superseded:
            break
        }
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

    public func setShowsHiddenFiles(_ showsHiddenFiles: Bool) async {
        guard self.showsHiddenFiles != showsHiddenFiles else { return }
        self.showsHiddenFiles = showsHiddenFiles
        guard selectedStorageID != nil else { return }
        await reloadLatestDestination()
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
              let entry = entries.first(where: { $0.id == selectedID }),
              entry.isDirectory else {
            return
        }
        await navigate(to: entry)
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

    public func setFileOperationsDisabled(_ disabled: Bool) {
        fileOperationsDisabled = disabled
    }

    public func makeDirectory(named name: String) async -> Bool {
        guard canStartFileOperation, let storageID = selectedStorageID else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let siblings = try await siblingsForValidation(storageID: storageID)
            guard validate(name, siblings: siblings, renaming: nil) else { return false }
            let succeeded = try await provider.makeDirectory(
                input: MakeDirectoryInput(
                    storageId: storageID,
                    fullPath: Self.childPath(parent: currentPath, name: name)
                )
            )
            guard succeeded else {
                throw DeviceBrowserError.operationFailed("The phone didn’t create the folder.")
            }
            await refresh()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func renameSelectedEntry(to name: String) async -> Bool {
        guard canStartFileOperation,
              let storageID = selectedStorageID,
              selectedEntries.count == 1,
              let entry = selectedEntries.first else {
            return false
        }
        guard name != entry.name else { return true }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let siblings = try await siblingsForValidation(storageID: storageID)
            guard validate(name, siblings: siblings, renaming: entry) else { return false }
            let succeeded = try await provider.renameFile(
                input: RenameFileInput(
                    storageId: storageID,
                    fullPath: entry.location,
                    newFileName: name
                )
            )
            guard succeeded else {
                throw DeviceBrowserError.operationFailed("The phone didn’t rename the item.")
            }
            await refresh()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func deleteSelectedEntries() async -> Bool {
        let entriesToDelete = selectedEntries
        guard canStartFileOperation,
              let storageID = selectedStorageID,
              !entriesToDelete.isEmpty else {
            return false
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let succeeded = try await provider.deleteFiles(
                input: DeleteFileInput(
                    storageId: storageID,
                    files: entriesToDelete.map(\.location)
                )
            )
            guard succeeded else {
                throw DeviceBrowserError.operationFailed("The phone didn’t delete the items.")
            }
            await refresh()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func deletionConfirmation() -> FileDeletionConfirmation? {
        let names = selectedEntries.map(\.name)
        guard !names.isEmpty else { return nil }
        return FileDeletionConfirmation(destination: .device, names: names)
    }

    public func existingPaths(_ paths: [String], storageID: UInt32) async throws -> Set<String> {
        let results = try await provider.fileExists(
            input: FileExistsInput(storageId: storageID, files: paths)
        )
        return Set(results.lazy.filter(\.exists).map { Self.normalizeDevicePath($0.fullpath) })
    }

    /// Lists `path` straight from the device, bypassing ``loadDirectory`` so a
    /// background scan cannot move the pane the user is looking at.
    /// Scan exclusions must not depend on the browser's hidden-files toggle;
    /// ``ScanExclusionRules`` is the only authority on scan exclusions.
    public func listDirectoryForScan(
        _ path: String,
        objectId: UInt32? = nil,
        storageID: UInt32,
        onProgress: (@Sendable (WalkProgress) -> Void)? = nil
    ) async throws -> [BrowserEntry] {
        try await walk(
            path: path,
            objectId: objectId,
            storageID: storageID,
            skipHiddenFiles: false,
            onProgress: onProgress
        )
    }

    /// Reloads the folder the pane is showing or, while a navigation (or a
    /// storage switch) is still walking, the folder it is going to, keeping
    /// that navigation's history and selection behaviour.
    private func reloadLatestDestination() async {
        if let pendingLoad {
            await loadDirectory(
                pendingLoad.path,
                storageID: pendingLoad.storageID,
                addingCurrentToHistory: pendingLoad.addingCurrentToHistory,
                clearsSelection: pendingLoad.clearsSelection
            )
        } else if let selectedStorageID {
            await loadDirectory(
                currentPath,
                storageID: selectedStorageID,
                addingCurrentToHistory: false,
                clearsSelection: false
            )
        }
    }

    @discardableResult
    private func loadDirectory(
        _ destination: String,
        storageID: UInt32,
        addingCurrentToHistory: Bool,
        clearsSelection: Bool
    ) async -> DirectoryLoadResult {
        loadGeneration += 1
        let generation = loadGeneration
        pendingLoad = PendingDirectoryLoad(
            path: destination,
            storageID: storageID,
            addingCurrentToHistory: addingCurrentToHistory,
            clearsSelection: clearsSelection
        )
        isLoading = true
        error = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                loadingProgress = nil
                hasLoaded = true
                pendingLoad = nil
            }
        }

        do {
            let loadedEntries = try await walkReportingProgress(
                path: destination,
                storageID: storageID,
                generation: generation
            )
            guard generation == loadGeneration else { return .superseded }
            if storageID != selectedStorageID {
                // A storage switch (possibly carried on by a refresh that
                // superseded it) starts that storage's history afresh.
                selectedStorageID = storageID
                history = []
            }
            if addingCurrentToHistory, destination != currentPath {
                history.append(currentPath)
            }
            currentPath = destination
            entries = BrowserEntrySorter.sorted(
                loadedEntries,
                by: sortDescriptor,
                directoriesFirst: directoriesFirst
            )
            if clearsSelection {
                selection.clear()
            }
            return .loaded
        } catch {
            guard generation == loadGeneration else { return .superseded }
            entries = []
            selection.clear()
            self.error = BrowserPaneError(message: ErrorDescription.message(for: error))
            return .failed(generation: generation)
        }
    }

    private func walk(
        path: String,
        objectId: UInt32? = nil,
        storageID: UInt32,
        skipHiddenFiles: Bool,
        onProgress: (@Sendable (WalkProgress) -> Void)? = nil
    ) async throws -> [BrowserEntry] {
        let input = DirectoryWalkInput(
            storageId: storageID, fullPath: path, objectId: objectId,
            skipDisallowedFiles: true, skipHiddenFiles: skipHiddenFiles
        )
        let walkEntries: [WalkEntry]
        if let onProgress {
            walkEntries = try await provider.walk(input: input, onProgress: onProgress)
        } else {
            walkEntries = try await provider.walk(input: input)
        }
        return walkEntries.map { BrowserEntry(walkEntry: $0) }
    }

    /// A browsing walk that feeds ``loadingProgress``. The device reports on
    /// its own thread; reports from a superseded or finished load are dropped.
    private func walkReportingProgress(
        path: String,
        storageID: UInt32,
        generation: Int
    ) async throws -> [BrowserEntry] {
        loadingProgress = BrowserLoadingProgress(path: path)
        return try await walk(
            path: path,
            storageID: storageID,
            skipHiddenFiles: !showsHiddenFiles
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.applyLoadingProgress(progress, generation: generation)
            }
        }
    }

    private func applyLoadingProgress(_ progress: WalkProgress, generation: Int) {
        guard generation == loadGeneration,
              let current = loadingProgress,
              current.path == progress.fullPath else { return }
        loadingProgress = BrowserLoadingProgress(
            path: current.path,
            itemCount: progress.itemCount,
            fractionCompleted: progress.fractionCompleted
        )
    }

    private func siblingsForValidation(storageID: UInt32) async throws -> [BrowserEntry] {
        let walkEntries = try await provider.walk(
            input: DirectoryWalkInput(
                storageId: storageID,
                fullPath: currentPath,
                skipDisallowedFiles: true,
                skipHiddenFiles: false
            )
        )
        return walkEntries.map { BrowserEntry(walkEntry: $0) }
    }

    private var canStartFileOperation: Bool {
        !fileOperationsDisabled && !isLoading
    }

    private func validate(
        _ name: String,
        siblings: [BrowserEntry],
        renaming entry: BrowserEntry?
    ) -> Bool {
        if let validationMessage = FileNameValidator.validationMessage(
            for: name,
            existingNames: siblings.map(\.name),
            originalName: entry?.name
        ) {
            error = BrowserPaneError(message: validationMessage)
            return false
        }
        return true
    }

    private func present(_ error: any Error) {
        self.error = BrowserPaneError(message: ErrorDescription.message(for: error))
    }

    private static func parentPath(of path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private static func childPath(parent: String, name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private static func normalizeDevicePath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized.isEmpty ? "/" : normalized
    }

    private static func deviceName(from deviceInfo: DeviceInfo) -> String? {
        deviceInfo.displayName
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

private struct StorageSelectionSnapshot {
    let storageID: UInt32?
    let path: String
    let history: [String]
    let entries: [BrowserEntry]
    let selection: BrowserSelectionState
}

private struct PendingDirectoryLoad {
    let path: String
    let storageID: UInt32
    let addingCurrentToHistory: Bool
    let clearsSelection: Bool
}

private enum DirectoryLoadResult {
    case loaded
    case failed(generation: Int)
    case superseded
}

/// A place on the device: the storage and the folder within it.
public struct DeviceBrowserLocation: Equatable, Sendable {
    public let storageID: UInt32
    public let path: String

    public init(storageID: UInt32, path: String) {
        self.storageID = storageID
        self.path = path
    }
}
