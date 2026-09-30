// LifecycleProbe: verifies the connection lifecycle of the app's Core on a real
// phone — reconnect after re-enumeration, device loss during a copy, giving up
// when the phone does not come back, quitting during a copy, and the bug
// report — with the same objects the app wires together (USBWatcher hotplug,
// DeviceConnectionController, TransferViewModel/TransferQueue,
// DeviceSessionShutdown, BugReportGenerator), minus SwiftUI — and Stop
// mid-file on a large upload and download.
//
//   LifecycleProbe [--scenarios 1,2,3,5,6,4] [--size-mb 300] [--work DIR]
//
// adb triggers the USB events. Everything written on the phone lives in
// /Download/ART-Lifecycle-Probe/. The last line is "VERIFICATION ok" only when
// every attempted scenario passed; otherwise "VERIFICATION failed: …" and
// exit status 1. The phone is left in File transfer (mtp).

#if canImport(Glibc)
@preconcurrency import Glibc
#endif
import AndroidRapidTransferCore
import Foundation

@main
@MainActor
struct LifecycleProbe {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        var scenarios = ["1", "2", "3", "5", "6", "4"]
        var sizeMB = 300
        var work = FileManager.default.temporaryDirectory.appending(path: "ART-LifecycleProbe")
        var childQuit = false

        var arguments = CommandLine.arguments.dropFirst()
        while let argument = arguments.popFirst() {
            switch argument {
            case "--scenarios":
                scenarios = (arguments.popFirst() ?? "").split(separator: ",").map(String.init)
            case "--size-mb":
                guard let value = arguments.popFirst().flatMap(Int.init), value > 0 else { usage() }
                sizeMB = value
            case "--work":
                guard let value = arguments.popFirst() else { usage() }
                work = URL(fileURLWithPath: value)
            case "--child-quit":
                childQuit = true
            default:
                usage()
            }
        }

        let upload = work.appending(path: "upload")
        let context = ProbeContext(
            work: work,
            bigFile: upload.appending(path: "art-lifecycle-big.bin"),
            smallFile: upload.appending(path: "art-lifecycle-small.bin"),
            bigSize: sizeMB << 20,
            smallSize: 1 << 20
        )
        if childQuit {
            await runQuitChild(context)
        }

        log("LifecycleProbe scenarios=\(scenarios.joined(separator: ",")) size=\(sizeMB) MiB work=\(work.path)")
        do {
            try FileManager.default.createDirectory(at: upload, withIntermediateDirectories: true)
            try ensureRandomFile(at: context.bigFile, size: context.bigSize)
            try ensureRandomFile(at: context.smallFile, size: context.smallSize)
        } catch {
            finish(["setup: local fixtures: \(error)"], results: [])
        }

        let adbReachable = await ADB.reachable()
        let functions = await ADB.functions()
        log("adb reachable=\(adbReachable) functions=\(functions)")
        guard adbReachable else { finish(["setup: adb is not reachable"], results: []) }
        if !functions.contains("mtp"), !(await ADB.ensureMTP()) {
            finish(["setup: the phone is not in File transfer"], results: [])
        }

        let harness = Harness(localDirectory: work)
        await harness.start()
        guard await harness.waitConnectedAndLoaded(timeout: 40) else {
            finish(["setup: never connected: \(harness.describeController())"], results: [])
        }
        do {
            try await harness.openSandbox(clearing: true)
        } catch {
            finish(["setup: sandbox: \(error)"], results: [])
        }
        log("connected: \(harness.describeController()), at \(harness.controller.deviceModel?.currentLocation ?? "?")")

        let runner = Scenarios(harness: harness, context: context)
        var results: [ScenarioResult] = []
        for scenario in scenarios {
            log("=== scenario \(scenario) ===")
            switch scenario {
            case "1": results.append(await runner.reconnectAfterReenumeration())
            case "2":
                results.append(await runner.deviceLossDuringUpload())
                await recover(harness)
                results.append(await runner.deviceLossDuringDownload())
            case "3":
                results.append(await runner.phoneLeavesMTPWithHotplug())
                await recover(harness)
                results.append(await runner.phoneLeavesMTPWithoutHotplug())
            case "4": results.append(await runner.quitDuringCopy())
            case "5": results.append(await runner.bugReport())
            case "6":
                results.append(await runner.stopMidFileUpload())
                await recover(harness)
                results.append(await runner.stopMidFileDownload())
            default: log("unknown scenario \(scenario)")
            }
            if let last = results.last { log("\(last.outcome.rawValue): \(last.name)") }
            if scenario != "4" { await recover(harness) }
        }

