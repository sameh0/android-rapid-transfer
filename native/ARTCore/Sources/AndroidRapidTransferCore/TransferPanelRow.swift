import Foundation

public enum TransferPanelRowState: Equatable, Sendable {
    case queued
    case preprocessing
    case transferring(TransferProgressSnapshot)
    case completed
    /// A friendly title and guidance, with the raw error kept as
    /// ``TransferFailureDescription/technicalDetail``.
    case failed(TransferFailureDescription)
    case cancelled

    public var isActive: Bool {
        switch self {
        case .preprocessing, .transferring:
            true
        case .queued, .completed, .failed, .cancelled:
            false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .preprocessing, .transferring:
            false
        }
    }
}

public struct TransferPanelRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let request: TransferRequest
    public let state: TransferPanelRowState
    public let startedAt: Date?
    public let endedAt: Date?
    public let lastProgress: TransferProgressSnapshot?
    /// A stop was requested for this job; the file in flight is being
    /// aborted. See `TransferJobSnapshot.cancelRequested`.
    public let cancelRequested: Bool
    /// Files that failed while the rest of the job kept going. See
    /// `TransferJobSnapshot.fileFailures`.
    public let fileFailures: [TransferFileFailure]

    public init(job: TransferJobSnapshot) {
        id = job.id
        request = job.request
        state = Self.panelState(for: job.state, direction: job.request.direction)
        startedAt = job.startedAt
        endedAt = job.endedAt
        lastProgress = job.lastProgress
        cancelRequested = job.cancelRequested
        fileFailures = job.fileFailures
    }

    /// Wall-clock time the job spent active, known once it reaches a
    /// terminal state. `nil` for jobs that never left the queue.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// Total size of the transfer as reported by the provider, if any
    /// progress was ever observed.
    public var totalBytes: Int64? {
        lastProgress?.totalBytes
    }

    /// Bytes actually moved before the job finished or failed.
    public var sentBytes: Int64? {
        lastProgress?.sentBytes
    }

    public var sourceSummary: String {
        if request.sources.count == 1 {
            return request.displayNameOverride
                ?? URL(fileURLWithPath: request.sources[0]).lastPathComponent
        }
        return "\(request.sources.count) items"
    }

    /// Transfer requests are grouped so their sources normally share one parent
    /// directory. If that invariant is broken, this returns their deepest common
    /// ancestor. The document root is represented by `"/"`; only an empty source
    /// list has no directory to report.
    public var sourceDirectory: String? {
        guard !request.sources.isEmpty else { return nil }

        let parentComponents = request.sources.map { source in
            URL(fileURLWithPath: source)
                .standardizedFileURL
                .deletingLastPathComponent()
                .pathComponents
        }
        guard var commonComponents = parentComponents.first else { return nil }

        for components in parentComponents.dropFirst() {
            commonComponents = zip(commonComponents, components)
                .prefix { $0 == $1 }
                .map(\.0)
        }

        let path = NSString.path(withComponents: commonComponents)
        return path.isEmpty ? nil : path
    }

    /// Where a download's items land on this Mac, for "Show in Finder".
    /// Empty for uploads, whose results live on the phone.
    public var localResultPaths: [String] {
        guard request.direction == .download else { return [] }
        if case let .moveStagedItem(_, destinationPath, _) = request.completionAction {
            return [destinationPath]
        }
        let destination = URL(fileURLWithPath: request.destination)
        return request.sources.map {
            destination.appending(path: URL(fileURLWithPath: $0).lastPathComponent).path
        }
    }

    /// Friendly copy for each file that failed while the job kept going.
    public var fileFailureDescriptions: [TransferFailureDescription] {
        fileFailures.map {
            TransferFailureDescription(fileFailureMessage: $0.message, direction: request.direction)
        }
    }

    private static func panelState(
        for state: TransferJobState,
        direction: TransferDirection
    ) -> TransferPanelRowState {
        switch state {
        case .queued:
            .queued
        case .preprocessing:
            .preprocessing
        case let .transferring(progress):
            .transferring(progress)
        case .completed:
            .completed
        case let .failed(errorType, message):
            .failed(TransferFailureDescription(type: errorType, message: message, direction: direction))
        case .cancelled:
            .cancelled
        }
    }
}
