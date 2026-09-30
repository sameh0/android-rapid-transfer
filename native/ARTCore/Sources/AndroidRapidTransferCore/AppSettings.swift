import Foundation
import Observation

@MainActor
@Observable
public final class AppSettings {
    public var theme: AppTheme { didSet { persist() } }
    public var localShowsHiddenFiles: Bool { didSet { persist() } }
    public var deviceShowsHiddenFiles: Bool { didSet { persist() } }
    public var localViewMode: BrowserViewMode { didSet { persist() } }
    public var deviceViewMode: BrowserViewMode { didSet { persist() } }
    public var showLocalPane: Bool { didSet { persist() } }
    public var localPaneOnLeft: Bool { didSet { persist() } }
    public var enableUsbHotplug: Bool { didSet { persist() } }
    public var enableStatusBar: Bool { didSet { persist() } }
    public var fileConflictPolicy: FileConflictPolicy { didSet { persist() } }
    public var showDirectoriesFirst: Bool { didSet { persist() } }
    /// "Display overall progress": the transfer walks the whole source tree
    /// first so the transfer screen can show totals, which costs seconds to
    /// minutes on large copies.
    public var preprocessFilesBeforeUpload: Bool { didSet { persist() } }
    public var preprocessFilesBeforeDownload: Bool { didSet { persist() } }
    /// Update preferences. The app owns them and pushes them into the updater,
    /// so they live alongside every other setting rather than in Sparkle's own
    /// user defaults.
    public var automaticallyChecksForUpdates: Bool { didSet { persist() } }
    public var automaticallyDownloadsUpdates: Bool { didSet { persist() } }
    public var receivesBetaUpdates: Bool { didSet { persist() } }
    public private(set) var deviceFirstLayoutVersion: Int { didSet { persist() } }
    public private(set) var usbHotplugDefaultVersion: Int { didSet { persist() } }
    public private(set) var onboardingShownVersion: String? { didSet { persist() } }

    @ObservationIgnored private let settingsURL: URL
    @ObservationIgnored private let fileManager: FileManager

    public init(
        settingsURL: URL = AppSettings.defaultSettingsURL(),
        fileManager: FileManager = .default
    ) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager

        var snapshot = Self.loadNativeSettings(from: settingsURL) ?? AppSettingsSnapshot()

        if snapshot.deviceFirstLayoutVersion < 1 {
            snapshot.showLocalPane = false
            snapshot.deviceFirstLayoutVersion = 1
        }

        // Hotplug used to default to off, and every save wrote that default
        // out, so a saved `false` from before this migration is not a choice
        // anyone made. Without hotplug an unplugged phone stays on screen and
        // a returning one is never picked up, so switch it on once; turning it
        // off again afterwards sticks.
        if snapshot.usbHotplugDefaultVersion < 1 {
            snapshot.enableUsbHotplug = true
            snapshot.usbHotplugDefaultVersion = 1
        }

        theme = snapshot.theme
        localShowsHiddenFiles = snapshot.localShowsHiddenFiles
        deviceShowsHiddenFiles = snapshot.deviceShowsHiddenFiles
        localViewMode = snapshot.localViewMode
        deviceViewMode = snapshot.deviceViewMode
        showLocalPane = snapshot.showLocalPane
        localPaneOnLeft = snapshot.localPaneOnLeft
        enableUsbHotplug = snapshot.enableUsbHotplug
        enableStatusBar = snapshot.enableStatusBar
        fileConflictPolicy = snapshot.fileConflictPolicy
        showDirectoriesFirst = snapshot.showDirectoriesFirst
        preprocessFilesBeforeUpload = snapshot.preprocessFilesBeforeUpload
        preprocessFilesBeforeDownload = snapshot.preprocessFilesBeforeDownload
        automaticallyChecksForUpdates = snapshot.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = snapshot.automaticallyDownloadsUpdates
        receivesBetaUpdates = snapshot.receivesBetaUpdates
        deviceFirstLayoutVersion = snapshot.deviceFirstLayoutVersion
        usbHotplugDefaultVersion = snapshot.usbHotplugDefaultVersion
        onboardingShownVersion = snapshot.onboardingShownVersion

        persist()
    }

    public var paneOrder: [BrowserPaneKind] {
        guard showLocalPane else { return [.device] }
        return localPaneOnLeft ? [.local, .device] : [.device, .local]
    }

    public var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            theme: theme,
            localShowsHiddenFiles: localShowsHiddenFiles,
            deviceShowsHiddenFiles: deviceShowsHiddenFiles,
            localViewMode: localViewMode,
            deviceViewMode: deviceViewMode,
            showLocalPane: showLocalPane,
            localPaneOnLeft: localPaneOnLeft,
            enableUsbHotplug: enableUsbHotplug,
            enableStatusBar: enableStatusBar,
            fileConflictPolicy: fileConflictPolicy,
            showDirectoriesFirst: showDirectoriesFirst,
            preprocessFilesBeforeUpload: preprocessFilesBeforeUpload,
            preprocessFilesBeforeDownload: preprocessFilesBeforeDownload,
            automaticallyChecksForUpdates: automaticallyChecksForUpdates,
            automaticallyDownloadsUpdates: automaticallyDownloadsUpdates,
            receivesBetaUpdates: receivesBetaUpdates,
            deviceFirstLayoutVersion: deviceFirstLayoutVersion,
            usbHotplugDefaultVersion: usbHotplugDefaultVersion,
            onboardingShownVersion: onboardingShownVersion
        )
    }

    /// Whether a transfer in `direction` should preprocess its sources.
    public func preprocessesFiles(for direction: TransferDirection) -> Bool {
        switch direction {
        case .upload: preprocessFilesBeforeUpload
        case .download: preprocessFilesBeforeDownload
        }
    }

    /// The update behaviour these settings produce for this build.
    public func updatePreferences(appVersion: String = AppVersion.current) -> UpdatePreferences {
        UpdatePreferences(
            automaticallyChecks: automaticallyChecksForUpdates,
            automaticallyDownloads: automaticallyDownloadsUpdates,
            receivesBetaUpdates: receivesBetaUpdates,
            appVersion: appVersion
        )
    }

    public func needsOnboarding(for version: String = AppVersion.current) -> Bool {
        guard let onboardingShownVersion else { return true }
        return AppVersion.isOlder(onboardingShownVersion, than: version)
    }

    public func markOnboardingShown(version: String = AppVersion.current) {
        onboardingShownVersion = version
    }

    public static func defaultSettingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        homeDirectory(environment: environment)
            .appending(path: "Library/Application Support/\(AppIdentity.supportDirectoryName)/settings.json")
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            // Settings persistence must never make the file manager unusable.
        }
    }

    private static func loadNativeSettings(from url: URL) -> AppSettingsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
    }

    private static func homeDirectory(environment: [String: String]) -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return .homeDirectory
    }
}
