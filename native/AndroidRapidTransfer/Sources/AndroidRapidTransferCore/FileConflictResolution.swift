import Foundation

public enum FileConflictResolution: Equatable, Sendable {
    case replace
    case skip
    case keepBoth
}

public struct FileConflictPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileName: String
    public let destination: String
    /// The item being copied, when its details are known.
    public let incoming: FileConflictItem?
    /// The item already at the destination, when its details are known.
    public let existing: FileConflictItem?

    public init(
        id: UUID = UUID(),
        fileName: String,
        destination: String,
        incoming: FileConflictItem? = nil,
        existing: FileConflictItem? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.destination = destination
        self.incoming = incoming
        self.existing = existing
    }
}

/// One side of a name conflict, for the dialog's side-by-side comparison.
public struct FileConflictItem: Equatable, Sendable {
    public enum Location: Equatable, Sendable {
        case mac
        case phone
    }

    public let location: Location
    public let isDirectory: Bool
    /// `nil` for folders and for sizes the listing did not report.
    public let size: Int64?
    public let modified: Date?

    public init(location: Location, isDirectory: Bool, size: Int64?, modified: Date?) {
        self.location = location
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// A phone item as the device listing reported it.
    public init(deviceEntry entry: BrowserEntry) {
        self.init(
            location: .phone,
            isDirectory: entry.isDirectory,
            size: entry.isDirectory ? nil : entry.size,
            modified: entry.modified
        )
    }

    /// A Mac item read from disk; `nil` when it cannot be read.
    public init?(localURL url: URL) {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        ) else { return nil }
        let isDirectory = values.isDirectory ?? false
        self.init(
            location: .mac,
            isDirectory: isDirectory,
            size: isDirectory ? nil : values.fileSize.map(Int64.init),
            modified: values.contentModificationDate
        )
    }

    /// How this side compares with `other`, for the dialog's hint line.
    public func comparison(to other: FileConflictItem) -> FileConflictComparison {
        if let modified, let otherModified = other.modified,
           abs(modified.timeIntervalSince(otherModified)) >= 1 {
            return modified > otherModified ? .newer : .older
        }
        if let size, let otherSize = other.size {
            if size == otherSize { return .sameSize }
            return size > otherSize ? .larger : .smaller
        }
        return .unknown
    }
}

public enum FileConflictComparison: Equatable, Sendable {
    case newer
    case older
    case larger
    case smaller
    /// Same size; the dates match within a second or are unknown.
    case sameSize
    case unknown
}

public struct FileConflictDecision: Equatable, Sendable {
    public let resolution: FileConflictResolution
    public let appliesToAll: Bool

    public init(resolution: FileConflictResolution, appliesToAll: Bool) {
        self.resolution = resolution
        self.appliesToAll = appliesToAll
    }
}

@MainActor
public enum KeepBothNameGenerator {
    /// Returns `name (2).ext`, `name (3).ext`, and so on. The original name is
    /// intentionally not returned because this is called only after a collision.
    public static func availableName(
        for originalName: String,
        exists: (String) async throws -> Bool
    ) async rethrows -> String {
        let parts = nameParts(of: originalName)
        var suffix = 2

        while true {
            let candidate = "\(parts.stem) (\(suffix))\(parts.extensionSuffix)"
            if try await !exists(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func nameParts(of name: String) -> (stem: String, extensionSuffix: String) {
        let url = URL(fileURLWithPath: name)
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty, !name.hasPrefix(".") else {
            return (name, "")
        }

        let extensionSuffix = ".\(pathExtension)"
        return (String(name.dropLast(extensionSuffix.count)), extensionSuffix)
    }
}
