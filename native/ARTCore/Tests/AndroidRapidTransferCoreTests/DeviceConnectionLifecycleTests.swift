import Foundation
import MTPKit
@testable import AndroidRapidTransferCore
import USBWatcher
import XCTest

/// Connection lifecycle: automatic reconnection after the device changed or
/// vanished (audit C16), clean teardown when the session is lost mid-operation
/// (C20), and bounded release on window close and quit (C22).
@MainActor
final class DeviceConnectionLifecycleTests: XCTestCase {
    // MARK: - Reconnect budget

    func testReconnectBudgetIsSpentByFailuresAndNeverReplenishedByThem() async {
        var budget = DeviceReconnectBudget(policy: Self.fastPolicy(attempts: 3))
        let start = ContinuousClock.now
        XCTAssertNotNil(budget.nextDelay(now: start))
        XCTAssertNotNil(budget.nextDelay(now: start))
        XCTAssertNotNil(budget.nextDelay(now: start))
        XCTAssertNil(budget.nextDelay(now: start))
        // Time alone does not refill a budget that never produced a connection,
        // so a device that is really gone stays bounded.
        XCTAssertNil(budget.nextDelay(now: start.advanced(by: .seconds(60))))
    }

    func testReconnectBudgetRefillsOnlyAfterSuccessAndTheWindow() async {
        let policy = DeviceReconnectPolicy(
            delays: [.milliseconds(1), .milliseconds(1)],
            window: .seconds(15)
        )
        var budget = DeviceReconnectBudget(policy: policy)
        let start = ContinuousClock.now
        _ = budget.nextDelay(now: start)
        _ = budget.nextDelay(now: start)
        budget.recordSuccess()
        // A device that connects and drops again at once cannot loop faster
        // than the budget allows within the window.
        XCTAssertNil(budget.nextDelay(now: start.advanced(by: .seconds(5))))
        XCTAssertNotNil(budget.nextDelay(now: start.advanced(by: .seconds(16))))
    }

    /// The connection before a loss is itself a success. Counted against the
    /// sequence that follows, it refilled the budget once the window passed,
    /// so a phone that never came back got twelve attempts over ~31 s instead
    /// of six over ~15 s (seen on a real phone).
    func testSuccessBeforeTheSequenceDoesNotRefillItsBudget() async {
        let policy = DeviceReconnectPolicy(
            delays: [.seconds(5), .seconds(5), .seconds(6)],
            window: .seconds(15)
        )
        var budget = DeviceReconnectBudget(policy: policy)
        budget.recordSuccess()
        let start = ContinuousClock.now
        XCTAssertNotNil(budget.nextDelay(now: start))
        XCTAssertNotNil(budget.nextDelay(now: start.advanced(by: .seconds(5))))
        XCTAssertNotNil(budget.nextDelay(now: start.advanced(by: .seconds(10))))
        XCTAssertNil(budget.nextDelay(now: start.advanced(by: .seconds(16))))
    }

    // MARK: - Automatic reconnection (C16)

    func testDeviceChangedMidSessionReconnectsAutomatically() async throws {
        let factory = LifecycleProviderFactory()
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.deviceChanged, for: .walk)
        let model = try XCTUnwrap(controller.deviceModel)

