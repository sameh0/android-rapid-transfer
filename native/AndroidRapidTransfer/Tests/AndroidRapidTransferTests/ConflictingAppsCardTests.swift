import AppKit
@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import SwiftUI
import XCTest

/// A fixed list of running apps; a quit request is sent but the app stays.
@MainActor
private final class StaticRunningApplications: RunningApplicationsProviding {
    var runningApplications: [RunningAppSnapshot]

    init(_ apps: [RunningAppSnapshot]) {
        runningApplications = apps
    }

    func terminate(processIdentifier: Int32) -> Bool { true }
    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void) {}
    func stopObserving() {}
}

/// Lets quit checks finish at once until `holds` is set.
@MainActor
private final class SleepGate {
    var holds = false
}

@MainActor
final class ConflictingAppsCardTests: XCTestCase {
    func testHelpWindowHasTheTopicTheCardLinksTo() {
        XCTAssertTrue(HelpContent.topics().contains { $0.id == HelpCenterView.conflictingAppsTopicID })
    }

    func testWorkspaceProviderCannotQuitAMissingProcess() {
        let provider = WorkspaceRunningApplications()
        XCTAssertFalse(provider.terminate(processIdentifier: -1))
        XCTAssertFalse(provider.runningApplications.contains { $0.processIdentifier == -1 })
    }

    func testWorkspaceProviderStartsAndStopsObserving() {
        let provider = WorkspaceRunningApplications()
        provider.startObserving {}
        provider.startObserving {}
        provider.stopObserving()
        provider.stopObserving()
    }

    // Offscreen renders of the card's states; skipped unless ART_RENDER_DIR is set:
    //
    //     ART_RENDER_DIR=/tmp/renders swift test --filter ConflictingAppsCard
    func testRenderStates() async throws {
        try XCTSkipIf(BrowserRenderSupport.outputDirectory == nil, "Set ART_RENDER_DIR to render.")
        let clear = ConflictingAppsModel(provider: StaticRunningApplications([]))
        clear.start()
        let gate = SleepGate()
        let busy = ConflictingAppsModel(
            provider: StaticRunningApplications([
                RunningAppSnapshot(processIdentifier: 990_001, bundleIdentifier: "com.google.android.mtpviewer", name: "Android File Transfer"),
                RunningAppSnapshot(processIdentifier: 990_002, bundleIdentifier: "com.getdropbox.dropbox", name: "Dropbox"),
                RunningAppSnapshot(processIdentifier: 990_003, bundleIdentifier: "com.apple.Preview", name: "Preview")
            ]),
            sleep: { _ in
                if await gate.holds { try? await Task.sleep(for: .seconds(3_600)) }
            }
        )
        busy.start()
        // Preview didn't quit; Dropbox is quitting; Android File Transfer is untouched.
        busy.quit(busy.entries[2])
        while busy.entries[2].quitState != .stillRunning {
            await Task.yield()
        }
        gate.holds = true
        busy.quit(busy.entries[1])

        for dark in [false, true] {
            for (name, model) in [("conflicting-apps-none", clear), ("conflicting-apps-running", busy)] {
                let card = ConflictingAppsCard(model: model, showDetails: {})
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(.background)
                BrowserRenderSupport.render(card, size: CGSize(width: 640, height: 300), dark: dark, name: name)
            }
        }
    }
}
