import Foundation
import MTPKit
import USBWatcher
import XCTest
@testable import AndroidRapidTransferCore

// The phone is held by another program (macOS's Image Capture agent on a
// Samsung phone), or its interface cannot be claimed: what the controller
// does, what the pane says, and the "Release the Phone" action.

/// The provider's text for a claim that found the interface taken (what
/// `USBClaimRetry` produces on macOS after its retries).
private let busyByImageCapture = MTPCallError(
    message: "could not open the MTP interface: opening IOUSBHostInterface: kIOReturnExclusiveAccess [IOUSBHostErrorDomain]: ptpcamerad (pid 19641) is using the phone (exclusiveAccess, IOReturn 0xe00002c5)",
    type: .deviceSetup
)

/// A claim refused with kIOReturnInternalError while nobody is named as holder.
private let claimInternalError = MTPCallError(
    message: "could not open the MTP interface: opening IOUSBHostInterface: kIOReturnInternalError [IOUSBHostErrorDomain] (io, IOReturn 0xe00002c9)",
    type: .deviceSetup
)

/// A setup failure that is the phone's, not the Mac's: the replug case.
private let openSessionFailure = MTPCallError(message: "OpenSession failed: DeviceBusy", type: .deviceSetup)

final class DeviceAccessHolderTests: XCTestCase {
    func testMacHolderIsReadFromTheTransportText() {
        let holder = DeviceAccessProblem(message: busyByImageCapture.description)?.holder
        XCTAssertEqual(holder, DeviceHolder(name: "ptpcamerad", kind: .process(pid: 19641)))
        XCTAssertEqual(holder?.isImageCaptureAgent, true)
        XCTAssertEqual(holder?.isCurrentProcess, false)
    }

    func testKernelDriverHolder() {
        let message = "could not open the MTP interface: opening IOUSBHostInterface: kIOReturnExclusiveAccess [d]: AppleUSBACMControl (kernel driver) is using the phone (exclusiveAccess, IOReturn 0xe00002c5)"
        let holder = DeviceAccessProblem(message: message)?.holder
        XCTAssertEqual(holder, DeviceHolder(name: "AppleUSBACMControl", kind: .kernelDriver))
        XCTAssertEqual(holder?.isImageCaptureAgent, false)
    }

    func testLinuxHolderFormsAreReadToo() {
        let plain = "ErrorDeviceSetup: could not open the MTP interface: claiming interface 0 of /dev/bus/usb/003/010: gvfsd-mtp (pid 42) is using the phone (exclusiveAccess, errno 16)"
        XCTAssertEqual(DeviceAccessProblem(message: plain)?.holder, DeviceHolder(name: "gvfsd-mtp", kind: .process(pid: 42)))
        let named = "claiming interface 0 of /dev/bus/usb/003/010: GNOME Files (gvfsd-mtp), pid 1200 is using the phone (exclusiveAccess, errno 16)"
        XCTAssertEqual(DeviceAccessProblem(message: named)?.holder,
                       DeviceHolder(name: "GNOME Files (gvfsd-mtp)", kind: .process(pid: 1200)))
    }

    func testNoHolderWhenUnnamedSeveralOrNotBusy() {
        let unnamed = "could not open the MTP interface: x: another program or driver has claimed the phone's MTP interface (exclusiveAccess, IOReturn 0xe00002c5)"
        XCTAssertNotNil(DeviceAccessProblem(message: unnamed))
        XCTAssertNil(DeviceAccessProblem(message: unnamed)?.holder)
        let several = "x: mtp-probe (pid 5), kiod6 (pid 6) are using the phone (exclusiveAccess, errno 16)"
        XCTAssertNil(DeviceAccessProblem(message: several)?.holder)
        let denied = "cannot open /dev/bus/usb/001/007: Permission denied (notPermitted, errno 13)"
        XCTAssertNil(DeviceAccessProblem(message: denied)?.holder)
    }