        await model.load()
        try await eventually { await factory.creationCount() == 2 }
        try await eventually { @MainActor in controller.state.isConnected }
        XCTAssertFalse(controller.isReconnecting)
        XCTAssertNil(controller.connectionNotice)
        XCTAssertFalse(controller.deviceModel === model, "A fresh session replaces the lost one")
    }

    func testVanishingMidOperationReconnectsAutomatically() async throws {
        let factory = LifecycleProviderFactory()
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(
            MTPCallError(message: "LIBUSB_ERROR_NO_DEVICE", type: .listDirectory),
            for: .walk
        )
        await controller.deviceModel?.load()

        try await eventually { await factory.creationCount() == 2 }
        try await eventually { @MainActor in controller.state.isConnected }
    }

    func testSameSerialReconnectReopensWhereTheUserWas() async throws {
        let factory = LifecycleProviderFactory(entries: Self.tree)
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let firstModel = try XCTUnwrap(controller.deviceModel)
        await firstModel.load()
        let dcim = try XCTUnwrap(firstModel.entries.first { $0.name == "DCIM" })
        await firstModel.navigate(to: dcim)
        XCTAssertEqual(firstModel.currentLocation, "/DCIM")

        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.deviceChanged, for: .walk)
        await firstModel.refresh()

        try await eventually { @MainActor in
            controller.state.isConnected && controller.deviceModel !== firstModel
        }
        let reconnected = try XCTUnwrap(controller.deviceModel)
        await reconnected.load()
        XCTAssertEqual(reconnected.currentLocation, "/DCIM")
        XCTAssertEqual(reconnected.selectedStorageID, 1)
    }

    func testDifferentSerialAfterDeviceChangeOpensAtTheRoot() async throws {
        let factory = LifecycleProviderFactory(entries: Self.tree, serials: ["FIRST", "SECOND"])
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let firstModel = try XCTUnwrap(controller.deviceModel)
        await firstModel.load()
        let dcim = try XCTUnwrap(firstModel.entries.first { $0.name == "DCIM" })
        await firstModel.navigate(to: dcim)

        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.deviceChanged, for: .walk)
        await firstModel.refresh()

        try await eventually { @MainActor in
            controller.state.isConnected && controller.deviceModel !== firstModel
        }
        let reconnected = try XCTUnwrap(controller.deviceModel)
        await reconnected.load()
        XCTAssertEqual(reconnected.currentLocation, "/", "A different phone must not inherit the old path")
    }

    func testReconnectIsBoundedAndEndsInNoDeviceWithANotice() async throws {
        // First creation succeeds; every later one finds no device.
        let factory = LifecycleProviderFactory(failAfterFirst: true)
        let controller = Self.makeController(factory: factory, policy: Self.fastPolicy(attempts: 3))
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.deviceChanged, for: .walk)
        await controller.deviceModel?.load()

        try await eventually { @MainActor in
            controller.state == .noDevice && !controller.isReconnecting
        }
        let attempts = await factory.creationCount()
        XCTAssertEqual(attempts, 1 + 3, "The initial connection plus exactly the budget")
        XCTAssertEqual(controller.connectionNotice, DeviceConnectionController.reconnectExhaustedNotice)

        try await Task.sleep(for: .milliseconds(80))
        let attemptsLater = await factory.creationCount()
        XCTAssertEqual(attemptsLater, attempts, "No attempts after the budget is spent")
    }

    func testReconnectPublishesEachAttemptNumberThenResets() async throws {
        let factory = LifecycleProviderFactory(failAfterFirst: true)
        let recorder = AttemptRecorder()
        let controller = DeviceConnectionController(
            providerFactory: {
                // What the controller reports while each connection attempt runs.
                await recorder.record()
                return try await factory.makeProvider()
            },
            events: AsyncStream { _ in },
            attachDebounce: .milliseconds(30),
            reconnectPolicy: Self.fastPolicy(attempts: 3)
        )
        recorder.controller = controller
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        XCTAssertEqual(controller.reconnectAttemptLimit, 3)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.deviceChanged, for: .walk)
        await controller.deviceModel?.load()

        try await eventually { @MainActor in
            controller.state == .noDevice && !controller.isReconnecting
        }
        XCTAssertEqual(recorder.values, [0, 1, 2, 3], "The first connection, then each attempt in order")
        XCTAssertEqual(controller.reconnectAttempt, 0, "The number resets when the sequence ends")
    }

    func testPlainNoDeviceAtStartupDoesNotStartReconnecting() async throws {
        let factory = LifecycleProviderFactory(failAll: true)
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        XCTAssertEqual(controller.state, .noDevice)
        XCTAssertFalse(controller.isReconnecting)
        try await Task.sleep(for: .milliseconds(80))
        let attempts = await factory.creationCount()
        XCTAssertEqual(attempts, 1, "No device found waits for hotplug or Retry")
    }

    func testUnplugDuringReconnectEndsInNoDevicePromptly() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = LifecycleProviderFactory()
        let slowPolicy = DeviceReconnectPolicy(delays: [.seconds(5)], window: .seconds(15))
        let controller = Self.makeController(factory: factory, policy: slowPolicy, events: events.stream)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.deviceChanged, for: .walk)
        await controller.deviceModel?.load()
        try await eventually { @MainActor in controller.isReconnecting }

        events.continuation.yield(Self.event(.detached))
        try await eventually { @MainActor in
            controller.state == .noDevice && !controller.isReconnecting
        }
        XCTAssertNil(controller.connectionNotice, "An unplug is the user's doing, not an error")
        let attempts = await factory.creationCount()
        XCTAssertEqual(attempts, 1)
    }

    func testManualRetryCancelsThePendingReconnect() async throws {
        let factory = LifecycleProviderFactory()
        let slowPolicy = DeviceReconnectPolicy(delays: [.seconds(5)], window: .seconds(15))
        let controller = Self.makeController(factory: factory, policy: slowPolicy)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.deviceChanged, for: .walk)
        await controller.deviceModel?.load()
        try await eventually { @MainActor in controller.isReconnecting }

        await controller.retry()
        XCTAssertTrue(controller.state.isConnected)
        XCTAssertFalse(controller.isReconnecting)
        let attempts = await factory.creationCount()
        XCTAssertEqual(attempts, 2, "Only the manual attempt ran")
    }

    // MARK: - Mid-operation loss (C20)

    func testLossWithoutReconnectTriggerShowsANoticeAndClearsTheSession() async throws {
        let factory = LifecycleProviderFactory()
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        await first.scriptFailure(.mtpDetectFailed, for: .walk)
        await controller.deviceModel?.load()

        try await eventually { @MainActor in controller.state == .noDevice }
        XCTAssertNil(controller.deviceModel)
        XCTAssertNil(controller.transferQueue)
        XCTAssertNil(controller.transferSessionID)
        XCTAssertFalse(controller.isReconnecting)
        XCTAssertEqual(controller.connectionNotice, DeviceConnectionController.connectionLostNotice)
        controller.dismissConnectionNotice()
        XCTAssertNil(controller.connectionNotice)
    }

    func testMidOperationLossAbortsQueuedTransfers() async throws {
        let factory = LifecycleProviderFactory()
        let controller = Self.makeController(factory: factory, policy: .disabled)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        let gate = MockTransferGate()
        await first.setTransferScripts([MockTransferScript(completionGate: gate)])
        let queue = try XCTUnwrap(controller.transferQueue)
        let activeID = await queue.enqueue(Self.uploadRequest)
        let queuedID = await queue.enqueue(Self.uploadRequest)
        try await eventually { await queue.snapshot.activeJobId == activeID }

        await first.scriptFailure(
            MTPCallError(message: "LIBUSB_ERROR_NO_DEVICE", type: .listDirectory),
            for: .walk
        )
        await controller.deviceModel?.load()
        try await eventually { @MainActor in controller.state == .noDevice }
        try await eventually {
            guard case .failed(errorType: .deviceLost, _) = await Self.state(of: queuedID, in: queue)
            else { return false }
            return true
        }
        await gate.open()
    }

    func testAttachingANewSessionReleasesTheOldSessionsBusyLock() async throws {
        let root = try Self.makeLocalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalBrowserViewModel(rootURL: root, startURL: root)
        let model = TransferViewModel(localModel: local)

        let oldProvider = MockMTPProvider()
        let gate = MockTransferGate()
        await oldProvider.setTransferScripts([MockTransferScript(completionGate: gate)])
        let oldQueue = TransferQueue(provider: oldProvider, sessionID: UUID())
        model.attach(queue: oldQueue, deviceModel: DeviceBrowserViewModel(provider: oldProvider))
        let jobID = await oldQueue.enqueue(Self.uploadRequest)
        try await eventually { @MainActor in model.isDeviceNavigationDisabled }
        XCTAssertTrue(model.hasActiveTransfers)

        // The reconnected session arrives without the view ever seeing nil.
        let newProvider = MockMTPProvider()
        let newQueue = TransferQueue(provider: newProvider, sessionID: UUID())
        model.attach(queue: newQueue, deviceModel: DeviceBrowserViewModel(provider: newProvider))

        XCTAssertFalse(model.isDeviceNavigationDisabled, "The lost session's lock must not survive")
        XCTAssertFalse(model.hasActiveTransfers)
        let settled = try XCTUnwrap(model.rows.first { $0.id == jobID }?.state)
        guard case .failed = settled
        else { return XCTFail("The lost session's job should be settled as failed, not left active") }
        await gate.open()
    }

    // MARK: - Window close (C22)

    func testClosingTheLastPaneReleasesAnIdleSession() async throws {
        let factory = LifecycleProviderFactory()
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.paneAppeared(hotplugEnabled: false)
        await controller.paneAppeared(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))

        controller.paneDisappeared(hasActiveTransfers: false)
        XCTAssertTrue(controller.state.isConnected, "Another window still shows the device")

        controller.paneDisappeared(hasActiveTransfers: false)
        XCTAssertEqual(controller.state, .noDevice)
        try await eventually { await first.callHistory().contains(.dispose) }

        await controller.paneAppeared(hotplugEnabled: false)
        XCTAssertTrue(controller.state.isConnected, "Reopening a window reconnects")
    }

    func testClosingTheLastPaneKeepsASessionWithActiveTransfers() async throws {
        let factory = LifecycleProviderFactory()
        let controller = Self.makeController(factory: factory)
        defer { controller.stop() }

        await controller.paneAppeared(hotplugEnabled: false)
        controller.paneDisappeared(hasActiveTransfers: true)
        XCTAssertTrue(controller.state.isConnected)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        let calls = await first.callHistory()
        XCTAssertFalse(calls.contains(.dispose))
    }

    // MARK: - Quit (C22)

    func testShutdownStopsTransfersBeforeReleasingTheDevice() async {
        let log = CallLog()
        let outcome = await DeviceSessionShutdown.run(
            timeout: .seconds(2),
            stopTransfers: { log.calls.append("stopTransfers") },
            releaseDevice: { log.calls.append("releaseDevice") }
        )
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(log.calls, ["stopTransfers", "releaseDevice"])
    }

    func testShutdownNeverHangsQuitOnADeviceThatStoppedAnswering() async {
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await DeviceSessionShutdown.run(
            timeout: .milliseconds(100),
            stopTransfers: {},
            releaseDevice: { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
        )
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testShutdownAbortsTheActiveTransferThenDisposesAfterItDrains() async throws {
        let factory = LifecycleProviderFactory()
        let controller = Self.makeController(factory: factory)
        await controller.start(hotplugEnabled: false)
        let first = try await XCTUnwrapAsync(await factory.provider(at: 0))
        let gate = MockTransferGate()
        await first.setTransferScripts([MockTransferScript(completionGate: gate)])
        let queue = try XCTUnwrap(controller.transferQueue)
        let activeID = await queue.enqueue(Self.uploadRequest)
        try await eventually { await queue.snapshot.activeJobId == activeID }

        // The active job would never finish on its own (its gate stays shut).
        // Quit aborts it through the controller's provider wrapper, so the
        // queue drains and the device is released inside the bound, and only
        // after the native transfer has ended.
        let outcome = await DeviceSessionShutdown.run(
            timeout: .seconds(2),
            stopTransfers: { await queue.cancelAll() },
            releaseDevice: { _ = await controller.releaseDevice() }
        )
        XCTAssertEqual(outcome, .completed)
        let job = await queue.snapshot.jobs.first { $0.id == activeID }
        XCTAssertEqual(job?.cancelRequested, true)
        XCTAssertEqual(job?.state, .cancelled)
        let aborted = await first.cancelledTransferCount()
        XCTAssertEqual(aborted, 1, "the native transfer was aborted, not awaited")
        let calls = await first.callHistory()
        XCTAssertEqual(calls.last, .dispose, "released once the aborted transfer drained")
    }

    // MARK: - Helpers

    private static func fastPolicy(attempts: Int) -> DeviceReconnectPolicy {
        DeviceReconnectPolicy(
            delays: Array(repeating: .milliseconds(5), count: attempts),
            window: .seconds(15)
        )
    }

    private static func makeController(
        factory: LifecycleProviderFactory,
        policy: DeviceReconnectPolicy = fastPolicy(attempts: 6),
        events: AsyncStream<USBDeviceEvent> = AsyncStream { _ in }
    ) -> DeviceConnectionController {
        DeviceConnectionController(
            providerFactory: { try await factory.makeProvider() },
            events: events,
            attachDebounce: .milliseconds(30),
            reconnectPolicy: policy
        )
    }

    private static let tree: [WalkEntry] = [
        entry("/DCIM", isFolder: true, objectID: 10),
        entry("/DCIM/Camera", isFolder: true, objectID: 11),
        entry("/Download", isFolder: true, objectID: 12),
    ]

    private static func entry(_ path: String, isFolder: Bool, objectID: UInt32) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: 0,
            isFolder: isFolder,
            modified: wallClockDate("2026-09-27T00:00:00.000Z"),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: "",
            parentId: 0,
            objectId: objectID
        )
    }

    private static func event(_ kind: USBDeviceEvent.Kind) -> USBDeviceEvent {
        USBDeviceEvent(
            kind: kind,
            vendorId: 0x18D1,
            productId: 0x4EE1,
            serialNumber: "TEST",
            productName: "Pixel",
            isLikelyMTPDevice: true,
            locationId: 0x1000
        )
    }

    private static let uploadRequest = TransferRequest(
        direction: .upload,
        sources: ["/tmp/upload.txt"],
        destination: "/",
        storageId: 1
    )

    private static func state(of id: UUID, in queue: TransferQueue) async -> TransferJobState? {
        await queue.snapshot.jobs.first(where: { $0.id == id })?.state
    }

    private static func makeLocalRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met before timeout")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

