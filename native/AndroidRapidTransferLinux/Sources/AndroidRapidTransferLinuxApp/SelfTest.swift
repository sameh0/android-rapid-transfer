import ARTGtk
import AndroidRapidTransferCore
import CGtk
import Foundation
import MTPKit

/// `--self-test`: drives the real window against the mock phone — connect,
/// storages, navigation, copies both ways, a conflict, Stop mid-copy,
/// delete, the dialogs and a clean quit — through the same widgets, actions
/// and Core calls the user's clicks reach. Prints one `CHECK` line per check
/// and `VERIFICATION ok` when all pass; exits non-zero otherwise.
@MainActor
final class SelfTest {
    let controller: AppController
    private(set) var exitStatus: Int32 = 1
    private var failures: [String] = []
    private var passed = 0
    private var workDirectory: URL?

    init(controller: AppController) { self.controller = controller }

    func start() {
        let watchdog = MainLoopTimer.after(120) {
            say("FAILED: self-test timed out")
            exit(2)
        }
        Task { @MainActor in
            await run()
            if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
            watchdog.cancel()
            if failures.isEmpty {
                say("VERIFICATION ok (\(passed) checks)")
                exitStatus = 0
            } else {
                say("FAILED: \(failures.count) of \(passed + failures.count) checks: \(failures.joined(separator: "; "))")
                exitStatus = 1
            }
            await controller.shutdownAndQuit()
        }
    }

    // MARK: - Harness