    func testOnlyTheImageCaptureAgentWithAPidIsReleasable() {
        XCTAssertTrue(DeviceHolder(name: "ptpcamerad", kind: .process(pid: 9)).isImageCaptureAgent)
        XCTAssertFalse(DeviceHolder(name: "ptpcamerad", kind: .unnamedKind).isImageCaptureAgent)
        XCTAssertFalse(DeviceHolder(name: "Photos", kind: .process(pid: 9)).isImageCaptureAgent)
        XCTAssertTrue(DeviceHolder(name: "me", kind: .process(pid: ProcessInfo.processInfo.processIdentifier)).isCurrentProcess)
    }
}

final class ConnectionAccessClassifierTests: XCTestCase {
    func testABusyClaimIsAnAccessProblemNotAReplug() {
        XCTAssertEqual(ConnectionFatalClassifier.disposition(for: busyByImageCapture), .accessBlocked)
        let denied = MTPCallError(message: "could not open the MTP interface: x (notPermitted, errno 13)", type: .deviceSetup)
        XCTAssertEqual(ConnectionFatalClassifier.disposition(for: denied), .accessBlocked)
    }

    func testOtherSetupFailuresStillAskForAReplug() {
        XCTAssertEqual(ConnectionFatalClassifier.disposition(for: openSessionFailure), .requiresReplug)
    }

    #if os(macOS)
    func testAnyOtherFailedClaimOnMacOSIsExplainedNotAReplug() {
        XCTAssertEqual(ConnectionFatalClassifier.disposition(for: claimInternalError), .accessBlocked)
    }
    #endif

    /// The access markers count only for setup: a refused transfer mid-session
    /// is an ordinary failure, not a reason to drop the session.
    func testAccessMarkersOutsideSetupAreNotFatal() {
        let error = MTPCallError(message: "bulk read: kIOReturnNotPermitted (notPermitted, IOReturn 0xe00002e2)", type: .fileTransfer)
        XCTAssertNil(ConnectionFatalClassifier.disposition(for: error))
    }
}

final class ConnectionBlockedPresentationTests: XCTestCase {
    private let app = AppIdentity.name

    func testImageCaptureAgentIsExplainedAndOffersRelease() throws {
        let screen = try XCTUnwrap(ConnectionBlockedPresentation(message: busyByImageCapture.description))
        XCTAssertEqual(screen.title, "macOS’s Image Capture service is using your phone")
        XCTAssertTrue(screen.message.contains("(ptpcamerad)"))
        XCTAssertTrue(screen.message.contains("\(app) can’t connect"))
        XCTAssertTrue(screen.guidance.contains("Release the Phone"))
        XCTAssertTrue(screen.offersRelease)
        XCTAssertEqual(screen.detail, busyByImageCapture.description)
    }

    func testAnotherProgramIsNamedWithRetryOnly() throws {
        let message = "could not open the MTP interface: x: Android File Transfer (pid 812) is using the phone (exclusiveAccess, IOReturn 0xe00002c5)"
        let screen = try XCTUnwrap(ConnectionBlockedPresentation(message: message))
        XCTAssertEqual(screen.title, "Another program is using your phone")
        XCTAssertEqual(screen.message, "“Android File Transfer” (process 812) has the phone open, so \(app) can’t connect to it. Only one program can use the phone at a time.")
        XCTAssertEqual(screen.guidance, "Quit Android File Transfer, then click Retry.")
        XCTAssertFalse(screen.offersRelease)
    }

    func testDriverAndUnknownAndSelfHolders() throws {
        let driver = try XCTUnwrap(ConnectionBlockedPresentation(
            message: "could not open the MTP interface: x: AppleUSBACMControl (kernel driver) is using the phone (exclusiveAccess, IOReturn 0xe00002c5)"
        ))
        XCTAssertEqual(driver.title, "A macOS driver is using your phone")
        XCTAssertTrue(driver.message.contains("AppleUSBACMControl"))
        XCTAssertFalse(driver.offersRelease)

        let unknown = try XCTUnwrap(ConnectionBlockedPresentation(
            message: "could not open the MTP interface: x: another program or driver has claimed the phone's MTP interface (exclusiveAccess, IOReturn 0xe00002c5)"
        ))
        XCTAssertEqual(unknown.title, "Another program is using your phone")
        XCTAssertTrue(unknown.guidance.contains("Troubleshooting"))
        XCTAssertFalse(unknown.offersRelease)

        let pid = ProcessInfo.processInfo.processIdentifier
        let me = try XCTUnwrap(ConnectionBlockedPresentation(
            message: "could not open the MTP interface: x: AndroidRapidTr (pid \(pid)) is using the phone (exclusiveAccess, IOReturn 0xe00002c5)"
        ))
        XCTAssertEqual(me.title, "The previous connection is still closing")
        XCTAssertFalse(me.offersRelease)
    }

