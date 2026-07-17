import Foundation
import Observation

/// The transfer clipboard: items copied from one pane, waiting to be pasted
/// into the other pane (Copy / Copy to Queue / Paste) or, for device items,
/// executed as a structure-preserving batch copy from the transfer panel.
///
/// Every item comes from the same pane: a queue mixing both panes would have
/// no destination that can accept it, so copying from the other pane starts a
/// new queue instead.
@MainActor
@Observable
public final class CopyQueue {
    public private(set) var items: [CopyQueueItem] = []
    public private(set) var sessionID: UUID?
    public private(set) var storageID: UInt32?

    private var queuedPaths: Set<String> = []
    private var queuedDirectoryPaths: Set<String> = []

    /// The pane the queued items were copied from; `nil` when empty.
    public var source: BrowserPaneKind? {
        items.first?.source
    }

    public init() {}

    public var count: Int {
        items.count
    }

    public var totalBytes: Int64 {
        items.reduce(into: 0) { total, item in
            total += max(0, item.size ?? 0)
        }
    }

    public var hasUnknownSizes: Bool {
        items.contains { $0.size == nil }
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    /// A queued directory owns its entire subtree: descendants added later are
    /// ignored, while a newly added ancestor replaces descendants at their
    /// earliest position so unrelated selections keep their insertion order.
    ///
    /// Items from a different pane than the queued ones replace the queue
    /// rather than mixing with it.
    public func add(_ entries: [CopyQueueItem]) {
        if let incomingSource = entries.first?.source,
           let source, source != incomingSource {
            removeAllItems()
        }
        for entry in entries {
            add(entry)
        }
    }

    /// Replaces the queue with `entries` (Copy, as opposed to Copy to Queue).
    public func replace(with entries: [CopyQueueItem]) {
        removeAllItems()
        add(entries)
    }

    public func remove(id: CopyQueueItem.ID) {
        removeItems { $0.id == id }
    }

    public func removeAll() {
        removeAllItems()
    }

    /// Device paths are only meaningful inside the session and storage that
    /// produced them, so either identity changing invalidates every staged
    /// device item. Local paths stay valid across device sessions and are kept.
    public func bind(sessionID: UUID?, storageID: UInt32?) {
        guard self.sessionID != sessionID || self.storageID != storageID else { return }
        if source != .local {
            removeAll()
        }
        self.sessionID = sessionID
        self.storageID = storageID
    }

    private func add(_ entry: CopyQueueItem) {
        if let entryStorageID = entry.storage?.id {
            let expectedStorageID = storageID ?? items.first?.storage?.id
            guard expectedStorageID == nil || expectedStorageID == entryStorageID else { return }
        }
        guard !queuedPaths.contains(entry.path) else { return }
        guard !queuedDirectoryPaths.contains(where: {
            Self.isAncestor($0, of: entry.path)
        }) else { return }

        guard entry.isDirectory else {
            insertItem(entry)
            return
        }

        let insertionIndex = removeItems {
            Self.isAncestor(entry.path, of: $0.path)
        }
        insertItem(entry, at: insertionIndex)
    }

    private func insertItem(_ entry: CopyQueueItem, at index: Int? = nil) {
        if let index {
            items.insert(entry, at: index)
        } else {
            items.append(entry)
        }
        queuedPaths.insert(entry.path)
        if entry.isDirectory {
            queuedDirectoryPaths.insert(entry.path)
        }
    }

    @discardableResult
    private func removeItems(
        where shouldRemove: (CopyQueueItem) -> Bool
    ) -> Int? {
        var firstRemovalIndex: Int?
        var retainedItems: [CopyQueueItem] = []
        retainedItems.reserveCapacity(items.count)
        var removedPaths: Set<String> = []
        var removedDirectoryPaths: Set<String> = []

        for item in items {
            guard shouldRemove(item) else {
                retainedItems.append(item)
                continue
            }

            if firstRemovalIndex == nil {
                firstRemovalIndex = retainedItems.count
            }
            removedPaths.insert(item.path)
            if item.isDirectory {
                removedDirectoryPaths.insert(item.path)
            }
        }

        guard firstRemovalIndex != nil else { return nil }
        items = retainedItems
        queuedPaths.subtract(removedPaths)
        queuedDirectoryPaths.subtract(removedDirectoryPaths)
        return firstRemovalIndex
    }

    private func removeAllItems() {
        items.removeAll()
        queuedPaths.removeAll()
        queuedDirectoryPaths.removeAll()
    }

    private static func isAncestor(_ candidate: String, of path: String) -> Bool {
        guard candidate != path else { return false }
        if candidate == "/" {
            return path.hasPrefix("/")
        }
        return path.hasPrefix(candidate + "/")
    }
}

/// The local directory one copy-queue item lands in: the chosen destination
/// plus the item's device parent path, reproducing the device layout locally.
/// Shared by request construction and batch recording so the persisted batch
/// always names the same directory the transfer actually targets.
func copyQueueItemDestinationPath(for item: CopyQueueItem, under destination: URL) -> String {
    let sourceURL = URL(fileURLWithPath: item.path).standardizedFileURL
    let relativeParentComponents = sourceURL.pathComponents
        .dropFirst()
        .dropLast()
    return relativeParentComponents
        .reduce(destination.standardizedFileURL) { partial, component in
            partial.appending(path: component, directoryHint: .isDirectory)
        }
        .path
}

/// Loose files sharing a destination parent are grouped, while directories
/// remain single-source requests so the transfer engine preserves expansion.
/// Only device items become download requests; local items are ignored.
public func copyQueueTransferRequests(
    items: [CopyQueueItem],
    destination: URL
) -> [TransferRequest] {
    var groupedRequests: [
        (
            destination: String,
            storageID: UInt32,
            sources: [String],
            directorySources: Set<String>,
            sourceObjectIds: [String: UInt32]
        )
    ] = []
    var fileRequestIndexByDestination: [String: Int] = [:]

    for item in items {
        guard let storage = item.storage else { continue }
        let destinationPath = copyQueueItemDestinationPath(for: item, under: destination)

        if item.isDirectory {
            groupedRequests.append((
                destination: destinationPath,
                storageID: storage.id,
                sources: [item.path],
                directorySources: [item.path],
                sourceObjectIds: item.objectId.map { [item.path: $0] } ?? [:]
            ))
        } else if let requestIndex = fileRequestIndexByDestination[destinationPath] {
            groupedRequests[requestIndex].sources.append(item.path)
            if let objectId = item.objectId {
                groupedRequests[requestIndex].sourceObjectIds[item.path] = objectId
            }
        } else {
            fileRequestIndexByDestination[destinationPath] = groupedRequests.count
            groupedRequests.append((
                destination: destinationPath,
                storageID: storage.id,
                sources: [item.path],
                directorySources: [],
                sourceObjectIds: item.objectId.map { [item.path: $0] } ?? [:]
            ))
        }
    }

    return groupedRequests.map { request in
        TransferRequest(
            direction: .download,
            sources: request.sources,
            destination: request.destination,
            storageId: request.storageID,
            directorySources: request.directorySources,
            sourceObjectIds: request.sourceObjectIds
        )
    }
}
