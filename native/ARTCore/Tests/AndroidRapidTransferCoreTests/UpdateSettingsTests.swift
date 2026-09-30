import Foundation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class UpdateSettingsTests: XCTestCase {
    // MARK: - Settings

    func testFreshSettingsCheckAndDownloadAutomaticallyOnTheStableChannel() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )

        XCTAssertTrue(settings.automaticallyChecksForUpdates)
        XCTAssertTrue(settings.automaticallyDownloadsUpdates)
        XCTAssertFalse(settings.receivesBetaUpdates)
    }

    func testUpdateSettingsPersistAcrossLaunches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        settings.automaticallyChecksForUpdates = false
        settings.automaticallyDownloadsUpdates = false
        settings.receivesBetaUpdates = true

        let reloaded = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertFalse(reloaded.automaticallyChecksForUpdates)
        XCTAssertFalse(reloaded.automaticallyDownloadsUpdates)
        XCTAssertTrue(reloaded.receivesBetaUpdates)
    }

    func testSettingsFileWrittenBeforeUpdateKeysLoadsUpdateDefaults() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data(#"{"theme":"dark","deviceFirstLayoutVersion":1}"#.utf8)
            .write(to: fixture.nativeSettings)

        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )

        XCTAssertEqual(settings.theme, .dark)
        XCTAssertTrue(settings.automaticallyChecksForUpdates)
        XCTAssertTrue(settings.automaticallyDownloadsUpdates)
        XCTAssertFalse(settings.receivesBetaUpdates)
    }

    // MARK: - Effective preferences

    func testBackgroundDownloadsNeedAutomaticChecks() async {
        let preferences = UpdatePreferences(
            automaticallyChecks: false,
            automaticallyDownloads: true,
            receivesBetaUpdates: false,
            appVersion: "1.0.0"
        )
        XCTAssertFalse(preferences.automaticallyChecks)
        XCTAssertFalse(preferences.automaticallyDownloads)
    }

    func testStableBuildFollowsTheBetaSwitch() async {
        let off = UpdatePreferences(
            automaticallyChecks: true,
            automaticallyDownloads: true,
            receivesBetaUpdates: false,
            appVersion: "1.0.0"
        )
        XCTAssertFalse(off.receivesBetaUpdates)
        XCTAssertFalse(off.isBetaChannelLocked)
        XCTAssertEqual(off.allowedChannels, [])

        let on = UpdatePreferences(
            automaticallyChecks: true,
            automaticallyDownloads: true,
            receivesBetaUpdates: true,
            appVersion: "1.0.0"
        )
        XCTAssertTrue(on.receivesBetaUpdates)
        XCTAssertEqual(on.allowedChannels, [UpdatePreferences.betaChannel])
    }

    func testPrereleaseBuildIsLockedOntoTheBetaChannel() async {
        let preferences = UpdatePreferences(
            automaticallyChecks: true,
            automaticallyDownloads: true,
            receivesBetaUpdates: false,
            appVersion: "1.1.0-beta.2"
        )
        XCTAssertTrue(preferences.receivesBetaUpdates)
        XCTAssertTrue(preferences.isBetaChannelLocked)
        XCTAssertEqual(preferences.allowedChannels, ["beta"])
    }

    func testPrereleaseVersionDetection() async {
        XCTAssertTrue(AppVersion.isPrerelease("0.2.0-beta.1"))
        XCTAssertTrue(AppVersion.isPrerelease("1.0.0-rc1"))
        XCTAssertFalse(AppVersion.isPrerelease("1.0.0"))
        XCTAssertFalse(AppVersion.isPrerelease("0.1"))
    }

    func testSettingsProduceThePreferencesForTheirBuild() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        settings.automaticallyChecksForUpdates = false

        let preferences = settings.updatePreferences(appVersion: "2.0.0")
        XCTAssertFalse(preferences.automaticallyChecks)
        XCTAssertFalse(preferences.automaticallyDownloads)
        XCTAssertFalse(preferences.receivesBetaUpdates)
    }

    // MARK: - Updater availability

    func testOnlyAnAppBundleWithFeedAndKeyCanUpdate() async {
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        let complete: [String: Any] = [
            UpdaterAvailability.feedURLKey: "https://example.com/appcast.xml",
            UpdaterAvailability.publicKeyKey: "abc="
        ]
        XCTAssertTrue(UpdaterAvailability.isAvailable(bundleURL: app, infoDictionary: complete))

        // `swift run` and test hosts are not app bundles.
        let tool = URL(fileURLWithPath: "/tmp/.build/debug")
        XCTAssertFalse(UpdaterAvailability.isAvailable(bundleURL: tool, infoDictionary: complete))

        var missingKey = complete
        missingKey[UpdaterAvailability.publicKeyKey] = "  "
        XCTAssertFalse(UpdaterAvailability.isAvailable(bundleURL: app, infoDictionary: missingKey))

        var insecureFeed = complete
        insecureFeed[UpdaterAvailability.feedURLKey] = "http://example.com/appcast.xml"
        XCTAssertFalse(UpdaterAvailability.isAvailable(bundleURL: app, infoDictionary: insecureFeed))

        XCTAssertFalse(UpdaterAvailability.isAvailable(bundleURL: app, infoDictionary: nil))
    }

    // MARK: - Install deferral

    func testInstallProceedsImmediatelyWithoutTransfers() async {
        let gate = UpdateInstallGate(hasActiveTransfers: { false })
        var installs = 0

        XCTAssertFalse(gate.shouldPostponeInstall { installs += 1 })
        XCTAssertFalse(gate.isHoldingInstall)
        XCTAssertEqual(installs, 0, "Sparkle proceeds itself; the handler must not also run")
    }

    func testInstallWaitsForTheLastTransferToFinish() async {
        var active = true
        let gate = UpdateInstallGate(hasActiveTransfers: { active })
        var installs = 0

        XCTAssertTrue(gate.shouldPostponeInstall { installs += 1 })
        XCTAssertTrue(gate.isHoldingInstall)

        gate.transferActivityChanged()
        XCTAssertEqual(installs, 0, "Still copying: the relaunch stays parked")

        active = false
        gate.transferActivityChanged()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(gate.isHoldingInstall)

        gate.transferActivityChanged()
        XCTAssertEqual(installs, 1, "The parked relaunch runs exactly once")
    }

    func testActivityChangesWithNothingParkedDoNothing() async {
        let gate = UpdateInstallGate(hasActiveTransfers: { false })
        gate.transferActivityChanged()
        XCTAssertFalse(gate.isHoldingInstall)
    }

    private func makeFixture() throws -> (root: URL, nativeSettings: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "UpdateSettingsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root,
            root.appending(path: "native-settings.json")
        )
    }
}
