import XCTest
@testable import MTPKit

final class MockMTPProviderTests: XCTestCase {
    func testWalkAndMutationsMaintainDirectoryTree() async throws {
        let provider = MockMTPProvider(entries: Self.fixtureEntries)

        let direct = try await provider.walk(input: walkInput(path: "/"))
        XCTAssertEqual(direct.map(\.path), ["/.hidden", "/DCIM"])

        let nested = try await provider.walk(input: walkInput(path: "/DCIM", skipHidden: true))
        XCTAssertEqual(nested.map(\.path), ["/DCIM/100MEDIA"])

        let madeDirectory = try await provider.makeDirectory(
            input: MakeDirectoryInput(storageId: 1, fullPath: "/DCIM/New")
        )
        XCTAssertTrue(madeDirectory)
        var existence = try await provider.fileExists(
            input: FileExistsInput(storageId: 1, files: ["/DCIM/New", "/missing"])
        )
        XCTAssertEqual(existence, [
            FileExistsData(fullpath: "/DCIM/New", exists: true),
            FileExistsData(fullpath: "/missing", exists: false)
        ])

        let renamed = try await provider.renameFile(
            input: RenameFileInput(
                storageId: 1,
                fullPath: "/DCIM/100MEDIA",
                newFileName: "Renamed"
            )
        )
        XCTAssertTrue(renamed)
        existence = try await provider.fileExists(
            input: FileExistsInput(
                storageId: 1,
                files: ["/DCIM/100MEDIA/a.jpg", "/DCIM/Renamed/a.jpg"]
            )
        )
        XCTAssertEqual(existence.map(\.exists), [false, true])

        let deleted = try await provider.deleteFiles(
            input: DeleteFileInput(storageId: 1, files: ["/DCIM/Renamed"])
        )
        XCTAssertTrue(deleted)
        let remaining = await provider.allEntries()
        XCTAssertEqual(remaining.map(\.path), ["/.hidden", "/DCIM", "/DCIM/New"])
    }

    func testDownloadProgressStreamPreservesSyntheticOrdering() async throws {
        let events: [TransferEvent] = [
            .preprocess(TransferPreprocessData(fullPath: "/DCIM/a.jpg", name: "a.jpg", size: 100)),
            .progress(Self.progress(sent: 25)),
            .progress(Self.progress(sent: 100))
        ]
        let provider = MockMTPProvider(entries: Self.fixtureEntries, transferEvents: events)
        let operation = try await provider.downloadFiles(
            input: DownloadFilesInput(
                storageId: 1,
                sources: ["/DCIM/100MEDIA/a.jpg"],
                destination: "/tmp/download",
                preprocessFiles: true
            )
        )

        var received: [TransferEvent] = []
        for await event in operation.progress {
            received.append(event)
        }

        XCTAssertEqual(received, events)
        let result = try await operation.result.value
        XCTAssertTrue(result)
    }

    func testUploadMutatesTreeAndEmitsConfiguredProgress() async throws {
        let event = TransferEvent.progress(Self.progress(sent: 100))
        let provider = MockMTPProvider(entries: Self.fixtureEntries, transferEvents: [event])
        let operation = try await provider.uploadFiles(
            input: UploadFilesInput(
                storageId: 1,
                sources: ["/tmp/new.txt"],
                destination: "/DCIM",
                preprocessFiles: true
            )
        )
        let values = await operation.progress.reduce(into: [TransferEvent]()) { $0.append($1) }

        XCTAssertEqual(values, [event])
        let result = try await operation.result.value
        XCTAssertTrue(result)
        let existence = try await provider.fileExists(
            input: FileExistsInput(storageId: 1, files: ["/DCIM/new.txt"])
        )
        XCTAssertEqual(existence, [FileExistsData(fullpath: "/DCIM/new.txt", exists: true)])
    }

