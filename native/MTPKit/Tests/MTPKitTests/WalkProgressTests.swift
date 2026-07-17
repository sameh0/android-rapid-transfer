import Foundation
import XCTest
@testable import MTPKit

final class WalkProgressTests: XCTestCase {
    func testProtocolDefaultUsesPlainWalk() async throws {
        let concrete = PlainProvider()
        let provider: any MTPDeviceProvider = concrete
        let result = try await provider.walk(input: DirectoryWalkInput(storageId: 1, fullPath: "/",
            skipDisallowedFiles: false, skipHiddenFiles: false)) { _ in XCTFail("Unexpected progress") }
        XCTAssertEqual(result, [])
        let calls = await concrete.base.callHistory()
        XCTAssertEqual(calls, [.walk])
    }
}

private struct PlainProvider: MTPDeviceProvider {
    let base = MockMTPProvider()
    func deviceInfo() async throws -> DeviceInfo { try await base.deviceInfo() }
    func storages() async throws -> [StorageInfo] { try await base.storages() }
    func walk(input: DirectoryWalkInput) async throws -> [WalkEntry] { try await base.walk(input: input) }
    func fileExists(input: FileExistsInput) async throws -> [FileExistsData] { try await base.fileExists(input: input) }
    func deleteFiles(input: DeleteFileInput) async throws -> Bool { try await base.deleteFiles(input: input) }
    func makeDirectory(input: MakeDirectoryInput) async throws -> Bool { try await base.makeDirectory(input: input) }
    func renameFile(input: RenameFileInput) async throws -> Bool { try await base.renameFile(input: input) }
    func downloadFiles(input: DownloadFilesInput) async throws -> TransferOperation { try await base.downloadFiles(input: input) }
    func uploadFiles(input: UploadFilesInput) async throws -> TransferOperation { try await base.uploadFiles(input: input) }
    func dispose() async throws -> Bool { try await base.dispose() }
}
