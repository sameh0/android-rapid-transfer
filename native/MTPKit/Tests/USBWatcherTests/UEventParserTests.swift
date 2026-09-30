#if os(Linux)
import Foundation
import XCTest
@testable import USBWatcher

final class UEventParserTests: XCTestCase {
    private let phoneDevpath = "/devices/pci0000:00/0000:00:14.0/usb3/3-2"

    private func properties(_ pairs: [String]) -> [UInt8] {
        pairs.flatMap { Array($0.utf8) + [0] }
    }

    /// A udev monitor message as systemd-udevd sends it on group 2.
    private func udevBlob(_ pairs: [String], magic: [UInt8] = [0xFE, 0xED, 0xCA, 0xFE]) -> [UInt8] {
        let body = properties(pairs)
        func u32(_ value: Int) -> [UInt8] {
            withUnsafeBytes(of: UInt32(value)) { Array($0) } // host byte order
        }
        var blob = Array("libudev".utf8) + [0]
        blob += magic
        blob += u32(40) + u32(40) + u32(body.count)
        blob += u32(0x1234) + u32(0x5678) + u32(0) + u32(0)
        return blob + body
    }

    func testParsesUdevMessage() throws {
        let blob = udevBlob([
            "ACTION=add", "DEVPATH=\(phoneDevpath)", "SUBSYSTEM=usb", "DEVTYPE=usb_device",
            "PRODUCT=2717/ff48/606", "ID_USB_INTERFACES=:060101:ff4201:", "ID_SERIAL_SHORT=10000001",
            "ID_MODEL=REDMI_Note_15_5G", "SEQNUM=4242"
        ])
        let event = try XCTUnwrap(UEventParser.parse(blob))
        XCTAssertEqual(event.source, .udev)
        XCTAssertEqual(event.action, "add")
        XCTAssertEqual(event.devpath, phoneDevpath)
        XCTAssertEqual(event.subsystem, "usb")
        XCTAssertEqual(event.devtype, "usb_device")
        XCTAssertEqual(event.sysfsName, "3-2")
        XCTAssertEqual(event.properties["ID_SERIAL_SHORT"], "10000001")
        XCTAssertEqual(event.properties["SEQNUM"], "4242")
    }

    func testRejectsUdevMessageWithWrongMagicOrShortHeader() {
        let pairs = ["ACTION=add", "DEVPATH=\(phoneDevpath)"]
        XCTAssertNil(UEventParser.parse(udevBlob(pairs, magic: [0xCA, 0xFE, 0xED, 0xFE])))
        XCTAssertNil(UEventParser.parse(Array(udevBlob(pairs).prefix(30))))
    }

    func testRejectsUdevMessageWithoutActionOrDevpath() {
        XCTAssertNil(UEventParser.parse(udevBlob(["SUBSYSTEM=usb"])))
    }

    func testParsesKernelMessage() throws {
        let blob = Array("remove@\(phoneDevpath)".utf8) + [0] + properties([
            "ACTION=remove", "DEVPATH=\(phoneDevpath)", "SUBSYSTEM=usb", "DEVTYPE=usb_device",
            "PRODUCT=2717/ff48/606", "TYPE=0/0/0", "BUSNUM=003", "DEVNUM=010", "SEQNUM=77"
        ])
        let event = try XCTUnwrap(UEventParser.parse(blob))
        XCTAssertEqual(event.source, .kernel)
        XCTAssertEqual(event.action, "remove")
        XCTAssertEqual(event.devpath, phoneDevpath)
        XCTAssertEqual(event.properties["BUSNUM"], "003")
    }

    func testKernelHeaderAloneIsEnough() throws {
        let event = try XCTUnwrap(UEventParser.parse(Array("add@/devices/virtual/foo".utf8) + [0]))
        XCTAssertEqual(event.action, "add")
        XCTAssertEqual(event.devpath, "/devices/virtual/foo")
    }

    func testRejectsGarbage() {
        XCTAssertNil(UEventParser.parse([]))
        XCTAssertNil(UEventParser.parse(Array("no separator here".utf8)))
        XCTAssertNil(UEventParser.parse(Array("add@relative/path".utf8) + [0]))
    }

    func testInterfaceListImageClass() {
        XCTAssertEqual(UEventParser.interfacesListImageClass(":060101:ff4201:"), true)
        XCTAssertEqual(UEventParser.interfacesListImageClass(":ff4201:030102:"), false)
        XCTAssertNil(UEventParser.interfacesListImageClass(nil))
        XCTAssertNil(UEventParser.interfacesListImageClass(":"))
    }

