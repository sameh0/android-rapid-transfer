import AndroidRapidTransferCore
import CryptoKit
import Foundation
import MTPKit

// MARK: - 6. Stop mid-file

/// The longest a Stop may take, from the click to the job settling as
/// cancelled, while a single large file is in flight.
let stopLatencyBound = 1.0

extension Scenarios {
    /// A large upload stopped mid-file through the transfer panel's Stop
    /// (`TransferViewModel.cancel(jobID:)`): it settles as cancelled at once,
    /// leaves nothing on the phone or in staging, and the next copy works.
    func stopMidFileUpload() async -> ScenarioResult {
        var result = ScenarioResult(name: "S6a Stop mid-file (upload)")
        do {
            try await harness.openSandbox(clearing: true)
            let stagingBefore = stagingDirectories()
            let job = try await harness.enqueueUpload(context.bigFile)
            let latency = try await stopMidFile(job, into: &result)

            let leftover = await harness.sandboxEntry(named: context.bigFile.lastPathComponent)
            result.check(leftover == nil, "no partial object on the phone: \(leftover.map { "present, \($0.size.map(String.init) ?? "?") bytes" } ?? "absent")")
            let newStaging = stagingDirectories().subtracting(stagingBefore)
            result.check(newStaging.isEmpty, "no staging leftovers: [\(newStaging.sorted().joined(separator: ", "))]")

            // The next copy works, and arrives intact (read back and hashed).
            let small = try await harness.enqueueUpload(context.smallFile)
            let row = await harness.waitTerminal(small, timeout: 60)
            let state = await harness.typedState(small)
            result.check(state == .completed, "next upload: \(describe(state)) in \(fmt(row?.duration ?? -1))s")
            let readBack = try freshDirectory(context.work.appending(path: "stop-upload-readback"))
            let download = try await harness.enqueueDownload(named: context.smallFile.lastPathComponent, to: readBack)
            _ = await harness.waitTerminal(download, timeout: 60)
            let copied = readBack.appending(path: context.smallFile.lastPathComponent)
            let sameBytes = try sha256(copied) == sha256(context.smallFile)
            result.check(sameBytes, "next upload read back from the phone: SHA-256 \(sameBytes ? "matches" : "differs"), size \(fileSize(copied).map(String.init) ?? "missing")")
            print("STOP_RESULT direction=upload latency=\(fmt(latency, 3)) partialOnPhone=\(leftover != nil) stagingLeftovers=\(newStaging.count) nextCopy=\(state == .completed && sameBytes ? "ok" : "failed")")
        } catch {
            result.check(false, "error: \(error)")
        }
        return result
    }