    /// Like the real provider: cancelling `result` aborts a transfer that
    /// would otherwise wait forever, reports `CancellationError`, and leaves
    /// no partial upload behind.
    func testCancellingAHeldUploadAbortsItAndRemovesThePartialObject() async throws {
        let provider = MockMTPProvider(
            entries: Self.fixtureEntries,
            transferScripts: [MockTransferScript(completionGate: MockTransferGate())]
        )
        let operation = try await provider.uploadFiles(
            input: UploadFilesInput(
                storageId: 1,
                sources: ["/tmp/big.mov"],
                destination: "/DCIM",
                preprocessFiles: false
            )
        )
        var existence = try await provider.fileExists(
            input: FileExistsInput(storageId: 1, files: ["/DCIM/big.mov"])
        )
        XCTAssertEqual(existence.map(\.exists), [true])

        operation.result.cancel()
        do {
            _ = try await operation.result.value
            XCTFail("the upload was cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        existence = try await provider.fileExists(
            input: FileExistsInput(storageId: 1, files: ["/DCIM/big.mov"])
        )
        XCTAssertEqual(existence.map(\.exists), [false])
        let cancelled = await provider.cancelledTransferCount()
        XCTAssertEqual(cancelled, 1)
        // The stream finished with the transfer.
        for await _ in operation.progress {}
    }

    func testScriptedFailuresAreFIFOAndConsumedPerCall() async throws {
        let provider = MockMTPProvider(
            entries: Self.fixtureEntries,
            scriptedFailures: [.walk: [.deviceLocked, .deviceChanged]]
        )

        await assertCallError(.deviceLocked) {
            _ = try await provider.walk(input: self.walkInput(path: "/"))
        }
        await assertCallError(.deviceChanged) {
            _ = try await provider.walk(input: self.walkInput(path: "/"))
        }
        let successful = try await provider.walk(input: walkInput(path: "/"))
        XCTAssertEqual(successful.count, 2)

        await provider.scriptFailure(.fileTransfer, for: .downloadFiles)
        await assertCallError(.fileTransfer) {
            _ = try await provider.downloadFiles(
                input: DownloadFilesInput(
                    storageId: 1,
                    sources: ["/DCIM/100MEDIA/a.jpg"],
                    destination: "/tmp",
                    preprocessFiles: true
                )
            )
        }
    }

    private func walkInput(
        path: String,
        skipHidden: Bool = false
    ) -> DirectoryWalkInput {
        DirectoryWalkInput(
            storageId: 1,
            fullPath: path,
            skipDisallowedFiles: false,
            skipHiddenFiles: skipHidden
        )
    }

    private func assertCallError(
        _ expected: MTPErrorType,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected MTPCallError")
        } catch let error as MTPCallError {
            XCTAssertEqual(error.type, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static let fixtureEntries: [WalkEntry] = [
        entry(path: "/DCIM", folder: true, objectID: 1),
        entry(path: "/DCIM/100MEDIA", folder: true, objectID: 2),
        entry(path: "/DCIM/100MEDIA/a.jpg", folder: false, objectID: 3, size: 100),
        entry(path: "/.hidden", folder: false, objectID: 4)
    ]

    private static func entry(
        path: String,
        folder: Bool,
        objectID: UInt32,
        size: Int64 = 0
    ) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: size,
            isFolder: folder,
            modified: Date(timeIntervalSince1970: 0),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: folder ? "" : url.pathExtension,
            parentId: 0,
            objectId: objectID
        )
    }

    private static func progress(sent: Int64) -> TransferProgressInfo {
        TransferProgressInfo(
            fullPath: "/DCIM/100MEDIA/a.jpg",
            name: "a.jpg",
            elapsedTime: sent,
            speed: 1,
            totalFiles: 1,
            totalDirectories: 0,
            filesSent: sent == 100 ? 1 : 0,
            filesSentProgress: Float(sent),
            activeFileSize: TransferSizeInfo(total: 100, sent: sent, progress: Float(sent)),
            bulkFileSize: TransferSizeInfo(total: 100, sent: sent, progress: Float(sent))
        )
    }
}
