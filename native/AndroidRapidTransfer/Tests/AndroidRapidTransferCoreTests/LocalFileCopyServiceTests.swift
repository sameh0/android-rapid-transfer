import Foundation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class LocalFileCopyServiceTests: XCTestCase {
    func testFailedReplaceCopyLeavesOriginalFileIntact() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ART-LocalCopyTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)

        let destination = root.appending(path: "report.txt")
        let missingSource = root.appending(path: "missing.txt")
        try Data("original".utf8).write(to: destination)
        let service = LocalFileCopyService()

        do {
            try service.copy(
                source: missingSource,
                to: destination,
                replaceExisting: true
            )
            XCTFail("Expected the staged copy to fail")
        } catch {
            XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
            XCTAssertEqual(
                try fileManager.contentsOfDirectory(atPath: root.path),
                ["report.txt"]
            )
        }
    }
}
