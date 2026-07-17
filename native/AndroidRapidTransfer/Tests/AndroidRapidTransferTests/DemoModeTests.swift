#if DEBUG
@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import MTPKit
import XCTest

@MainActor
final class DemoModeTests: XCTestCase {
    func testDemoIsRequestedOnlyByItsFlag() {
        XCTAssertTrue(DemoMode.isRequested(["app", "--demo"]))
        XCTAssertFalse(DemoMode.isRequested(["app", "--mock"]))
        XCTAssertFalse(DemoMode.isRequested(["app"]))
    }

    func testTheAccountsOwnHomeIsNeverWritable() {
        XCTAssertNil(DemoMode.throwawayHome(environment: ["HOME": "/Users/someone"], accountHome: "/Users/someone"))
        XCTAssertNil(DemoMode.throwawayHome(environment: ["HOME": "/Users/someone/"], accountHome: "/Users/someone"))
        XCTAssertNil(DemoMode.throwawayHome(environment: [:], accountHome: "/Users/someone"))
        XCTAssertEqual(
            DemoMode.throwawayHome(environment: ["HOME": "/tmp/demo-home"], accountHome: "/Users/someone")?.path,
            "/tmp/demo-home"
        )
    }

    func testTransferPlanMovesEveryByteAtAboutTheGivenSpeed() throws {
        let files = [
            DemoTransferFile(path: "/a.jpg", name: "a.jpg", size: 5_000_000, isFolder: false),
            DemoTransferFile(path: "/b.mp4", name: "b.mp4", size: 80_000_000, isFolder: false),
            DemoTransferFile(path: "/c.jpg", name: "c.jpg", size: 3_000_000, isFolder: false)
        ]
        let plan = DemoTransferPlan(files: files, speed: 40, tick: .milliseconds(100))
        let last = try XCTUnwrap(plan.events.last)

        XCTAssertEqual(last.bulkFileSize.sent, 88_000_000)
        XCTAssertEqual(last.bulkFileSize.total, 88_000_000)
        XCTAssertEqual(last.filesSent, 3)
        XCTAssertEqual(last.totalFiles, 3)
        XCTAssertEqual(last.filesSentProgress, 100)
        // 88 MB at ~40 MB/s is ~2.2 s, one event per 100 ms (plus a final
        // partial tick per file).
        XCTAssertEqual(Double(last.elapsedTime) / 1_000, 2.2, accuracy: 0.4)
        XCTAssertTrue(plan.events.allSatisfy { (36 ... 44).contains($0.speed) })
        let sent = plan.events.map(\.bulkFileSize.sent)
        XCTAssertEqual(sent, sent.sorted(), "Progress never goes backwards")
    }

    func testThePhoneConnectsOnlyOncePluggedIn() async throws {
        let session = DemoDeviceSession(connectDelay: .zero, writableRoot: nil)
        do {
            _ = try await session.providerFactory()
            XCTFail("An unplugged demo phone must not connect")
        } catch let error as MTPCallError {
            XCTAssertEqual(error.type, .mtpDetectFailed)
        }

        var events = session.events.makeAsyncIterator()
        session.plugIn()
        let event = await events.next()
        XCTAssertEqual(event?.kind, .attached)
        let provider = try await session.providerFactory()
        let info = try await provider.deviceInfo()
        XCTAssertEqual(info.model, "Pixel 8 Pro")
    }

    func testTheControllerGoesFromNoPhoneToConnectedOnPlugIn() async throws {
        let session = DemoDeviceSession(connectDelay: .milliseconds(50), writableRoot: nil)
        let controller = DeviceConnectionController(
            providerFactory: session.providerFactory,
            events: session.events,
            attachDebounce: .milliseconds(10)
        )
        await controller.start()
        XCTAssertEqual(controller.state, .noDevice)

        session.plugIn()
        for _ in 0 ..< 200 {
            if case .connected = controller.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case let .connected(info, storages) = controller.state else {
            return XCTFail("Expected a connection, got \(controller.state)")
        }
        XCTAssertEqual(info.model, "Pixel 8 Pro")
        XCTAssertEqual(storages.count, 2)
        _ = await controller.releaseDevice()
    }

    func testUploadsAppearOnThePhoneWithTheirSizeAndDate() async throws {
        let folder = try makeTemporaryFolder()
        let source = folder.appending(path: "Tram 28.jpg")
        try Data(count: 4_096).write(to: source)
        let provider = DemoMTPProvider(writableRoot: nil, tick: .milliseconds(1))

        let operation = try await provider.uploadFiles(input: UploadFilesInput(
            storageId: 65537,
            sources: [source.path],
            destination: "/DCIM/Camera",
            preprocessFiles: false
        ))
        let succeeded = try await operation.result.value
        XCTAssertTrue(succeeded)

        let listing = try await provider.walk(input: DirectoryWalkInput(
            storageId: 65537,
            fullPath: "/DCIM/Camera",
            skipDisallowedFiles: false,
            skipHiddenFiles: true
        ))
        let uploaded = try XCTUnwrap(listing.first { $0.name == "Tram 28.jpg" })
        XCTAssertEqual(uploaded.size, 4_096)
        XCTAssertGreaterThan(try XCTUnwrap(uploaded.modified), Date(timeIntervalSinceNow: -60))
    }

    func testDownloadsLeavePlaceholdersOnlyInsideTheThrowawayHome() async throws {
        let home = try makeTemporaryFolder()
        let inside = home.appending(path: "Pictures")
        let outside = try makeTemporaryFolder()
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let provider = DemoMTPProvider(writableRoot: home, tick: .milliseconds(1))
        let source = "/Download/boarding-pass.pdf"

        for destination in [inside, outside] {
            let operation = try await provider.downloadFiles(input: DownloadFilesInput(
                storageId: 65537,
                sources: [source],
                destination: destination.path,
                preprocessFiles: true
            ))
            _ = try await operation.result.value
        }

        let placeholder = inside.appending(path: "boarding-pass.pdf")
        let size = try FileManager.default.attributesOfItem(atPath: placeholder.path)[.size] as? Int
        XCTAssertEqual(size, 284_119)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appending(path: "boarding-pass.pdf").path))
    }

    private func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DemoModeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }
}
#endif
