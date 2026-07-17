import AppKit
import Observation
import AndroidRapidTransferCore
import Sparkle

/// Owns Sparkle's updater and keeps it in step with the app's settings.
///
/// Sparkle's standard user driver supplies the whole update UI: checking
/// progress, the update-available prompt with release notes, download and
/// install progress, and its network/offline/general error alerts. It draws in
/// its own windows and never touches the Dock tile (it only requests user
/// attention), so it cannot overwrite the transfer progress bar that
/// `DockProgressPresenter` draws there.
@MainActor
@Observable
final class AppUpdater {
    /// False for development runs and bundles built without update keys; the
    /// menu item and settings reflect that instead of starting an updater.
    let isAvailable: Bool
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let installGate: UpdateInstallGate
    @ObservationIgnored private let hasActiveTransfers: () -> Bool
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var delegate: UpdaterDelegate?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init(
        settings: AppSettings,
        hasActiveTransfers: @escaping () -> Bool,
        bundle: Bundle = .main
    ) {
        self.settings = settings
        self.hasActiveTransfers = hasActiveTransfers
        installGate = UpdateInstallGate(hasActiveTransfers: hasActiveTransfers)
        isAvailable = UpdaterAvailability.isAvailable(
            bundleURL: bundle.bundleURL,
            infoDictionary: bundle.infoDictionary
        )
        guard isAvailable else { return }

        let delegate = UpdaterDelegate(settings: settings, installGate: installGate)
        self.delegate = delegate
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.controller = controller

        // Apply the app's settings before the first scheduled check can run.
        // Setting these explicitly also suppresses Sparkle's own "check for
        // updates automatically?" prompt: the app already asked in Settings.
        applyPreferences()
        controller.startUpdater()

        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            // Sparkle changes this on the main thread.
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        observeSettings()
        observeTransfers()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func applyPreferences() {
        guard let updater = controller?.updater else { return }
        let preferences = settings.updatePreferences()
        if updater.automaticallyChecksForUpdates != preferences.automaticallyChecks {
            updater.automaticallyChecksForUpdates = preferences.automaticallyChecks
        }
        if updater.automaticallyDownloadsUpdates != preferences.automaticallyDownloads {
            updater.automaticallyDownloadsUpdates = preferences.automaticallyDownloads
        }
    }

    /// Re-applies the preferences whenever any update setting changes. The
    /// channel is read by the delegate at check time, so it needs no push.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.updatePreferences()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyPreferences()
                self?.observeSettings()
            }
        }
    }

    /// Releases a parked relaunch once the last copy finishes.
    private func observeTransfers() {
        withObservationTracking {
            _ = hasActiveTransfers()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.installGate.transferActivityChanged()
                self?.observeTransfers()
            }
        }
    }
}

/// Sparkle calls these on the main thread.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let settings: AppSettings
    private let installGate: UpdateInstallGate

    init(settings: AppSettings, installGate: UpdateInstallGate) {
        self.settings = settings
        self.installGate = installGate
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        settings.updatePreferences().allowedChannels
    }

    /// Install and Relaunch during a copy would kill the device session and
    /// abort it. Park the relaunch until the transfers finish instead.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard installGate.shouldPostponeInstall(installHandler) else { return false }
        announcePostponedInstall()
        return true
    }

    /// Without this, Install and Relaunch would appear to do nothing.
    private func announcePostponedInstall() {
        let alert = NSAlert()
        alert.messageText = "The update will install when your copies finish"
        alert.informativeText = "Relaunching now would stop the copies in progress. "
            + "The app will relaunch into the new version as soon as they are done."
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
