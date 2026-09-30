import AndroidRapidTransferCore
import Foundation
import MTPKit

struct ScenarioResult {
    enum Outcome: String {
        case pass = "PASS"
        case fail = "FAIL"
        case skip = "SKIP"
    }

    let name: String
    var outcome: Outcome = .pass
    var evidence: [String] = []

    mutating func note(_ line: String) {
        evidence.append(line)
        log("  \(name): \(line)")
    }

    mutating func check(_ condition: Bool, _ line: String) {
        if !condition { outcome = .fail }
        note("\(condition ? "ok" : "FAILED"): \(line)")
    }
}

struct ProbeContext {
    let work: URL
    let bigFile: URL
    let smallFile: URL
    let bigSize: Int
    let smallSize: Int
}

/// Timeouts, in seconds.
enum Budget {
    static let lossNoticed = 15.0
    static let reconnect = 45.0
    static let transfer = 240.0
}

@MainActor
struct Scenarios {
    let harness: Harness
    let context: ProbeContext

    private var controller: DeviceConnectionController { harness.controller }

    // MARK: - 1. Reconnect after re-enumeration

    func reconnectAfterReenumeration() async -> ScenarioResult {
        var result = ScenarioResult(name: "S1 reconnect after re-enumeration")
        guard harness.isConnected, let model = controller.deviceModel,
              let serial = harness.connectedSerial else {
            result.check(false, "precondition: connected (\(harness.describeController()))")
            return result
        }
        let storage = model.selectedStorageID
        let location = model.currentLocation
        result.note("before: serial=\(serial) storage=\(storage.map(String.init) ?? "?") folder=\(location)")

        let factoryBefore = harness.factoryCallTimes.count
        let t0 = elapsed()
        // Not awaited: adb itself drops with the re-enumeration.
        let trigger = Task.detached { await ADB.reenumerate() }
        var tLoss = t0
        let noticed = await harness.waitUntil(timeout: Budget.lossNoticed) {
            tLoss = elapsed()
            return !harness.isConnected
        }
        let adb = await trigger.value
        result.note("adb svc usb resetUsbGadget: status=\(adb.reset.status)\(adb.reset.timedOut ? " (timed out: adb dropped)" : "")")
        if let reselected = adb.mtpReselectedAt {
            result.note("the phone came back without mtp (locked); mtp selected again at +\(fmt(reselected - t0))s")
        }
        result.check(noticed, "loss noticed without any user action after \(fmt(tLoss - t0))s")
        if !noticed {
            return result
        }
        var sawReconnecting = false
        let back = await harness.waitUntil(timeout: Budget.reconnect) {
            if controller.isReconnecting { sawReconnecting = true }
            return harness.isConnected && harness.deviceModelReady
        }
        let tBack = elapsed()
        result.check(back, "reconnected on its own \(fmt(tBack - t0))s after the trigger (\(fmt(tBack - tLoss))s after the loss"
                     + (adb.mtpReselectedAt.map { ", \(fmt(tBack - $0))s after mtp was selected again" } ?? "") + ")")
        guard back, let restored = controller.deviceModel else { return result }
        result.check(harness.connectedSerial == serial, "same serial: \(harness.connectedSerial ?? "?")")
        result.check(restored.currentLocation == location, "folder restored: \(restored.currentLocation)")
        result.check(restored.selectedStorageID == storage, "storage restored: \(restored.selectedStorageID.map(String.init) ?? "?")")
        result.check(controller.connectionNotice == nil, "no notice after reconnecting")
        let attempts = harness.factoryCallTimes.dropFirst(factoryBefore).map { fmt($0 - t0) }
        result.note("path: \(sawReconnecting ? "reconnect policy" : "hotplug attach"); provider opens at +\(attempts.joined(separator: ", +"))s")
        return result
    }

    // MARK: - 2. Device loss during a copy

