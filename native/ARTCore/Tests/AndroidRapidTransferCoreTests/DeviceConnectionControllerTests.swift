import Foundation
import MTPKit
import USBWatcher
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class DeviceConnectionControllerTests: XCTestCase {
    func testAttachConnectsAfterInitialNoDeviceResult() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(firstFailure: .mtpDetectFailed)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        XCTAssertEqual(controller.state, .noDevice)

        events.continuation.yield(Self.event(.attached))
        try await eventually { controller.state.isConnected }

        guard case let .connected(deviceInfo, storages) = controller.state else {
            return XCTFail("Expected a connected state")
        }
        XCTAssertEqual(deviceInfo.model, "Test Pixel")
        XCTAssertEqual(storages.count, 1)
    }

    func testDetachDisconnectsConnectedProvider() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        XCTAssertTrue(controller.state.isConnected)

        events.continuation.yield(Self.event(.detached))
        try await eventually { controller.state == .noDevice }
        XCTAssertNil(controller.deviceModel)
    }

    func testUnknownIdentityDetachDisconnectsConnectedProvider() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        XCTAssertTrue(controller.state.isConnected)

        events.continuation.yield(Self.unknownDeviceEvent(.detached))

        try await eventually { controller.state == .noDevice }
        XCTAssertNil(controller.deviceModel)
    }

    func testNonDeviceDetectionErrorSurfacesAsRetryable() async {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(firstFailure: .deviceLocked)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()

        guard case let .error(message, retryable) = controller.state else {
            return XCTFail("Expected an error state")
        }
        XCTAssertTrue(message.contains("ErrorDeviceLocked"))
        XCTAssertTrue(retryable)
    }

    func testDeviceSetupFailureRequiresReplugWithKnownDeviceName() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(firstFailure: .deviceSetup)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }
        events.continuation.yield(Self.event(.attached))

        await controller.start()

        try await eventually {
            controller.state == .needsReplug(deviceName: "Pixel", message: nil)
        }
        XCTAssertNil(controller.deviceModel)
    }

    func testDeviceSetupFailureDuringBrowsingRequiresReplug() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }
        events.continuation.yield(Self.event(.attached))
        await controller.start()

        let latestProvider = await factory.currentProvider()
        let provider = try XCTUnwrap(latestProvider)
        await provider.scriptFailure(.deviceSetup, for: .walk)
        let model = try XCTUnwrap(controller.deviceModel)

        await model.load()
        try await eventually {
            controller.state == .needsReplug(deviceName: "Test Pixel", message: nil)
        }
        XCTAssertNil(controller.deviceModel)
    }

    func testSameDeviceReattachOnDifferentPortRetriesFullConnection() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        events.continuation.yield(Self.event(.attached))
        try await Task.sleep(for: .milliseconds(20))
        let latestProvider = await factory.currentProvider()
        let provider = try XCTUnwrap(latestProvider)
        await provider.scriptFailure(.deviceSetup, for: .walk)
        let model = try XCTUnwrap(controller.deviceModel)
        await model.load()
        try await eventually {
            controller.state == .needsReplug(deviceName: "Test Pixel", message: nil)
        }

        events.continuation.yield(Self.otherDeviceEvent(.detached))
        events.continuation.yield(Self.otherDeviceEvent(.attached))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.state, .needsReplug(deviceName: "Test Pixel", message: nil))
        let attemptsBeforeMatchingReplug = await factory.currentCreationCount()
        XCTAssertEqual(attemptsBeforeMatchingReplug, 1)

        events.continuation.yield(Self.event(.detached))
        events.continuation.yield(Self.event(.attached, locationID: 0x2000))
        try await eventually { controller.state.isConnected }
        let attemptsAfterMatchingReplug = await factory.currentCreationCount()
        XCTAssertEqual(attemptsAfterMatchingReplug, 2)
    }

    func testNilReplugTargetAdoptsFirstAttach() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(firstFailure: .deviceSetup)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        XCTAssertEqual(controller.state, .needsReplug(deviceName: nil, message: nil))
        XCTAssertTrue(controller.canManuallyRetryReplug)

        events.continuation.yield(Self.event(.attached))
        try await eventually {
            controller.state == .needsReplug(deviceName: "Pixel", message: nil)
        }
        events.continuation.yield(Self.event(.detached))
        events.continuation.yield(Self.event(.attached))

        try await eventually { controller.state.isConnected }
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 2)
    }

    func testAttachDuringFailedAttemptSchedulesFreshConnection() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let firstFactoryGate = MockTransferGate()
        let factory = ProviderFactoryRecorder(
            firstFailure: .mtpDetectFailed,
            firstFactoryGate: firstFactoryGate
        )
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        let startTask = Task { await controller.start() }
        try await eventually { controller.state == .detecting }

        events.continuation.yield(Self.event(.attached))
        try await Task.sleep(for: .milliseconds(20))
        await firstFactoryGate.open()
        await startTask.value

        try await eventually { controller.state.isConnected }
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 2)
    }

    func testAttachDuringGenerationAbortedAttemptSchedulesFreshConnection() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let firstFactoryGate = MockTransferGate()
        let factory = ProviderFactoryRecorder(firstFactoryGate: firstFactoryGate)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        let startTask = Task { await controller.start() }
        try await eventually { controller.state == .detecting }

        events.continuation.yield(Self.event(.detached))
        try await eventually { controller.state == .noDevice }
        events.continuation.yield(Self.event(.attached, locationID: 0x2000))
        try await Task.sleep(for: .milliseconds(20))
        await firstFactoryGate.open()
        await startTask.value

        try await eventually { controller.state.isConnected }
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 2)
    }

    func testAttachStormIsCoalescedIntoOneConnectionAttempt() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(firstFailure: .mtpDetectFailed)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        events.continuation.yield(Self.event(.attached))
        events.continuation.yield(Self.event(.attached))
        events.continuation.yield(Self.event(.attached))

        try await eventually { controller.state.isConnected }
        try await Task.sleep(for: .milliseconds(80))
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 2)
    }

    func testDeviceChangedDuringBrowsingInvalidatesSession() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        let latestProvider = await factory.currentProvider()
        let provider = try XCTUnwrap(latestProvider)
        await provider.scriptFailure(.deviceChanged, for: .walk)
        let model = try XCTUnwrap(controller.deviceModel)

        await model.load()
        try await eventually { controller.state == .noDevice }
        XCTAssertNil(controller.deviceModel)
    }

    /// When the phone vanishes mid-listing, the kernel closes its handle and
    /// reports the disconnect inside the listing error. The controller must drop
    /// the session rather than keep browsing a device that is gone.
    func testDeviceVanishingDuringBrowsingInvalidatesSession() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        let latestProvider = await factory.currentProvider()
        let provider = try XCTUnwrap(latestProvider)
        await provider.scriptFailure(
            MTPCallError(message: "LIBUSB_ERROR_NO_DEVICE", type: .listDirectory),
            for: .walk
        )
        let model = try XCTUnwrap(controller.deviceModel)

        await model.load()
        try await eventually { controller.state == .noDevice }
        XCTAssertNil(controller.deviceModel)
    }

    func testHotplugSettingGatesWatcherWithoutGatingManualConnection() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let watcher = WatcherRecorder()
        let controller = DeviceConnectionController(
            providerFactory: { await factory.makeProvider() },
            events: events.stream,
            attachDebounce: .milliseconds(30),
            startWatching: watcher.start,
            stopWatching: watcher.stop
        )
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start(hotplugEnabled: false)
        XCTAssertTrue(controller.state.isConnected)
        XCTAssertEqual(watcher.startCount, 0)

        await controller.setUsbHotplugEnabled(true)
        XCTAssertEqual(watcher.startCount, 1)
        await controller.setUsbHotplugEnabled(false)
        XCTAssertEqual(watcher.stopCount, 1)
    }

    func testManualRetryRecoversNeedsReplugWithHotplugAndStaleDisposalFailure() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(firstFailure: .deviceSetup, disposeResult: false)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        events.continuation.yield(Self.event(.attached))
        await controller.start()
        try await eventually {
            controller.state == .needsReplug(deviceName: "Pixel", message: nil)
        }
        XCTAssertTrue(controller.canManuallyRetryReplug)

        await controller.retry()

        XCTAssertTrue(controller.state.isConnected)
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 2)
    }

    func testUnrelatedUSBEventsDoNotDisconnectOrRecycleConnectedDevice() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        events.continuation.yield(Self.keyboardEvent(.detached))
        events.continuation.yield(Self.otherDeviceEvent(.detached))
        events.continuation.yield(Self.otherDeviceEvent(.attached))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(controller.state.isConnected)
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 1)
    }

    func testInitialWatcherAttachDoesNotRecycleStartupConnection() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }
        events.continuation.yield(Self.event(.attached))

        await controller.start()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(controller.state.isConnected)
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 1)
    }

    func testDisconnectInvalidatesQueueAndAbortsQueuedJobs() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }
        events.continuation.yield(Self.event(.attached))
        await controller.start()

        let currentProvider = await factory.currentProvider()
        let provider = try XCTUnwrap(currentProvider)
        let gate = MockTransferGate()
        await provider.setTransferScripts([
            MockTransferScript(completionGate: gate)
        ])
        let queue = try XCTUnwrap(controller.transferQueue)
        let activeID = await queue.enqueue(Self.uploadRequest)
        let queuedID = await queue.enqueue(Self.uploadRequest)
        try await eventually {
            controller.state.isConnected
        }
        try await waitUntil {
            await queue.snapshot.activeJobId == activeID
        }

        events.continuation.yield(Self.event(.detached))
        try await eventually { controller.state == .noDevice }
        try await waitUntil {
            guard case .failed(errorType: .deviceLost, _) = await self.state(
                of: queuedID,
                in: queue
            ) else { return false }
            return true
        }
        let callsBeforeDrain = await provider.callHistory()
        XCTAssertEqual(callsBeforeDrain, [.deviceInfo, .storages, .uploadFiles])

        await gate.open()
        try await waitUntil { await self.state(of: activeID, in: queue) == .completed }
    }

    func testFailedDisposalRequiresReplugWithDiagnosticMessage() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(disposeResult: false)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        events.continuation.yield(Self.event(.attached))
        await controller.start()
        events.continuation.yield(Self.event(.detached))
        try await eventually { controller.state == .noDevice }
        events.continuation.yield(Self.event(.attached))

        try await eventually {
            if case .needsReplug = controller.state { return true }
            return false
        }
        guard case let .needsReplug(deviceName, message) = controller.state else {
            return XCTFail("Expected failed disposal to require a fresh device session")
        }
        // The phone connected earlier as "Test Pixel" (its MTP model); the
        // same serial is still called that rather than its USB product string.
        XCTAssertEqual(deviceName, "Test Pixel")
        XCTAssertTrue(message?.contains("unsuccessful disposal result") == true)
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 1)
    }

    func testNewDeviceAttachClearsStaleDisposalFailure() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder(disposeResult: false)
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        events.continuation.yield(Self.event(.attached))
        await controller.start()
        XCTAssertTrue(controller.state.isConnected)

        events.continuation.yield(Self.event(.detached))
        try await eventually { controller.state == .noDevice }
        events.continuation.yield(Self.otherDeviceEvent(.attached))

        try await eventually { controller.state.isConnected }
        let creationCount = await factory.currentCreationCount()
        XCTAssertEqual(creationCount, 2)
    }

    /// The bug report (release, then start) and closing the last window stop
    /// and restart the controller. Cancelling the task that iterated the
    /// event stream used to terminate the stream for good, so a restarted
    /// controller never saw another hotplug event.
    func testHotplugEventsStillArriveAfterTheControllerRestarts() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        XCTAssertTrue(controller.state.isConnected)
        let wasRunning = await controller.releaseDevice()
        XCTAssertTrue(wasRunning)
        await controller.start()
        XCTAssertTrue(controller.state.isConnected)

        events.continuation.yield(Self.event(.detached))
        try await eventually { controller.state == .noDevice }
        events.continuation.yield(Self.event(.attached))
        try await eventually { controller.state.isConnected }
    }

    func testHotplugEventsStillArriveAfterTheSettingIsToggled() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        await controller.setUsbHotplugEnabled(false)
        await controller.setUsbHotplugEnabled(true)
        XCTAssertTrue(controller.state.isConnected)

        events.continuation.yield(Self.event(.detached))
        try await eventually { controller.state == .noDevice }
    }

    func testHotplugEventsAreIgnoredWhileNotWatching() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ProviderFactoryRecorder()
        let controller = makeController(events: events.stream, factory: factory)
        defer {
            controller.stop()
            events.continuation.finish()
        }

        await controller.start()
        await controller.setUsbHotplugEnabled(false)
        events.continuation.yield(Self.event(.detached))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.state.isConnected)
    }

    private func makeController(
        events: AsyncStream<USBDeviceEvent>,
        factory: ProviderFactoryRecorder
    ) -> DeviceConnectionController {
        DeviceConnectionController(
            providerFactory: { await factory.makeProvider() },
            events: events,
            attachDebounce: .milliseconds(30)
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("Condition was not met before timeout")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
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

    private func state(of id: UUID, in queue: TransferQueue) async -> TransferJobState? {
        await queue.snapshot.jobs.first(where: { $0.id == id })?.state
    }

    private static func event(
        _ kind: USBDeviceEvent.Kind,
        locationID: UInt64? = 0x1000
    ) -> USBDeviceEvent {
        USBDeviceEvent(
            kind: kind,
            vendorId: 0x18D1,
            productId: 0x4EE1,
            serialNumber: "TEST",
            productName: "Pixel",
            isLikelyMTPDevice: true,
            locationId: locationID
        )
    }

    private static func otherDeviceEvent(_ kind: USBDeviceEvent.Kind) -> USBDeviceEvent {
        USBDeviceEvent(
            kind: kind,
            vendorId: 0x1234,
            productId: 0x5678,
            serialNumber: "OTHER",
            productName: "Other phone",
            isLikelyMTPDevice: true,
            locationId: 0x3000
        )
    }

    private static func unknownDeviceEvent(_ kind: USBDeviceEvent.Kind) -> USBDeviceEvent {
        USBDeviceEvent(
            kind: kind,
            vendorId: 0,
            productId: 0,
            serialNumber: nil,
            productName: nil,
            isLikelyMTPDevice: nil
        )
    }

    private static func keyboardEvent(_ kind: USBDeviceEvent.Kind) -> USBDeviceEvent {
        USBDeviceEvent(
            kind: kind,
            vendorId: 0x05AC,
            productId: 0x024F,
            serialNumber: "KEYBOARD",
            productName: "Keyboard",
            isLikelyMTPDevice: false
        )
    }

    private static let uploadRequest = TransferRequest(
        direction: .upload,
        sources: ["/tmp/upload.txt"],
        destination: "/",
        storageId: 1
    )
}

private final class WatcherRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    func start() throws {
        lock.withLock { starts += 1 }
    }

    func stop() {
        lock.withLock { stops += 1 }
    }
}

