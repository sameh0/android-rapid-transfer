import AndroidRapidTransferCore
import Foundation
import MTPKit

/// A job enqueued through `TransferViewModel`, with the queue that runs it so
/// its typed state (`.failed(errorType: .deviceLost, …)`) can be read back.
struct TrackedJob {
    let id: UUID
    let queue: TransferQueue
}

extension Harness {
    func enqueueUpload(_ url: URL) async throws -> TrackedJob {
        guard let queue = controller.transferQueue else { throw ProbeFailure("upload: no transfer queue") }
        let ids = await transferModel.enqueueDroppedFilesOnDevice([url])
        try require(ids.count == 1, "upload: expected one job, got \(ids.count) (\(transferModel.operationErrorMessage ?? "-"))")
        return TrackedJob(id: ids[0], queue: queue)
    }

    func enqueueDownload(named name: String, to destination: URL) async throws -> TrackedJob {
        guard let model = controller.deviceModel, let queue = controller.transferQueue else {
            throw ProbeFailure("download: not connected")
        }
        try require(model.currentLocation == sandboxDevicePath, "download: device pane is at \(model.currentLocation)")
        await model.refresh()
        guard let entry = model.entries.first(where: { $0.name == name }) else {
            throw ProbeFailure("download: \(name) is not in the sandbox")
        }
        model.selectEntry(id: entry.id, extending: false, toggling: false)
        guard let id = await transferModel.enqueueDownload(destination: destination.path) else {
            throw ProbeFailure("download: nothing enqueued")
        }
        return TrackedJob(id: id, queue: queue)
    }

    func row(_ job: TrackedJob) -> TransferPanelRow? {
        transferModel.rows.first { $0.id == job.id }
    }

    func typedState(_ job: TrackedJob) async -> TransferJobState? {
        await job.queue.snapshot.jobs.first { $0.id == job.id }?.state
    }

    /// Waits until the job has moved at least `bytes`; returns the bytes seen,
    /// or nil if it ended (or timed out) first.
    func waitForProgress(_ job: TrackedJob, bytes: Int64, timeout: Double) async -> Int64? {
        var sent: Int64 = 0
        let reached = await waitUntil(timeout: timeout) {
            guard let row = row(job) else { return false }
            if case let .transferring(progress) = row.state {
                sent = progress.sentBytes
                return progress.sentBytes >= bytes
            }
            return row.state.isTerminal
        }
        guard reached, let row = row(job), !row.state.isTerminal else { return nil }
        return sent
    }

    func waitTerminal(_ job: TrackedJob, timeout: Double) async -> TransferPanelRow? {
        _ = await waitUntil(timeout: timeout) { row(job)?.state.isTerminal == true }
        guard let row = row(job), row.state.isTerminal else { return nil }
        return row
    }
}

func describe(_ state: TransferJobState?) -> String {
    guard let state else { return "unknown" }
    switch state {
    case .queued: return "queued"
    case .preprocessing: return "preprocessing"
    case let .transferring(progress): return "transferring(\(progress.sentBytes)/\(progress.totalBytes))"
    case .completed: return "completed"
    case let .failed(type, message): return "failed(\(type), \(message))"
    case .cancelled: return "cancelled"
    }
}

extension TransferJobState {
    var isTerminalForProbe: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .preprocessing, .transferring: false
        }
    }
}

func isDeviceLost(_ state: TransferJobState?) -> Bool {
    if case .failed(.deviceLost, _) = state { return true }
    return false
}

// MARK: - Local fixtures

func ensureRandomFile(at url: URL, size: Int) throws {
    let fileManager = FileManager.default
    if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
       (attributes[.size] as? NSNumber)?.intValue == size {
        return
    }
    try? fileManager.removeItem(at: url)
    fileManager.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var remaining = size
    var buffer = [UInt8](repeating: 0, count: 8 << 20)
    while remaining > 0 {
        let count = min(remaining, buffer.count)
        buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
        try handle.write(contentsOf: Data(buffer[0..<count]))
        remaining -= count
    }
}

/// Every item in a directory, hidden ones included.
func directoryContents(_ url: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
}

func fileSize(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size].flatMap { ($0 as? NSNumber)?.intValue }
}

func freshDirectory(_ url: URL) throws -> URL {
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
