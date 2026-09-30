import ARTGtk
import AndroidRapidTransferCore
import CGtk
import Foundation
import MTPKit
import USBWatcher

/// Command-line options.
struct LaunchOptions {
    var mock = false
    var selfTest = false
    /// Screenshot scenarios (`--scenario transfer|conflict|grid|dark|prefs|nophone`).
    var scenario: String?
    var skipOnboarding = false
    /// A mock phone that fails to connect the way a real one can
    /// (`nophone`, `busy`, `permission` scenarios).
    var mockFailure: String?
    /// `--device-check [quick]`: scripted run against a real phone.
    var deviceCheck: String?

    init(arguments: [String]) {
        mock = arguments.contains("--mock")
        selfTest = arguments.contains("--self-test")
        if selfTest { mock = true }
        if let index = arguments.firstIndex(of: "--scenario"), index + 1 < arguments.count {
            scenario = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--device-check") {
            deviceCheck = index + 1 < arguments.count && arguments[index + 1] == "quick" ? "quick" : "full"
        }
        skipOnboarding = selfTest || scenario != nil || deviceCheck != nil || arguments.contains("--no-onboarding")
        if let scenario, ["nophone", "busy", "permission"].contains(scenario) { mockFailure = scenario }
    }
}

/// Composes the app from Core, as the macOS app does: settings, the
/// computer and transfer view models, and the device connection (a real
/// phone through `USBWatcher` and the MTP engine, or the built-in mock).
@MainActor
final class AppController {
    let application: Application
    let options: LaunchOptions
    let settings: AppSettings
    let localModel: LocalBrowserViewModel
    let transferModel: TransferViewModel
    let connection: DeviceConnectionController
    let batchStore: TransferBatchStore
    let mockProvider: MockMTPProvider?
    let previousSessionEndedAbnormally: Bool
    private let sessionMarker = AbnormalExitMonitor()
    private(set) var mainWindow: MainWindow?
    private var isQuitting = false
    private var cssProvider: GObjectRef?
    private let bag = ObserverBag()
    /// Where a test or screenshot run keeps its throwaway settings and history.
    private let isolatedDirectory: URL?

    init(application: Application, options: LaunchOptions) {
        self.application = application
        self.options = options
        let isolatedState = options.selfTest || options.scenario != nil || options.deviceCheck != nil
        previousSessionEndedAbnormally = isolatedState ? false : sessionMarker.beginSession()

        isolatedDirectory = isolatedState
            ? FileManager.default.temporaryDirectory.appending(path: "art-\(getpid())", directoryHint: .isDirectory)
            : nil
        let settingsURL = isolatedDirectory?.appending(path: "settings.json") ?? AppSettings.defaultSettingsURL()
        let isFirstRun = !FileManager.default.fileExists(atPath: settingsURL.path)
        let settings = AppSettings(settingsURL: settingsURL)
        if isFirstRun {
            // On Linux both panes show by default: there is no Finder to
            // drag to, and the dual pane is the app's layout here.
            settings.showLocalPane = true
            settings.localPaneOnLeft = true
        }
        self.settings = settings

        let localModel = LocalBrowserViewModel(
            rootURL: URL(fileURLWithPath: "/"),
            startURL: XDGUserDirectories().home,
            favorites: LocalFavorite.linuxStandard,
            fileOpener: DesktopFileOpener(),
            viewMode: settings.localViewMode,
            showsHiddenFiles: settings.localShowsHiddenFiles,
            directoriesFirst: settings.showDirectoriesFirst
        )
        self.localModel = localModel
        let batchStore = TransferBatchStore(directoryURL: isolatedDirectory?.appending(path: "Batches", directoryHint: .isDirectory))
        self.batchStore = batchStore
        transferModel = TransferViewModel(
            localModel: localModel,
            batchStore: batchStore,
            fileConflictPolicy: { settings.fileConflictPolicy },
            preprocessesFiles: { settings.preprocessesFiles(for: $0) }
        )

        if options.mock {
            let provider = MockDeviceFixture.makeProvider()
            mockProvider = provider
            let failure = options.mockFailure
            connection = DeviceConnectionController(
                providerFactory: {
                    if let failure { throw MockDeviceFixture.connectionError(failure) }
                    return provider
                },
                events: AsyncStream { _ in },
                deviceViewMode: settings.deviceViewMode,
                deviceShowsHiddenFiles: settings.deviceShowsHiddenFiles,
                deviceDirectoriesFirst: settings.showDirectoriesFirst
            )
        } else {
            let watcher = USBWatcher()
            mockProvider = nil
            connection = DeviceConnectionController(
                providerFactory: { MTPProviderFactory.make() },
                events: watcher.events,
                deviceViewMode: settings.deviceViewMode,
                deviceShowsHiddenFiles: settings.deviceShowsHiddenFiles,
                deviceDirectoriesFirst: settings.showDirectoriesFirst,
                startWatching: watcher.start,
                stopWatching: watcher.stop
            )
        }

        transferModel.onSessionFinished = { [weak self] summary in self?.sessionFinished(summary) }
        installActions()
        installSettingsObservers()
    }

