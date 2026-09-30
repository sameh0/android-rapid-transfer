import XCTest
@testable import AndroidRapidTransferCore

final class FileOperationSupportTests: XCTestCase {
    func testNameValidationRejectsEmptySlashAndSiblingCollision() {
        XCTAssertEqual(
            FileNameValidator.validationMessage(for: "  ", existingNames: []),
            "The name cannot be empty."
        )
        XCTAssertEqual(
            FileNameValidator.validationMessage(for: "a/b", existingNames: []),
            "The name cannot contain a slash (/)."
        )
        XCTAssertEqual(
            FileNameValidator.validationMessage(for: "photos", existingNames: ["Photos"]),
            "An item named “photos” already exists."
        )
        XCTAssertNil(
            FileNameValidator.validationMessage(
                for: "PHOTOS",
                existingNames: ["Photos"],
                originalName: "Photos"
            )
        )
    }

    func testNewFolderSuggestionStartsAtTwoAndSkipsCollisions() {
        XCTAssertEqual(
            NewFolderNameSuggestion.availableName(existingNames: []),
            "untitled folder"
        )
        XCTAssertEqual(
            NewFolderNameSuggestion.availableName(existingNames: ["Untitled Folder"]),
            "untitled folder 2"
        )
        XCTAssertEqual(
            NewFolderNameSuggestion.availableName(
                existingNames: ["untitled folder", "untitled folder 2", "untitled folder 3"]
            ),
            "untitled folder 4"
        )
    }

    func testDeleteConfirmationListsFirstFiveAndRemainderWithCorrectConsequence() {
        let names = (1...8).map { "item-\($0)" }
        let local = FileDeletionConfirmation(destination: .trash, names: names)
        XCTAssertEqual(local.title, "Move 8 Items to Trash?")
        XCTAssertTrue(local.message.contains("will be moved to the Trash"))
        XCTAssertTrue(local.message.contains("item-5"))
        XCTAssertFalse(local.message.contains("item-6"))
        XCTAssertTrue(local.message.hasSuffix("…and 3 more"))

        let device = FileDeletionConfirmation(destination: .device, names: ["photo.jpg"])
        XCTAssertEqual(device.title, "Permanently Delete Item?")
        XCTAssertTrue(device.message.contains("permanent and cannot be undone"))
        XCTAssertTrue(device.message.hasSuffix("photo.jpg"))
    }
}