    func deviceLossDuringUpload() async -> ScenarioResult {
        var result = ScenarioResult(name: "S2a device loss during upload")
        do {
            try await harness.openSandbox(clearing: true)
            let job = try await harness.enqueueUpload(context.bigFile)
            try await interrupt(job, into: &result)
            guard await reconnected(into: &result) else { return result }
            let small = try await harness.enqueueUpload(context.smallFile)
            let row = await harness.waitTerminal(small, timeout: 60)
            let state = await harness.typedState(small)
            result.check(state == .completed, "follow-up small upload: \(describe(state)) in \(fmt(row?.duration ?? -1))s")
            let entry = await harness.sandboxEntry(named: context.smallFile.lastPathComponent)
            result.check(entry?.size == Int64(context.smallSize), "small file on the phone: size \(entry?.size.map(String.init) ?? "missing")")
            let partial = await harness.sandboxEntry(named: context.bigFile.lastPathComponent)
            result.note("interrupted upload on the phone afterwards: \(partial.map { "present, \($0.size.map(String.init) ?? "?") bytes" } ?? "absent")")
        } catch {
            result.check(false, "error: \(error)")
        }
        return result
    }

    func deviceLossDuringDownload() async -> ScenarioResult {
        var result = ScenarioResult(name: "S2b device loss during download")
        do {
            try await harness.openSandbox(clearing: false)
            // The source must be complete on the phone: upload it uninterrupted.
            let upload = try await harness.enqueueUpload(context.bigFile)
            let uploaded = await harness.waitTerminal(upload, timeout: Budget.transfer)
            let uploadState = await harness.typedState(upload)
            try require(uploadState == .completed, "seeding the download source: \(describe(uploadState))")
            if let duration = uploaded?.duration, duration > 0 {
                result.note("seed upload \(context.bigSize >> 20) MiB in \(fmt(duration))s (\(fmt(Double(context.bigSize) / duration / 1e6, 1)) MB/s)")
            }

            let destination = try freshDirectory(context.work.appending(path: "download-interrupted"))
            let job = try await harness.enqueueDownload(named: context.bigFile.lastPathComponent, to: destination)
            try await interrupt(job, into: &result)
            let leftovers = directoryContents(destination)
            let clean = leftovers.isEmpty
            result.check(clean, "no partial file in the local destination: [\(leftovers.joined(separator: ", "))]")
            guard await reconnected(into: &result) else { return result }

            let smallDestination = try freshDirectory(context.work.appending(path: "download-followup"))
            try await harness.openSandbox(clearing: false)
            // The small file came from S2a; upload it again if S2a did not run.
            if await harness.sandboxEntry(named: context.smallFile.lastPathComponent) == nil {
                let seed = try await harness.enqueueUpload(context.smallFile)
                _ = await harness.waitTerminal(seed, timeout: 60)
            }
            let small = try await harness.enqueueDownload(named: context.smallFile.lastPathComponent, to: smallDestination)
            let row = await harness.waitTerminal(small, timeout: 60)
            let state = await harness.typedState(small)
            result.check(state == .completed, "follow-up small download: \(describe(state)) in \(fmt(row?.duration ?? -1))s")
            let size = fileSize(smallDestination.appending(path: context.smallFile.lastPathComponent))
            result.check(size == context.smallSize, "small file on the Mac: size \(size.map(String.init) ?? "missing")")
        } catch {
            result.check(false, "error: \(error)")
        }
        return result
    }