    func testRefusedClaimShowsItsCodeAndOffersRetry() throws {
        let screen = try XCTUnwrap(ConnectionBlockedPresentation(message: claimInternalError.description))
        XCTAssertEqual(screen.title, "Couldn’t open the phone’s file transfer connection")
        XCTAssertEqual(screen.message, "macOS didn’t let \(app) open the phone’s file transfer (MTP) connection (kIOReturnInternalError, 0xE00002C9).")
        XCTAssertTrue(screen.guidance.hasPrefix("Click Retry."))
        XCTAssertFalse(screen.offersRelease)
    }

    func testOtherFailuresKeepTheGenericScreen() {
        XCTAssertNil(ConnectionBlockedPresentation(message: "ErrorDeviceLocked: device is not open"))
        XCTAssertNil(ConnectionBlockedPresentation(message: openSessionFailure.description))
    }
}

final class DeviceFriendlyNameTests: XCTestCase {
    func testGenericProductStringsAreReplacedByTheMaker() {
        XCTAssertEqual(DeviceFriendlyName.resolve(model: nil, productName: "SAMSUNG_Android", vendorID: 0x04E8), "Samsung phone")
        XCTAssertEqual(DeviceFriendlyName.resolve(model: "", productName: "Android", vendorID: 0x2717), "Xiaomi phone")
        XCTAssertEqual(DeviceFriendlyName.resolve(model: " ", productName: "MTP", vendorID: 0x18D1), "Google phone")
        XCTAssertNil(DeviceFriendlyName.resolve(model: nil, productName: "MediaTek_Android", vendorID: 0x0E8D),
                     "an unknown maker leaves the UI's own wording")
        XCTAssertNil(DeviceFriendlyName.resolve(model: nil, productName: nil, vendorID: nil))
    }

    func testRealNamesAreKept() {
        XCTAssertEqual(DeviceFriendlyName.resolve(model: "SM-S918B", productName: "SAMSUNG_Android", vendorID: 0x04E8), "SM-S918B")
        XCTAssertEqual(DeviceFriendlyName.resolve(model: nil, productName: "Pixel 8", vendorID: 0x18D1), "Pixel 8")
        XCTAssertEqual(DeviceFriendlyName.resolve(model: "Android", productName: "Mi 9", vendorID: 0x2717), "Mi 9")
        XCTAssertFalse(DeviceFriendlyName.isGeneric("Galaxy S23 Android Edition"))
        XCTAssertTrue(DeviceFriendlyName.isGeneric("rockchip-android"))
    }

    func testDeviceInfoDisplayNameUsesTheSameRules() {
        let samsung = DeviceInfo(model: "", usb: USBDeviceInfo(vendorID: 0x04E8, productID: 0x6860, product: "SAMSUNG_Android"))
        XCTAssertEqual(samsung.displayName, "Samsung phone")
    }
}

final class ImageCaptureAgentReleaseTests: XCTestCase {
    /// An in-memory process table; nothing real is ever signalled.
    private final class FakeSystem: @unchecked Sendable {
        private let lock = NSLock()
        var record: ImageCaptureAgentRelease.ProcessRecord?
        var signals: [Int32] = []
        /// Signals that make the process exit.
        var exitsOn: Set<Int32> = [SIGTERM, SIGKILL]
        var signalError: Int32 = 0
        var holdsUSBAfterExit = false
        /// Replaces the process after SIGTERM (pid reuse).
        var replacementAfterTerm: ImageCaptureAgentRelease.ProcessRecord?

        func lookup(_ pid: Int32) -> ImageCaptureAgentRelease.ProcessRecord? { lock.withLock { record } }

