@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import XCTest

final class BrowserChromeTests: XCTestCase {
    func testStatusSummaryCountsItemsSelectionAndItsSize() {
        let summary = BrowserStatusSummary(
            itemCount: 1_204,
            selectedEntries: [
                entry("a.jpg", size: 1_000_000),
                entry("b.jpg", size: 500_000),
                entry("Folder", size: nil)
            ],
            capacity: BrowserCapacity(freeBytes: 25, totalBytes: 100)
        )
        XCTAssertEqual(summary.itemsText, "\(1_204.formatted()) items")
        XCTAssertEqual(
            summary.selectionText,
            "3 selected (\(Int64(1_500_000).formatted(.byteCount(style: .file))))"
        )
        XCTAssertEqual(summary.usedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertTrue(summary.capacityText.contains(" free of "))
    }

    func testStatusSummaryWithoutSelectionOrCapacity() {
        let summary = BrowserStatusSummary(itemCount: 1, selectedEntries: [], capacity: nil)
        XCTAssertEqual(summary.itemsText, "1 item")
        XCTAssertNil(summary.selectionText)
        XCTAssertNil(summary.usedFraction)
        XCTAssertEqual(summary.capacityText, "Free space unavailable")

        let foldersOnly = BrowserStatusSummary(
            itemCount: 2,
            selectedEntries: [entry("A", size: nil)],
            capacity: BrowserCapacity(freeBytes: 0, totalBytes: 0)
        )
        XCTAssertEqual(foldersOnly.selectionText, "1 selected")
        XCTAssertNil(foldersOnly.usedFraction)
    }

    func testDropTitlesNameTheFolderOrTheRoot() {
        let camera = BrowserDropTitle(destination: "/DCIM/Camera", rootName: "Phone")
        XCTAssertEqual(camera.hover, "Copy to Camera")
        XCTAssertEqual(camera.confirmation, "Copying to Camera")
        XCTAssertEqual(BrowserDropTitle(destination: "/", rootName: "Phone").hover, "Copy to Phone")
        XCTAssertEqual(
            BrowserDropTitle(destination: "/", rootName: "This Mac").confirmation,
            "Copying to This Mac"
        )
    }

    private func entry(_ name: String, size: Int64?) -> BrowserEntry {
        BrowserEntry(
            id: "/\(name)",
            name: name,
            size: size,
            modified: nil,
            isDirectory: size == nil,
            location: "/\(name)"
        )
    }
}
