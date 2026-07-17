import Foundation

/// Aggregate progress across a batch of transfer jobs, used by the transfer
/// panel header to present a bulk copy as one overall operation instead of
/// only showing the first active job.
///
/// The percentage is file-based (`filesCompleted / totalFiles`), mirroring the
/// per-job provider semantics. Byte totals are surfaced for display and ETA;
/// they only cover jobs that have reported progress, so the byte denominator
/// grows as queued jobs start.
public struct TransferOverallProgress: Equatable, Sendable {
    /// Jobs currently touching the device (preprocessing or transferring).
    public let activeJobCount: Int
    /// Jobs still waiting in the queue.
    public let queuedJobCount: Int
    /// Bytes moved so far, including the full totals of completed jobs.
    public let sentBytes: Int64
    /// Total bytes known so far across the batch.
    public let totalBytes: Int64
    /// Files finished, including settled (failed or cancelled) jobs' files so
    /// the bar can still reach 100% when a batch partially fails.
    public let filesCompleted: Int64
    /// Total files known across the batch. Queued jobs contribute their
    /// top-level source count.
    public let totalFiles: Int64
    /// Throughput of the currently transferring job in decimal MB/s.
    public let speed: Double
    /// True when at least one job in the batch can still be stopped.
    public let isCancellable: Bool
    /// The byte share of files currently being copied, so the overall gauge
    /// moves during one large file instead of only between files.
    public let inFlightFileFraction: Double

    public var percent: Double? {
        guard totalFiles > 0 else { return nil }
        return min(max((Double(filesCompleted) + inFlightFileFraction) / Double(totalFiles), 0), 1)
    }

    public var eta: TimeInterval? {
        guard totalBytes > 0, sentBytes >= 0, speed > 0, speed.isFinite else { return nil }
        let remainingBytes = max(totalBytes - sentBytes, 0)
        return Double(remainingBytes) / (speed * 1_000_000)
    }

    /// Builds the aggregate for one batch of rows. Returns `nil` when every
    /// row is terminal, i.e. there is no in-flight work to describe.
    public init?(rows: [TransferPanelRow]) {
        var activeJobCount = 0
        var queuedJobCount = 0
        var sentBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var filesCompleted: Int64 = 0
        var totalFiles: Int64 = 0
        var speed = 0.0
        var isCancellable = false
        var hasUnfinished = false
        var inFlightFileFraction = 0.0

        for row in rows {
            switch row.state {
            case .queued:
                hasUnfinished = true
                queuedJobCount += 1
                isCancellable = true
                totalFiles += Int64(row.request.sources.count)
            case .preprocessing:
                hasUnfinished = true
                activeJobCount += 1
                isCancellable = isCancellable || !row.cancelRequested
                totalFiles += Int64(row.request.sources.count)
            case let .transferring(progress):
                hasUnfinished = true
                activeJobCount += 1
                isCancellable = isCancellable || !row.cancelRequested
                sentBytes += progress.sentBytes
                totalBytes += progress.totalBytes
                filesCompleted += progress.filesSent
                totalFiles += progress.totalFiles
                inFlightFileFraction += progress.currentFileFraction ?? 0
                if progress.speed > 0 {
                    speed = progress.speed
                }
            case .completed:
                if let progress = row.lastProgress {
                    sentBytes += progress.totalBytes
                    totalBytes += progress.totalBytes
                    filesCompleted += progress.totalFiles
                    totalFiles += progress.totalFiles
                } else {
                    let sources = Int64(row.request.sources.count)
                    filesCompleted += sources
                    totalFiles += sources
                }
            case .failed, .cancelled:
                // Settled without finishing: count the job's known files as
                // complete so remaining siblings can still reach 100%.
                let known = row.lastProgress?.totalFiles ?? Int64(row.request.sources.count)
                filesCompleted += known
                totalFiles += known
            }
        }

        guard hasUnfinished else { return nil }
        self.activeJobCount = activeJobCount
        self.queuedJobCount = queuedJobCount
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
        self.filesCompleted = filesCompleted
        self.totalFiles = totalFiles
        self.speed = speed
        self.isCancellable = isCancellable
        self.inFlightFileFraction = inFlightFileFraction
    }
}

/// Human phrasing for a transfer's estimated time remaining, rounded so the
/// text does not flicker with every progress report.
public enum TransferRemainingTime {
    /// e.g. "Almost done", "About 20 sec left", "About 3 min left",
    /// "About 1 hr 5 min left"; `nil` when there is no usable estimate.
    public static func phrase(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 5 { return "Almost done" }
        if seconds < 60 {
            let rounded = max(5, Int((seconds / 5).rounded()) * 5)
            return rounded >= 60 ? "About 1 min left" : "About \(rounded) sec left"
        }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "About \(minutes) min left" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "About \(hours) hr left" : "About \(hours) hr \(remainder) min left"
    }

