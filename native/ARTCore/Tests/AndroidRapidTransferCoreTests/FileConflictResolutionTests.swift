import Foundation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class FileConflictResolutionTests: XCTestCase {
    func testKeepBothUsesTwoThenAdvancesAcrossMultipleCollisions() async {
        let noNumberedCollisions = await KeepBothNameGenerator.availableName(
            for: "photo.jpg"
        ) { _ in false }
        XCTAssertEqual(noNumberedCollisions, "photo (2).jpg")

        let existingNames: Set<String> = ["photo (2).jpg", "photo (3).jpg"]
        let afterMultipleCollisions = await KeepBothNameGenerator.availableName(
            for: "photo.jpg"
        ) { existingNames.contains($0) }
        XCTAssertEqual(afterMultipleCollisions, "photo (4).jpg")
    }

    func testKeepBothPreservesNamesWithoutExtensions() async {
        let name = await KeepBothNameGenerator.availableName(for: "Documents") { candidate in
            candidate == "Documents (2)"
        }
        XCTAssertEqual(name, "Documents (3)")
    }

    func testStagingMoveRenamesDownloadedItemAndCanReplaceDestination() async throws {
        let fileManager = FileManager.default
        let destinationDirectory = fileManager.temporaryDirectory
            .appending(path: "ART-StagingTests-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: false
        )
        let stagingDirectory = try TransferStaging.makeDirectory(
            appropriateFor: destinationDirectory,
            fileManager: fileManager
        )
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: destinationDirectory)
        }

        let stagedItem = stagingDirectory.appending(path: "photo.jpg")
        let destination = destinationDirectory.appending(path: "photo (2).jpg")
        try Data("new".utf8).write(to: stagedItem)
        try Data("old".utf8).write(to: destination)

        try TransferStaging.finish(
            .moveStagedItem(
                sourcePath: stagedItem.path,
                destinationPath: destination.path,
                replaceExisting: true
            ),
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: stagedItem.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    func testUploadStagingCopiesSourceUnderPrecomputedName() async throws {
        let fileManager = FileManager.default
        let source = fileManager.temporaryDirectory
            .appending(path: "ART-UploadSource-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: source)
        let stagingDirectory = try TransferStaging.makeDirectory(
            appropriateFor: source,
            fileManager: fileManager
        )
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: source)
        }

        let staged = try TransferStaging.copyForUpload(
            source: source,
            named: "report (3).txt",
            in: stagingDirectory,
            fileManager: fileManager
        )

        XCTAssertEqual(staged.lastPathComponent, "report (3).txt")
        XCTAssertEqual(try Data(contentsOf: staged), Data("payload".utf8))
    }
}
