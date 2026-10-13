import Foundation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
private final class FakeRunningApplications: RunningApplicationsProviding {
    var runningApplications: [RunningAppSnapshot] = []
    /// Whether `terminate` succeeds in sending the request.
    var acceptsTerminate = true
    /// Whether an app actually quits when asked.
    var quitsWhenAsked = true
    private(set) var terminated: [Int32] = []
    private(set) var isObserving = false
    private var onChange: (@MainActor @Sendable () -> Void)?

    func terminate(processIdentifier: Int32) -> Bool {
        terminated.append(processIdentifier)
        guard acceptsTerminate else { return false }
        if quitsWhenAsked {
            remove(processIdentifier)
        }
        return true
    }

    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        isObserving = true
        self.onChange = onChange
    }

    func stopObserving() {
        isObserving = false
        onChange = nil
    }

    func launch(_ pid: Int32, _ bundleIdentifier: String?, _ name: String?) {
        runningApplications.append(RunningAppSnapshot(processIdentifier: pid, bundleIdentifier: bundleIdentifier, name: name))
        onChange?()
    }

    func remove(_ pid: Int32) {
        runningApplications.removeAll { $0.processIdentifier == pid }
        onChange?()
    }
}

@MainActor
final class ConflictingAppsModelTests: XCTestCase {
    private var provider: FakeRunningApplications!
    private var model: ConflictingAppsModel!

    override func setUp() async throws {
        provider = FakeRunningApplications()
        model = ConflictingAppsModel(provider: provider, sleep: { _ in })
    }

    private var names: [String] { model.entries.map(\.name) }
    private var states: [ConflictingAppsModel.QuitState] { model.entries.map(\.quitState) }

    func testListsOnlyKnownConflictingAppsInHelpOrder() {
        provider.launch(10, "com.apple.Photos", "Photos")
        provider.launch(11, "com.apple.Safari", "Safari")
        provider.launch(12, "com.google.android.mtpviewer", "Android File Transfer")
        provider.launch(13, nil, "Background Helper")
        provider.launch(14, "com.getdropbox.dropbox", "Dropbox")
        model.start()
        XCTAssertEqual(names, ["Android File Transfer", "Dropbox", "Photos"])
        XCTAssertEqual(model.entries.map(\.app.id), ["android-file-transfer", "dropbox", "photos"])
        XCTAssertEqual(states, [.running, .running, .running])
    }

    func testMatchesEveryIdentifierOfAnApp() {
        provider.launch(1, "com.google.android.mtpagent", "Android File Transfer Agent")
        provider.launch(2, "com.microsoft.OneDrive-mac", "OneDrive")
        provider.launch(3, "com.microsoft.OneDrive", "OneDrive")
        model.start()
        XCTAssertEqual(model.entries.map(\.app.id), ["android-file-transfer", "onedrive", "onedrive"])
        XCTAssertEqual(model.entries.map(\.processIdentifier), [1, 2, 3])
    }

    func testSmartSwitchMatchesByNameIgnoringCase() {
        provider.launch(1, "com.example.unknown", "smart switch")
        provider.launch(2, nil, "Samsung Smart Switch")
        provider.launch(3, nil, "Smart Switcher")
        model.start()
        XCTAssertEqual(Set(model.entries.map(\.processIdentifier)), [1, 2])
        XCTAssertTrue(model.entries.allSatisfy { $0.app.id == "smart-switch" })
    }

