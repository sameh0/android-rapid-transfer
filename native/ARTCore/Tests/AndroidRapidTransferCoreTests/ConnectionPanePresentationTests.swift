@testable import AndroidRapidTransferCore
import MTPKit
import XCTest

@MainActor
final class ConnectionPanePresentationTests: XCTestCase {
    private let progress = ConnectionReconnectProgress(limit: 3)

    private func phase(
        _ state: DeviceConnectionController.State,
        reconnecting: Bool = false,
        model: Bool = false,
        notice: String? = nil
    ) -> ConnectionPanePhase {
        ConnectionPanePhase(
            state: state,
            isReconnecting: reconnecting,
            hasDeviceModel: model,
            notice: notice,
            reconnectProgress: progress
        )
    }

    private var connected: DeviceConnectionController.State {
        .connected(DeviceInfo(manufacturer: "Google", model: "Pixel"), [])
    }

    // MARK: - Phase mapping

    func testIdleStatesMapToTheirScreens() async {
        XCTAssertEqual(phase(.noDevice), .waiting(notice: nil))
        XCTAssertEqual(phase(.noDevice, notice: "Lost"), .waiting(notice: "Lost"))
        XCTAssertEqual(phase(.detecting), .detecting)
        XCTAssertEqual(
            phase(.needsReplug(deviceName: "Pixel", message: nil)),
            .needsReplug(deviceName: "Pixel", message: nil)
        )
        XCTAssertEqual(
            phase(.error(message: "Boom", retryable: false)),
            .failed(message: "Boom", retryable: false)
        )
    }

    func testReconnectingWinsOverNoDeviceAndDetecting() async {
        XCTAssertEqual(phase(.noDevice, reconnecting: true, notice: "Lost"), .reconnecting(progress))
        XCTAssertEqual(phase(.detecting, reconnecting: true), .reconnecting(progress))
        XCTAssertEqual(phase(.noDevice, reconnecting: true).kind, .reconnecting)
    }

    func testConnectedNeedsTheBrowserModel() async {
        XCTAssertEqual(phase(connected, model: false), .detecting)
        XCTAssertEqual(phase(connected, model: true), .connected)
        // A stale reconnecting flag never hides a working connection.
        XCTAssertEqual(phase(connected, reconnecting: true, model: true), .connected)
    }

    func testKindIgnoresDetails() async {
        XCTAssertEqual(ConnectionPanePhase.waiting(notice: "a").kind, ConnectionPanePhase.waiting(notice: nil).kind)
        XCTAssertEqual(ConnectionPanePhase.failed(message: "a", retryable: true).kind, .failed)
    }

    // MARK: - Reconnect progress

    func testProgressClampsTheAttemptToTheBudget() async {
        let progress = ConnectionReconnectProgress(attempt: 2, limit: 3, isAttempting: true)
        XCTAssertEqual(progress.attempt, 2)
        XCTAssertTrue(progress.isAttempting)
        XCTAssertEqual(progress.fraction, 2.0 / 3.0, accuracy: 0.0001)

        XCTAssertEqual(ConnectionReconnectProgress(attempt: 9, limit: 2).attempt, 2)
        XCTAssertEqual(ConnectionReconnectProgress(attempt: 9, limit: 2).fraction, 1)
        XCTAssertEqual(ConnectionReconnectProgress(attempt: -1, limit: 2).attempt, 0)
    }

    func testNoAttemptYetIsNeverRunning() async {
        let progress = ConnectionReconnectProgress(attempt: 0, limit: 3, isAttempting: true)
        XCTAssertFalse(progress.isAttempting, "Waiting for the first attempt is not an attempt")
    }

    func testProgressReadsAnIdleControllerAsNoSequence() async {
        let controller = DeviceConnectionController(
            providerFactory: { throw CancellationError() },
            events: AsyncStream { _ in },
            reconnectPolicy: DeviceReconnectPolicy(delays: [.seconds(1), .seconds(1)], window: .seconds(15))
        )
        let progress = ConnectionReconnectProgress(controller: controller)
        XCTAssertEqual(progress.limit, 2, "The limit is the controller's own budget")
        XCTAssertEqual(progress.attempt, 0)
        XCTAssertFalse(progress.isAttempting)
    }

    func testDefaultLimitMatchesTheStandardPolicy() async {
        XCTAssertEqual(ConnectionReconnectProgress().limit, DeviceReconnectPolicy.standard.delays.count)
        XCTAssertEqual(ConnectionReconnectProgress(limit: 0).fraction, 0)
    }

    // MARK: - Arrival

    func testArrivalTitleSaysWhetherItReconnected() async {
        XCTAssertEqual(
            ConnectionArrival(deviceName: "Pixel 8", freeBytes: nil, isReconnect: false).title,
            "Pixel 8 connected"
        )
        XCTAssertEqual(
            ConnectionArrival(deviceName: "Pixel 8", freeBytes: 1, isReconnect: true).title,
            "Reconnected to Pixel 8"
        )
    }

    // MARK: - Storage

    func testUsedFractionAndLevel() async {
        let roomy = DeviceStorage(id: 1, name: "Internal shared storage", totalBytes: 100, freeBytes: 60)
        XCTAssertEqual(roomy.usedFraction ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(roomy.usageLevel, .normal)

        let tight = DeviceStorage(id: 2, name: "x", totalBytes: 100, freeBytes: 8)
        XCTAssertEqual(tight.usageLevel, .nearlyFull)

        let full = DeviceStorage(id: 3, name: "x", totalBytes: 100, freeBytes: 1)
        XCTAssertEqual(full.usageLevel, .full)
    }

    func testUsedFractionIsClampedAndOptional() async {
        XCTAssertNil(DeviceStorage(id: 1, name: "x").usedFraction)
        XCTAssertNil(DeviceStorage(id: 1, name: "x").usageLevel)
        XCTAssertNil(DeviceStorage(id: 1, name: "x", totalBytes: 0, freeBytes: 0).usedFraction)
        // Phones sometimes report more free space than capacity, or less than none.
        XCTAssertEqual(DeviceStorage(id: 1, name: "x", totalBytes: 100, freeBytes: 250).usedFraction, 0)
        XCTAssertEqual(DeviceStorage(id: 1, name: "x", totalBytes: 100, freeBytes: -5).usedFraction, 1)
    }

    func testRemovableStorageIsRecognisedByName() async {
        for name in ["SD card", "SanDisk SD", "External USB", "microSD", "Card"] {
            XCTAssertTrue(DeviceStorage(id: 1, name: name).isRemovable, name)
        }
        for name in ["Internal shared storage", "Phone", "Storage 1", "Cardinal"] {
            XCTAssertFalse(DeviceStorage(id: 1, name: name).isRemovable, name)
        }
    }
}
