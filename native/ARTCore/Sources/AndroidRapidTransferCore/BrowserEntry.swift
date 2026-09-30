import Foundation
import MTPKit

public struct BrowserEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let size: Int64?
    public let modified: Date?
    public let isDirectory: Bool
    public let location: String
    /// A per-session MTP handle hint. Never persist this value; `nil` always
    /// falls back to resolving `location` by path.
    public let objectId: UInt32?

    public init(
        id: String,
        name: String,
        size: Int64?,
        modified: Date?,
        isDirectory: Bool,
        location: String,
        objectId: UInt32? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
        self.location = location
        self.objectId = objectId
    }

    /// A device entry as the browser shows it.
    public init(walkEntry entry: WalkEntry) {
        self.init(
            id: entry.path,
            name: entry.name,
            size: entry.isFolder ? nil : entry.size,
            modified: entry.modified,
            isDirectory: entry.isFolder,
            location: entry.path,
            objectId: entry.objectId == 0 ? nil : entry.objectId
        )
    }

    public var formattedSize: String {
        guard let size else { return "—" }
        return size.formatted(.byteCount(style: .file))
    }

    public var formattedModifiedDate: String {
        guard let modified else { return "—" }
        return modified.formatted(date: .abbreviated, time: .shortened)
    }

    public var sortableSize: Int64 {
        size ?? 0
    }

    public var sortableModifiedDate: Date {
        modified ?? .distantPast
    }
}