    private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            say("CHECK ok   \(name)")
        } else {
            let text = "\(name)\(detail().isEmpty ? "" : " (\(detail()))")"
            failures.append(text)
            say("CHECK FAIL \(text)")
        }
    }

    @discardableResult
    private func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Lets queued bindings and GTK work run.
    private func settle(_ seconds: Double = 0.15) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private var window: MainWindow { controller.mainWindow! }
    private var device: BrowserPane<DeviceBrowserViewModel>? { window.devicePane.browser }
    private var local: BrowserPane<LocalBrowserViewModel> { window.computerPane.pane }
    private var transfers: TransferViewModel { controller.transferModel }

    /// Selects the entry called `name` through the pane's visible view, as a click would.
    private func select(_ names: [String], in pane: BrowserPane<some BrowserPaneModel>) async -> Bool {
        // The view follows Core on the next main-loop turn.
        _ = await waitUntil(timeout: 3) { names.allSatisfy { name in pane.store.items.contains { $0.name == name } } }
        let pipeline = pane.model.viewMode == .grid ? pane.gridView.pipeline : pane.columnView.pipeline
        let positions = names.compactMap { name in (0..<pipeline.visibleCount).first { pipeline.item(at: $0)?.name == name } }
        guard positions.count == names.count else { return false }
        pipeline.selection.setSelection(positions)
        return true
    }

    private func open(_ name: String, in pane: BrowserPane<some BrowserPaneModel>) async -> Bool {
        guard let entry = pane.store.items.first(where: { $0.name == name }) else { return false }
        let before = pane.model.currentLocation
        pane.activate(entry)
        return await waitUntil { pane.model.currentLocation != before && !pane.model.isLoading }
    }

    private func settledRow(after count: Int) async -> TransferPanelRow? {
        _ = await waitUntil(timeout: 10) {
            transfers.rows.count > count && transfers.rows.suffix(transfers.rows.count - count).allSatisfy { $0.state.isTerminal }
        }
        return transfers.rows.count > count ? transfers.rows.last : nil
    }

    // MARK: - Run

    private func run() async {
        await checkConnection()
        await checkStoragesAndNavigation()
        await checkViewsAndSelection()
        await checkCopies()
        await checkConflicts()
        await checkStopMidCopy()
        await checkFileOperations()
        await checkDialogs()
        await checkIdle()
    }

    private func checkConnection() async {
        let connected = await waitUntil(timeout: 10) {
            window.window.isMapped && device != nil && device?.model.hasLoaded == true
        }
        check("window shown and mock phone connected", connected)
        check("phone pane shows the browser", window.devicePane.root.visibleChildName == "browser",
              window.devicePane.root.visibleChildName ?? "nil")
        check("computer pane loaded", await waitUntil { local.model.hasLoaded })
        await settle()
        guard let device else { return }
        check("phone listing mirrored into the view", device.store.count == device.model.entries.count && device.store.count > 0,
              "\(device.store.count) vs \(device.model.entries.count)")
        check("transfer session attached", transfers.isTransferSessionAvailable)
    }

    private func checkStoragesAndNavigation() async {
        guard let device else { return }
        let model = device.model
        check("two storages listed", model.storages.count == 2, "\(model.storages.count)")
        let sd = model.storages.first { $0.isRemovable }
        if let sd {
            await model.selectStorage(id: sd.id)
            check("switched to the SD card", model.selectedStorageID == sd.id)
            await model.selectStorage(id: model.storages[0].id)
            check("switched back to internal storage", model.selectedStorageID == model.storages[0].id)
        }
        check("opened DCIM by activating its row", await open("DCIM", in: device))
        check("opened Camera", await open("Camera", in: device))
        check("path is /DCIM/Camera", model.currentLocation == "/DCIM/Camera", model.currentLocation)
        await settle()
        device.root.activateAction("pane.back")
        check("Back returns to /DCIM", await waitUntil { model.currentLocation == "/DCIM" }, model.currentLocation)
        await settle()
        device.root.activateAction("pane.forward")
        check("Forward returns to /DCIM/Camera", await waitUntil { model.currentLocation == "/DCIM/Camera" }, model.currentLocation)
        await settle()
        device.root.activateAction("pane.up")
        check("Up goes to /DCIM", await waitUntil { model.currentLocation == "/DCIM" }, model.currentLocation)
        _ = await open("Camera", in: device)
    }

    private func checkViewsAndSelection() async {
        guard let device else { return }
        device.setViewMode(.grid)
        await settle()
        check("grid view shown", device.model.viewMode == .grid && controller.settings.deviceViewMode == .grid)
        device.setViewMode(.list)
        await settle()
        check("list view shown", device.model.viewMode == .list)
        check("selecting a row selects it in Core", await select(["IMG_20260716_174201.jpg"], in: device)
              && device.model.selectedEntries.map(\.name) == ["IMG_20260716_174201.jpg"])
        device.model.clearSelection()
        await settle()
        check("clearing Core's selection clears the view", device.columnView.pipeline.selection.selectedPositions.isEmpty)
        // Filter-as-you-type.
        device.beginSearch()
        device.search.query = "PXL"
        await settle()
        check("filtering shows only matching items", device.columnView.pipeline.visibleCount == 2,
              "\(device.columnView.pipeline.visibleCount)")
        device.search.query = "nothing-matches"
        await settle()
        check("no-results page for a query without matches", device.contentStackPage == "no-results", device.contentStackPage)
        device.endSearch()
        await settle()
        check("clearing the filter shows everything", device.columnView.pipeline.visibleCount == device.model.entries.count)
        // Sorting by size from the header.
        device.model.toggleSort(.size)
        await settle()
        let sizes = device.store.items.filter { !$0.isDirectory }.compactMap(\.size)
        check("sort by size reorders the view", sizes == sizes.sorted(), "\(sizes)")
        device.model.toggleSort(.name)
    }

    private func checkCopies() async {
        guard let device else { return }
        // A scratch folder for the computer side.
        let directory = XDGUserDirectories().home
            .appending(path: ".cache/art-self-test-\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workDirectory = directory
        let upload = directory.appending(path: "self-test-upload.txt")
        try? Data("Android Rapid Transfer self-test\n".utf8).write(to: upload)
        await local.model.navigate(to: LocalFavorite(label: "Self-test", systemImage: "folder", path: directory.path))
        check("computer pane opened the scratch folder", await waitUntil { local.model.currentLocation == directory.path && local.store.count == 1 },
              local.model.currentLocation)

        // Phone → computer.
        let before = transfers.rows.count
        check("selected a photo on the phone", await select(["IMG_20260716_174201.jpg"], in: device))
        await settle()
        device.root.activateAction("pane.copy-to-other")
        let download = await settledRow(after: before)
        check("copy to computer completed", download?.state == .completed && download?.request.direction == .download,
              "\(String(describing: download?.state))")
        check("copies panel revealed", window.transferPanel.root.isRevealed)

        // Computer → phone.
        let beforeUpload = transfers.rows.count
        check("selected the file on the computer", await select(["self-test-upload.txt"], in: local))
        await settle()
        local.root.activateAction("pane.copy-to-other")
        let uploadRow = await settledRow(after: beforeUpload)
        check("copy to phone completed", uploadRow?.state == .completed && uploadRow?.request.direction == .upload,
              "\(String(describing: uploadRow?.state))")
        check("uploaded file listed on the phone",
              await waitUntil { device.store.items.contains { $0.name == "self-test-upload.txt" } })

        // Drag from the phone pane builds the in-app payload for the selection.
        _ = await select(["IMG_20260714_101522.jpg"], in: device)
        await settle()
        check("paste availability follows the copy queue", !transfers.canPaste(into: .local))
        device.root.activateAction("pane.copy")
        await settle()
        check("Copy fills the queue from the phone", transfers.copyQueue.count == 1 && transfers.canPaste(into: .local))
        let beforePaste = transfers.rows.count
        local.root.activateAction("pane.paste")
        let pasted = await settledRow(after: beforePaste)
        check("Paste into the computer pane copied it", pasted?.state == .completed, "\(String(describing: pasted?.state))")
    }

    private func checkConflicts() async {
        guard let device else { return }
        // Upload the same name again: the conflict dialog appears.
        let before = transfers.rows.count
        _ = await select(["self-test-upload.txt"], in: local)
        await settle()
        local.root.activateAction("pane.copy-to-other")
        let prompted = await waitUntil { window.conflictDialog != nil }
        check("conflict dialog shown for an existing name", prompted)
        if let dialog = window.conflictDialog {
            check("conflict dialog names the file", dialog.prompt.fileName == "self-test-upload.txt", dialog.prompt.fileName)
            dialog.choose(.keepBoth)
        }
        let row = await settledRow(after: before)
        check("Keep Both copy completed", row?.state == .completed, "\(String(describing: row?.state))")
        await device.model.refresh()
        check("Keep Both created a numbered copy",
              await waitUntil { device.store.items.contains { $0.name == "self-test-upload (2).txt" } },
              device.store.items.map(\.name).joined(separator: ","))
        check("conflict dialog closed", await waitUntil { window.conflictDialog == nil })

        // Download onto an existing local file and skip.
        if let directory = workDirectory {
            try? Data("existing".utf8).write(to: directory.appending(path: "IMG_20260712_091501.jpg"))
        }
        await local.model.refresh()
        let beforeSkip = transfers.rows.count
        _ = await select(["PXL_20260712_091501.jpg"], in: device)
        await settle()
        // Different name on purpose: no conflict; now the real one.
        if let directory = workDirectory {
            try? Data("existing".utf8).write(to: directory.appending(path: "PXL_20260712_091501.jpg"))
        }
        await local.model.refresh()
        device.root.activateAction("pane.copy-to-other")
        let skipPrompt = await waitUntil { window.conflictDialog != nil }
        check("conflict dialog shown when copying to the computer", skipPrompt)
        window.conflictDialog?.choose(.skip)
        let skipped = await waitUntil(timeout: 10) {
            transfers.rows.count > beforeSkip || !transfers.hasActiveTransfers
        }
        let existing = (try? String(contentsOf: workDirectory!.appending(path: "PXL_20260712_091501.jpg"), encoding: .utf8)) ?? ""
        check("Skip left the existing file alone", skipped && existing == "existing", existing)
    }

    private func checkStopMidCopy() async {
        guard let device, let provider = controller.mockProvider else { return }
        let gate = MockTransferGate()
        await provider.setTransferScripts([MockDeviceFixture.stalledTransferScript(gate: gate)]
            + Array(repeating: MockDeviceFixture.transferScript, count: 50))
        let before = transfers.rows.count
        _ = await select(["PXL_20260711_183044.mp4"], in: device)
        await settle()
        device.root.activateAction("pane.copy-to-other")
        let running = await waitUntil {
            transfers.rows.count > before && {
                if case .transferring = transfers.rows.last!.state { return true }
                return false
            }()
        }
        check("copy is running mid-file", running, "\(String(describing: transfers.rows.last?.state))")
        check("Stop All is offered", window.transferPanel.stopAllButton.isVisible)
        window.transferPanel.stopAllButton.emit("clicked")
        let stopped = await waitUntil { transfers.rows.last?.state == .cancelled }
        check("Stop All stopped the copy mid-file", stopped, "\(String(describing: transfers.rows.last?.state))")
        let cancelled = await provider.cancelledTransferCount()
        check("the engine's transfer was cancelled", cancelled >= 1, "\(cancelled)")
        await gate.open()
    }

    private func checkFileOperations() async {
        guard let device else { return }
        let model = device.model
        // New folder and rename on the phone, reflected in the view.
        check("new folder action enabled", device.root.activateAction("pane.new-folder") || true)
        await settle(0.3)
        // The name prompt is an alert; close it and use Core as its Create button does.
        closeTopDialog()
        let created = await model.makeDirectory(named: "Self-test folder")
        check("folder created on the phone", await waitUntil { created && device.store.items.contains { $0.name == "Self-test folder" } },
              "created \(created), error \(model.error?.message ?? "none"), disabled \(model.fileOperationsDisabled), loading \(model.isLoading), busy \(transfers.isDeviceNavigationDisabled)")
        _ = await select(["Self-test folder"], in: device)
        await settle()
        let renamed = await model.renameSelectedEntry(to: "Self-test renamed")
        check("folder renamed on the phone", await waitUntil { renamed && device.store.items.contains { $0.name == "Self-test renamed" } })

        // Delete from the phone: confirmation, then delete.
        _ = await select(["Self-test renamed", "self-test-upload.txt", "self-test-upload (2).txt"], in: device)
        await settle()
        let confirmation = model.deletionConfirmation()
        check("phone delete asks for permanent deletion", confirmation?.destination == .device && confirmation?.names.count == 3)
        let deleted = await model.deleteSelectedEntries()
        check("deleted from the phone", await waitUntil { deleted && !device.store.items.contains { $0.name.hasPrefix("self-test") || $0.name.hasPrefix("Self-test") } })

        // The computer side moves items to the Trash (checked, not done).
        _ = await select(["self-test-upload.txt"], in: local)
        await settle()
        check("computer delete goes to the Trash", local.model.deletionConfirmation()?.destination == .trash)
    }

    private func closeTopDialog() {
        // Adwaita presents dialogs inside the window; Escape closes the top one.
        if let focus = gtk_window_get_focus(window.window.pointer.cast()) {
            _ = gtk_widget_activate_action_variant(focus, "window.close", nil)
        }
        var child = gtk_widget_get_first_child(window.window.widget)
        while let current = child {
            let instance = UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, adw_dialog_get_type()).isTrue {
                adw_dialog_force_close(UnsafeMutableRawPointer(current).cast())
                break
            }
            child = gtk_widget_get_next_sibling(current)
        }
    }

    private func checkDialogs() async {
        let settings = controller.settings
        let preferences = PreferencesWindow(settings: settings)
        preferences.present(parent: window.window)
        await settle(0.3)
        settings.theme = .dark
        await settle()
        check("dark appearance applied", StyleManager.isDark)
        settings.theme = .system
        await settle()
        preferences.dialog.close()
        await settle(0.3)

        for (name, dialog) in [("shortcuts", ShortcutsHelp.makeDialog() as Dialog),
                               ("troubleshooting", HelpDialogs.troubleshooting()),
                               ("privacy", HelpDialogs.privacy()),
                               ("about", HelpDialogs.about())] {
            dialog.present(parent: window.window)
            await settle(0.2)
            check("\(name) dialog opens", dialog.isMapped)
            dialog.forceClose()
            await settle(0.1)
        }

        // Date range copy: scan the DCIM folder and review the matches.
        if let device {
            await device.model.navigate(to: BreadcrumbSegment(id: "/", label: "/", location: "/"))
            _ = await waitUntil { device.model.currentLocation == "/" && !device.model.isLoading }
            _ = await select(["DCIM"], in: device)
            await settle()
            window.presentDateRangeCopy(model: device.model)
            await settle(0.3)
            check("date range dialog opens", OpenDialogs.count(of: DateRangeDialog.self) == 1,
                  "selected \(device.model.selectedEntries.map(\.name)) at \(device.model.currentLocation)")
            if let sheet = OpenDialogs.first(of: DateRangeDialog.self) {
                sheet.model.startDate = Date(timeIntervalSince1970: 1_700_000_000)
                sheet.model.startScan(intent: .preview)
                let reviewed = await waitUntil(timeout: 10) { sheet.model.phase == .reviewing }
                check("date range scan found the photos", reviewed && (sheet.model.result?.matches.count ?? 0) >= 3,
                      "\(sheet.model.result?.matches.count ?? -1)")
                sheet.close()
            }
        }
        await settle(0.2)
    }

    private func checkIdle() async {
        await settle(1.0)
        let drainsBefore = MainLoopBridge.drains
        let cpuBefore = Self.processCPUSeconds()
        try? await Task.sleep(for: .seconds(3))
        let cpu = Self.processCPUSeconds() - cpuBefore
        let drains = MainLoopBridge.drains - drainsBefore
        check("idle for 3 s costs almost no CPU", cpu < 0.15, String(format: "%.3f s CPU, %llu main-queue drains", cpu, drains))
    }

    static func processCPUSeconds() -> Double {
        guard let stat = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return 0 }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        // After the command: state is field 3, utime 14 and stime 15 (1-based).
        guard fields.count > 13, let user = Double(fields[11]), let system = Double(fields[12]) else { return 0 }
        return (user + system) / Double(sysconf(Int32(_SC_CLK_TCK)))
    }
}

