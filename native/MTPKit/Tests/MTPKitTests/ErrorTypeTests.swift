import XCTest
@testable import MTPKit

final class ErrorTypeTests: XCTestCase {
    /// The transfer panel shows `rawValue` as a failure's title, so these
    /// strings are user-visible and must not drift.
    func testRawValuesAreStable() {
        let expected: [MTPErrorType: String] = [
            .mtpDetectFailed: "ErrorMtpDetectFailed",
            .deviceChanged: "ErrorDeviceChanged",
            .deviceSetup: "ErrorDeviceSetup",
            .multipleDevice: "ErrorMultipleDevice",
            .allowStorageAccess: "ErrorAllowStorageAccess",
            .deviceLocked: "ErrorDeviceLocked",
            .deviceInfo: "ErrorDeviceInfo",
            .storageInfo: "ErrorStorageInfo",
            .noStorage: "ErrorNoStorage",
            .storageFull: "ErrorStorageFull",
            .listDirectory: "ErrorListDirectory",
            .filePermission: "ErrorFilePermission",
            .localFileRead: "ErrorLocalFileRead",
            .invalidPath: "ErrorInvalidPath",
            .fileTransfer: "ErrorFileTransfer",
            .fileObjectRead: "ErrorFileObjectRead",
            .sendObject: "ErrorSendObject",
            .general: "ErrorGeneral"
        ]
        XCTAssertEqual(Set(expected.keys), Set(MTPErrorType.allCases))
        for (type, rawValue) in expected {
            XCTAssertEqual(type.rawValue, rawValue)
        }
    }

    func testCallErrorDescription() {
        XCTAssertEqual(
            MTPCallError(message: "device is locked", type: .deviceLocked).description,
            "ErrorDeviceLocked: device is locked"
        )
        XCTAssertEqual(MTPCallError(message: "", type: .general).description, "ErrorGeneral")
    }
}
