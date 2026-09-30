import Foundation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class AppSettingsTests: XCTestCase {
    func testSettingsRoundTripAndCreateNativeFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.nativeSettings.path))

        settings.theme = .dark
        settings.localShowsHiddenFiles = true
        settings.deviceShowsHiddenFiles = true
        settings.localViewMode = .list
        settings.deviceViewMode = .grid
        settings.showLocalPane = false
        settings.localPaneOnLeft = false
        settings.enableUsbHotplug = true
        settings.enableStatusBar = false
        settings.markOnboardingShown(version: "1.2.3")

        let reloaded = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertEqual(reloaded.snapshot, settings.snapshot)
    }

    func testCorruptNativeFileRecoversToDefaultsAndRewritesValidJSON() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("not-json".utf8).write(to: fixture.nativeSettings)

        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )

        XCTAssertEqual(settings.snapshot, AppSettingsSnapshot())
        let recoveredData = try Data(contentsOf: fixture.nativeSettings)
        let recovered = try JSONDecoder().decode(AppSettingsSnapshot.self, from: recoveredData)
        XCTAssertEqual(recovered, AppSettingsSnapshot())
    }

    /// Earlier builds saved a transfer-engine choice. The key is ignored on
    /// load, keeps every other setting, and is dropped at the next save.
    func testRemovedEngineSettingIsToleratedAndDropped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data(#"{ "theme": "dark", "mtpEngine": "builtin", "deviceFirstLayoutVersion": 1, "usbHotplugDefaultVersion": 1 }"#.utf8)
            .write(to: fixture.nativeSettings)

        let settings = AppSettings(settingsURL: fixture.nativeSettings)

        XCTAssertEqual(settings.theme, .dark)
        let saved = try String(contentsOf: fixture.nativeSettings, encoding: .utf8)
        XCTAssertFalse(saved.contains("mtpEngine"), saved)
        XCTAssertTrue(saved.contains("\"theme\" : \"dark\""), saved)
    }

    func testOlderSettingsLayoutMigratesToDeviceFirstLayoutOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let olderJSON = """
        {
          "showLocalPane": true,
          "localPaneOnLeft": true
        }
        """
        try Data(olderJSON.utf8).write(to: fixture.nativeSettings)

        let migrated = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertFalse(migrated.showLocalPane)
        XCTAssertEqual(migrated.deviceFirstLayoutVersion, 1)

        migrated.showLocalPane = true
        let reloaded = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertTrue(reloaded.showLocalPane)
        XCTAssertEqual(reloaded.deviceFirstLayoutVersion, 1)
    }

    func testUsbHotplugIsOnByDefault() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let settings = AppSettings(settingsURL: fixture.nativeSettings)

        XCTAssertTrue(settings.enableUsbHotplug)
        XCTAssertTrue(AppSettingsSnapshot().enableUsbHotplug)
    }

    /// Earlier builds defaulted hotplug off and saved that default, so the
    /// installed app never noticed a phone being unplugged or plugged back in.
    func testSavedHotplugOffFromBeforeTheDefaultChangeIsSwitchedOnOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let savedByEarlierBuild = """
        {
          "deviceFirstLayoutVersion": 1,
          "enableUsbHotplug": false,
          "deviceViewMode": "grid"
        }
        """
        try Data(savedByEarlierBuild.utf8).write(to: fixture.nativeSettings)

        let migrated = AppSettings(settingsURL: fixture.nativeSettings)
        XCTAssertTrue(migrated.enableUsbHotplug)
        XCTAssertEqual(migrated.usbHotplugDefaultVersion, 1)

        // Turning it off after the migration is a real choice and is kept.
        migrated.enableUsbHotplug = false
        let reloaded = AppSettings(settingsURL: fixture.nativeSettings)
        XCTAssertFalse(reloaded.enableUsbHotplug)
        XCTAssertEqual(reloaded.usbHotplugDefaultVersion, 1)
    }

    func testThemeAndPaneLayoutApplicationLogic() async throws {
        XCTAssertNil(AppTheme.system.appearanceOverride)
        XCTAssertEqual(AppTheme.light.appearanceOverride, .light)
        XCTAssertEqual(AppTheme.dark.appearanceOverride, .dark)

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )

        XCTAssertEqual(settings.paneOrder, [.device])
        settings.showLocalPane = true
        XCTAssertEqual(settings.paneOrder, [.local, .device])
        settings.localPaneOnLeft = false
        XCTAssertEqual(settings.paneOrder, [.device, .local])
        settings.showLocalPane = false
        XCTAssertEqual(settings.paneOrder, [.device])
    }

    func testDefaultURLUsesInjectedHome() async {
        let home = URL(fileURLWithPath: "/tmp/art-test-home", isDirectory: true)
        #if os(Linux)
        XCTAssertEqual(
            AppSettings.defaultSettingsURL(environment: ["HOME": home.path]).path,
            "/tmp/art-test-home/.config/\(AppIdentity.supportDirectoryName)/settings.json"
        )
        XCTAssertEqual(
            AppSettings.defaultSettingsURL(environment: ["HOME": home.path, "XDG_CONFIG_HOME": "/tmp/xdg-config"]).path,
            "/tmp/xdg-config/\(AppIdentity.supportDirectoryName)/settings.json"
        )
        #else
        XCTAssertEqual(
            AppSettings.defaultSettingsURL(environment: ["HOME": home.path]).path,
            home.appending(
                path: "Library/Application Support/\(AppIdentity.supportDirectoryName)/settings.json"
            ).path
        )
        #endif
    }

    func testXDGAppDirectoriesFollowTheSpecification() {
        let defaults = XDGAppDirectories(environment: ["HOME": "/home/u"], directoryName: "app")
        XCTAssertEqual(defaults.config.path, "/home/u/.config/app")
        XCTAssertEqual(defaults.state.path, "/home/u/.local/state/app")
        XCTAssertEqual(defaults.data.path, "/home/u/.local/share/app")

        let custom = XDGAppDirectories(environment: [
            "HOME": "/home/u",
            "XDG_CONFIG_HOME": "/c",
            "XDG_STATE_HOME": "/s",
            // Relative values are invalid and ignored.
            "XDG_DATA_HOME": "relative/data"
        ], directoryName: "app")
        XCTAssertEqual(custom.config.path, "/c/app")
        XCTAssertEqual(custom.state.path, "/s/app")
        XCTAssertEqual(custom.data.path, "/home/u/.local/share/app")
    }

    func testDeviceAccessProblemsAreRecognisedFromTheTransportText() {
        let busy = DeviceAccessProblem(message: "ErrorDeviceSetup: could not open the MTP interface: claiming interface 0 of /dev/bus/usb/003/010: gvfsd-mtp (pid 42) is using the phone (exclusiveAccess, errno 16)")
        XCTAssertEqual(busy?.deviceNodePath, "/dev/bus/usb/003/010")
        if case .busy = busy {} else { XCTFail("not busy: \(String(describing: busy))") }

        let denied = DeviceAccessProblem(message: "could not open the MTP interface: cannot open /dev/bus/usb/001/007: Permission denied. /dev/bus/usb/001/007 is owned by root:root (notPermitted, errno 13)")
        XCTAssertEqual(denied?.deviceNodePath, "/dev/bus/usb/001/007")
        if case .permissionDenied = denied {} else { XCTFail("not permission: \(String(describing: denied))") }

        XCTAssertNil(DeviceAccessProblem(message: "ErrorMtpDetectFailed: no MTP devices found"))
    }

    func testOnboardingIsRequiredOnFirstLaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )

        XCTAssertTrue(settings.needsOnboarding(for: "1.0.0"))
    }

    func testOnboardingIsNotRequiredAfterCurrentVersionWasShown() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )

        settings.markOnboardingShown(version: "1.0.0")

        XCTAssertFalse(settings.needsOnboarding(for: "1.0.0"))
        let reloaded = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertEqual(reloaded.onboardingShownVersion, "1.0.0")
        XCTAssertFalse(reloaded.needsOnboarding(for: "1.0.0"))
    }

    func testOnboardingIsRequiredAfterVersionBump() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )

        settings.markOnboardingShown(version: "1.0.0")

        XCTAssertTrue(settings.needsOnboarding(for: "1.1.0"))
        XCTAssertFalse(settings.needsOnboarding(for: "0.9.0"))
    }

    func testFileConflictPolicyRoundTrips() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertEqual(settings.fileConflictPolicy, .askEveryFile)

        settings.fileConflictPolicy = .alwaysOverwrite

        let reloaded = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertEqual(reloaded.fileConflictPolicy, .alwaysOverwrite)
    }

    func testMissingFileConflictPolicyDecodesToDefault() async throws {
        // A settings.json written before the key existed must decode to the
        // default rather than failing.
        let json = """
        { "theme": "dark", "enableStatusBar": true }
        """
        let snapshot = try JSONDecoder().decode(
            AppSettingsSnapshot.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(snapshot.fileConflictPolicy, .askEveryFile)
    }

    private func makeFixture() throws -> (
        root: URL,
        nativeSettings: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ART-AppSettingsTests-(UUID().uuidString)")
        let nativeSettings = root.appending(path: "native/settings.json")
        try FileManager.default.createDirectory(
            at: nativeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (root, nativeSettings)
    }
}
