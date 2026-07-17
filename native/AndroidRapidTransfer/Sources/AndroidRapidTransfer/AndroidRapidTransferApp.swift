import MTPKit
import AndroidRapidTransferCore
import SwiftUI
import USBWatcher

@main
struct AndroidRapidTransferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var localModel: LocalBrowserViewModel
    @State private var connectionController: DeviceConnectionController
    @State private var transferModel: TransferViewModel
    @State private var focusCoordinator = PaneFocusCoordinator()
    @State private var onboarding = OnboardingCoordinator()
    @State private var updater: AppUpdater
    @State private var abnormalExitNotice: AbnormalExitNotice
    private let mockProvider: MockMTPProvider?
    #if DEBUG
    private let demoSession: DemoDeviceSession?
    #endif

    init() {
        _abnormalExitNotice = State(initialValue: SessionMarker.begin())
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        #if DEBUG
        let demoSession = DemoMode.isRequested() ? DemoDeviceSession() : nil
        self.demoSession = demoSession
        let demoLocalStart = demoSession == nil ? nil : DemoMode.localStartURL()
        #else
        let demoLocalStart: URL? = nil
        #endif
        let localModel = LocalBrowserViewModel(
            // The demo's throwaway home stands in for the user's: its
            // breadcrumbs start at Home rather than at its real path.
            rootURL: demoLocalStart == nil ? URL(fileURLWithPath: "/") : .homeDirectory,
            startURL: demoLocalStart ?? .homeDirectory,
            fileOpener: WorkspaceFileOpener(),
            viewMode: settings.localViewMode,
            showsHiddenFiles: settings.localShowsHiddenFiles,
            directoriesFirst: settings.showDirectoriesFirst
        )
        _localModel = State(initialValue: localModel)
        let transferModel = TransferViewModel(
            localModel: localModel,
            batchStore: TransferBatchStore(),
            fileConflictPolicy: { settings.fileConflictPolicy },
            preprocessesFiles: { settings.preprocessesFiles(for: $0) }
        )
        _transferModel = State(initialValue: transferModel)
        // A session that finishes while the app is in the background bounces
        // the Dock and posts a notification (permission asked at the first one).
        let completionNotifier = TransferCompletionNotifier(
            center: SystemNotificationCenter.makeIfAvailable(),
            isAppActive: { NSApp?.isActive ?? true }
        )
        transferModel.onSessionFinished = { summary in
            if NSApp?.isActive == true {
                AccessibilityNotification.Announcement(summary.headline).post()
            }
            DockProgressPresenter.shared.announce(summary)
            Task { await completionNotifier.sessionFinished(summary) }
        }
        _updater = State(
            initialValue: AppUpdater(
                settings: settings,
                hasActiveTransfers: { transferModel.hasActiveTransfers }
            )
        )

        let connectionController: DeviceConnectionController
        #if DEBUG
        let demoConnection = demoSession.map { session in
            DeviceConnectionController(
                providerFactory: session.providerFactory,
                events: session.events,
                deviceViewMode: settings.deviceViewMode,
                deviceShowsHiddenFiles: settings.deviceShowsHiddenFiles,
                deviceDirectoriesFirst: settings.showDirectoriesFirst
            )
        }
        #else
        let demoConnection: DeviceConnectionController? = nil
        #endif
        if let demoConnection {
            mockProvider = nil
            connectionController = demoConnection
        } else if CommandLine.arguments.contains("--mock") {
            let provider = MockDeviceFixture.makeProvider()
            mockProvider = provider
            connectionController = DeviceConnectionController(
                providerFactory: { provider },
                events: AsyncStream { _ in },
                deviceViewMode: settings.deviceViewMode,
                deviceShowsHiddenFiles: settings.deviceShowsHiddenFiles,
                deviceDirectoriesFirst: settings.showDirectoriesFirst
            )
            if CommandLine.arguments.contains(MockDeviceFixture.copyOnLaunchArgument) {
                MockDeviceFixture.copyOnLaunch(controller: connectionController, transferModel: transferModel)
            }
        } else {
            let watcher = USBWatcher()
            mockProvider = nil
            connectionController = DeviceConnectionController(
                providerFactory: { MTPProviderFactory.make() },
                events: watcher.events,
                deviceViewMode: settings.deviceViewMode,
                deviceShowsHiddenFiles: settings.deviceShowsHiddenFiles,
                deviceDirectoriesFirst: settings.showDirectoriesFirst,
                startWatching: watcher.start,
                stopWatching: watcher.stop
            )
        }
        _connectionController = State(initialValue: connectionController)

        // Quitting cancels transfers, then releases the device session so the
        // phone is not left with a claimed interface; bounded so quit never hangs.
        AppDelegate.prepareForTermination = {
            _ = await DeviceSessionShutdown.run(
                stopTransfers: { await transferModel.stopAll() },
                releaseDevice: { _ = await connectionController.releaseDevice() }
            )
        }
    }

    var body: some Scene {
        WindowGroup(AppIdentity.name) {
            ContentView(
                localModel: localModel,
                connectionController: connectionController,
                transferModel: transferModel,
                settings: settings,
                focusCoordinator: focusCoordinator,
                onboarding: onboarding
            )
                .abnormalExitNotice(abnormalExitNotice)
                .frame(minWidth: 900, minHeight: 520)
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .defaultSize(width: 1_180, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AndroidRapidTransferCommands(
                settings: settings,
                focusCoordinator: focusCoordinator,
                onboarding: onboarding,
                updater: updater
            )
            #if DEBUG
            // Development only: failure injection for the --mock device.
            if let mockProvider {
                DebugCommands(provider: mockProvider, controller: connectionController)
            }
            if let demoSession {
                DemoCommands(session: demoSession)
            }
            #endif
        }

        Settings {
            SettingsView(settings: settings, updater: updater)
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }

        Window("About \(AppIdentity.name)", id: AppWindowID.about) {
            AboutView()
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Troubleshooting & FAQ", id: AppWindowID.help) {
            HelpCenterView()
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .defaultSize(width: 640, height: 680)

        Window("Privacy", id: AppWindowID.privacy) {
            PrivacyView()
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .defaultSize(width: 560, height: 560)

        Window("Acknowledgements", id: AppWindowID.acknowledgements) {
            AcknowledgementsView()
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .defaultSize(width: 720, height: 640)

        Window("Keyboard Shortcuts", id: AppWindowID.keyboardShortcuts) {
            KeyboardShortcutsView()
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .defaultSize(width: 580, height: 620)

        Window("Report a Bug", id: AppWindowID.reportBug) {
            BugReportView(
                connectionController: connectionController,
                transferModel: transferModel,
                settings: settings
            )
            .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .windowResizability(.contentSize)

        Window("Resume Copies", id: AppWindowID.resumeCopies) {
            ResumeCopiesView(transferModel: transferModel)
                .preferredColorScheme(settings.theme.preferredColorScheme)
        }
        .defaultSize(width: 760, height: 480)
    }
}