private actor ProviderFactoryRecorder {
    private let firstFailure: MTPErrorType?
    private let disposeResult: Bool
    private let firstFactoryGate: MockTransferGate?
    private(set) var creationCount = 0
    private(set) var latestProvider: MockMTPProvider?

    init(
        firstFailure: MTPErrorType? = nil,
        disposeResult: Bool = true,
        firstFactoryGate: MockTransferGate? = nil
    ) {
        self.firstFailure = firstFailure
        self.disposeResult = disposeResult
        self.firstFactoryGate = firstFactoryGate
    }

    func makeProvider() async -> MockMTPProvider {
        creationCount += 1
        if creationCount == 1, let firstFactoryGate {
            await firstFactoryGate.wait()
        }
        let failures: [MTPProviderCall: [MTPErrorType]]
        if creationCount == 1, let firstFailure {
            failures = [.deviceInfo: [firstFailure]]
        } else {
            failures = [:]
        }
        let provider = MockMTPProvider(
            deviceInfo: DeviceInfo(model: "Test Pixel", usb: USBDeviceInfo(vendorID: 0x18D1, productID: 0x4EE1, serialNumber: "TEST")),
            storages: [
                StorageInfo(id: 1, storageDescription: "Internal storage")
            ],
            scriptedFailures: failures,
            disposeResult: disposeResult
        )
        latestProvider = provider
        return provider
    }

    func currentCreationCount() -> Int {
        creationCount
    }

    func currentProvider() -> MockMTPProvider? {
        latestProvider
    }
}

private extension DeviceConnectionController.State {
    var isConnected: Bool {
        if case .connected = self {
            true
        } else {
            false
        }
    }
}
