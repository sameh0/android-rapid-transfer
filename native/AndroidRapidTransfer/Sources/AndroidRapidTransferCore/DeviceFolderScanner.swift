import Foundation
import MTPKit

/// One file that fell inside the requested modification-date window.
public struct DateRangeMatch: Identifiable, Hashable, Sendable {
    public let entry: BrowserEntry
    /// The full device path relative to the storage root, e.g.
    /// `DCIM/Camera/x.jpg` for `/DCIM/Camera/x.jpg` on the device.
    /// The selected scan root does not affect destination placement.
    public let relativePath: String

    public var id: String { entry.location }

    public init(entry: BrowserEntry, relativePath: String) {
        self.entry = entry
        self.relativePath = relativePath
    }

    /// The storage-root-relative parent directory, empty exactly when the file
    /// sits directly at the storage root.
    public var relativeDirectory: String {
        relativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Files the device reported without a size are counted as empty so totals
    /// stay additive rather than becoming optional.
    public var size: Int64 { entry.size ?? 0 }
}

/// A folder that could not be listed.
///
/// The scan records these and keeps going: one unreadable directory on a phone
/// (a permission-guarded `Android/data` subtree is the common case) must not
/// void an otherwise complete result.
public struct DateRangeScanFailure: Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Incremental scan state. Walking a large phone subtree over MTP takes long
/// enough that the sheet must show motion rather than an indeterminate spinner.
public struct DateRangeScanProgress: Equatable, Sendable {
    public let scannedFolders: Int
    public let matchedFiles: Int
    public let currentPath: String

    public init(scannedFolders: Int, matchedFiles: Int, currentPath: String) {
        self.scannedFolders = scannedFolders
        self.matchedFiles = matchedFiles
        self.currentPath = currentPath
    }
}

public struct DateRangeScanResult: Equatable, Sendable {
    public let matches: [DateRangeMatch]
    public let failures: [DateRangeScanFailure]
    public let scannedFolders: Int
    /// `true` when the scan stopped early because its task was cancelled, so the
    /// caller can tell "nothing matched" apart from "we never finished looking".
    public let isCancelled: Bool

    public init(
        matches: [DateRangeMatch],
        failures: [DateRangeScanFailure],
        scannedFolders: Int,
        isCancelled: Bool
    ) {
        self.matches = matches
        self.failures = failures
        self.scannedFolders = scannedFolders
        self.isCancelled = isCancelled
    }

    public var totalSize: Int64 {
        matches.reduce(0) { $0 + $1.size }
    }

    public var isEmpty: Bool { matches.isEmpty }
}

/// Progress within one directory listing; nil fields are not yet known.
public struct DirectoryListingProgress: Equatable, Sendable {
    public let path: String
    public let itemCount: Int?
    public let fractionCompleted: Double?

    public init(path: String, itemCount: Int?, fractionCompleted: Double?) {
        self.path = path
        self.itemCount = itemCount
        self.fractionCompleted = fractionCompleted
    }
}

/// Each invocation owns a distinct token, even when a later scan repeats a path.
private final class ListingToken: @unchecked Sendable {
    // Recursive because an onListing handler may synchronously cancel its scan.
    private let lock = NSRecursiveLock()
    private var active = true
    @MainActor private let onListing: (DirectoryListingProgress) -> Void

    @MainActor init(onListing: @escaping (DirectoryListingProgress) -> Void) {
        self.onListing = onListing
    }

    func close() { lock.withLock { active = false } }

    @MainActor func deliver(_ progress: WalkProgress) {
        lock.withLock {
            guard active else { return }
            onListing(DirectoryListingProgress(
                path: progress.fullPath, itemCount: progress.itemCount,
                fractionCompleted: progress.fractionCompleted
            ))
        }
    }
}

/// Walks selected device folders recursively, collecting files whose
/// modification date falls inside a ``DateRangeFilter``.
///
/// The directory listing is injected rather than taken as an `MTPDeviceProvider`
/// so the traversal can be exercised against a fake tree without a device. The
/// walk is hand-rolled, one directory at a time, so results stream in as they
/// are found and the scan can be cancelled at any point.
@MainActor
public struct DeviceFolderScanner {
    /// Lists a single directory by path and optional per-session handle hint.
    public typealias DirectoryLister = (String, UInt32?) async throws -> [BrowserEntry]

    public typealias ProgressDirectoryLister = (
        String, UInt32?, @escaping @Sendable (WalkProgress) -> Void
    ) async throws -> [BrowserEntry]

    private let listDirectory: ProgressDirectoryLister

    public init(listDirectory: @escaping DirectoryLister) {
        self.listDirectory = { path, objectID, _ in try await listDirectory(path, objectID) }
    }

    public init(listDirectory: @escaping ProgressDirectoryLister) {
        self.listDirectory = listDirectory
    }