        func signal(_ pid: Int32, _ sig: Int32) -> Int32 {
            lock.withLock {
                signals.append(sig)
                if signalError != 0 { return signalError }
                if sig == SIGTERM, let replacementAfterTerm { record = replacementAfterTerm }
                else if exitsOn.contains(sig) { record = nil }
                return 0
            }
        }

        func holdsUSB(_ pid: Int32) -> Bool { lock.withLock { record != nil || holdsUSBAfterExit } }

        func release(currentUID: UInt32 = 501) -> ImageCaptureAgentRelease {
            ImageCaptureAgentRelease(
                lookup: { self.lookup($0) },
                currentUserID: { currentUID },
                userName: { $0 == 502 ? "guest" : nil },
                sendSignal: { self.signal($0, $1) },
                holdsUSB: { self.holdsUSB($0) },
                sleep: { _ in }
            )
        }
    }

    private static let agent = ImageCaptureAgentRelease.ProcessRecord(
        name: "ptpcamerad", path: "/usr/libexec/ptpcamerad", realUserID: 501, effectiveUserID: 501
    )

    func testAgentThatHonoursSIGTERMIsReleasedWithoutForce() {
        let system = FakeSystem()
        system.record = Self.agent
        XCTAssertEqual(system.release().release(pid: 19641), .released(forced: false))
        XCTAssertEqual(system.signals, [SIGTERM])
    }

    /// Seen on a Mac: ptpcamerad ignored SIGTERM while it held a Samsung phone.
    func testAgentThatIgnoresSIGTERMIsKilled() {
        let system = FakeSystem()
        system.record = Self.agent
        system.exitsOn = [SIGKILL]
        let outcome = system.release().release(pid: 19641)
        XCTAssertEqual(outcome, .released(forced: true))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertNil(outcome.failureMessage)
        XCTAssertEqual(system.signals, [SIGTERM, SIGKILL])
    }

    func testAgentThatSurvivesSIGKILLIsReported() {
        let system = FakeSystem()
        system.record = Self.agent
        system.exitsOn = []
        let outcome = system.release().release(pid: 19641)
        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertEqual(outcome.failureMessage?.hasPrefix("macOS’s Image Capture service didn’t stop"), true)
    }

    func testExitedAgentStillNamedAsOwnerIsReported() {
        let system = FakeSystem()
        system.record = Self.agent
        system.holdsUSBAfterExit = true
        XCTAssertEqual(system.release().release(pid: 19641), .stillHoldsPhone)
    }

    func testAnotherProgramIsNeverSignalled() {
        let system = FakeSystem()
        system.record = .init(name: "Photos", path: "/System/Applications/Photos.app/Contents/MacOS/Photos",
                              realUserID: 501, effectiveUserID: 501)
        XCTAssertEqual(system.release().release(pid: 19641), .notImageCaptureAgent(name: "Photos"))
        XCTAssertEqual(system.signals, [])
    }

    func testAProcessNamedLikeTheAgentElsewhereIsNeverSignalled() {
        let system = FakeSystem()
        system.record = .init(name: "ptpcamerad", path: "/tmp/ptpcamerad", realUserID: 501, effectiveUserID: 501)
        XCTAssertEqual(system.release().release(pid: 19641), .notImageCaptureAgent(name: "ptpcamerad"))
        XCTAssertEqual(system.signals, [])
    }

    func testAnotherUsersAgentIsNeverSignalled() {
        let system = FakeSystem()
        system.record = .init(name: "ptpcamerad", path: "/usr/libexec/ptpcamerad", realUserID: 502, effectiveUserID: 502)
        let outcome = system.release(currentUID: 501).release(pid: 19641)
        XCTAssertEqual(outcome, .ownedByAnotherUser(userName: "guest"))
        XCTAssertEqual(system.signals, [])
        XCTAssertEqual(outcome.failureMessage?.contains("another user on this Mac (guest)"), true)
    }

    func testPidReusedBeforeTheKillIsNotKilled() {
        let system = FakeSystem()
        system.record = Self.agent
        system.replacementAfterTerm = .init(name: "Safari", path: nil, realUserID: 501, effectiveUserID: 501)
        XCTAssertEqual(system.release().release(pid: 19641), .notImageCaptureAgent(name: "Safari"))
        XCTAssertEqual(system.signals, [SIGTERM], "identity is checked again before SIGKILL")
    }

