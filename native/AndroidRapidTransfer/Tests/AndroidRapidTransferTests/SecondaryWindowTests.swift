@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import XCTest

final class SecondaryWindowTests: XCTestCase {
    // MARK: - Keyboard Shortcuts keycaps

    func testKeycapsSplitModifiersFromTheKey() {
        XCTAssertEqual(KeyboardShortcutsView.keycaps(for: "⇧⌘C"), ["⇧", "⌘", "C"])
        XCTAssertEqual(KeyboardShortcutsView.keycaps(for: "⌘N"), ["⌘", "N"])
        XCTAssertEqual(KeyboardShortcutsView.keycaps(for: "Delete"), ["Delete"])
        XCTAssertEqual(KeyboardShortcutsView.keycaps(for: "⇧↑"), ["⇧", "↑"])
        XCTAssertEqual(KeyboardShortcutsView.keycaps(for: ""), [])
    }

    func testEveryListedShortcutHasAKeyCap() {
        for group in ShortcutHelp.groups() {
            for shortcut in group.shortcuts {
                let caps = KeyboardShortcutsView.keycaps(for: shortcut.displayValue)
                XCTAssertFalse(caps.isEmpty, shortcut.title)
                XCTAssertEqual(caps.joined(), shortcut.displayValue, shortcut.title)
            }
        }
    }

    // MARK: - Bug report progress

    private typealias StageState = BugReportProgressView.StageState

    private func states(_ items: [StageState]) -> [StageState.State] {
        items.map(\.state)
    }

    func testNothingHasStartedBeforeAReport() {
        XCTAssertEqual(states(StageState.all(current: nil)), [.pending, .pending, .pending, .pending])
    }

    func testEarlierStagesAreDoneWhileOneRuns() {
        XCTAssertEqual(states(StageState.all(current: .release)), [.active, .pending, .pending, .pending])
        XCTAssertEqual(states(StageState.all(current: .collect)), [.done, .done, .active, .pending])
        XCTAssertEqual(states(StageState.all(current: .archive)), [.done, .done, .done, .active])
    }

    func testAFinishedReportTicksEveryStage() {
        XCTAssertEqual(states(StageState.all(current: nil, isFinished: true)), [.done, .done, .done, .done])
    }

    func testAFailureMarksTheStageThatWasRunning() {
        XCTAssertEqual(
            states(StageState.all(current: .diagnose, didFail: true)),
            [.done, .failed, .pending, .pending]
        )
        XCTAssertEqual(StageState.all(current: nil).map(\.stage), BugReportStage.allCases)
    }
}