    /// "18.5 MB/s": the provider reports decimal megabytes per second.
    public static func speedText(megabytesPerSecond speed: Double) -> String {
        "\(speed.formatted(.number.precision(.fractionLength(1)))) MB/s"
    }
}

/// How an activity session ended, for the panel's completion line ("All 128
/// files copied") and the celebration that marks a clean finish.
///
/// File counts come from each job's last progress report, so an expanded
/// folder job counts its files, not just its one top-level source.
public struct TransferSessionSummary: Equatable, Sendable, Identifiable {
    /// Distinguishes one finished session from the next, so views fire their
    /// one-shot animation exactly once per session.
    public let id: UUID
    /// The session's direction, when every job went the same way.
    public let direction: TransferDirection?
    public let filesCopied: Int64
    /// Files (or, for a job that failed as a whole, jobs) that did not copy.
    public let itemsFailed: Int64
    public let jobsCancelled: Int
    public let bytesCopied: Int64
    /// The item's name when the session copied exactly one thing.
    public let singleItemName: String?

    /// `nil` while any row is unsettled, or when there are no rows.
    public init?(rows: [TransferPanelRow], id: UUID = UUID()) {
        guard !rows.isEmpty, rows.allSatisfy({ $0.state.isTerminal }) else { return nil }
        var filesCopied: Int64 = 0
        var itemsFailed: Int64 = 0
        var jobsCancelled = 0
        var bytesCopied: Int64 = 0
        for row in rows {
            let failedFiles = Int64(row.fileFailures.count)
            switch row.state {
            case .completed:
                let files = row.lastProgress?.totalFiles ?? Int64(row.request.sources.count)
                filesCopied += max(files - failedFiles, 0)
                itemsFailed += failedFiles
                bytesCopied += row.lastProgress?.totalBytes ?? 0
            case .failed:
                filesCopied += row.lastProgress?.filesSent ?? 0
                itemsFailed += max(failedFiles, 1)
                bytesCopied += row.lastProgress?.sentBytes ?? 0
            case .cancelled:
                filesCopied += row.lastProgress?.filesSent ?? 0
                jobsCancelled += 1
                bytesCopied += row.lastProgress?.sentBytes ?? 0
            case .queued, .preprocessing, .transferring:
                break
            }
        }
        let directions = Set(rows.map(\.request.direction))
        self.id = id
        direction = directions.count == 1 ? directions.first : nil
        self.filesCopied = filesCopied
        self.itemsFailed = itemsFailed
        self.jobsCancelled = jobsCancelled
        self.bytesCopied = bytesCopied
        singleItemName = rows.count == 1 && filesCopied == 1 && itemsFailed == 0
            ? rows[0].sourceSummary
            : nil
    }

    /// Everything that was asked for arrived: nothing failed or was stopped.
    public var isCleanSuccess: Bool {
        itemsFailed == 0 && jobsCancelled == 0 && filesCopied > 0
    }

    /// e.g. "All 128 files copied", "Copied photo.jpg",
    /// "126 files copied, 2 need attention", "Stopped after 40 files".
    public var headline: String {
        if isCleanSuccess {
            if let singleItemName { return "Copied \(singleItemName)" }
            return filesCopied == 1 ? "1 file copied" : "All \(filesCopied.formatted()) files copied"
        }
        if itemsFailed > 0 {
            guard filesCopied > 0 else {
                return itemsFailed == 1
                    ? "The copy didn’t finish"
                    : "\(itemsFailed.formatted()) items didn’t copy"
            }
            let failed = itemsFailed == 1 ? "1 needs attention" : "\(itemsFailed.formatted()) need attention"
            return "\(Self.files(filesCopied)) copied, \(failed)"
        }
        if jobsCancelled > 0 {
            return filesCopied > 0 ? "Stopped after \(Self.files(filesCopied))" : "Copy stopped"
        }
        return "Nothing to copy"
    }

    /// "to this Mac" / "to the phone", when the whole session went one way.
    public var destinationPhrase: String? {
        switch direction {
        case .download: "to this Mac"
        case .upload: "to the phone"
        case nil: nil
        }
    }

    private static func files(_ count: Int64) -> String {
        count == 1 ? "1 file" : "\(count.formatted()) files"
    }
}