    func testRefusedSignalIsReported() {
        let system = FakeSystem()
        system.record = Self.agent
        system.signalError = EPERM
        XCTAssertEqual(system.release().release(pid: 19641), .signalFailed(errno: EPERM))
    }

    func testAlreadyExitedAgentNeedsNoSignal() {
        let system = FakeSystem()
        XCTAssertEqual(system.release().release(pid: 19641), .alreadyGone)
        XCTAssertEqual(system.signals, [])
    }

    func testOwnProcessAndLowPidsAreRefused() {
        let system = FakeSystem()
        system.record = Self.agent
        XCTAssertFalse(system.release().release(pid: 1).succeeded)
        XCTAssertFalse(system.release().release(pid: ProcessInfo.processInfo.processIdentifier).succeeded)
        XCTAssertEqual(system.signals, [])
    }
}

@MainActor
final class DeviceConnectionAccessTests: XCTestCase {
    private actor ScriptedFactory {
        /// Failures of each attempt's deviceInfo, in order; nil connects.
        private var failures: [MTPCallError?]
        private let model: String
        private let firstGate: MockTransferGate?
        private(set) var creations = 0
        private(set) var latest: MockMTPProvider?

        init(failures: [MTPCallError?], model: String = "", firstGate: MockTransferGate? = nil) {
            self.failures = failures
            self.model = model
            self.firstGate = firstGate
        }

        func make() async -> MockMTPProvider {
            creations += 1
            if creations == 1, let firstGate { await firstGate.wait() }
            let provider = MockMTPProvider(
                deviceInfo: DeviceInfo(model: model, usb: USBDeviceInfo(
                    vendorID: 0x04E8, productID: 0x6860, product: "SAMSUNG_Android", serialNumber: "RFTEST00001"
                )),
                storages: [StorageInfo(id: 1, storageDescription: "Internal storage")]
            )
            if !failures.isEmpty, let failure = failures.removeFirst() {
                await provider.scriptFailure(failure, for: .deviceInfo)
            }
            latest = provider
            return provider
        }
    }

    private final class ReleaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var record: ImageCaptureAgentRelease.ProcessRecord? = .init(
            name: "ptpcamerad", path: "/usr/libexec/ptpcamerad", realUserID: 501, effectiveUserID: 501
        )
        private(set) var signalled: [(pid: Int32, signal: Int32)] = []
        let uid: UInt32

        init(uid: UInt32 = 501) { self.uid = uid }

