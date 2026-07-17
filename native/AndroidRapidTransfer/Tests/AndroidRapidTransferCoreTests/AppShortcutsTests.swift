import XCTest
@testable import AndroidRapidTransferCore

final class AppShortcutsTests: XCTestCase {
    func testEveryRegisteredShortcutAppearsInHelpListing() {
        XCTAssertEqual(AppShortcuts.helpListing, AppShortcuts.registered)
        XCTAssertEqual(
            Set(AppShortcuts.helpListing.map(\.id)).count,
            AppShortcuts.registered.count,
            "Each registered shortcut should appear exactly once in help."
        )
    }
}