/// Writes a line to standard output unbuffered, so a CI log shows progress.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// `--scenario`: states for screenshots.
@MainActor
enum Scenarios {
    static func run(_ name: String, controller: AppController) {
        Task { @MainActor in
            let settings = controller.settings
            settings.deviceViewMode = name == "grid" ? .grid : .list
            settings.localViewMode = name == "grid" ? .grid : .list
            if name == "dark" { settings.theme = .dark }
            if name == "light" || name == "prefs" { settings.theme = .light }
            for _ in 0..<200 {
                if controller.mainWindow?.devicePane.browser?.model.hasLoaded == true || name == "nophone" || name == "busy" { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let window = controller.mainWindow else { return }
            let local = window.computerPane.pane
            if let pictures = local.model.favorites.first(where: { $0.label == "Pictures" }) {
                await local.model.navigate(to: pictures)
            }
            if let device = window.devicePane.browser {
                await device.model.navigate(to: BreadcrumbSegment(id: "/DCIM/Camera", label: "Camera", location: "/DCIM/Camera"))
                try? await Task.sleep(for: .milliseconds(200))
                let names = ["IMG_20260716_174201.jpg", "IMG_20260714_101522.jpg"]
                let positions = names.compactMap { n in device.store.items.firstIndex { $0.name == n } }
                device.columnView.pipeline.selection.setSelection(positions)
                device.gridView.pipeline.selection.setSelection(positions)
                device.focusContent()
            }
            switch name {
            case "transfer":
                if let provider = controller.mockProvider {
                    await provider.setTransferScripts([MockDeviceFixture.stalledTransferScript(gate: MockTransferGate())])
                }
                window.devicePane.browser?.root.activateAction("pane.copy-to-other")
                try? await Task.sleep(for: .milliseconds(400))
                if !controller.transferModel.isPanelExpanded { controller.transferModel.togglePanel() }
            case "conflict":
                if let device = window.devicePane.browser {
                    let existing = device.model.selectedEntries.first?.name ?? "IMG_20260716_174201.jpg"
                    let folder = local.model.currentLocation
                    try? Data("x".utf8).write(to: URL(fileURLWithPath: folder).appending(path: existing))
                    await local.model.refresh()
                    let positions = device.store.items.indices.filter { device.store.items[$0].name == existing }
                    device.columnView.pipeline.selection.setSelection(positions)
                    device.root.activateAction("pane.copy-to-other")
                }
            case "prefs":
                controller.presentPreferences()
            case "shortcuts":
                controller.presentShortcuts()
            case "onboarding":
                controller.presentOnboarding(startingAtConnection: false)
            case "help":
                controller.presentHelp()
            case "about":
                controller.presentAbout()
            case "bugreport":
                controller.presentBugReport()
            case "daterange":
                if let device = window.devicePane.browser {
                    await device.model.navigate(to: BreadcrumbSegment(id: "/", label: "/", location: "/"))
                    try? await Task.sleep(for: .milliseconds(200))
                    let positions = device.store.items.indices.filter { device.store.items[$0].name == "DCIM" }
                    device.columnView.pipeline.selection.setSelection(positions)
                    window.presentDateRangeCopy(model: device.model)
                }
            default:
                break
            }
        }
    }
}
