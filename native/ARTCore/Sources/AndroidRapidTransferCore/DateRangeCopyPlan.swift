import Foundation

/// The matched files grouped into units the transfer queue can accept.
///
/// ``TransferRequest`` addresses a single flat destination directory, so the
/// device layout is reproduced by issuing one request per distinct relative
/// subdirectory rather than by teaching the engine about nested placement. Files
/// that share a relative directory travel together in one request, which keeps
/// the number of native calls proportional to the number of folders touched
/// rather than to the number of files.
public struct DateRangeCopyPlan: Equatable, Sendable {
    /// One destination subdirectory and the device files that belong in it.
    public struct Group: Equatable, Sendable {
        /// Path relative to the copy destination; empty means the destination
        /// root itself.
        public let relativeDirectory: String
        /// Absolute device paths.
        public let sources: [String]
        /// Session-only device path → MTP handle hints.
        public let sourceObjectIds: [String: UInt32]

        public init(
            relativeDirectory: String,
            sources: [String],
            sourceObjectIds: [String: UInt32] = [:]
        ) {
            self.relativeDirectory = relativeDirectory
            self.sources = sources
            self.sourceObjectIds = sourceObjectIds
        }
    }

    public let groups: [Group]
    public let fileCount: Int
    public let totalSize: Int64

    /// Groups `matches` while preserving first-encounter order, so the copy runs
    /// in the same order the preview listed.
    public init(matches: [DateRangeMatch]) {
        var orderedDirectories: [String] = []
        var sourcesByDirectory: [String: [String]] = [:]
        var objectIdsByDirectory: [String: [String: UInt32]] = [:]

        for match in matches {
            let directory = match.relativeDirectory
            if sourcesByDirectory[directory] == nil {
                orderedDirectories.append(directory)
                sourcesByDirectory[directory] = []
            }
            sourcesByDirectory[directory]?.append(match.entry.location)
            if let objectId = match.entry.objectId {
                objectIdsByDirectory[directory, default: [:]][match.entry.location] = objectId
            }
        }

        groups = orderedDirectories.map { directory in
            Group(
                relativeDirectory: directory,
                sources: sourcesByDirectory[directory] ?? [],
                sourceObjectIds: objectIdsByDirectory[directory] ?? [:]
            )
        }
        fileCount = matches.count
        totalSize = matches.reduce(0) { $0 + $1.size }
    }

    public var isEmpty: Bool { groups.isEmpty }
}