    // MARK: - Lifecycle

    func activate() {
        if mainWindow == nil {
            loadStyles()
            applyTheme()
            mainWindow = MainWindow(app: self)
        }
        mainWindow?.present()
    }

    /// The window is on screen: start the device session and show the
    /// welcome sheet on first launch.
    func windowAppeared() {
        let connection = connection
        let transferModel = transferModel
        bag.onChange(initial: true, { connection.transferSessionID }) { _ in
            if let queue = connection.transferQueue, let deviceModel = connection.deviceModel {
                transferModel.attach(queue: queue, deviceModel: deviceModel)
            } else {
                transferModel.detach()
            }
        }
        let hotplug = settings.enableUsbHotplug
        Task { await connection.paneAppeared(hotplugEnabled: hotplug) }
        if !options.skipOnboarding, settings.needsOnboarding() {
            presentOnboarding(startingAtConnection: false)
        }
    }

    /// Quits cleanly: confirms if copies are running, stops them, releases
    /// the phone (bounded), then exits the main loop.
    func requestQuit() {
        guard !isQuitting else { return }
        if transferModel.hasActiveTransfers, let window = mainWindow?.window {
            let alert = AlertDialog(heading: "Stop Copying and Quit?",
                                    body: "Copies in progress will stop. Files already copied stay where they are.")
            alert.addResponse("cancel", "Keep Copying")
            alert.addResponse("quit", "Stop and Quit", appearance: .destructive)
            alert.closeResponse = "cancel"
            alert.defaultResponse = "cancel"
            Task {
                guard await alert.choose(parent: window) == "quit" else { return }
                await self.shutdownAndQuit()
            }
        } else {
            Task { await shutdownAndQuit() }
        }
    }

