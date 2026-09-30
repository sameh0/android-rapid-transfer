#if os(Linux)
import Foundation
import XCTest
@testable import SwiftMTP

final class LinuxUSBTests: XCTestCase {
    // MARK: - Descriptors

    private let deviceDescriptor: [UInt8] = [18, 1, 0x00, 0x02, 0, 0, 0, 64, 0x17, 0x27, 0x48, 0xFF, 0x06, 0x06, 1, 2, 3, 1]

    private func endpoint(_ address: UInt8, _ attributes: UInt8, _ mps: Int, interval: UInt8 = 0) -> [UInt8] {
        [7, 5, address, attributes, UInt8(mps & 0xFF), UInt8(mps >> 8), interval]
    }

    private func interface(_ number: UInt8, alt: UInt8 = 0, endpoints: UInt8, cls: UInt8, sub: UInt8, proto: UInt8) -> [UInt8] {
        [9, 4, number, alt, endpoints, cls, sub, proto, 5]
    }

    private func configuration(_ value: UInt8, _ body: [UInt8]) -> [UInt8] {
        let total = 9 + body.count
        return [9, 2, UInt8(total & 0xFF), UInt8(total >> 8), 2, value, 4, 0x80, 250] + body
    }

    /// The phone's layout: MTP (bulk in/out + interrupt in) and ADB.
    private var phoneConfiguration: [UInt8] {
        configuration(1,
            interface(0, endpoints: 3, cls: 6, sub: 1, proto: 1)
            + [6, 0x30, 0, 0, 0, 0] // an unrelated class descriptor in between
            + endpoint(0x81, 2, 512) + endpoint(0x01, 2, 512) + endpoint(0x82, 3, 28, interval: 6)
            + interface(1, endpoints: 2, cls: 0xFF, sub: 0x42, proto: 1)
            + endpoint(0x02, 2, 512) + endpoint(0x83, 2, 512))
    }

