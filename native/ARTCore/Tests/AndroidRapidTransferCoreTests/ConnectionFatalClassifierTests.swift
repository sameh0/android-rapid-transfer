import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

final class ConnectionFatalClassifierTests: XCTestCase {
    /// A phone that drops off mid-operation is reported inside that operation's
    /// error type; the libusb disconnect code in the message is what reveals it.
    func testNoDeviceInsideAnOperationErrorMeansTheDeviceIsUnavailable() {
        for type in [MTPErrorType.listDirectory, .fileTransfer, .general, .storageInfo, .deviceInfo] {
            let error = MTPCallError(message: "walk failed: LIBUSB_ERROR_NO_DEVICE", type: type)
            XCTAssertEqual(
                ConnectionFatalClassifier.disposition(for: error), .deviceUnavailable,
                "\(type) carrying LIBUSB_ERROR_NO_DEVICE"
            )
        }
    }

    /// The type-based dispositions keep precedence: a setup failure still asks
    /// for a replug even when the underlying cause was the device vanishing.
    func testTypeBasedDispositionsKeepPrecedenceOverTheMessage() {
        let setup = MTPCallError(
            message: "opening after reset: LIBUSB_ERROR_NO_DEVICE", type: .deviceSetup
        )
        XCTAssertEqual(ConnectionFatalClassifier.disposition(for: setup), .requiresReplug)

        let changed = MTPCallError(message: "ErrorDeviceChanged", type: .deviceChanged)
        XCTAssertEqual(ConnectionFatalClassifier.disposition(for: changed), .deviceUnavailable)
    }

    /// Other libusb failures on a present device are not disconnects. In
    /// particular NOT_FOUND is what an unclaimed interface produces on macOS.
    func testOtherOperationFailuresAreNotFatal() {
        for message in [
            "OpenSession failed: LIBUSB_ERROR_NOT_FOUND",
            "LIBUSB_ERROR_TIMEOUT",
            "LIBUSB_ERROR_IO",
            "File not found: /DCIM/x.jpg",
        ] {
            let error = MTPCallError(message: message, type: .listDirectory)
            XCTAssertNil(ConnectionFatalClassifier.disposition(for: error), message)
        }
    }
}
