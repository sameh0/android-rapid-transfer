import Foundation
import XCTest
@testable import USBWatcher

final class USBDeviceEventTests: XCTestCase {
    func testMapsDevicePropertiesAndImageClassInterface() {
        let event = USBDeviceEvent.make(
            kind: .attached,
            deviceProperties: [
                "idVendor": NSNumber(value: 0x18D1),
                "idProduct": NSNumber(value: 0x4EE1),
                "locationID": NSNumber(value: 0x0012_0000),
                "USB Serial Number": "ABC123",
                "USB Product Name": "Pixel"
            ],
            interfaceProperties: [["bInterfaceClass": NSNumber(value: 6)]]
        )

        XCTAssertEqual(event.kind, .attached)
        XCTAssertEqual(event.vendorId, 0x18D1)
        XCTAssertEqual(event.productId, 0x4EE1)
        XCTAssertEqual(event.serialNumber, "ABC123")
        XCTAssertEqual(event.productName, "Pixel")
        XCTAssertEqual(event.locationId, 0x0012_0000)
        XCTAssertEqual(event.isLikelyMTPDevice, true)
    }

    func testInterfaceNameMatchingIsCaseInsensitive() {
        let event = USBDeviceEvent.make(
            kind: .detached,
            deviceProperties: ["idVendor": "1452", "idProduct": 7],
            interfaceProperties: [["kUSBString": "vendor mtp interface"]]
        )

        XCTAssertEqual(event.kind, .detached)
        XCTAssertEqual(event.vendorId, 1452)
        XCTAssertEqual(event.productId, 7)
        XCTAssertEqual(event.isLikelyMTPDevice, true)
    }

    func testEnumeratedNonMTPInterfaceMapsFalse() {
        let event = USBDeviceEvent.make(
            kind: .attached,
            deviceProperties: [:],
            interfaceProperties: [[
                "bInterfaceClass": NSNumber(value: 8),
                "USB Interface Name": "Mass Storage"
            ]]
        )

        XCTAssertEqual(event.vendorId, 0)
        XCTAssertEqual(event.productId, 0)
        XCTAssertEqual(event.isLikelyMTPDevice, false)
    }

    func testUnavailableInterfaceEnumerationMapsUnknown() {
        let event = USBDeviceEvent.make(
            kind: .attached,
            deviceProperties: [:],
            interfaceProperties: nil
        )

        XCTAssertNil(event.isLikelyMTPDevice)
    }
}