    func testParsesPhoneConfiguration() throws {
        let configs = try USBDescriptorParser.configurations(deviceDescriptor + phoneConfiguration)
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].value, 1)
        XCTAssertEqual(configs[0].interfaces.map(\.number), [0, 1])
        XCTAssertEqual(configs[0].interfaces[0].interfaceClass, 6)
        XCTAssertEqual(configs[0].interfaces[0].endpoints.count, 3)
        XCTAssertEqual(configs[0].interfaces[1].endpoints.map(\.address), [0x02, 0x83])
    }

    func testFindsMTPEndpoints() throws {
        let set = try USBDescriptorParser.mtpEndpoints(deviceDescriptor + phoneConfiguration, configurationValue: 1, interfaceNumber: 0)
        XCTAssertEqual(set.bulkIn, USBEndpointDescriptor(address: 0x81, attributes: 2, maxPacketSize: 512))
        XCTAssertEqual(set.bulkOut, USBEndpointDescriptor(address: 0x01, attributes: 2, maxPacketSize: 512))
        XCTAssertEqual(set.interruptIn, USBEndpointDescriptor(address: 0x82, attributes: 3, maxPacketSize: 28, interval: 6))
    }

    func testPicksActiveConfigurationAndMasksHighBandwidthBits() throws {
        let other = configuration(2, interface(0, endpoints: 3, cls: 6, sub: 1, proto: 1)
            + endpoint(0x84, 2, 0x1800 | 64) + endpoint(0x05, 2, 64) + endpoint(0x86, 3, 8))
        let blob = deviceDescriptor + phoneConfiguration + other
        XCTAssertEqual(try USBDescriptorParser.mtpEndpoints(blob, configurationValue: 2, interfaceNumber: 0).bulkIn.address, 0x84)
        XCTAssertEqual(try USBDescriptorParser.mtpEndpoints(blob, configurationValue: 2, interfaceNumber: 0).bulkIn.maxPacketSize, 64)
        // Unknown configuration value: the first one.
        XCTAssertEqual(try USBDescriptorParser.mtpEndpoints(blob, configurationValue: 9, interfaceNumber: 0).bulkIn.address, 0x81)
        XCTAssertEqual(try USBDescriptorParser.mtpEndpoints(blob, configurationValue: nil, interfaceNumber: 0).bulkIn.address, 0x81)
    }

    func testIgnoresAlternateSettings() throws {
        let config = configuration(1,
            interface(0, endpoints: 3, cls: 6, sub: 1, proto: 1)
            + endpoint(0x81, 2, 512) + endpoint(0x01, 2, 512) + endpoint(0x82, 3, 28)
            + interface(0, alt: 1, endpoints: 1, cls: 6, sub: 1, proto: 1) + endpoint(0x85, 2, 512))
        let set = try USBDescriptorParser.mtpEndpoints(deviceDescriptor + config, configurationValue: 1, interfaceNumber: 0)
        XCTAssertEqual(set.bulkIn.address, 0x81)
    }

    func testRejectsMissingEndpointsOrInterface() {
        let adbOnly = configuration(1, interface(0, endpoints: 2, cls: 0xFF, sub: 0x42, proto: 1)
            + endpoint(0x81, 2, 512) + endpoint(0x01, 2, 512))
        XCTAssertThrowsError(try USBDescriptorParser.mtpEndpoints(deviceDescriptor + adbOnly, configurationValue: 1, interfaceNumber: 0))
        XCTAssertThrowsError(try USBDescriptorParser.mtpEndpoints(deviceDescriptor + phoneConfiguration, configurationValue: 1, interfaceNumber: 7))
        XCTAssertThrowsError(try USBDescriptorParser.configurations([1, 2, 3]))
        XCTAssertThrowsError(try USBDescriptorParser.configurations(deviceDescriptor))
    }

    func testTruncatedBlobDoesNotCrash() throws {
        let blob = deviceDescriptor + phoneConfiguration
        for length in 18..<blob.count {
            _ = try? USBDescriptorParser.configurations(Array(blob.prefix(length)))
        }
        XCTAssertThrowsError(try USBDescriptorParser.mtpEndpoints(Array(blob.prefix(40)), configurationValue: 1, interfaceNumber: 0))
    }

    // MARK: - Addresses

    func testAddresses() {
        XCTAssertEqual(LinuxUSBAddress.deviceNodePath(bus: 3, device: 10), "/dev/bus/usb/003/010")
        XCTAssertEqual(LinuxUSBAddress.interfaceID(bus: 3, device: 10, interface: 1), 0x0003_000A_0001)
        XCTAssertEqual(LinuxUSBAddress.locationID(deviceName: "3-2"), 0x0320_0000)
        XCTAssertEqual(LinuxUSBAddress.locationID(deviceName: "1-4.1.3"), 0x0141_3000)
        XCTAssertNil(LinuxUSBAddress.locationID(deviceName: "usb3"))
        XCTAssertNil(LinuxUSBAddress.portChain("3-2:1.0"))
        XCTAssertNil(LinuxUSBAddress.portChain("3-x"))
    }

    // MARK: - sysfs discovery

    private func write(_ dir: URL, _ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, value) in values {
            try (value + "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// /sys/bus/usb/devices as flat entries: a root hub, the phone, its MTP
    /// and ADB interfaces, and a keyboard.
    private func makeSysfsFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sysfs-\(UUID().uuidString)")
        try write(root.appendingPathComponent("usb3"), ["busnum": "3", "devnum": "1", "idVendor": "1d6b", "idProduct": "0002"])
        try write(root.appendingPathComponent("3-0:1.0"), ["bInterfaceClass": "09", "bInterfaceNumber": "00", "bNumEndpoints": "01"])
        try write(root.appendingPathComponent("3-2"), [
            "busnum": "3", "devnum": "10", "idVendor": "2717", "idProduct": "ff48", "manufacturer": "Xiaomi",
            "product": "REDMI Note 15 5G", "serial": "10000001", "bcdDevice": "0606", "bConfigurationValue": "1"
        ])
        try write(root.appendingPathComponent("3-2:1.0"), [
            "bInterfaceNumber": "00", "bInterfaceClass": "06", "bInterfaceSubClass": "01", "bInterfaceProtocol": "01",
            "bNumEndpoints": "03", "interface": "MTP"
        ])
        try write(root.appendingPathComponent("3-2:1.1"), [
            "bInterfaceNumber": "01", "bInterfaceClass": "ff", "bInterfaceSubClass": "42", "bInterfaceProtocol": "01",
            "bNumEndpoints": "02", "interface": "ADB Interface"
        ])
        try write(root.appendingPathComponent("1-4.2"), ["busnum": "1", "devnum": "5", "idVendor": "046d", "idProduct": "c31c"])
        try write(root.appendingPathComponent("1-4.2:1.0"), [
            "bInterfaceNumber": "00", "bInterfaceClass": "03", "bInterfaceSubClass": "01", "bInterfaceProtocol": "01",
            "bNumEndpoints": "01"
        ])
        return root
    }

    func testSysfsDiscoveryDescribesInterfaces() throws {
        let root = try makeSysfsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = SysfsUSBDiscovery.allInterfaces(root: root.path)
        // A root hub's interface (3-0:1.0) has no "3-0" device entry: skipped.
        XCTAssertEqual(all.map { $0.platformPath ?? "" }, ["1-4.2:1.0", "3-2:1.0", "3-2:1.1"])

        let mtp = try XCTUnwrap(all.first { $0.platformPath == "3-2:1.0" })
        XCTAssertEqual(mtp, MTPInterfaceCandidate(
            registryEntryID: LinuxUSBAddress.interfaceID(bus: 3, device: 10, interface: 0),
            vendorID: 0x2717, productID: 0xFF48, manufacturer: "Xiaomi", productName: "REDMI Note 15 5G",
            serialNumber: "10000001", locationID: 0x0320_0000, interfaceNumber: 0, interfaceClass: 6,
            interfaceSubClass: 1, interfaceProtocol: 1, interfaceName: "MTP", endpointCount: 3,
            deviceRelease: 0x0606, platformPath: "3-2:1.0", busNumber: 3, deviceAddress: 10))
        XCTAssertEqual(mtp.sysfsDeviceName, "3-2")
        XCTAssertEqual(SysfsUSBDiscovery.activeConfiguration(deviceName: "3-2", root: root.path), 1)

        let selected = MTPInterfaceSelection.select(all)
        XCTAssertEqual(selected.map(\.platformPath), ["3-2:1.0"])
        XCTAssertNoThrow(try MTPDeviceOpener.choose(selected))
    }

    func testSysfsDiscoveryOfMissingRootIsEmpty() {
        XCTAssertEqual(SysfsUSBDiscovery.allInterfaces(root: "/nonexistent/sysfs"), [])
    }

    // MARK: - errno mapping

    func testErrnoMapping() {
        XCTAssertEqual(UsbfsErrno.kind(ENODEV), .noDevice)
        XCTAssertEqual(UsbfsErrno.kind(ESHUTDOWN), .noDevice)
        XCTAssertEqual(UsbfsErrno.kind(ETIMEDOUT), .timeout)
        XCTAssertEqual(UsbfsErrno.kind(EPIPE), .stall)
        XCTAssertEqual(UsbfsErrno.kind(EBUSY), .exclusiveAccess)
        XCTAssertEqual(UsbfsErrno.kind(EACCES), .notPermitted)
        XCTAssertEqual(UsbfsErrno.kind(EPERM), .notPermitted)
        XCTAssertEqual(UsbfsErrno.kind(ENOENT), .aborted)
        XCTAssertEqual(UsbfsErrno.kind(EPROTO), .io)
        let error = UsbfsErrno.error(EPIPE, "bulk read")
        XCTAssertEqual(error.kind, .stall)
        XCTAssertEqual(error.status, EPIPE)
        XCTAssertEqual(error.description, "bulk read: Broken pipe (stall, errno \(EPIPE))")
    }

    // MARK: - Holder diagnostics

    private func makeProcFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proc-\(UUID().uuidString)")
        func process(_ pid: Int32, _ comm: String, links: [String]) throws {
            let dir = root.appendingPathComponent(String(pid))
            let fd = dir.appendingPathComponent("fd")
            try FileManager.default.createDirectory(at: fd, withIntermediateDirectories: true)
            try (comm + "\n").write(to: dir.appendingPathComponent("comm"), atomically: true, encoding: .utf8)
            for (index, target) in links.enumerated() {
                try FileManager.default.createSymbolicLink(atPath: fd.appendingPathComponent(String(index + 3)).path,
                                                           withDestinationPath: target)
            }
        }
        try process(1200, "gvfsd-mtp", links: ["/dev/null", "/dev/bus/usb/003/010"])
        try process(900, "adb", links: ["/dev/bus/usb/003/010", "socket:[1234]"])
        try process(77, "bash", links: ["/dev/pts/0", "/dev/bus/usb/003/011"])
        try process(4242, "self", links: ["/dev/bus/usb/003/010"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("self"), withIntermediateDirectories: true)
        return root
    }

    func testFindsHoldersExcludingSelf() throws {
        let root = try makeProcFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let holders = USBDeviceHolder.find(bus: 3, dev: 10, procRoot: root.path, excludingPID: 4242)
        XCTAssertEqual(holders, [USBDeviceHolder.Process(pid: 900, command: "adb"),
                                 USBDeviceHolder.Process(pid: 1200, command: "gvfsd-mtp")])
        XCTAssertEqual(USBDeviceHolder.busyMessage(holders), "GNOME Files (gvfsd-mtp), pid 1200 is using the phone")
    }

    func testBusyMessageNamesADBOnlyWhenAlone() {
        let adb = USBDeviceHolder.Process(pid: 900, command: "adb")
        XCTAssertEqual(USBDeviceHolder.busyMessage([adb]), "adb (pid 900) is using the phone")
        XCTAssertNil(USBDeviceHolder.busyMessage([]))
        let two = [USBDeviceHolder.Process(pid: 5, command: "mtp-probe"), USBDeviceHolder.Process(pid: 6, command: "kiod6")]
        XCTAssertEqual(USBDeviceHolder.busyMessage(two),
                       "mtp-probe (pid 5), KDE's device service (kiod6), pid 6 are using the phone")
    }

    func testPermissionReport() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("node-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        chmod(file.path, 0o600)
        let readable = USBDeviceNodeDiagnostics.permissionReport(path: file.path)
        XCTAssertTrue(readable.contains("mode 0600"), readable)
        XCTAssertTrue(readable.contains("has read-write access"), readable)
        if getuid() != 0 {
            chmod(file.path, 0o444)
            let denied = USBDeviceNodeDiagnostics.permissionReport(path: file.path)
            XCTAssertTrue(denied.contains("mode 0444"), denied)
            XCTAssertTrue(denied.contains("has no read-write access"), denied)
        }
        XCTAssertTrue(USBDeviceNodeDiagnostics.permissionReport(path: "/nonexistent/node").contains("No such file"))
    }
}
#endif