    func testLocationIDMatchesMacShape() {
        XCTAssertEqual(LinuxUSBLocation.locationID(deviceName: "3-2"), 0x0320_0000)
        XCTAssertEqual(LinuxUSBLocation.locationID(deviceName: "1-4.1.3"), 0x0141_3000)
        XCTAssertEqual(LinuxUSBLocation.locationID(deviceName: "2-17"), 0x02F0_0000)
        XCTAssertNil(LinuxUSBLocation.locationID(deviceName: "usb3"))
        XCTAssertNil(LinuxUSBLocation.locationID(deviceName: "3-2:1.0"))
    }

    // MARK: - Events from a sysfs fixture

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uevent-sysfs-\(UUID().uuidString)")
        let device = root.appendingPathComponent("3-2")
        func write(_ dir: URL, _ values: [String: String]) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, value) in values {
                try (value + "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        try write(device, ["idVendor": "2717", "idProduct": "ff48", "serial": "10000001", "product": "REDMI Note 15 5G"])
        try write(device.appendingPathComponent("3-2:1.0"), ["bInterfaceClass": "06", "interface": "MTP"])
        try write(device.appendingPathComponent("3-2:1.1"), ["bInterfaceClass": "ff", "interface": "ADB Interface"])
        return root
    }

    func testAttachEventReadsSysfs() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let event = USBWatcher.attachEvent(name: "3-2", devicePath: root.appendingPathComponent("3-2").path, properties: [:])
        XCTAssertEqual(event, USBDeviceEvent(kind: .attached, vendorId: 0x2717, productId: 0xFF48, serialNumber: "10000001",
                                             productName: "REDMI Note 15 5G", isLikelyMTPDevice: true,
                                             locationId: 0x0320_0000))
    }

    func testAttachEventFallsBackToUeventProperties() {
        let event = USBWatcher.attachEvent(name: "1-4", devicePath: "/nonexistent/1-4", properties: [
            "PRODUCT": "18d1/4ee1/440", "ID_SERIAL_SHORT": "ABC", "ID_MODEL": "Pixel", "ID_USB_INTERFACES": ":ff4201:"
        ])
        XCTAssertEqual(event.vendorId, 0x18D1)
        XCTAssertEqual(event.productId, 0x4EE1)
        XCTAssertEqual(event.serialNumber, "ABC")
        XCTAssertEqual(event.productName, "Pixel")
        XCTAssertEqual(event.isLikelyMTPDevice, false)
        XCTAssertEqual(event.locationId, 0x0140_0000)
    }

    func testDetachEventUsesCachedAttachDetails() {
        let cached = USBDeviceEvent(kind: .attached, vendorId: 0x2717, productId: 0xFF48, serialNumber: "10000001",
                                    productName: "REDMI Note 15 5G", isLikelyMTPDevice: true, locationId: 0x0320_0000)
        let event = USBWatcher.detachEvent(name: "3-2", properties: ["PRODUCT": "2717/ff48/606"], cached: cached)
        XCTAssertEqual(event, USBDeviceEvent(kind: .detached, vendorId: 0x2717, productId: 0xFF48, serialNumber: "10000001",
                                             productName: "REDMI Note 15 5G", isLikelyMTPDevice: true,
                                             locationId: 0x0320_0000))
        let uncached = USBWatcher.detachEvent(name: "3-2", properties: ["PRODUCT": "2717/ff48/606"], cached: nil)
        XCTAssertEqual(uncached.vendorId, 0x2717)
        XCTAssertEqual(uncached.productId, 0xFF48)
        XCTAssertNil(uncached.serialNumber)
        XCTAssertNil(uncached.isLikelyMTPDevice)
    }

    func testReleasingAStartedWatcherStopsIt() throws {
        weak var released: USBWatcher?
        do {
            let watcher = USBWatcher()
            try watcher.start()
            released = watcher
        }
        XCTAssertNil(released, "the watcher thread must not keep the watcher alive")
    }

    func testStartAndStopAreIdempotent() throws {
        let watcher = USBWatcher()
        try watcher.start()
        try watcher.start()
        watcher.stop()
        watcher.stop()
        try watcher.start()
        watcher.stop()
    }
}
#endif
