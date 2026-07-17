import Foundation
import XCTest
@testable import SwiftMTP

final class SwiftMTPDiagnosticsTests: XCTestCase {
    private let phone = MTPInterfaceCandidate(
        registryEntryID: 42, vendorID: 0x2717, productID: 0xFF40, manufacturer: "FakeCo",
        productName: "Fake Phone", serialNumber: "FAKE0001", locationID: 0x0110_0000,
        interfaceNumber: 0, interfaceClass: 0xFF, interfaceSubClass: 0xFF, interfaceProtocol: 0,
        interfaceName: "MTP", endpointCount: 3
    )
    private let keyboard = MTPInterfaceCandidate(
        registryEntryID: 7, vendorID: 0x05AC, productID: 0x0250, manufacturer: "Apple",
        productName: "Keyboard", serialNumber: nil, locationID: nil,
        interfaceNumber: 0, interfaceClass: 3, interfaceSubClass: 1, interfaceProtocol: 1,
        interfaceName: nil, endpointCount: 1
    )

    private func options(_ device: FakeMTPDevice?, interfaces: [MTPInterfaceCandidate]? = nil,
                         opens: OpenCounter = OpenCounter()) -> SwiftMTPDiagnostics.Options {
        var options = SwiftMTPDiagnostics.Options()
        let all = interfaces ?? [keyboard, phone]
        options.discover = { all }
        options.open = { _, log in
            opens.increment()
            log("open attempt logged")
            guard let device else { throw MTPTransportError(.exclusiveAccess, "busy") }
            return device
        }
        options.bulkTimeout = 1
        options.sessionID = { 5 }
        return options
    }

    private func seededDevice() -> FakeMTPDevice {
        let device = FakeMTPDevice()
        device.addFolder("DCIM/Camera")
        device.addFolder("Download")
        device.addFile("notes.txt", data: Data("hi".utf8))
        device.addFile("card.jpg", data: Data("x".utf8), storage: 0x20001)
        return device
    }

    func testCompletedRunDescribesTheDeviceAndNeverWritesOrResets() {
        let device = seededDevice()
        let opens = OpenCounter()

        let report = SwiftMTPDiagnostics.run(options: options(device, opens: opens))

        XCTAssertTrue(report.completed, report.text)
        XCTAssertTrue(report.text.hasSuffix(SwiftMTPDiagnostics.completionMarker + "\n"), report.text)
        XCTAssertEqual(opens.value, 1, "The device must be opened exactly once")
        XCTAssertTrue(report.text.contains("class 255/255/0 \"MTP\""), report.text)
        XCTAssertFalse(report.text.contains("Keyboard"), "Unrelated USB devices are not listed")
        XCTAssertTrue(report.text.contains("Model: Fake Phone 5G"))
        XCTAssertTrue(report.text.contains("microsoft.com: 1.0; android.com: 1.0;"))
        XCTAssertTrue(report.text.contains("0x9805 GetObjectPropList"))
        XCTAssertTrue(report.text.contains("\"Internal shared storage\""))
        XCTAssertTrue(report.text.contains("0x00010001: 3 top-level items"), report.text)
        XCTAssertTrue(report.text.contains("2 folders, 1 files among 3 examined"), report.text)
        XCTAssertTrue(report.text.contains("0x00020001: 1 top-level items"), report.text)
        XCTAssertTrue(report.text.contains("open attempt logged"))

        let writes: Set<UInt16> = [PTPOperation.sendObjectInfo, PTPOperation.sendObject,
                                   PTPOperation.deleteObject, PTPOperation.setObjectPropValue]
        XCTAssertTrue(device.commands.allSatisfy { !writes.contains($0.code) },
                      "\(device.commands.map { PTPOperation.name($0.code) })")
        XCTAssertEqual(device.commands.last?.code, PTPOperation.closeSession)
        XCTAssertEqual(device.closeCount, 1)
        XCTAssertFalse(device.sessionOpen)
    }

    func testWithoutPropListFoldersAreCountedPerObject() {
        let device = seededDevice()
        device.supportsPropList = false
        device.deviceInfo.operationsSupported.removeAll { $0 == PTPOperation.getObjectPropList }

        let report = SwiftMTPDiagnostics.run(options: options(device))

        XCTAssertTrue(report.completed, report.text)
        XCTAssertTrue(report.text.contains("Folders counted with GetObjectInfo"))
        XCTAssertTrue(report.text.contains("2 folders, 1 files among 3 examined"), report.text)
    }

    func testNoDeviceIsReportedWithoutOpeningAnything() {
        let opens = OpenCounter()

        let report = SwiftMTPDiagnostics.run(options: options(nil, interfaces: [keyboard], opens: opens))

        XCTAssertFalse(report.completed)
        XCTAssertEqual(opens.value, 0)
        XCTAssertTrue(report.text.contains("no MTP devices found"), report.text)
        XCTAssertTrue(report.text.contains("DIAGNOSTIC incomplete: no single MTP device to open"), report.text)
    }

    func testOpenFailureIsReported() {
        let report = SwiftMTPDiagnostics.run(options: options(nil))

        XCTAssertFalse(report.completed)
        XCTAssertTrue(report.text.contains("ERROR: open: busy"), report.text)
    }

    func testStepFailuresAreCollectedAndTheSessionIsStillClosed() {
        let device = seededDevice()
        device.openSessionFailure = PTPResponseCode.generalError

        let report = SwiftMTPDiagnostics.run(options: options(device))

        XCTAssertFalse(report.completed)
        XCTAssertTrue(report.text.contains("ERROR: OpenSession"), report.text)
        XCTAssertTrue(report.text.contains("DIAGNOSTIC incomplete: OpenSession failed"), report.text)
        XCTAssertEqual(device.closeCount, 1)
    }

    func testCancellationStopsBeforeTheNextStep() {
        let device = seededDevice()
        let cancellation = SwiftMTPDiagnosticsCancellation()
        cancellation.cancel()

        let report = SwiftMTPDiagnostics.run(options: options(device), cancellation: cancellation)

        XCTAssertFalse(report.completed)
        XCTAssertTrue(report.text.contains("cancelled before opening the interface"), report.text)
        XCTAssertTrue(device.commands.isEmpty)
    }

    func testSpentTimeBudgetSkipsLaterSteps() {
        let device = seededDevice()
        var options = options(device)
        options.deadline = 0
        let ticks = Ticker()
        options.clock = { ticks.next() }

        let report = SwiftMTPDiagnostics.run(options: options)

        XCTAssertFalse(report.completed)
        XCTAssertTrue(report.text.contains("time budget"), report.text)
    }
}

final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A clock that advances one second per reading.
final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    func next() -> UInt64 {
        lock.withLock {
            now += 1_000_000_000
            return now
        }
    }
}
