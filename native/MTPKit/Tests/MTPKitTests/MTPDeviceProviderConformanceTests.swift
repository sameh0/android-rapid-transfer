import XCTest
@testable import MTPKit

final class MTPDeviceProviderConformanceTests: XCTestCase {
    func testConcreteProvidersConform() {
        assertProvider(MockMTPProvider.self)
    }

    func testProtocolSurfaceDispatchesThroughExistential() async throws {
        let concrete = MockMTPProvider(
            deviceInfo: DeviceInfo(model: "mock"),
            storages: [StorageInfo(id: 1)]
        )
        let provider: any MTPDeviceProvider = concrete

        let deviceInfo = try await provider.deviceInfo()
        let storages = try await provider.storages()
        let walk = try await provider.walk(input: walkInput())
        let existence = try await provider.fileExists(
            input: FileExistsInput(storageId: 1, files: ["/x"])
        )
        XCTAssertEqual(deviceInfo.model, "mock")
        XCTAssertEqual(storages.count, 1)
        XCTAssertEqual(walk, [])
        XCTAssertEqual(existence, [FileExistsData(fullpath: "/x", exists: false)])

        let madeDirectory = try await provider.makeDirectory(
            input: MakeDirectoryInput(storageId: 1, fullPath: "/Folder")
        )
        XCTAssertTrue(madeDirectory)
        let renamed = try await provider.renameFile(
            input: RenameFileInput(storageId: 1, fullPath: "/Folder", newFileName: "Renamed")
        )
        XCTAssertTrue(renamed)
        let deleted = try await provider.deleteFiles(
            input: DeleteFileInput(storageId: 1, files: ["/Renamed"])
        )
        XCTAssertTrue(deleted)

        let upload = try await provider.uploadFiles(
            input: UploadFilesInput(
                storageId: 1,
                sources: ["/tmp/a"],
                destination: "/",
                preprocessFiles: false
            )
        )
        let uploadResult = try await upload.result.value
        XCTAssertTrue(uploadResult)
        let download = try await provider.downloadFiles(
            input: DownloadFilesInput(
                storageId: 1,
                sources: ["/a"],
                destination: "/tmp",
                preprocessFiles: false
            )
        )
        let downloadResult = try await download.result.value
        XCTAssertTrue(downloadResult)
        let disposed = try await provider.dispose()
        XCTAssertTrue(disposed)
    }

    private func assertProvider<T: MTPDeviceProvider>(_ type: T.Type) {}

    private func walkInput() -> DirectoryWalkInput {
        DirectoryWalkInput(
            storageId: 1,
            fullPath: "/",
            skipDisallowedFiles: false,
            skipHiddenFiles: false
        )
    }
}
