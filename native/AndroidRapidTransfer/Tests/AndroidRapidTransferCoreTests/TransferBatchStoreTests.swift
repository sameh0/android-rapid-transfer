import Foundation
import XCTest
@testable import AndroidRapidTransferCore

final class TransferBatchStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ART-BatchStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveAndLoadRoundTripsBatchRecord() async throws {
        let store = TransferBatchStore(directoryURL: directory)
        let batch = Self.batch(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            items: [
                Self.item(path: "/DCIM/a.jpg", status: .pending),
                Self.item(path: "/DCIM/b.jpg", size: nil, status: .completed),
                Self.item(
                    path: "/DCIM/folder",
                    isDirectory: true,
                    status: .failed(message: "The device went away")
                )
            ]
        )

        await store.save(batch)
        let loaded = await store.loadAll()

        XCTAssertEqual(loaded, [batch])
        XCTAssertEqual(loaded.first?.pendingCount, 1)
        XCTAssertEqual(loaded.first?.completedCount, 1)
        XCTAssertEqual(loaded.first?.failedCount, 1)
        XCTAssertEqual(
            loaded.first?.resumableItems.map(\.devicePath),
            ["/DCIM/a.jpg", "/DCIM/folder"]
        )
        let storedFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first
        )
        let storedJSON = try String(contentsOf: storedFile, encoding: .utf8)
        XCTAssertFalse(storedJSON.contains("objectId"))
    }

    func testUpdateItemStatusesRewritesBatchFile() async throws {
        let store = TransferBatchStore(directoryURL: directory)
        let batch = Self.batch(items: [
            Self.item(path: "/DCIM/a.jpg", status: .pending),
            Self.item(path: "/DCIM/b.jpg", status: .pending)
        ])
        await store.save(batch)

        await store.updateItemStatuses(
            batchID: batch.id,
            statusesByDevicePath: [
                "/DCIM/a.jpg": .completed,
                "/DCIM/b.jpg": .failed(message: "Transfer failed"),
                "/DCIM/unknown.jpg": .completed
            ]
        )

        let reloadedRecord = await store.load(id: batch.id)
        let reloaded = try XCTUnwrap(reloadedRecord)
        XCTAssertEqual(
            reloaded.items.map(\.status),
            [.completed, .failed(message: "Transfer failed")]
        )
        // The rewrite reached disk: a fresh store instance sees the update.
        let freshStore = TransferBatchStore(directoryURL: directory)
        let freshCopy = await freshStore.load(id: batch.id)
        XCTAssertEqual(freshCopy, reloaded)
    }

    func testPruningKeepsOnlyTheMostRecentBatches() async throws {
        let store = TransferBatchStore(directoryURL: directory, maxStoredBatches: 3)
        for index in 0..<5 {
            await store.save(
                Self.batch(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    items: [Self.item(path: "/DCIM/\(index).jpg", status: .pending)]
                )
            )
        }

        let loaded = await store.loadAll()

        XCTAssertEqual(loaded.count, 3)
        // Newest first, and exactly the newest three survived the prune.
        XCTAssertEqual(
            loaded.map(\.createdAt.timeIntervalSince1970),
            [1_700_000_004, 1_700_000_003, 1_700_000_002]
        )
    }

    func testCorruptedFileIsSkippedNotFatal() async throws {
        let store = TransferBatchStore(directoryURL: directory)
        let batch = Self.batch(items: [Self.item(path: "/DCIM/a.jpg", status: .pending)])
        await store.save(batch)
        try Data("this is not JSON".utf8).write(
            to: directory.appending(path: "\(UUID().uuidString).json")
        )

        let loaded = await store.loadAll()

        XCTAssertEqual(loaded, [batch])
    }

    func testDeleteAndClearCompletedRemoveTheRightBatches() async throws {
        let store = TransferBatchStore(directoryURL: directory)
        let fullyCompleted = Self.batch(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            items: [Self.item(path: "/DCIM/a.jpg", status: .completed)]
        )
        let partiallyFailed = Self.batch(
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            items: [
                Self.item(path: "/DCIM/b.jpg", status: .completed),
                Self.item(path: "/DCIM/c.jpg", status: .failed(message: "Transfer failed"))
            ]
        )
        let pending = Self.batch(
            createdAt: Date(timeIntervalSince1970: 1_700_000_002),
            items: [Self.item(path: "/DCIM/d.jpg", status: .pending)]
        )
        await store.save(fullyCompleted)
        await store.save(partiallyFailed)
        await store.save(pending)

        await store.deleteFullyCompleted()
        let afterClear = await store.loadAll()
        XCTAssertEqual(afterClear.map(\.id), [pending.id, partiallyFailed.id])

        await store.delete(batchID: pending.id)
        // Deleting an already-deleted batch is a no-op, not an error.
        await store.delete(batchID: pending.id)
        let afterDelete = await store.loadAll()
        XCTAssertEqual(afterDelete.map(\.id), [partiallyFailed.id])
    }

    private static func batch(
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        items: [TransferBatchRecord.Item]
    ) -> TransferBatchRecord {
        TransferBatchRecord(
            createdAt: createdAt,
            origin: .copyQueue,
            destinationRoot: "/Users/test/Downloads",
            storageID: 7,
            deviceLabel: "Test Pixel",
            items: items
        )
    }

    private static func item(
        path: String,
        size: Int64? = 1_000,
        isDirectory: Bool = false,
        status: TransferBatchRecord.Item.Status
    ) -> TransferBatchRecord.Item {
        TransferBatchRecord.Item(
            devicePath: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            size: size,
            isDirectory: isDirectory,
            destinationDirectory: "/Users/test/Downloads",
            status: status
        )
    }
}