    func shutdownAndQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        mainWindow?.window.isVisible = false
        let transferModel = transferModel
        let connection = connection
        let outcome = await DeviceSessionShutdown.run(
            stopTransfers: { await transferModel.stopAll() },
            releaseDevice: { _ = await connection.releaseDevice() }
        )
        if outcome == .timedOut {
            FileHandle.standardError.write(Data("warning: releasing the phone timed out at quit\n".utf8))
        }
        if let isolatedDirectory {
            try? FileManager.default.removeItem(at: isolatedDirectory)
        } else {
            sessionMarker.endSessionCleanly()
        }
        mainWindow?.window.destroy()
        application.quit()
    }

    // MARK: - Settings

    private func installSettingsObservers() {
        let settings = settings
        let connection = connection
        let localModel = localModel
        bag.onChange({ settings.enableUsbHotplug }) { enabled in
            Task { await connection.setUsbHotplugEnabled(enabled) }
        }
        bag.onChange({ settings.localViewMode }) { mode in localModel.viewMode = mode }
        bag.onChange({ settings.localShowsHiddenFiles }) { show in
            guard localModel.showsHiddenFiles != show else { return }
            Task { await localModel.setShowsHiddenFiles(show) }
        }
        bag.onChange({ settings.showDirectoriesFirst }) { first in localModel.setDirectoriesFirst(first) }
        bag.onChange({ [settings.deviceViewMode.rawValue, "\(settings.deviceShowsHiddenFiles)", "\(settings.showDirectoriesFirst)"] }) { _ in
            let mode = settings.deviceViewMode
            let hidden = settings.deviceShowsHiddenFiles
            let first = settings.showDirectoriesFirst
            Task { await connection.updateDevicePreferences(viewMode: mode, showsHiddenFiles: hidden, directoriesFirst: first) }
        }
        bag.onChange({ settings.theme }) { [weak self] _ in self?.applyTheme() }
    }

    private func applyTheme() {
        StyleManager.colorScheme = switch settings.theme {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    private func loadStyles() {
        cssProvider = CSS.load(AppStyle.css)
    }

    // MARK: - Notifications

    private func sessionFinished(_ summary: TransferSessionSummary) {
        let notification = TransferCompletionNotification(summary: summary)
        let windowIsActive = mainWindow?.window.isActive ?? false
        if windowIsActive {
            mainWindow?.toast(summary.headline)
        } else {
            let desktop = DesktopNotification(
                title: notification.title,
                body: notification.body,
                iconName: summary.isCleanSuccess ? "object-select-symbolic" : "dialog-warning-symbolic"
            )
            desktop.setDefaultAction("app.show-copies")
            application.send(desktop, id: "transfer-finished")
            mainWindow?.toast(summary.headline)
        }
    }

    // MARK: - Actions

    private func installActions() {
        let app = application
        app.addAction("quit") { [weak self] in self?.requestQuit() }
        app.addAction("preferences") { [weak self] in self?.presentPreferences() }
        app.addAction("shortcuts") { [weak self] in self?.presentShortcuts() }
        app.addAction("help") { [weak self] in self?.presentHelp() }
        app.addAction("connection-help") { [weak self] in self?.presentOnboarding(startingAtConnection: true) }
        app.addAction("report-bug") { [weak self] in self?.presentBugReport() }
        app.addAction("privacy") { [weak self] in self?.presentPrivacy() }
        app.addAction("about") { [weak self] in self?.presentAbout() }
        app.addAction("resume-copies") { [weak self] in self?.presentResumeCopies() }
        app.addAction("show-copies") { [weak self] in
            self?.mainWindow?.present()
            if self?.transferModel.isPanelVisible == true, self?.transferModel.isPanelExpanded == false {
                self?.transferModel.togglePanel()
            }
        }

        app.setAccelerators(["<Control>q"], for: "app.quit")
        app.setAccelerators(["<Control>comma"], for: "app.preferences")
        app.setAccelerators(["<Control>question"], for: "app.shortcuts")
        app.setAccelerators(["F1"], for: "app.help")
        app.setAccelerators([AppShortcuts.newFolder.gtkAccelerator], for: "win.new-folder")
        app.setAccelerators([AppShortcuts.refresh.gtkAccelerator, "F5"], for: "win.refresh")
        app.setAccelerators([AppShortcuts.switchPane.gtkAccelerator, "F6"], for: "win.switch-pane")
        app.setAccelerators(["F9"], for: "win.show-local-pane")
    }

    // MARK: - Secondary windows

    var window: Window? { mainWindow?.window }

    func presentPreferences() {
        PreferencesWindow(settings: settings).present(parent: window)
    }

    func presentShortcuts() {
        ShortcutsHelp.makeDialog().present(parent: window)
    }

    func presentHelp() {
        HelpDialogs.troubleshooting().present(parent: window)
    }

    func presentPrivacy() {
        HelpDialogs.privacy().present(parent: window)
    }

    func presentAbout() {
        HelpDialogs.about().present(parent: window)
    }

    func presentOnboarding(startingAtConnection: Bool) {
        let settings = settings
        let dialog = OnboardingDialog(startAtConnection: startingAtConnection)
        dialog.dialog.onClosed { settings.markOnboardingShown() }
        dialog.dialog.present(parent: window)
    }

    func presentBugReport() {
        BugReportDialog(app: self).present(parent: window)
    }

    func presentResumeCopies() {
        ResumeCopiesDialog(transferModel: transferModel, batchStore: batchStore).present(parent: window)
    }
}