    func testNameMatchingIsOnlyAFallback() {
        // An app named like a known one but with another identifier is not it.
        provider.launch(1, "com.example.preview", "Preview")
        model.start()
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testMissingNameFallsBackToTheCatalogName() {
        provider.launch(1, "com.google.drivefs", nil)
        provider.launch(2, "com.apple.Preview", "")
        model.start()
        XCTAssertEqual(names, ["Google Drive", "Preview"])
    }

    func testListFollowsLaunchesAndQuitsWhileObserving() {
        model.start()
        XCTAssertTrue(provider.isObserving)
        XCTAssertTrue(model.entries.isEmpty)
        provider.launch(5, "com.apple.Image_Capture", "Image Capture")
        XCTAssertEqual(names, ["Image Capture"])
        provider.launch(6, "com.google.drivefs", "Google Drive")
        XCTAssertEqual(names, ["Google Drive", "Image Capture"])
        provider.remove(5)
        XCTAssertEqual(names, ["Google Drive"])

        model.stop()
        XCTAssertFalse(provider.isObserving)
        provider.launch(7, "com.apple.Photos", "Photos")
        XCTAssertEqual(names, ["Google Drive"], "stopped models do not follow launches")
        model.start()
        XCTAssertEqual(names, ["Google Drive", "Photos"], "starting again catches up")
    }

    func testQuitRemovesTheAppOnceItQuits() async {
        provider.launch(1, "com.getdropbox.dropbox", "Dropbox")
        provider.launch(2, "com.apple.Photos", "Photos")
        model.start()
        model.quit(model.entries[0])
        XCTAssertEqual(provider.terminated, [1])
        XCTAssertEqual(names, ["Photos"])
        await model.waitForQuitChecks()
        XCTAssertEqual(names, ["Photos"])
        XCTAssertEqual(states, [.running])
    }

    func testAppStillRunningAfterTheTimeoutIsReported() async {
        provider.quitsWhenAsked = false
        provider.launch(1, "com.apple.Preview", "Preview")
        model.start()
        model.quit(model.entries[0])
        XCTAssertEqual(states, [.quitting])
        await model.waitForQuitChecks()
        XCTAssertEqual(states, [.stillRunning])

        // Trying again asks again; this time the app quits.
        provider.quitsWhenAsked = true
        model.quit(model.entries[0])
        XCTAssertEqual(provider.terminated, [1, 1])
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testQuittingAppIsNotAskedTwice() {
        provider.quitsWhenAsked = false
        provider.launch(1, "com.apple.Preview", "Preview")
        model.start()
        model.quit(model.entries[0])
        model.quit(model.entries[0])
        model.quitAll()
        XCTAssertEqual(provider.terminated, [1])
        XCTAssertFalse(model.canQuitAll)
    }

    func testAppThatQuitsLateDropsOutWithoutBeingMarked() async {
        provider.quitsWhenAsked = false
        provider.launch(1, "com.apple.Preview", "Preview")
        provider.launch(2, "com.apple.Photos", "Photos")
        model.start()
        model.quit(model.entries[0])
        // It quits after the user answers its save prompt.
        provider.remove(1)
        await model.waitForQuitChecks()
        XCTAssertEqual(names, ["Photos"])
        XCTAssertEqual(states, [.running])
    }

    func testRefusedQuitRequestIsReportedAtOnce() {
        provider.acceptsTerminate = false
        provider.launch(1, "com.apple.Photos", "Photos")
        model.start()
        model.quit(model.entries[0])
        XCTAssertEqual(states, [.stillRunning])
    }

    func testQuitAllAsksEveryAppAndReportsTheOnesLeft() async {
        provider.launch(1, "com.getdropbox.dropbox", "Dropbox")
        provider.launch(2, "com.apple.Preview", "Preview")
        provider.launch(3, "com.apple.Photos", "Photos")
        model.start()
        XCTAssertTrue(model.canQuitAll)
        provider.quitsWhenAsked = false
        model.quitAll()
        XCTAssertEqual(provider.terminated, [1, 2, 3])
        XCTAssertEqual(states, [.quitting, .quitting, .quitting])
        XCTAssertFalse(model.canQuitAll)
        // Two quit; Preview waits on a save prompt.
        provider.remove(1)
        provider.remove(3)
        await model.waitForQuitChecks()
        XCTAssertEqual(names, ["Preview"])
        XCTAssertEqual(states, [.stillRunning])
        XCTAssertTrue(model.canQuitAll)
    }

    func testCatalogMatchesTheHelpTopic() {
        let apps = ConflictingApp.knownApps()
        XCTAssertEqual(Set(apps.map(\.id)).count, apps.count)
        for app in apps {
            XCTAssertFalse(app.reason.isEmpty, app.id)
            XCTAssertFalse(app.bundleIdentifiers.isEmpty && app.fallbackNames.isEmpty, app.id)
        }
        #if !os(Linux)
        let topic = HelpContent.topics().first { $0.id == "interfering-apps" }
        let sections = topic?.sections ?? []
        for app in apps {
            let section = sections.first { $0.id == app.helpSectionID }
            XCTAssertNotNil(section, "\(app.id) points at a missing help section")
            let text = ([section?.title ?? ""] + (section?.paragraphs ?? [])).joined(separator: "\n")
            XCTAssertTrue(text.contains(app.name), "the help section for \(app.id) does not name \(app.name)")
        }
        #endif
    }
}
