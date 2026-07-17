import Foundation

public struct AppSettingsSnapshot: Codable, Equatable, Sendable {
    public var theme: AppTheme
    public var localShowsHiddenFiles: Bool
    public var deviceShowsHiddenFiles: Bool
    public var localViewMode: BrowserViewMode
    public var deviceViewMode: BrowserViewMode
    public var showLocalPane: Bool
    public var localPaneOnLeft: Bool
    public var enableUsbHotplug: Bool
    public var enableStatusBar: Bool
    public var fileConflictPolicy: FileConflictPolicy
    public var showDirectoriesFirst: Bool
    public var preprocessFilesBeforeUpload: Bool
    public var preprocessFilesBeforeDownload: Bool
    public var automaticallyChecksForUpdates: Bool
    public var automaticallyDownloadsUpdates: Bool
    public var receivesBetaUpdates: Bool
    public var deviceFirstLayoutVersion: Int
    /// 1 once ``enableUsbHotplug`` has been switched on by the migration that
    /// made hotplug the default (see ``AppSettings``). Files written before it
    /// have no key and decode as 0.
    public var usbHotplugDefaultVersion: Int
    public var onboardingShownVersion: String?

    public init(
        theme: AppTheme = .system,
        localShowsHiddenFiles: Bool = false,
        deviceShowsHiddenFiles: Bool = false,
        localViewMode: BrowserViewMode = .grid,
        deviceViewMode: BrowserViewMode = .grid,
        showLocalPane: Bool = false,
        localPaneOnLeft: Bool = true,
        enableUsbHotplug: Bool = true,
        enableStatusBar: Bool = true,
        fileConflictPolicy: FileConflictPolicy = .askEveryFile,
        showDirectoriesFirst: Bool = true,
        preprocessFilesBeforeUpload: Bool = true,
        preprocessFilesBeforeDownload: Bool = true,
        automaticallyChecksForUpdates: Bool = true,
        automaticallyDownloadsUpdates: Bool = true,
        receivesBetaUpdates: Bool = false,
        deviceFirstLayoutVersion: Int = 1,
        usbHotplugDefaultVersion: Int = 1,
        onboardingShownVersion: String? = nil
    ) {
        self.theme = theme
        self.localShowsHiddenFiles = localShowsHiddenFiles
        self.deviceShowsHiddenFiles = deviceShowsHiddenFiles
        self.localViewMode = localViewMode
        self.deviceViewMode = deviceViewMode
        self.showLocalPane = showLocalPane
        self.localPaneOnLeft = localPaneOnLeft
        self.enableUsbHotplug = enableUsbHotplug
        self.enableStatusBar = enableStatusBar
        self.fileConflictPolicy = fileConflictPolicy
        self.showDirectoriesFirst = showDirectoriesFirst
        self.preprocessFilesBeforeUpload = preprocessFilesBeforeUpload
        self.preprocessFilesBeforeDownload = preprocessFilesBeforeDownload
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        self.receivesBetaUpdates = receivesBetaUpdates
        self.deviceFirstLayoutVersion = deviceFirstLayoutVersion
        self.usbHotplugDefaultVersion = usbHotplugDefaultVersion
        self.onboardingShownVersion = onboardingShownVersion
    }

    public init(from decoder: any Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? defaults.theme
        localShowsHiddenFiles = try container.decodeIfPresent(
            Bool.self,
            forKey: .localShowsHiddenFiles
        ) ?? defaults.localShowsHiddenFiles
        deviceShowsHiddenFiles = try container.decodeIfPresent(
            Bool.self,
            forKey: .deviceShowsHiddenFiles
        ) ?? defaults.deviceShowsHiddenFiles
        localViewMode = try container.decodeIfPresent(
            BrowserViewMode.self,
            forKey: .localViewMode
        ) ?? defaults.localViewMode
        deviceViewMode = try container.decodeIfPresent(
            BrowserViewMode.self,
            forKey: .deviceViewMode
        ) ?? defaults.deviceViewMode
        showLocalPane = try container.decodeIfPresent(
            Bool.self,
            forKey: .showLocalPane
        ) ?? defaults.showLocalPane
        localPaneOnLeft = try container.decodeIfPresent(
            Bool.self,
            forKey: .localPaneOnLeft
        ) ?? defaults.localPaneOnLeft
        enableUsbHotplug = try container.decodeIfPresent(
            Bool.self,
            forKey: .enableUsbHotplug
        ) ?? defaults.enableUsbHotplug
        enableStatusBar = try container.decodeIfPresent(
            Bool.self,
            forKey: .enableStatusBar
        ) ?? defaults.enableStatusBar
        fileConflictPolicy = try container.decodeIfPresent(
            FileConflictPolicy.self,
            forKey: .fileConflictPolicy
        ) ?? defaults.fileConflictPolicy
        showDirectoriesFirst = try container.decodeIfPresent(
            Bool.self,
            forKey: .showDirectoriesFirst
        ) ?? defaults.showDirectoriesFirst
        preprocessFilesBeforeUpload = try container.decodeIfPresent(
            Bool.self,
            forKey: .preprocessFilesBeforeUpload
        ) ?? defaults.preprocessFilesBeforeUpload
        preprocessFilesBeforeDownload = try container.decodeIfPresent(
            Bool.self,
            forKey: .preprocessFilesBeforeDownload
        ) ?? defaults.preprocessFilesBeforeDownload
        automaticallyChecksForUpdates = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyChecksForUpdates
        ) ?? defaults.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyDownloadsUpdates
        ) ?? defaults.automaticallyDownloadsUpdates
        receivesBetaUpdates = try container.decodeIfPresent(
            Bool.self,
            forKey: .receivesBetaUpdates
        ) ?? defaults.receivesBetaUpdates
        deviceFirstLayoutVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceFirstLayoutVersion
        ) ?? 0
        usbHotplugDefaultVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .usbHotplugDefaultVersion
        ) ?? 0
        onboardingShownVersion = try container.decodeIfPresent(
            String.self,
            forKey: .onboardingShownVersion
        )
    }
}