    /// Re-enumerates the phone once `job` is well under way and checks that
    /// it fails as device-lost, promptly, with the busy lock released.
    private func interrupt(_ job: TrackedJob, into result: inout ScenarioResult) async throws {
        let threshold = Int64(context.bigSize / 6)
        guard let sent = await harness.waitForProgress(job, bytes: threshold, timeout: 60) else {
            let state = await harness.typedState(job)
            throw ProbeFailure("the copy never got under way (or finished first): \(describe(state))")
        }
        result.check(harness.transferModel.isDeviceNavigationDisabled, "busy lock held while copying (\(sent >> 20) MiB sent)")
        let t0 = elapsed()
        _ = Task.detached { await ADB.reenumerate() } // not awaited: adb drops with it
        result.note("adb svc usb resetUsbGadget at \(sent >> 20) MiB")
        let row = await harness.waitTerminal(job, timeout: 60)
        let tFail = elapsed()
        result.check(row != nil, "the copy's row ended \(fmt(tFail - t0))s after the trigger (no hang)")
        // When the hotplug detach wins the race against the native I/O error,
        // the view model settles the row (detach) while the queue is still
        // unwinding the native call; wait for the queue's own verdict.
        var state = await harness.typedState(job)
        let deadline = elapsed() + 20
        while !(state?.isTerminalForProbe ?? true), elapsed() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            state = await harness.typedState(job)
        }
        result.note("the queue's job settled \(fmt(elapsed() - t0))s after the trigger")
        result.check(isDeviceLost(state), "failed as device-lost: \(describe(state))")
        let released = await harness.waitUntil(timeout: 3) {
            !harness.transferModel.isDeviceNavigationDisabled && !harness.transferModel.hasActiveTransfers
        }
        result.check(released, "busy lock released, no active transfers")
        let sentAtEnd = row?.sentBytes ?? 0
        result.note("bytes reported moved before the failure: \(sentAtEnd >> 20) MiB of \(context.bigSize >> 20) MiB")
    }

    private func reconnected(into result: inout ScenarioResult) async -> Bool {
        let t0 = elapsed()
        let back = await harness.waitConnectedAndLoaded(timeout: Budget.reconnect)
        result.check(back, "controller reconnected (\(fmt(elapsed() - t0))s after the failure settled): \(harness.describeController())")
        if back {
            result.check(controller.deviceModel?.currentLocation == sandboxDevicePath,
                         "folder restored: \(controller.deviceModel?.currentLocation ?? "?")")
        }
        return back
    }

    // MARK: - 3. The phone does not come back

    /// Hotplug on, as by default: MTP disappears while adb stays.
    func phoneLeavesMTPWithHotplug() async -> ScenarioResult {
        var result = ScenarioResult(name: "S3a MTP removed (hotplug on)")
        guard await precheckAdbAcrossModeSwitch(into: &result) else { return result }
        let factoryBefore = harness.factoryCallTimes.count
        let t0 = elapsed()
        _ = await ADB.setFunctions("")
        let adbStays = await ADB.waitReachable(timeout: 20)
        let functions = await ADB.functions()
        result.note("after setFunctions '': adb reachable=\(adbStays), functions=\(functions.isEmpty ? "(none)" : functions)")
        guard adbStays else {
            result.outcome = .skip
            result.note("adb dropped with MTP; restoring and skipping")
            _ = await ADB.waitReachable(timeout: 60)
            await ADB.ensureMTP()
            return result
        }
        _ = await harness.waitUntil(timeout: 25) { false }
        let settled = harness.describeController()
        let timeline = harness.timeline.filter { $0.time >= t0 }.map { "+\(fmt($0.time - t0))s \($0.text)" }
        let attempts = harness.factoryCallTimes.dropFirst(factoryBefore).map { fmt($0 - t0) }
        result.note("timeline: \(timeline.joined(separator: " | "))")
        result.note("provider opens: \(attempts.isEmpty ? "none" : "+" + attempts.joined(separator: ", +") + "s")")
        if case .noDevice = controller.state {
            result.check(!controller.isReconnecting, "settled on no device, not reconnecting, after 25 s: \(settled)")
        } else {
            result.check(false, "settled on no device after 25 s: \(settled)")
        }
        result.check(controller.deviceModel == nil && controller.transferQueue == nil, "session cleared")

        let t1 = elapsed()
        _ = await ADB.setFunctions("mtp")
        let back = await harness.waitConnectedAndLoaded(timeout: Budget.reconnect)
        result.check(back, "hotplug reconnected \(fmt(elapsed() - t1))s after setFunctions mtp: \(harness.describeController())")
        return result
    }

    /// Hotplug off (Settings > USB hotplug unchecked): the loss is found by the
    /// next device operation, which starts the bounded reconnect sequence.
    func phoneLeavesMTPWithoutHotplug() async -> ScenarioResult {
        var result = ScenarioResult(name: "S3b MTP removed (hotplug off, budget)")
        guard await precheckAdbAcrossModeSwitch(into: &result) else { return result }
        await controller.setUsbHotplugEnabled(false)
        _ = await ADB.setFunctions("")
        let adbStays = await ADB.waitReachable(timeout: 20)
        guard adbStays else {
            result.outcome = .skip
            result.note("adb dropped with MTP; restoring and skipping")
            _ = await ADB.waitReachable(timeout: 60)
            await ADB.ensureMTP()
            await controller.setUsbHotplugEnabled(true)
            return result
        }
        try? await Task.sleep(for: .seconds(2))
        result.note("MTP gone, hotplug off: controller still \(harness.describeController())")

        let factoryBefore = harness.factoryCallTimes.count
        let t0 = elapsed()
        await controller.deviceModel?.refresh()
        result.note("refresh after the loss: \(controller.deviceModel?.error?.message ?? "pane already cleared")")
        var sawReconnecting = false
        let settled = await harness.waitUntil(timeout: 45) {
            if controller.isReconnecting { sawReconnecting = true }
            if case .noDevice = controller.state {
                return !controller.isReconnecting && controller.connectionNotice != nil
            }
            return false
        }
        let tEnd = elapsed()
        let attempts = harness.factoryCallTimes.dropFirst(factoryBefore).map { $0 - t0 }
        let gaps = zip(attempts.dropFirst(), attempts).map { fmt($0 - $1) }
        result.check(sawReconnecting, "a reconnect sequence started")
        result.check(settled, "ended in no device with the notice \(fmt(tEnd - t0))s after the loss was found: \(harness.describeController())")
        result.check(attempts.count == 6, "six attempts (\(attempts.count)) at +\(attempts.map { fmt($0) }.joined(separator: ", +"))s, gaps \(gaps.joined(separator: ", "))s")
        result.check(tEnd - t0 >= 14 && tEnd - t0 <= 30, "gave up after the ~15 s budget: \(fmt(tEnd - t0))s")

        // Restore the phone; hotplug is off, so re-enabling it (the setting)
        // must pick the phone up from the watcher's initial device scan.
        let t1 = elapsed()
        _ = await ADB.setFunctions("mtp")
        _ = await ADB.waitReachable(timeout: 20)
        try? await Task.sleep(for: .seconds(2))
        let stillDown = !harness.isConnected
        result.check(stillDown, "with hotplug off nothing reconnects by itself: \(harness.describeController())")
        await controller.setUsbHotplugEnabled(true)
        let back = await harness.waitConnectedAndLoaded(timeout: 20)
        result.check(back, "re-enabling hotplug reconnected \(fmt(elapsed() - t1))s after setFunctions mtp: \(harness.describeController())")
        if !back {
            result.note("recovering with Retry")
            await controller.retry()
            _ = await harness.waitConnectedAndLoaded(timeout: Budget.reconnect)
        }
        return result
    }

    private func precheckAdbAcrossModeSwitch(into result: inout ScenarioResult) async -> Bool {
        let reachable = await ADB.reachable()
        let functions = await ADB.functions()
        result.note("precheck: adb reachable=\(reachable), functions=\(functions)")
        guard reachable, functions.contains("mtp"), harness.isConnected else {
            result.check(false, "precondition: adb reachable, phone in mtp, connected (\(harness.describeController()))")
            return false
        }
        return true
    }

    // MARK: - 5. Bug report

    func bugReport() async -> ScenarioResult {
        var result = ScenarioResult(name: "S5 bug report end to end")
        guard harness.isConnected, let serial = harness.connectedSerial else {
            result.check(false, "precondition: connected (\(harness.describeController()))")
            return result
        }
        do {
            let output = try freshDirectory(context.work.appending(path: "bugreport"))
            let session = RecordingBugReportSession(
                inner: ConnectionControllerBugReportSession(
                    controller: controller,
                    hasActiveTransfers: { [transferModel = harness.transferModel] in transferModel.hasActiveTransfers },
                    hotplugEnabled: { true }
                ),
                harness: harness
            )
            let tool = RecordingDebugTool(inner: SwiftMTPDiagnosticTool())
            let generator = BugReportGenerator(
                session: session,
                debugTool: tool,
                diagnostics: .live(
                    settings: AppSettings(settingsURL: context.work.appending(path: "probe-settings.json")),
                    batchStore: TransferBatchStore()
                ),
                outputDirectory: output
            )
            let t0 = elapsed()
            let zip = try await generator.generate()
            let tDone = elapsed()
            result.note("report: \(zip.path) in \(fmt(tDone - t0))s")

            let times = tool.times
            result.check(session.stateAfterRelease == "noDevice", "device released before the tool: \(session.stateAfterRelease ?? "release not called")")
            if let released = session.releasedAt, let toolStart = times.start, let toolEnd = times.end,
               let resumeStart = session.resumeStartedAt {
                result.check(released <= toolStart && toolEnd <= resumeStart,
                             "order: release done +\(fmt(released - t0))s, tool +\(fmt(toolStart - t0))..+\(fmt(toolEnd - t0))s, resume +\(fmt(resumeStart - t0))s")
            } else {
                result.check(false, "release, tool and resume all ran")
            }

            let unpacked = try freshDirectory(context.work.appending(path: "bugreport-unzipped"))
            #if os(macOS)
            let unzip = await runCommand("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            #else
            let unzip = await runCommand("/usr/bin/unzip", ["-q", zip.path, "-d", unpacked.path])
            #endif
            result.check(unzip.status == 0, "zip unpacks (\(unzip.output))")
            let folder = unpacked.appending(path: BugReportGenerator.folderName)
            let files = directoryContents(folder)
            let expected = (generator.contents.map(\.fileName) + ["README.txt"]).sorted()
            result.check(files == expected, "zip contents: \(files.joined(separator: ", "))")
            let reportText = (try? String(contentsOf: folder.appending(path: BugReportItem.deviceDiagnostic.fileName), encoding: .utf8)) ?? ""
            let outcomeLine = reportText.split(separator: "\n").first { $0.hasPrefix("Outcome:") }.map(String.init) ?? "no outcome line"
            result.check(outcomeLine == "Outcome: completed", "the diagnostic ran: \(outcomeLine), \(reportText.utf8.count) bytes")
            let model = reportText.split(separator: "\n").first { $0.hasPrefix("Model: ") }.map(String.init)
            result.check(model != nil, "the diagnostic read the phone's DeviceInfo: \(model ?? "no DeviceInfo")")
            let device = (try? String(contentsOf: folder.appending(path: "device.txt"), encoding: .utf8)) ?? ""
            result.check(device.contains(serial), "device.txt describes the phone")

            let back = await harness.waitConnectedAndLoaded(timeout: 30)
            result.check(back, "resumed: reconnected \(fmt(elapsed() - (session.resumeStartedAt ?? tDone)))s after resume began: \(harness.describeController())")

            // The resumed controller must still follow hotplug.
            if back {
                let t1 = elapsed()
                _ = Task.detached { await ADB.reenumerate() } // not awaited: adb drops with it
                let noticed = await harness.waitUntil(timeout: Budget.lossNoticed) { !harness.isConnected }
                result.check(noticed, "after resume, hotplug still sees a re-enumeration (\(fmt(elapsed() - t1))s)")
                let again = noticed ? await harness.waitConnectedAndLoaded(timeout: Budget.reconnect) : false
                result.check(again, "after resume, hotplug reconnects (\(fmt(elapsed() - t1))s)")
                if !again || !noticed {
                    result.note("recovering with Retry")
                    await controller.retry()
                    _ = await harness.waitConnectedAndLoaded(timeout: Budget.reconnect)
                }
            }
        } catch {
            result.check(false, "error: \(error)")
        }
        return result
    }

    // MARK: - 4. Quit during a copy

    func quitDuringCopy() async -> ScenarioResult {
        var result = ScenarioResult(name: "S4 quit during a copy")
        // The quit runs in a child process, which then exits like the app does
        // once `applicationShouldTerminate` is answered. This process lets go
        // of the phone first so the child can open it.
        _ = await controller.releaseDevice()
        harness.stopObserving()
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var environment = ProcessInfo.processInfo.environment
        environment["LIFECYCLE_PROBE_LOG_PREFIX"] = "child| "
        let child = await runChild(
            executable,
            ["--child-quit", "--work", context.work.path,
             "--size-mb", String(context.bigSize >> 20)],
            environment: environment,
            timeout: 180
        )
        let tExit = elapsed()
        let crashMarkers = ["fatal error:", "SIGSEGV"]
        let crashed = child.status > 1 || crashMarkers.contains { child.output.contains($0) }
        result.check(child.status == 0 && !crashed, "child exited with status \(child.status)")
        let quitLine = child.output.split(separator: "\n").last { $0.contains("QUIT_RESULT") }.map(String.init)
        result.note(quitLine ?? "no QUIT_RESULT line")
        if let quitLine, let value = Self.field("elapsed", in: quitLine), let elapsedQuit = Double(value) {
            // Quit aborts the file in flight, so the phone is released by the
            // quit path itself (measured ~0.34 s), not by the 3 s timeout and
            // process exit.
            result.check(Self.field("outcome", in: quitLine) == "completed",
                         "the quit path completed instead of timing out: outcome \(Self.field("outcome", in: quitLine) ?? "?")")
            result.check(elapsedQuit <= Self.quitReleaseBound,
                         "the phone was released \(value)s after quit began (bound \(fmt(Self.quitReleaseBound, 1))s)")
            result.check(Self.field("released", in: quitLine) == "true", "releaseDevice() returned")
            result.check(Self.field("job", in: quitLine) == "cancelled", "the copy settled as cancelled: \(Self.field("job", in: quitLine) ?? "?")")
            result.check(Self.field("copying", in: quitLine) == "true", "a copy was running when quit began")
        } else {
            result.check(false, "the child reported the quit path")
        }

        // A fresh provider opens the phone at once.
        let t0 = elapsed()
        do {
            let provider = makeProvider(log: { log("  swiftmtp: \($0)") })
            let storages: [StorageInfo]
            do {
                storages = try await provider.storages()
            } catch {
                result.check(false, "fresh provider's first open, \(fmt(elapsed() - t0))s after the child exited: \(error)")
                // How long until the phone can be opened at all (the app would
                // need a Retry or a replug here).
                var reopened: [StorageInfo]?
                var lastError: Error = error
                for _ in 0..<6 where reopened == nil {
                    try await Task.sleep(for: .seconds(3))
                    do {
                        reopened = try await provider.storages()
                    } catch {
                        lastError = error
                        result.note("open failed again at +\(fmt(elapsed() - t0))s: \(error)")
                    }
                }
                guard let reopened else { throw lastError }
                storages = reopened
                result.note("a later open succeeded \(fmt(elapsed() - t0))s after the child exited")
            }
            guard let first = storages.enumerated().compactMap({ DeviceStorage(storage: $0.element, index: $0.offset) }).first else {
                throw ProbeFailure("no storage")
            }
            let root = try await provider.walk(input: DirectoryWalkInput(
                storageId: first.id, fullPath: "/", skipDisallowedFiles: false, skipHiddenFiles: true))
            result.check(true, "fresh provider opened the phone and listed / (\(root.count) entries) \(fmt(elapsed() - t0))s after the child exited (+\(fmt(t0 - tExit))s)")
            // Clean the sandbox: the interrupted upload may have left a file.
            let sandbox = try await provider.walk(input: DirectoryWalkInput(
                storageId: first.id, fullPath: sandboxDevicePath, skipDisallowedFiles: false, skipHiddenFiles: false))
            result.check(sandbox.isEmpty, "no partial object on the phone after the quit: [\(sandbox.map { "\($0.name) \($0.size)B" }.joined(separator: ", "))]")
            if !sandbox.isEmpty {
                let deleted = try? await provider.deleteFiles(input: DeleteFileInput(
                    storageId: first.id, files: sandbox.map { "\(sandboxDevicePath)/\($0.name)" }))
                result.note("sandbox cleared: \(deleted == true)")
            }
            _ = try? await provider.dispose()
        } catch {
            result.check(false, "fresh provider could not open the phone: \(error)")
        }
        _ = await ADB.waitReachable(timeout: 30)
        let functions = await ADB.functions()
        result.check(functions.contains("mtp"), "phone still in MTP: \(functions)")
        return result
    }

    /// The longest quit may take to release the phone while a large file is
    /// in flight: well inside ``DeviceSessionShutdown/standardTimeout``.
    static let quitReleaseBound = 1.5

    static func field(_ name: String, in line: String) -> String? {
        for part in line.split(separator: " ") where part.hasPrefix("\(name)=") {
            return String(part.dropFirst(name.count + 1))
        }
        return nil
    }
}