    /// Compatibility overload for path-only listers; every request falls back
    /// to path resolution.
    public init(listDirectory: @escaping (String) async throws -> [BrowserEntry]) {
        self.listDirectory = { path, _, _ in try await listDirectory(path) }
    }

    /// Scans `roots` breadth-first, streaming matches and reporting progress
    /// after each listed folder.
    ///
    /// Directories are recursed into but never reported as matches — only files
    /// are copied. Listing failures are collected per folder instead of aborting.
    ///
    /// `exclusions` defaults to ``ScanExclusionRules/none`` because it is a pure
    /// widening: the default is provably identical to the pre-exclusion
    /// behaviour, and the single production call site (the date-range view
    /// model) always passes its rules explicitly, so the default cannot hide a
    /// forgotten argument — it only spares the many test call sites noise.
    /// `onMatch` receives one batch per successfully listed folder, including
    /// an empty batch when that folder contains no matching files.
    /// `onListing` announces each folder before it is read, then forwards advisory
    /// native progress on the main actor while that specific listing remains active.
    public func scan(
        roots: [String],
        filter: DateRangeFilter,
        exclusions: ScanExclusionRules = .none,
        onMatch: (([DateRangeMatch]) -> Void)? = nil,
        onProgress: ((DateRangeScanProgress) -> Void)? = nil,
        onListing: ((DirectoryListingProgress) -> Void)? = nil
    ) async -> DateRangeScanResult {
        var matches: [DateRangeMatch] = []
        var failures: [DateRangeScanFailure] = []
        var scannedFolders = 0
        // Guards against a device reporting a cycle, and makes a folder reachable
        // from two roots contribute its files exactly once.
        var visitedPaths = Set<String>()

        for root in Self.topLevelRoots(roots) {
            var pending: [(path: String, objectId: UInt32?)] = [(root, nil)]

            while !pending.isEmpty {
                if Task.isCancelled {
                    return DateRangeScanResult(
                        matches: matches,
                        failures: failures,
                        scannedFolders: scannedFolders,
                        isCancelled: true
                    )
                }

                let folder = pending.removeFirst()
                guard visitedPaths.insert(folder.path).inserted else { continue }

                let token = onListing.map { ListingToken(onListing: $0) }
                onListing?(DirectoryListingProgress(
                    path: folder.path, itemCount: nil, fractionCompleted: nil
                ))
                let entries: [BrowserEntry]
                do {
                    entries = try await withTaskCancellationHandler {
                        try await listDirectory(folder.path, folder.objectId) { progress in
                            guard let token else { return }
                            DispatchQueue.main.async { token.deliver(progress) }
                        }
                    } onCancel: {
                        token?.close()
                    }
                    token?.close()
                } catch {
                    token?.close()
                    failures.append(
                        DateRangeScanFailure(
                            path: folder.path,
                            message: ErrorDescription.message(for: error)
                        )
                    )
                    continue
                }
                scannedFolders += 1
                var directoryMatches: [DateRangeMatch] = []

                for entry in entries {
                    // Exclusions run before anything else so a skipped directory
                    // is pruned from the walk — its subtree is never listed —
                    // and a skipped file never reaches the date filter or the
                    // matched totals.
                    if exclusions.shouldSkip(name: entry.name, isDirectory: entry.isDirectory) {
                        continue
                    }
                    if entry.isDirectory {
                        pending.append((entry.location, entry.objectId))
                    } else if filter.matches(entry) {
                        let relativePath = entry.location.hasPrefix("/")
                            ? String(entry.location.dropFirst())
                            : entry.location
                        let match = DateRangeMatch(entry: entry, relativePath: relativePath)
                        matches.append(match)
                        directoryMatches.append(match)
                    }
                }

                onMatch?(directoryMatches)
                onProgress?(
                    DateRangeScanProgress(
                        scannedFolders: scannedFolders,
                        matchedFiles: matches.count,
                        currentPath: folder.path
                    )
                )
            }
        }

        return DateRangeScanResult(
            matches: matches,
            failures: failures,
            scannedFolders: scannedFolders,
            isCancelled: Task.isCancelled
        )
    }

    /// Drops any selected folder that already sits inside another selected
    /// folder. Without this, picking both `/DCIM` and `/DCIM/Camera` would copy
    /// the camera roll twice under two different relative paths.
    static func topLevelRoots(_ roots: [String]) -> [String] {
        let normalized = roots.map(normalize)
        return normalized.enumerated().compactMap { index, candidate in
            let hasSelectedAncestor = normalized.enumerated().contains { otherIndex, other in
                otherIndex != index && isDescendant(candidate, of: other)
            }
            return hasSelectedAncestor ? nil : candidate
        }
    }

    /// Strips a trailing slash so `/DCIM/` and `/DCIM` compare equal, while
    /// leaving the storage root `/` intact.
    private static func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Compares on path-component boundaries so `/DCIM2` is not treated as a
    /// child of `/DCIM`.
    private static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" { return path != "/" }
        return path.hasPrefix(ancestor + "/")
    }
}
