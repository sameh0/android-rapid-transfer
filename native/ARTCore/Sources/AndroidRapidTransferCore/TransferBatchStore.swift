import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// One recorded batch copy: what was asked for, where it was going, and how
/// far each item got. Persisted as JSON so an interrupted or partially failed
/// batch can be inspected and resumed after a relaunch.
public struct TransferBatchRecord: Codable, Equatable, Identifiable, Sendable {
    /// Where the batch came from; a display label, not a behavioral switch.
    public enum Origin: String, Codable, Sendable {
        case copyQueue
        case dateRange
        case directCopy

        public var displayLabel: String {
            switch self {
            case .copyQueue:
                "Copy Queue"
            case .dateRange:
                "Date Range Copy"
            case .directCopy:
                "Copy to Computer"
            }
        }
    }

    /// One top-level source of the batch. Directories stay a single item —
    /// the transfer engine expands them — so resume can re-request the same
    /// units the original run did.
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public enum Status: Codable, Equatable, Sendable {
            case pending
            case completed
            case failed(message: String)
        }

        /// Absolute path on the device; unique within a batch.
        public let devicePath: String
        public let displayName: String
        /// Size in bytes when the recording site knew it; `nil` otherwise.
        public let size: Int64?
        /// Whether the item is a folder, so resume can re-flag it for
        /// engine-side expansion.
        public let isDirectory: Bool
        /// The local directory this item lands in. Kept per item because one
        /// batch can fan out into several destination subdirectories while
        /// reproducing the device layout.
        public let destinationDirectory: String
        public var status: Status

        public var id: String { devicePath }

        public init(
            devicePath: String,
            displayName: String,
            size: Int64?,
            isDirectory: Bool,
            destinationDirectory: String,
            status: Status = .pending
        ) {
            self.devicePath = devicePath
            self.displayName = displayName
            self.size = size
            self.isDirectory = isDirectory
            self.destinationDirectory = destinationDirectory
            self.status = status
        }
    }

    public let id: UUID
    public let createdAt: Date
    public let origin: Origin
    /// The root the user picked; item destinations live underneath it.
    public let destinationRoot: String
    /// The MTP storage the batch was recorded against. Storage IDs are only
    /// stable within one device session, so this is a hint for display, not a
    /// key resume can trust across replugs.
    public let storageID: UInt32
    /// Best-available device label at recording time (the device pane title);
    /// `nil` when no session context was reachable.
    public let deviceLabel: String?
    public var items: [Item]

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        origin: Origin,
        destinationRoot: String,
        storageID: UInt32,
        deviceLabel: String? = nil,
        items: [Item]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.origin = origin
        self.destinationRoot = destinationRoot
        self.storageID = storageID
        self.deviceLabel = deviceLabel
        self.items = items
    }

    public var pendingCount: Int {
        items.count { $0.status == .pending }
    }

    public var completedCount: Int {
        items.count { $0.status == .completed }
    }

    public var failedCount: Int {
        items.count {
            if case .failed = $0.status { return true }
            return false
        }
    }

    /// The items a resume should re-copy: everything that has not completed.
    /// Failed items are retried; pending items were never confirmed done.
    public var resumableItems: [Item] {
        items.filter { $0.status != .completed }
    }
}

/// Persists ``TransferBatchRecord`` values as one JSON file per batch under
/// Application Support.
///
/// Writes are atomic (`Data.WritingOptions.atomic`) so a crash mid-write can
/// lose an update but never corrupt a stored batch. All I/O runs on this
/// actor, off the main actor's critical path; callers fire updates without
/// blocking UI work. Failures are logged rather than thrown because losing a
/// status update is an accepted trade-off while corrupting the UI flow is not.
public actor TransferBatchStore {
    /// Retention cap: only the most recent batches are kept, oldest pruned on
    /// every save. Fifty batches comfortably covers weeks of use while keeping
    /// the resume list and directory scan small.
    public static let defaultMaxStoredBatches = 50

    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "TransferBatchStore"
    )

    private let directoryURL: URL
    private let maxStoredBatches: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `directoryURL` defaults to `Application Support/<AppIdentity.supportDirectoryName>/Batches`;
    /// tests inject a temporary directory. The directory is created lazily on
    /// first write so merely constructing the store touches nothing on disk.
    public init(
        directoryURL: URL? = nil,
        maxStoredBatches: Int = TransferBatchStore.defaultMaxStoredBatches
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.maxStoredBatches = maxStoredBatches
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Writes (or rewrites) one batch, then prunes beyond the retention cap.
    public func save(_ batch: TransferBatchRecord) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(batch)
            try data.write(to: fileURL(for: batch.id), options: .atomic)
        } catch {
            Self.logger.error(
                "Failed to save batch \(batch.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        pruneToRetentionCap()
    }

    /// Every stored batch, newest first. A file that fails to decode is
    /// skipped — one corrupted record must not take the resume list down.
    public func loadAll() -> [TransferBatchRecord] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var batches: [TransferBatchRecord] = []
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                batches.append(try decoder.decode(TransferBatchRecord.self, from: data))
            } catch {
                Self.logger.error(
                    "Skipping unreadable batch file \(fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return batches.sorted { $0.createdAt > $1.createdAt }
    }

    public func load(id: UUID) -> TransferBatchRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? decoder.decode(TransferBatchRecord.self, from: data)
    }

    /// Applies per-item status updates keyed by device path and rewrites the
    /// batch file. Paths that no longer match any item are ignored.
    public func updateItemStatuses(
        batchID: UUID,
        statusesByDevicePath: [String: TransferBatchRecord.Item.Status]
    ) {
        guard var batch = load(id: batchID), !statusesByDevicePath.isEmpty else { return }
        var didChange = false
        batch.items = batch.items.map { item in
            guard let status = statusesByDevicePath[item.devicePath],
                  status != item.status else { return item }
            var updated = item
            updated.status = status
            didChange = true
            return updated
        }
        guard didChange else { return }
        save(batch)
    }

    public func delete(batchID: UUID) {
        do {
            try FileManager.default.removeItem(at: fileURL(for: batchID))
        } catch CocoaError.fileNoSuchFile {
            // Already gone; deleting a missing batch is not an error.
        } catch {
            Self.logger.error(
                "Failed to delete batch \(batchID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Removes every batch whose items have all completed — the "Clear
    /// Completed" affordance of the resume window.
    public func deleteFullyCompleted() {
        for batch in loadAll() where !batch.items.isEmpty && batch.resumableItems.isEmpty {
            delete(batchID: batch.id)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appending(path: "\(id.uuidString).json")
    }

    /// Deletes the oldest batches beyond ``maxStoredBatches``. Undecodable
    /// files are left alone: they are invisible to `loadAll` already, and
    /// deleting data the store cannot read would be destructive guessing.
    private func pruneToRetentionCap() {
        let batches = loadAll()
        guard batches.count > maxStoredBatches else { return }
        for batch in batches.dropFirst(maxStoredBatches) {
            delete(batchID: batch.id)
        }
    }

    private static func defaultDirectoryURL() -> URL {
        #if os(Linux)
        return XDGAppDirectories().data.appending(path: "Batches", directoryHint: .isDirectory)
        #else
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "\(AppIdentity.supportDirectoryName)/Batches", directoryHint: .isDirectory)
        #endif
    }
}
