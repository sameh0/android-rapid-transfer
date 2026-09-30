#if os(Linux)
import Foundation

/// Address arithmetic for Linux USB devices.
public enum LinuxUSBAddress {
    /// The usbfs node of a device: `/dev/bus/usb/BBB/DDD`.
    public static func deviceNodePath(bus: Int, device: Int, devRoot: String = "/dev/bus/usb") -> String {
        String(format: "%@/%03d/%03d", devRoot, bus, device)
    }

    /// A 64-bit identity for one interface while the device stays enumerated
    /// (Linux reuses no device address until the bus wraps at 127).
    public static func interfaceID(bus: Int, device: Int, interface: Int) -> UInt64 {
        UInt64(UInt16(truncatingIfNeeded: bus)) << 32
            | UInt64(UInt16(truncatingIfNeeded: device)) << 16
            | UInt64(UInt16(truncatingIfNeeded: interface))
    }

    /// Splits a sysfs device name (`3-2`, `1-4.1.3`) into its bus and port
    /// chain. Root hubs (`usb3`) and interfaces (`3-2:1.0`) give nil.
    public static func portChain(_ deviceName: String) -> (bus: Int, ports: [Int])? {
        guard !deviceName.contains(":") else { return nil }
        let parts = deviceName.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let bus = Int(parts[0]) else { return nil }
        var ports: [Int] = []
        for piece in parts[1].split(separator: ".", omittingEmptySubsequences: false) {
            guard let port = Int(piece) else { return nil }
            ports.append(port)
        }
        return ports.isEmpty ? nil : (bus, ports)
    }

    /// A location key shaped like macOS's `locationID`: the bus in the top
    /// byte, then one hex digit per hub port (`3-2.1` → 0x03210000). Ports
    /// above 15 and chains deeper than six hubs are truncated.
    public static func locationID(deviceName: String) -> UInt32? {
        guard let (bus, ports) = portChain(deviceName) else { return nil }
        var value = UInt32(UInt8(truncatingIfNeeded: bus)) << 24
        for (index, port) in ports.prefix(6).enumerated() {
            value |= UInt32(min(port, 15)) << UInt32(20 - 4 * index)
        }
        return value
    }
}

/// Describes every USB interface from sysfs (`/sys/bus/usb/devices`), which
/// is world-readable: discovery needs no device permissions and opens nothing.
public enum SysfsUSBDiscovery {
    public static let defaultRoot = "/sys/bus/usb/devices"

    public static func allInterfaces(root: String = defaultRoot) -> [MTPInterfaceCandidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var result: [MTPInterfaceCandidate] = []
        for name in names.sorted() {
            // Interfaces are "<device>:<config>.<interface>".
            guard let colon = name.firstIndex(of: ":") else { continue }
            let deviceName = String(name[..<colon])
            if let candidate = describe(interface: name, device: deviceName, root: root) {
                result.append(candidate)
            }
        }
        return result
    }

    static func describe(interface name: String, device deviceName: String, root: String) -> MTPInterfaceCandidate? {
        let interfaceDir = root + "/" + name
        let deviceDir = root + "/" + deviceName
        guard let cls = SysfsAttribute.hex(interfaceDir, "bInterfaceClass"),
              let bus = SysfsAttribute.decimal(deviceDir, "busnum"),
              let address = SysfsAttribute.decimal(deviceDir, "devnum") else { return nil }
        let number = SysfsAttribute.hex(interfaceDir, "bInterfaceNumber") ?? 0
        return MTPInterfaceCandidate(
            registryEntryID: LinuxUSBAddress.interfaceID(bus: bus, device: address, interface: number),
            vendorID: SysfsAttribute.hex(deviceDir, "idVendor") ?? 0,
            productID: SysfsAttribute.hex(deviceDir, "idProduct") ?? 0,
            manufacturer: SysfsAttribute.string(deviceDir, "manufacturer"),
            productName: SysfsAttribute.string(deviceDir, "product"),
            serialNumber: SysfsAttribute.string(deviceDir, "serial"),
            locationID: LinuxUSBAddress.locationID(deviceName: deviceName),
            interfaceNumber: number,
            interfaceClass: cls,
            interfaceSubClass: SysfsAttribute.hex(interfaceDir, "bInterfaceSubClass") ?? 0,
            interfaceProtocol: SysfsAttribute.hex(interfaceDir, "bInterfaceProtocol") ?? 0,
            interfaceName: SysfsAttribute.string(interfaceDir, "interface"),
            endpointCount: SysfsAttribute.hex(interfaceDir, "bNumEndpoints") ?? 0,
            deviceRelease: SysfsAttribute.hex(deviceDir, "bcdDevice") ?? 0,
            platformPath: name,
            busNumber: bus,
            deviceAddress: address
        )
    }

    /// The active configuration value of a device (sysfs `bConfigurationValue`).
    public static func activeConfiguration(deviceName: String, root: String = defaultRoot) -> Int? {
        SysfsAttribute.decimal(root + "/" + deviceName, "bConfigurationValue")
    }
}

/// Reads one sysfs attribute file.
enum SysfsAttribute {
    /// The whole file, read with read(2) until EOF (sysfs reports a fake size).
    static func bytes(_ path: String, limit: Int = 1 << 16) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < limit {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }

    static func string(_ directory: String, _ name: String) -> String? {
        guard let bytes = bytes(directory + "/" + name),
              let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func hex(_ directory: String, _ name: String) -> Int? {
        string(directory, name).flatMap { Int($0, radix: 16) }
    }

    static func decimal(_ directory: String, _ name: String) -> Int? {
        string(directory, name).flatMap { Int($0) }
    }
}

extension MTPInterfaceCandidate {
    /// The sysfs device name (`3-2`) behind a Linux candidate.
    public var sysfsDeviceName: String? {
        guard let path = platformPath, let colon = path.firstIndex(of: ":") else { return nil }
        return String(path[..<colon])
    }
}
#endif
