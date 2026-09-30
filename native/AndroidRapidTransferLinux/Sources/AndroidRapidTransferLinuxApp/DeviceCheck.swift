import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// `--device-check [quick]`: drives the real window against a real phone —
/// connect, browse, copy both ways, a conflict, Stop mid-file, a simulated
/// unplug (through adb, when `ART_ADB` and `ANDROID_SERIAL` are set) and a
/// clean quit. Works in `/Download/ART-Linux-App-Test` on the phone and
/// removes it afterwards. `quick` only connects, lists and quits (to prove
/// the previous run released the phone). Prints `VERIFICATION ok` on success.
@MainActor
final class DeviceCheck {
    let controller: AppController
    let quick: Bool
    private(set) var exitStatus: Int32 = 1
    private var failures: [String] = []
    private var passed = 0
    private let start = Date()
    private let bag = ObserverBag()
    private static let phoneFolder = "ART-Linux-App-Test"

    init(controller: AppController, quick: Bool) {
        self.controller = controller
        self.quick = quick
    }

    func begin() {
        let watchdog = MainLoopTimer.after(quick ? 60 : 300) {
            say("FAILED: device check timed out")
            exit(2)
        }
        let connection = controller.connection
        bag.onChange(initial: true, { ConnectionPanePhase(controller: connection).kind }) { [weak self] kind in
            self?.log("PHASE \(kind)")
        }
        Task { @MainActor in
            if quick { await runQuick() } else { await run() }
            watchdog.cancel()
            if failures.isEmpty {
                say("VERIFICATION ok (\(passed) checks)")
                exitStatus = 0
            } else {
                say("FAILED: \(failures.count) of \(passed + failures.count) checks: \(failures.joined(separator: "; "))")
            }
            let quitStart = Date()
            await controller.shutdownAndQuit()
            say(String(format: "quit released the phone in %.3f s", Date().timeIntervalSince(quitStart)))
        }
    }

    private func log(_ text: String) {
        say(String(format: "[+%7.3f] %@", Date().timeIntervalSince(start), text))
    }

