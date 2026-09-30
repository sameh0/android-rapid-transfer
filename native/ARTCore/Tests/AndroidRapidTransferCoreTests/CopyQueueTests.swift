import Foundation
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class CopyQueueTests: XCTestCase {
    func testAddDeduplicatesPathsAndPreservesInsertionOrder() async {
        let queue = CopyQueue()
        let first = item(path: "/DCIM/first.jpg", size: 10)
        let second = item(path: "/Music/second.mp3", size: 20)

        queue.add([first, second, first])

        XCTAssertEqual(queue.items, [first, second])
        XCTAssertEqual(queue.count, 2)
    }

    func testAncestorDirectoryReplacesDescendantsAtEarliestPosition() async {
        let queue = CopyQueue()
        let firstPhoto = item(path: "/DCIM/Camera/first.jpg")
        let music = item(path: "/Music/song.mp3")
        let secondPhoto = item(path: "/DCIM/Camera/second.jpg")
        let camera = item(path: "/DCIM/Camera", isDirectory: true)

        queue.add([firstPhoto, music, secondPhoto])
        queue.add([camera])
        queue.add([item(path: "/DCIM/Camera/later.jpg")])

        XCTAssertEqual(queue.items, [camera, music])
    }

    func testCountAndTotalBytesUpdateAfterAddAndRemove() async {
        let queue = CopyQueue()
        let first = item(path: "/one.bin", size: 10)
        let unknown = item(path: "/folder", isDirectory: true)
        let second = item(path: "/two.bin", size: 30)

        queue.add([first, unknown, second])
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.totalBytes, 40)
        XCTAssertTrue(queue.hasUnknownSizes)

        queue.remove(id: first.id)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.totalBytes, 30)
        XCTAssertTrue(queue.hasUnknownSizes)
    }

    func testUnknownSizeStateClearsWhenUnknownItemsAreRemoved() async {
        let queue = CopyQueue()
        let known = item(path: "/known.bin", size: 10)
        let unknown = item(path: "/folder", isDirectory: true)

        queue.add([known, unknown])
        XCTAssertTrue(queue.hasUnknownSizes)

        queue.remove(id: unknown.id)
        XCTAssertFalse(queue.hasUnknownSizes)
    }

    func testSessionOrStorageChangeInvalidatesQueue() async {
        let queue = CopyQueue()
        let firstSession = UUID()
        let secondSession = UUID()

        queue.bind(sessionID: firstSession, storageID: 1)
        queue.add([item(path: "/first.jpg")])
        queue.bind(sessionID: firstSession, storageID: 1)
        XCTAssertEqual(queue.count, 1)

        queue.bind(sessionID: secondSession, storageID: 1)
        XCTAssertTrue(queue.isEmpty)

        queue.add([item(path: "/second.jpg")])
        queue.bind(sessionID: secondSession, storageID: 2)
        XCTAssertTrue(queue.isEmpty)
    }

    func testRequestConstructionPreservesStorageRootRelativePaths() async {
        let items = [
            item(path: "/DCIM/Camera/IMG_1.jpg", size: 10, objectId: 101),
            item(path: "/Music/song.mp3", size: 20),
            item(path: "/root.txt", size: 30),
            item(path: "/Pictures/Trips", isDirectory: true, objectId: 202)
        ]

        let requests = copyQueueTransferRequests(
            items: items,
            destination: URL(fileURLWithPath: "/Users/test/Batch")
        )

        XCTAssertEqual(requests.map(\.sources), [
            ["/DCIM/Camera/IMG_1.jpg"],
            ["/Music/song.mp3"],
            ["/root.txt"],
            ["/Pictures/Trips"]
        ])
        XCTAssertEqual(requests.map(\.destination), [
            "/Users/test/Batch/DCIM/Camera",
            "/Users/test/Batch/Music",
            "/Users/test/Batch",
            "/Users/test/Batch/Pictures"
        ])
        XCTAssertEqual(requests.map(\.storageId), [1, 1, 1, 1])
        XCTAssertEqual(requests[3].directorySources, ["/Pictures/Trips"])
        XCTAssertEqual(requests[0].sourceObjectIds, ["/DCIM/Camera/IMG_1.jpg": 101])
        XCTAssertTrue(requests[1].sourceObjectIds.isEmpty)
        XCTAssertEqual(requests[3].sourceObjectIds, ["/Pictures/Trips": 202])
    }

    func testRequestConstructionGroupsFilesByDestinationAndKeepsDirectoriesSeparate() async {
        let items = [
            item(path: "/DCIM/Camera/IMG_1.jpg", size: 10),
            item(path: "/Pictures/Trips", isDirectory: true),
            item(path: "/DCIM/Camera/IMG_2.jpg", size: 20),
            item(path: "/Music/song.mp3", size: 30)
        ]

        let requests = copyQueueTransferRequests(
            items: items,
            destination: URL(fileURLWithPath: "/Users/test/Batch")
        )

        XCTAssertEqual(requests.map(\.sources), [
            ["/DCIM/Camera/IMG_1.jpg", "/DCIM/Camera/IMG_2.jpg"],
            ["/Pictures/Trips"],
            ["/Music/song.mp3"]
        ])
        XCTAssertEqual(requests.map(\.destination), [
            "/Users/test/Batch/DCIM/Camera",
            "/Users/test/Batch/Pictures",
            "/Users/test/Batch/Music"
        ])
        XCTAssertTrue(requests[0].directorySources.isEmpty)
        XCTAssertEqual(requests[1].directorySources, ["/Pictures/Trips"])
        XCTAssertTrue(requests[2].directorySources.isEmpty)
    }

    func testReplaceSwapsQueueContentsWhileAddAppendsAndDeduplicates() async {
        let queue = CopyQueue()
        let first = item(path: "/DCIM/first.jpg")
        let second = item(path: "/DCIM/second.jpg")
        let third = item(path: "/DCIM/third.jpg")

        queue.add([first, second])
        queue.replace(with: [third])
        XCTAssertEqual(queue.items, [third])

        queue.add([first, third])
        XCTAssertEqual(queue.items, [third, first])
    }

    func testSourceFollowsItemsAndOtherPaneStartsANewQueue() async {
        let queue = CopyQueue()
        XCTAssertNil(queue.source)

        let device = item(path: "/DCIM/photo.jpg")
        queue.add([device])
        XCTAssertEqual(queue.source, .device)

        let local = localItem(path: "/Users/test/notes.txt")
        queue.add([local])
        XCTAssertEqual(queue.items, [local])
        XCTAssertEqual(queue.source, .local)

        queue.add([device])
        XCTAssertEqual(queue.items, [device])
        XCTAssertEqual(queue.source, .device)
    }

    func testDeviceSessionChangeKeepsLocalItemsButDropsDeviceItems() async {
        let queue = CopyQueue()
        queue.bind(sessionID: UUID(), storageID: 1)
        let local = localItem(path: "/Users/test/notes.txt")
        queue.add([local])

        queue.bind(sessionID: UUID(), storageID: 2)
        XCTAssertEqual(queue.items, [local])

        queue.add([item(path: "/DCIM/photo.jpg")])
        queue.bind(sessionID: nil, storageID: nil)
        XCTAssertTrue(queue.isEmpty)
    }

    func testLocalDirectoryOwnsItsSubtree() async {
        let queue = CopyQueue()
        let photo = localItem(path: "/Users/test/Trip/a.jpg")
        let trip = localItem(path: "/Users/test/Trip", isDirectory: true)

        queue.add([photo])
        queue.add([trip])
        queue.add([localItem(path: "/Users/test/Trip/b.jpg")])

        XCTAssertEqual(queue.items, [trip])
    }

    func testBatchRequestsIgnoreLocalItems() async {
        XCTAssertTrue(
            copyQueueTransferRequests(
                items: [localItem(path: "/Users/test/notes.txt")],
                destination: URL(fileURLWithPath: "/Users/test/Batch")
            ).isEmpty
        )
    }

    func testEmptyQueueProducesNoRequests() async {
        XCTAssertTrue(
            copyQueueTransferRequests(
                items: [],
                destination: URL(fileURLWithPath: "/Users/test/Batch")
            ).isEmpty
        )
    }

    private func item(
        path: String,
        size: Int64? = nil,
        isDirectory: Bool = false,
        objectId: UInt32? = nil
    ) -> CopyQueueItem {
        CopyQueueItem(
            absoluteDevicePath: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            size: size,
            isDirectory: isDirectory,
            storage: DeviceStorage(id: 1, name: "Internal Storage"),
            objectId: objectId
        )
    }

    private func localItem(path: String, isDirectory: Bool = false) -> CopyQueueItem {
        CopyQueueItem(
            localEntry: BrowserEntry(
                id: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                size: isDirectory ? nil : 1,
                modified: nil,
                isDirectory: isDirectory,
                location: path
            )
        )
    }
}