        var release: ImageCaptureAgentRelease {
            ImageCaptureAgentRelease(
                lookup: { _ in self.lock.withLock { self.record } },
                currentUserID: { self.uid },
                sendSignal: { pid, signal in
                    self.lock.withLock {
                        self.signalled.append((pid, signal))
                        self.record = nil
                    }
                    return 0
                },
                holdsUSB: { _ in self.lock.withLock { self.record != nil } },
                sleep: { _ in }
            )
        }
    }

    private func makeController(
        _ factory: ScriptedFactory,
        events: AsyncStream<USBDeviceEvent> = AsyncStream { _ in },
        release: ImageCaptureAgentRelease = ReleaseRecorder().release
    ) -> DeviceConnectionController {
        DeviceConnectionController(
            providerFactory: { await factory.make() },
            events: events,
            attachDebounce: .milliseconds(20),
            imageCaptureAgentRelease: release
        )
    }

    private static func samsung(_ kind: USBDeviceEvent.Kind) -> USBDeviceEvent {
        USBDeviceEvent(kind: kind, vendorId: 0x04E8, productId: 0x6860, serialNumber: "RFTEST00001",
                       productName: "SAMSUNG_Android", isLikelyMTPDevice: true, locationId: 0x1000)
    }

    private func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition was not met before timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testBusyInterfaceOnOpenIsARetryableErrorThenRetryConnects() async throws {
        let factory = ScriptedFactory(failures: [busyByImageCapture])
        let controller = makeController(factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        guard case let .error(message, retryable) = controller.state else {
            return XCTFail("expected an error, got \(controller.state)")
        }
        XCTAssertTrue(retryable)
        XCTAssertTrue(message.contains("ptpcamerad (pid 19641) is using the phone"))
        XCTAssertEqual(controller.releasableHolder?.processID, 19641)
        XCTAssertEqual(controller.lastConnectionError, busyByImageCapture.description)

        await controller.retry()
        XCTAssertTrue(controller.state.isConnectedForAccessTests)
        let creations = await factory.creations
        XCTAssertEqual(creations, 2)
    }

    #if os(macOS)
    func testRefusedClaimIsARetryableErrorNotAReplug() async {
        let factory = ScriptedFactory(failures: [claimInternalError])
        let controller = makeController(factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        XCTAssertEqual(controller.state, .error(message: claimInternalError.description, retryable: true))
        XCTAssertNil(controller.releasableHolder)
    }
    #endif

    func testReleaseStopsTheImageCaptureAgentThenRetriesAtOnce() async throws {
        let factory = ScriptedFactory(failures: [busyByImageCapture])
        let recorder = ReleaseRecorder()
        let controller = makeController(factory, release: recorder.release)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        await controller.releaseHolderAndRetry()

        XCTAssertTrue(controller.state.isConnectedForAccessTests)
        XCTAssertEqual(recorder.signalled.map(\.pid), [19641])
        XCTAssertEqual(recorder.signalled.map(\.signal), [SIGTERM])
        XCTAssertNil(controller.holderReleaseFailure)
        XCTAssertFalse(controller.isReleasingHolder)
        let creations = await factory.creations
        XCTAssertEqual(creations, 2)
    }

    func testFailedReleaseIsReportedAndTheConnectionIsStillRetried() async throws {
        let factory = ScriptedFactory(failures: [busyByImageCapture, busyByImageCapture])
        let recorder = ReleaseRecorder(uid: 777)
        let controller = makeController(factory, release: recorder.release)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        await controller.releaseHolderAndRetry()

        XCTAssertTrue(recorder.signalled.isEmpty, "another user's process is never signalled")
        guard case .error = controller.state else { return XCTFail("expected an error, got \(controller.state)") }
        XCTAssertEqual(controller.holderReleaseFailure?.contains("belongs to another user"), true)
        var creations = await factory.creations
        XCTAssertEqual(creations, 2, "the connection was retried after the release")

        await controller.retry()
        XCTAssertNil(controller.holderReleaseFailure)
        XCTAssertTrue(controller.state.isConnectedForAccessTests)
        creations = await factory.creations
        XCTAssertEqual(creations, 3)
    }

    func testReleaseWithoutAReleasableHolderJustRetries() async {
        let factory = ScriptedFactory(failures: [claimInternalError])
        let recorder = ReleaseRecorder()
        let controller = makeController(factory, release: recorder.release)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        await controller.releaseHolderAndRetry()
        XCTAssertTrue(recorder.signalled.isEmpty)
        XCTAssertTrue(controller.state.isConnectedForAccessTests)
    }

    func testReplugThatFailsTheSameWayEndsInAnErrorInsteadOfTheSameScreen() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ScriptedFactory(failures: [openSessionFailure, openSessionFailure])
        let controller = makeController(factory, events: events.stream)
        defer {
            controller.stop()
            events.continuation.finish()
        }
        events.continuation.yield(Self.samsung(.attached))
        await controller.start()
        try await eventually { controller.state == .needsReplug(deviceName: "Samsung phone", message: nil) }

        events.continuation.yield(Self.samsung(.detached))
        events.continuation.yield(Self.samsung(.attached))
        try await eventually {
            if case .error = controller.state { return true }
            return false
        }
        guard case let .error(message, retryable) = controller.state else { return }
        XCTAssertTrue(retryable)
        XCTAssertTrue(message.hasPrefix("The phone still couldn’t be opened after it was plugged back in."))
        XCTAssertTrue(message.contains("OpenSession failed: DeviceBusy"))
        let creations = await factory.creations
        XCTAssertEqual(creations, 2)
    }

    func testReplugThatWorksConnects() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ScriptedFactory(failures: [openSessionFailure, nil])
        let controller = makeController(factory, events: events.stream)
        defer {
            controller.stop()
            events.continuation.finish()
        }
        events.continuation.yield(Self.samsung(.attached))
        await controller.start()
        try await eventually { controller.state.needsReplugForAccessTests }
        events.continuation.yield(Self.samsung(.detached))
        events.continuation.yield(Self.samsung(.attached))
        try await eventually { controller.state.isConnectedForAccessTests }
    }

    func testConnectionLostToAnotherProgramShowsTheExplainedError() async throws {
        let factory = ScriptedFactory(failures: [nil], model: "SM-S918B")
        let controller = makeController(factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        XCTAssertTrue(controller.state.isConnectedForAccessTests)
        let latest = await factory.latest
        let provider = try XCTUnwrap(latest)
        await provider.scriptFailure(busyByImageCapture, for: .walk)
        let model = try XCTUnwrap(controller.deviceModel)
        await model.load()

        try await eventually {
            controller.state == .error(message: busyByImageCapture.description, retryable: true)
        }
        XCTAssertNil(controller.deviceModel)
        XCTAssertNil(controller.transferQueue)
        XCTAssertEqual(controller.releasableHolder?.processID, 19641)
        XCTAssertEqual(controller.lastConnectionError, busyByImageCapture.description)
    }

    func testRememberedModelNamesAPhoneThatFailsBeforeReportingIt() async throws {
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        let factory = ScriptedFactory(failures: [nil, openSessionFailure], model: "SM-S918B")
        let controller = makeController(factory, events: events.stream)
        defer {
            controller.stop()
            events.continuation.finish()
        }
        events.continuation.yield(Self.samsung(.attached))
        await controller.start()
        try await eventually { controller.state.isConnectedForAccessTests }

        events.continuation.yield(Self.samsung(.detached))
        try await eventually { controller.state == .noDevice }
        events.continuation.yield(Self.samsung(.attached))
        try await eventually { controller.state == .needsReplug(deviceName: "SM-S918B", message: nil) }
    }

    func testRetryWhileAnAttemptIsRunningIsIgnored() async throws {
        let gate = MockTransferGate()
        let factory = ScriptedFactory(failures: [nil], firstGate: gate)
        let controller = makeController(factory)
        defer { controller.stop() }

        let start = Task { await controller.start(hotplugEnabled: false) }
        try await eventually { controller.state == .detecting }
        await controller.retry()
        await controller.releaseHolderAndRetry()
        await gate.open()
        await start.value

        XCTAssertTrue(controller.state.isConnectedForAccessTests)
        let creations = await factory.creations
        XCTAssertEqual(creations, 1, "no second claim while the first attempt runs")
    }

    func testBugReportIncludesTheLastConnectionError() async {
        let factory = ScriptedFactory(failures: [openSessionFailure])
        let controller = makeController(factory)
        defer { controller.stop() }

        await controller.start(hotplugEnabled: false)
        let session = ConnectionControllerBugReportSession(
            controller: controller,
            hasActiveTransfers: { false },
            hotplugEnabled: { false }
        )
        let summary = session.deviceSummary()
        XCTAssertTrue(summary.contains("State: needs replug"), summary)
        XCTAssertTrue(summary.contains("Last connection error: ErrorDeviceSetup: OpenSession failed: DeviceBusy"), summary)
    }

    func testBugReportSummaryWithoutAnErrorIsUnchanged() {
        XCTAssertEqual(
            BugReportDeviceSummary.describe(.needsReplug(deviceName: nil, message: nil)),
            "State: needs replug\nDevice: unknown\nMessage: none\n"
        )
        XCTAssertEqual(
            BugReportDeviceSummary.describe(.noDevice, lastConnectionError: "ErrorDeviceSetup: x"),
            "State: no device connected when the report was created.\nLast connection error: ErrorDeviceSetup: x\n"
        )
    }
}

private extension DeviceConnectionController.State {
    var isConnectedForAccessTests: Bool {
        if case .connected = self { return true }
        return false
    }

    var needsReplugForAccessTests: Bool {
        if case .needsReplug = self { return true }
        return false
    }
}