@MainActor
private final class CallLog {
    var calls: [String] = []
}

/// Makes mock providers with a scripted serial per connection, and optionally
/// no device at all after the first connection or from the start.
@MainActor
private final class AttemptRecorder {
    weak var controller: DeviceConnectionController?
    private(set) var values: [Int] = []

    func record() {
        values.append(controller?.reconnectAttempt ?? -1)
    }
}

private actor LifecycleProviderFactory {
    private let entries: [WalkEntry]
    private let serials: [String]
    private let failAfterFirst: Bool
    private let failAll: Bool
    private var providers: [MockMTPProvider] = []
    private var attempts = 0

    init(
        entries: [WalkEntry] = [],
        serials: [String] = ["TEST"],
        failAfterFirst: Bool = false,
        failAll: Bool = false
    ) {
        self.entries = entries
        self.serials = serials
        self.failAfterFirst = failAfterFirst
        self.failAll = failAll
    }

    func makeProvider() throws -> MockMTPProvider {
        attempts += 1
        if failAll || (failAfterFirst && attempts > 1) {
            throw MTPCallError(message: "no MTP devices found", type: .mtpDetectFailed)
        }
        let serial = serials[min(providers.count, serials.count - 1)]
        let provider = MockMTPProvider(
            deviceInfo: DeviceInfo(model: "Test Pixel", usb: USBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE1, serialNumber: serial)),
            storages: [
                StorageInfo(id: 1, storageDescription: "Internal storage"),
            ],
            entries: entries
        )
        providers.append(provider)
        return provider
    }

    func creationCount() -> Int {
        attempts
    }

    func provider(at index: Int) -> MockMTPProvider? {
        providers.indices.contains(index) ? providers[index] : nil
    }
}

private extension DeviceConnectionController.State {
    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }
}