    private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            log("CHECK ok   \(name)\(detail().isEmpty ? "" : " — \(detail())")")
        } else {
            failures.append(name)
            log("CHECK FAIL \(name)\(detail().isEmpty ? "" : " (\(detail()))")")
        }
    }

    @discardableResult
    private func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private var window: MainWindow { controller.mainWindow! }
    private var device: BrowserPane<DeviceBrowserViewModel>? { window.devicePane.browser }
    private var local: BrowserPane<LocalBrowserViewModel> { window.computerPane.pane }
    private var transfers: TransferViewModel { controller.transferModel }

    private func select(_ names: [String], in pane: BrowserPane<some BrowserPaneModel>) async -> Bool {
        _ = await waitUntil(timeout: 5) { names.allSatisfy { name in pane.store.items.contains { $0.name == name } } }
        let pipeline = pane.model.viewMode == .grid ? pane.gridView.pipeline : pane.columnView.pipeline
        let positions = names.compactMap { name in (0..<pipeline.visibleCount).first { pipeline.item(at: $0)?.name == name } }
        guard positions.count == names.count else { return false }
        pipeline.selection.setSelection(positions)
        try? await Task.sleep(for: .milliseconds(100))
        return true
    }

    private func go(_ path: String, in pane: BrowserPane<some BrowserPaneModel>) async -> Bool {
        await pane.model.navigate(to: BreadcrumbSegment(id: path, label: path, location: path))
        return await waitUntil(timeout: 15) { pane.model.currentLocation == path && !pane.model.isLoading }
    }

    private func lastRowSettled(after count: Int, timeout: Double = 120) async -> TransferPanelRow? {
        _ = await waitUntil(timeout: timeout) {
            transfers.rows.count > count && transfers.rows.suffix(transfers.rows.count - count).allSatisfy { $0.state.isTerminal }
        }
        return transfers.rows.count > count ? transfers.rows.last : nil
    }

    // MARK: - Quick

    private func runQuick() async {
        let connected = await waitUntil(timeout: 30) { device?.model.hasLoaded == true }
        check("connected to the phone and listed its files", connected,
              "\(device?.model.title ?? "?"), \(device?.model.entries.count ?? 0) items at \(device?.model.currentLocation ?? "?")")
    }

    // MARK: - Full

    private func run() async {
        let connected = await waitUntil(timeout: 30) { device?.model.hasLoaded == true }
        check("connected to the phone", connected, "\(device?.model.title ?? "?")")
        guard connected, let device else { return }
        let model = device.model
        check("storages listed", !model.storages.isEmpty, model.storages.map { "\($0.name) (\($0.capacitySummary ?? "?"))" }.joined(separator: ", "))
        check("opened /Download", await go("/Download", in: device))
        if model.entries.contains(where: { $0.name == Self.phoneFolder }) {
            _ = await select([Self.phoneFolder], in: device)
            _ = await model.deleteSelectedEntries()
        }
        let made = await model.makeDirectory(named: Self.phoneFolder)
        check("created the test folder on the phone", made)
        let folder = "/Download/\(Self.phoneFolder)"
        check("opened the test folder", await go(folder, in: device))

        // Local scratch files.
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ART_DEVICE_CHECK_DIR"]
            ?? XDGUserDirectories().home.appending(path: ".cache/art-device-check").path)
        let back = scratch.appending(path: "back")
        try? FileManager.default.removeItem(at: back)
        try? FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let small = scratch.appending(path: "art-small.bin")
        let big = scratch.appending(path: "art-big.bin")
        if !FileManager.default.fileExists(atPath: small.path) {
            try? Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) }).write(to: small)
        }
        if (try? FileManager.default.attributesOfItem(atPath: big.path)[.size] as? Int) != 300 << 20 {
            _ = FileManager.default.createFile(atPath: big.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: big) {
                let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 40503 >> 3) })
                for _ in 0..<300 { handle.write(chunk) }
                try? handle.close()
            }
        }
        check("computer pane opened the scratch folder", await go(scratch.path, in: local))

        // Computer → phone.
        var before = transfers.rows.count
        _ = await select(["art-small.bin"], in: local)
        var t0 = Date()
        local.root.activateAction("pane.copy-to-other")
        let upload = await lastRowSettled(after: before)
        check("copied a file to the phone", upload?.state == .completed,
              String(format: "%@ in %.2f s", String(describing: upload?.state ?? .queued), Date().timeIntervalSince(t0)))
        await model.refresh()
        let listed = model.entries.first { $0.name == "art-small.bin" }
        check("the phone lists it with the right size", listed?.size == 5 << 20, "\(listed?.size ?? -1) bytes")

        // Phone → computer.
        check("computer pane opened the download folder", await go(back.path, in: local))
        before = transfers.rows.count
        _ = await select(["art-small.bin"], in: device)
        t0 = Date()
        device.root.activateAction("pane.copy-to-other")
        let download = await lastRowSettled(after: before)
        let original = try? Data(contentsOf: small)
        let copied = try? Data(contentsOf: back.appending(path: "art-small.bin"))
        check("copied it back to the computer, byte for byte", download?.state == .completed && copied != nil && copied == original,
              String(format: "%.2f s, %d bytes", Date().timeIntervalSince(t0), copied?.count ?? -1))

        // Conflict: the same download again, Keep Both.
        before = transfers.rows.count
        _ = await select(["art-small.bin"], in: device)
        device.root.activateAction("pane.copy-to-other")
        let prompted = await waitUntil(timeout: 20) { window.conflictDialog != nil }
        check("conflict dialog shown", prompted)
        window.conflictDialog?.choose(.keepBoth)
        let kept = await lastRowSettled(after: before)
        let second = try? Data(contentsOf: back.appending(path: "art-small (2).bin"))
        check("Keep Both saved a numbered copy", kept?.state == .completed && second == original,
              "\(String(describing: kept?.state)) \(second?.count ?? -1) bytes")

        // Stop mid-file on a large upload.
        check("computer pane back at the scratch folder", await go(scratch.path, in: local))
        before = transfers.rows.count
        _ = await select(["art-big.bin"], in: local)
        local.root.activateAction("pane.copy-to-other")
        let midFile = await waitUntil(timeout: 30) {
            guard transfers.rows.count > before, case let .transferring(progress) = transfers.rows.last!.state else { return false }
            return progress.sentBytes > 30 << 20
        }
        check("large upload running", midFile, "\(String(describing: transfers.rows.last?.state))")
        t0 = Date()
        window.transferPanel.stopAllButton.emit("clicked")
        let stopped = await waitUntil(timeout: 20) { transfers.rows.last?.state == .cancelled }
        check("Stop All stopped it mid-file", stopped, String(format: "%.3f s", Date().timeIntervalSince(t0)))
        _ = await waitUntil(timeout: 10) { !transfers.hasActiveTransfers }
        await model.refresh()
        check("no partial file left on the phone", !model.entries.contains { $0.name == "art-big.bin" },
              model.entries.map(\.name).joined(separator: ", "))

        // Simulated unplug: File transfer off, then on again.
        let environment = ProcessInfo.processInfo.environment
        if let adb = environment["ART_ADB"], let serial = environment["ANDROID_SERIAL"] {
            t0 = Date()
            Self.adb(adb, serial, ["shell", "svc", "usb", "setFunctions", "''"])
            let lost = await waitUntil(timeout: 15) { ConnectionPanePhase(controller: controller.connection) != .connected }
            check("unplug noticed", lost, String(format: "%.2f s, now %@", Date().timeIntervalSince(t0),
                                                 "\(ConnectionPanePhase(controller: controller.connection).kind)"))
            try? await Task.sleep(for: .seconds(2))
            t0 = Date()
            Self.adb(adb, serial, ["shell", "svc", "usb", "setFunctions", "mtp"])
            let back = await waitUntil(timeout: 40) { self.device?.model.hasLoaded == true }
            check("reconnected after File transfer came back", back, String(format: "%.2f s", Date().timeIntervalSince(t0)))
            if let device = self.device {
                check("reopened the same folder", device.model.currentLocation == folder, device.model.currentLocation)
            }
        }

        // Clean up the phone.
        if let device = self.device {
            _ = await go("/Download", in: device)
            _ = await select([Self.phoneFolder], in: device)
            let confirmation = device.model.deletionConfirmation()
            check("deleting asks for permanent deletion", confirmation?.destination == .device)
            let deleted = await device.model.deleteSelectedEntries()
            check("test folder removed from the phone", deleted && !device.model.entries.contains { $0.name == Self.phoneFolder })
        }
    }

    @discardableResult
    static func adb(_ adb: String, _ serial: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", serial] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
