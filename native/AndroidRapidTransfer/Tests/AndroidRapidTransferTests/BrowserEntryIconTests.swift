import AppKit
@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import UniformTypeIdentifiers
import XCTest

final class BrowserEntryIconTests: XCTestCase {
    func testKindComesFromFolderFlagThenNameExtension() {
        XCTAssertEqual(BrowserEntryIcon.contentType(for: entry("DCIM", isDirectory: true)), .folder)
        // A folder whose name looks like a file is still a folder.
        XCTAssertEqual(BrowserEntryIcon.contentType(for: entry("Photos.jpg", isDirectory: true)), .folder)
        XCTAssertEqual(BrowserEntryIcon.contentType(for: entry("IMG_0001.JPG")), .jpeg)
        XCTAssertEqual(BrowserEntryIcon.contentType(for: entry("VID_0001.mp4")), .mpeg4Movie)
        XCTAssertEqual(BrowserEntryIcon.contentType(for: entry("Invoice.pdf")), .pdf)
        XCTAssertEqual(BrowserEntryIcon.contentType(for: entry("README")), .data)
        XCTAssertEqual(BrowserEntryIcon.contentType(for: entry(".nomedia")), .data)
    }

    @MainActor
    func testIconsAreSharedPerKind() {
        let first = BrowserEntryIcon.image(for: entry("a.png"))
        XCTAssertTrue(first === BrowserEntryIcon.image(for: entry("b.png")))
        XCTAssertFalse(first === BrowserEntryIcon.image(for: entry("Folder", isDirectory: true)))
    }

    private func entry(_ name: String, isDirectory: Bool = false) -> BrowserEntry {
        BrowserEntry(
            id: "/\(name)",
            name: name,
            size: isDirectory ? nil : 1,
            modified: nil,
            isDirectory: isDirectory,
            location: "/\(name)"
        )
    }
}