        // Scenario 4 leaves the phone released; otherwise release it now.
        if !scenarios.contains("4") {
            try? await harness.openSandbox(clearing: true)
            _ = await harness.controller.releaseDevice()
        }
        let restored = await ADB.ensureMTP()
        var problems: [String] = []
        if !restored { problems.append("the phone could not be put back in mtp") }
        finish(problems, results: results)
    }

    /// Between scenarios: the phone in mtp, the controller connected and the
    /// pane in the sandbox, whatever the previous scenario left.
    static func recover(_ harness: Harness) async {
        // adb drops with a gadget reset; an unreachable adb reads as "no
        // functions", and re-selecting mtp would re-enumerate the phone again.
        _ = await ADB.waitReachable(timeout: 20)
        if !(await ADB.functions().contains("mtp")) {
            log("recover: phone left mtp; restoring")
            await ADB.ensureMTP()
        }
        if !(await harness.waitConnectedAndLoaded(timeout: 20)) {
            log("recover: not connected (\(harness.describeController())); Retry")
            await harness.controller.retry()
            if !(await harness.waitConnectedAndLoaded(timeout: 40)) {
                // Seen once after a gadget reset with no host session: the
                // phone stayed in mtp but its responder stopped answering.
                log("recover: still not connected; cycling the phone's USB functions")
                _ = await ADB.setFunctions("")
                try? await Task.sleep(for: .seconds(3))
                _ = await ADB.setFunctions("mtp")
                if !(await harness.waitConnectedAndLoaded(timeout: 20)) {
                    await harness.controller.retry()
                    _ = await harness.waitConnectedAndLoaded(timeout: 40)
                }
            }
        }
        if harness.isConnected {
            try? await harness.openSandbox(clearing: false)
        }
    }

    static func finish(_ problems: [String], results: [ScenarioResult]) -> Never {
        log("=== results ===")
        for result in results {
            print("\(result.outcome.rawValue)  \(result.name)")
            for line in result.evidence { print("      \(line)") }
        }
        let failed = results.filter { $0.outcome == .fail }.map(\.name) + problems
        if failed.isEmpty {
            print("VERIFICATION ok")
            exit(0)
        }
        print("VERIFICATION failed: \(failed.joined(separator: "; "))")
        exit(1)
    }

    static func usage() -> Never {
        print("usage: LifecycleProbe [--scenarios 1,2,3,5,6,4] [--size-mb N] [--work DIR]")
        exit(2)
    }

    /// Scenario 4's child: start a large upload, then run the app's quit path
    /// (what `AppDelegate.applicationShouldTerminate` defers to), report, and
    /// exit the way the app does once the quit is answered.
    static func runQuitChild(_ context: ProbeContext) async -> Never {
        let harness = Harness(localDirectory: context.work)
        await harness.start()
        guard await harness.waitConnectedAndLoaded(timeout: 40) else {
            print("QUIT_RESULT error=never-connected")
            exit(1)
        }
        do {
            try await harness.openSandbox(clearing: true)
            let job = try await harness.enqueueUpload(context.bigFile)
            guard let sent = await harness.waitForProgress(job, bytes: Int64(context.bigSize / 6), timeout: 60) else {
                print("QUIT_RESULT error=copy-never-started")
                exit(1)
            }
            let copying = harness.transferModel.hasActiveTransfers
            log("quitting with \(sent >> 20) MiB sent")
            let transferModel = harness.transferModel
            let controller = harness.controller
            let released = OutputBox()
            let t0 = ContinuousClock.now
            let outcome = await DeviceSessionShutdown.run(
                stopTransfers: { await transferModel.stopAll() },
                releaseDevice: {
                    _ = await controller.releaseDevice()
                    released.append("yes")
                }
            )
            let took = seconds(t0.duration(to: .now))
            let state = await harness.typedState(job)
            print("QUIT_RESULT outcome=\(outcome) elapsed=\(fmt(took, 3)) copying=\(copying) released=\(released.text == "yes") job=\(describe(state).replacingOccurrences(of: " ", with: "_"))")
            exit(0)
        } catch {
            print("QUIT_RESULT error=\(error)")
            exit(1)
        }
    }
}