    /// A large download stopped mid-file the same way: no partial file in the
    /// destination (hidden temporaries included), and the next copy works.
    func stopMidFileDownload() async -> ScenarioResult {
        var result = ScenarioResult(name: "S6b Stop mid-file (download)")
        do {
            try await harness.openSandbox(clearing: false)
            // The source must be complete on the phone.
            let existing = await harness.sandboxEntry(named: context.bigFile.lastPathComponent)
            if existing?.size != Int64(context.bigSize) {
                let seed = try await harness.enqueueUpload(context.bigFile)
                _ = await harness.waitTerminal(seed, timeout: Budget.transfer)
                let seedState = await harness.typedState(seed)
                try require(seedState == .completed, "seeding the download source: \(describe(seedState))")
            }

            let stagingBefore = stagingDirectories()
            let destination = try freshDirectory(context.work.appending(path: "stop-download"))
            let job = try await harness.enqueueDownload(named: context.bigFile.lastPathComponent, to: destination)
            let latency = try await stopMidFile(job, into: &result)

            let leftovers = directoryContents(destination)
            result.check(leftovers.isEmpty, "no partial file in the destination: [\(leftovers.joined(separator: ", "))]")
            let newStaging = stagingDirectories().subtracting(stagingBefore)
            result.check(newStaging.isEmpty, "no staging leftovers: [\(newStaging.sorted().joined(separator: ", "))]")
            let source = await harness.sandboxEntry(named: context.bigFile.lastPathComponent)
            result.check(source?.size == Int64(context.bigSize), "the source on the phone is untouched: \(source?.size.map(String.init) ?? "missing") bytes")

            // The next copy works, byte for byte.
            if await harness.sandboxEntry(named: context.smallFile.lastPathComponent) == nil {
                let seed = try await harness.enqueueUpload(context.smallFile)
                _ = await harness.waitTerminal(seed, timeout: 60)
            }
            let smallDestination = try freshDirectory(context.work.appending(path: "stop-download-next"))
            let small = try await harness.enqueueDownload(named: context.smallFile.lastPathComponent, to: smallDestination)
            let row = await harness.waitTerminal(small, timeout: 60)
            let state = await harness.typedState(small)
            result.check(state == .completed, "next download: \(describe(state)) in \(fmt(row?.duration ?? -1))s")
            let copied = smallDestination.appending(path: context.smallFile.lastPathComponent)
            let sameBytes = try sha256(copied) == sha256(context.smallFile)
            result.check(sameBytes, "next download: SHA-256 \(sameBytes ? "matches" : "differs"), size \(fileSize(copied).map(String.init) ?? "missing")")
            print("STOP_RESULT direction=download latency=\(fmt(latency, 3)) partialLocal=\(!leftovers.isEmpty) stagingLeftovers=\(newStaging.count) nextCopy=\(state == .completed && sameBytes ? "ok" : "failed")")
        } catch {
            result.check(false, "error: \(error)")
        }
        return result
    }

    /// Waits until `job` is well under way, presses Stop, and checks that it
    /// settles as cancelled within ``stopLatencyBound`` with the busy lock
    /// released. Returns the latency, in seconds.
    private func stopMidFile(_ job: TrackedJob, into result: inout ScenarioResult) async throws -> Double {
        let threshold = Int64(context.bigSize / 6)
        guard let sent = await harness.waitForProgress(job, bytes: threshold, timeout: 60) else {
            let state = await harness.typedState(job)
            throw ProbeFailure("the copy never got under way (or finished first): \(describe(state))")
        }
        result.check(harness.transferModel.hasActiveTransfers, "copying when Stop is pressed (\(sent >> 20) MiB of \(context.bigSize >> 20) MiB moved)")

        let t0 = ContinuousClock.now
        await harness.transferModel.cancel(jobID: job.id)
        var state = await harness.typedState(job)
        while !(state?.isTerminalForProbe ?? true), seconds(t0.duration(to: .now)) < 30 {
            try? await Task.sleep(for: .milliseconds(5))
            state = await harness.typedState(job)
        }
        let latency = seconds(t0.duration(to: .now))
        let settled = await harness.waitTerminal(job, timeout: 5)
        let rowLatency = seconds(t0.duration(to: .now))
        result.check(state == .cancelled, "settled as cancelled: \(describe(state))")
        result.check(latency <= stopLatencyBound, "the job settled \(fmt(latency, 3))s after Stop (bound \(fmt(stopLatencyBound, 1))s); row ended by \(fmt(rowLatency, 3))s")
        let moved = settled?.sentBytes ?? 0
        result.check(moved < Int64(context.bigSize), "stopped mid-file: \(moved >> 20) MiB of \(context.bigSize >> 20) MiB reported moved")
        let released = await harness.waitUntil(timeout: 3) {
            !harness.transferModel.isDeviceNavigationDisabled && !harness.transferModel.hasActiveTransfers
        }
        result.check(released, "busy lock released, no active transfers")
        return latency
    }
}

/// The app's staging folders (`TransferStaging`) that exist right now.
func stagingDirectories() -> Set<String> {
    let fileManager = FileManager.default
    guard let probe = try? fileManager.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: fileManager.temporaryDirectory,
        create: true
    ) else { return [] }
    let root = probe.deletingLastPathComponent()
    try? fileManager.removeItem(at: probe)
    let prefix = "\(AppIdentity.fileNamePrefix)-Staging-"
    return Set(directoryContents(root).filter { $0.hasPrefix(prefix) })
}

func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
