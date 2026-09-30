import Foundation
import XCTest
@testable import AndroidRapidTransferCore

final class AbnormalExitMonitorTests: XCTestCase {
    private var directory: URL!
    private var monitor: AbnormalExitMonitor!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "abnormal-exit-\(UUID().uuidString)", directoryHint: .isDirectory)
        monitor = AbnormalExitMonitor(markerURL: directory.appending(path: "nested/session-running"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testFirstLaunchIsNotAbnormalAndWritesMarker() {
        XCTAssertFalse(monitor.beginSession())
        XCTAssertTrue(FileManager.default.fileExists(atPath: monitor.markerURL.path))
    }

    func testCleanQuitIsNotReportedNextLaunch() {
        monitor.beginSession()
        monitor.endSessionCleanly()
        XCTAssertFalse(FileManager.default.fileExists(atPath: monitor.markerURL.path))
        XCTAssertFalse(monitor.beginSession())
    }

    func testSessionThatNeverQuitIsReportedOnceThenResets() {
        monitor.beginSession()
        // No clean quit: the process died.
        XCTAssertTrue(monitor.beginSession())
        monitor.endSessionCleanly()
        XCTAssertFalse(monitor.beginSession())
    }

    func testEndingWithoutAMarkerIsHarmless() {
        monitor.endSessionCleanly()
        XCTAssertFalse(monitor.beginSession())
    }

    func testDefaultMarkerSitsWithTheSettings() {
        let url = AbnormalExitMonitor.defaultMarkerURL(environment: ["HOME": "/tmp/fakehome"])
        #if os(Linux)
        XCTAssertEqual(url.path, "/tmp/fakehome/.local/state/\(AppIdentity.supportDirectoryName)/session-running")
        #else
        XCTAssertEqual(url.path, "/tmp/fakehome/Library/Application Support/\(AppIdentity.supportDirectoryName)/session-running")
        #endif
    }

    @MainActor
    func testNoticeShowsOnlyAfterAbnormalExitAndDismisses() {
        XCTAssertFalse(AbnormalExitNotice(previousSessionEndedAbnormally: false).isVisible)
        let notice = AbnormalExitNotice(previousSessionEndedAbnormally: true)
        XCTAssertTrue(notice.isVisible)
        notice.dismiss()
        XCTAssertFalse(notice.isVisible)
    }
}

final class ShortcutHelpTests: XCTestCase {
    func testGroupsCoverTheWholeHelpListingExactlyOnce() {
        let listed = ShortcutHelp.groups().flatMap(\.shortcuts).map(\.id)
        XCTAssertEqual(Set(listed), Set(AppShortcuts.helpListing.map(\.id)))
        XCTAssertEqual(listed.count, AppShortcuts.helpListing.count)
    }

    func testGroupsFollowScopeOrderAndPreserveListingOrder() {
        let groups = ShortcutHelp.groups()
        let expectedScopes = AppShortcut.Scope.allCases.filter { scope in
            AppShortcuts.helpListing.contains { $0.scope == scope }
        }
        XCTAssertEqual(groups.map(\.scope), expectedScopes)
        for group in groups {
            XCTAssertEqual(
                group.shortcuts.map(\.id),
                AppShortcuts.helpListing.filter { $0.scope == group.scope }.map(\.id)
            )
        }
    }

    func testEmptyScopesAreOmitted() {
        let appOnly = AppShortcuts.helpListing.filter { $0.scope == .app }
        XCTAssertEqual(ShortcutHelp.groups(from: appOnly).map(\.scope), [.app])
    }
}

final class HelpMenuTests: XCTestCase {
    func testEveryWindowDestinationIsADeclaredWindow() {
        for item in HelpMenuItem.allCases {
            if case let .window(id) = item.destination {
                XCTAssertTrue(AppWindowID.all.contains(id), "\(item) opens undeclared window \(id)")
            }
        }
    }

    func testRoutesToTheExpectedPlaces() {
        XCTAssertEqual(HelpMenuItem.troubleshooting.destination, .window(AppWindowID.help))
        XCTAssertEqual(HelpMenuItem.privacy.destination, .window(AppWindowID.privacy))
        XCTAssertEqual(HelpMenuItem.reportBug.destination, .window(AppWindowID.reportBug))
        XCTAssertEqual(HelpMenuItem.keyboardShortcuts.destination, .window(AppWindowID.keyboardShortcuts))
        XCTAssertEqual(HelpMenuItem.connectionHelp.destination, .connectionOnboarding)
        XCTAssertEqual(HelpMenuItem.onboarding.destination, .onboarding)
    }

    func testTitlesAndWindowIDsAreUnique() {
        let titles = HelpMenuItem.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(Set(AppWindowID.all).count, AppWindowID.all.count)
    }
}

final class HelpContentTests: XCTestCase {
    private func allText(appName: String) -> [String] {
        HelpContent.topics(appName: appName)
            .flatMap { [$0.title, $0.summary] + $0.sections.flatMap { [$0.title] + $0.paragraphs + $0.steps } }
            + HelpContent.connectionSteps(appName: appName)
            + PrivacyContent.sections(appName: appName).flatMap { [$0.title] + $0.paragraphs }
    }

    func testAppNameIsInterpolatedNotHardcoded() {
        let text = allText(appName: "Zzqx")
        XCTAssertFalse(text.contains { $0.contains(AppIdentity.fallbackName) })
        XCTAssertTrue(text.contains { $0.contains("Zzqx") })
    }

    func testTopicAndSectionIDsAreUnique() {
        let topics = HelpContent.topics()
        XCTAssertEqual(Set(topics.map(\.id)).count, topics.count)
        for topic in topics {
            XCTAssertFalse(topic.sections.isEmpty)
            XCTAssertEqual(Set(topic.sections.map(\.id)).count, topic.sections.count)
        }
    }

    func testConnectionStepsIncludeAllowAccessAndReplug() {
        let steps = HelpContent.connectionSteps().joined(separator: "\n")
        XCTAssertTrue(steps.contains("Allow"))
        XCTAssertTrue(steps.contains("Unplug"))
        XCTAssertTrue(steps.contains("File transfer"))
    }

    func testInterferingAppsNameTheKnownCulprits() {
        let topic = HelpContent.topics().first { $0.id == "interfering-apps" }
        let text = (topic?.sections ?? []).flatMap { [$0.title] + $0.paragraphs }.joined(separator: "\n")
        #if os(Linux)
        let culprits = ["Files (GNOME)", "GVFS", "KDE", "kiod", "Shotwell", "gphoto2"]
        #else
        let culprits = ["Android File Transfer", "Google Drive", "Dropbox", "OneDrive", "Image Capture", "Smart Switch"]
        #endif
        for app in culprits {
            XCTAssertTrue(text.contains(app), "missing \(app)")
        }
    }

    func testPrivacyListsExactlyTheBugReportContents() {
        let items = [BugReportItem(fileName: "a.txt", description: "first")]
        let section = PrivacyContent.sections(bugReportContents: items).first { $0.id == "bug-reports" }
        XCTAssertEqual(section?.steps, ["a.txt — first"])
        let real = PrivacyContent.sections().first { $0.id == "bug-reports" }
        XCTAssertEqual(real?.steps.count, BugReportGenerator.contents().count)
    }

    func testAppIdentityPrefersDisplayNameThenBundleName() {
        XCTAssertEqual(AppIdentity.name(from: ["CFBundleDisplayName": "Shown", "CFBundleName": "Bundle"]), "Shown")
        XCTAssertEqual(AppIdentity.name(from: ["CFBundleName": "Bundle"]), "Bundle")
        XCTAssertEqual(AppIdentity.name(from: ["CFBundleName": "  "]), AppIdentity.fallbackName)
        XCTAssertEqual(AppIdentity.name(from: nil), AppIdentity.fallbackName)
    }
}