/// Runs the child with its output streamed into this log as it arrives.
func runChild(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    timeout: TimeInterval
) async -> CommandResult {
    await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            collected.append(text)
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "launch failed: \(error)", timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                process.terminate()
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Not waitUntilExit(): on a cooperative thread it can spin its run
        // loop forever after the child has already exited (seen with adb).
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            let text = String(decoding: rest, as: UTF8.self)
            collected.append(text)
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        return CommandResult(status: status, output: collected.text, timedOut: timedOut)
    }.value
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.withLock { buffer += text } }
    var text: String { lock.withLock { buffer } }
}

// MARK: - Bug report instrumentation

@MainActor
final class RecordingBugReportSession: BugReportDeviceSession {
    private let inner: ConnectionControllerBugReportSession
    private let harness: Harness
    private(set) var releasedAt: Double?
    private(set) var stateAfterRelease: String?
    private(set) var resumeStartedAt: Double?

    init(inner: ConnectionControllerBugReportSession, harness: Harness) {
        self.inner = inner
        self.harness = harness
    }

    var hasActiveTransfers: Bool { inner.hasActiveTransfers }

    func deviceSummary() -> String { inner.deviceSummary() }

    func release() async -> Bool {
        let wasActive = await inner.release()
        releasedAt = elapsed()
        stateAfterRelease = harness.describeController()
        log("bug report: device released (wasActive=\(wasActive)), controller \(stateAfterRelease ?? "?")")
        return wasActive
    }

    func resume(wasActive: Bool) async {
        resumeStartedAt = elapsed()
        log("bug report: resuming (wasActive=\(wasActive))")
        await inner.resume(wasActive: wasActive)
    }
}

final class RecordingDebugTool: DebugToolRunning, @unchecked Sendable {
    private let inner: SwiftMTPDiagnosticTool
    private let lock = NSLock()
    private var start: Double?
    private var end: Double?

    init(inner: SwiftMTPDiagnosticTool) {
        self.inner = inner
    }

    var times: (start: Double?, end: Double?) { lock.withLock { (start, end) } }

    var reportItem: BugReportItem { inner.reportItem }

    func run() async -> DebugToolResult {
        lock.withLock { start = elapsed() }
        log("bug report: diagnostic starting")
        let result = await inner.run()
        lock.withLock { end = elapsed() }
        log("bug report: diagnostic finished, succeeded=\(result.succeeded)")
        return result
    }
}
