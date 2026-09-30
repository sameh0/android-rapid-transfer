import Foundation

/// One item staged in the transfer clipboard queue. Device items carry the
/// storage they were listed from; local items carry none. A queue only ever
/// holds items copied from one pane — see ``CopyQueue``.
public struct CopyQueueItem: Identifiable, Equatable, Sendable {
    /// Absolute path of the item within its source pane: a device path for
    /// device items, a local filesystem path for local items.
    public let path: String
    public let displayName: String
    public let size: Int64?
    public let isDirectory: Bool
    /// The device storage a device item was listed from; `nil` for local items.
    public let storage: DeviceStorage?
    /// Session-only MTP handle hint; intentionally not persisted.
    public let objectId: UInt32?

    public var id: String {
        path
    }

    /// The pane this item was copied from.
    public var source: BrowserPaneKind {
        storage == nil ? .local : .device
    }

    public init(
        absoluteDevicePath: String,
        displayName: String,
        size: Int64?,
        isDirectory: Bool,
        storage: DeviceStorage,
        objectId: UInt32? = nil
    ) {
        let rootedPath = absoluteDevicePath.hasPrefix("/")
            ? absoluteDevicePath
            : "/\(absoluteDevicePath)"
        self.path = URL(fileURLWithPath: rootedPath).standardizedFileURL.path
        self.displayName = displayName
        self.size = size
        self.isDirectory = isDirectory
        self.storage = storage
        self.objectId = objectId
    }

    public init(entry: BrowserEntry, storage: DeviceStorage) {
        self.init(
            absoluteDevicePath: entry.location,
            displayName: entry.name,
            size: entry.size,
            isDirectory: entry.isDirectory,
            storage: storage,
            objectId: entry.objectId
        )
    }

    /// A local item. Local listings already produce absolute paths.
    public init(localEntry entry: BrowserEntry) {
        self.path = URL(fileURLWithPath: entry.location).standardizedFileURL.path
        self.displayName = entry.name
        self.size = entry.isDirectory ? nil : entry.size
        self.isDirectory = entry.isDirectory
        self.storage = nil
        self.objectId = nil
    }
}
