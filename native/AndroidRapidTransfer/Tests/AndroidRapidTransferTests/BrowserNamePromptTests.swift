import AndroidRapidTransferCore
import XCTest
@testable import AndroidRapidTransfer

final class BrowserNamePromptTests: XCTestCase {
    private let entry = BrowserEntry(
        id: "/photo.jpg",
        name: "photo.jpg",
        size: 1,
        modified: nil,
        isDirectory: false,
        location: "/photo.jpg"
    )

    func testPhoneRenameCarriesSupportWarning() {
        XCTAssertEqual(
            BrowserNamePrompt(entry: entry, paneKind: .device).hint,
            "Enter a name. Not all phones will support the rename feature."
        )
    }

    func testOtherPromptsUseThePlainHint() {
        XCTAssertEqual(BrowserNamePrompt(entry: entry, paneKind: .local).hint, "Enter a name.")
        XCTAssertEqual(BrowserNamePrompt(entry: nil, paneKind: .device).hint, "Enter a name.")
        XCTAssertEqual(BrowserNamePrompt(entry: nil).hint, "Enter a name.")
    }
}
