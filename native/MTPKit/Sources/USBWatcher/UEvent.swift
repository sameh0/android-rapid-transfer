#if os(Linux)
import Foundation

/// One device event from the Linux kernel's uevent netlink socket, either as
/// the kernel sends it (group 1) or as udev rebroadcasts it (group 2) after
/// running its rules.
struct UEvent: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case kernel
        case udev
    }

    var source: Source
    var action: String
    var devpath: String
    var properties: [String: String]

    var subsystem: String? { properties["SUBSYSTEM"] }
    var devtype: String? { properties["DEVTYPE"] }
    /// The last DEVPATH component, the sysfs name (`3-2`, `3-2:1.0`, `usb3`).
    var sysfsName: String { devpath.split(separator: "/").last.map(String.init) ?? devpath }
}

enum UEventParser {
    /// udev's `libudev\0` prefix and its big-endian 0xfeedcafe magic.
    static let udevPrefix: [UInt8] = Array("libudev".utf8) + [0]
    static let udevMagic: [UInt8] = [0xFE, 0xED, 0xCA, 0xFE]
    /// prefix(8) + magic, header_size, properties_off, properties_len,
    /// filter_subsystem_hash, filter_devtype_hash, filter_tag_bloom_hi/lo (4 each).
    static let udevHeaderSize = 40

    static func parse(_ bytes: [UInt8]) -> UEvent? {
        if bytes.starts(with: udevPrefix) { return parseUdev(bytes) }
        return parseKernel(bytes)
    }

    /// udev: a fixed header, then NUL-separated KEY=VALUE pairs at
    /// `properties_off`. The header's integers are in host byte order.
    static func parseUdev(_ bytes: [UInt8]) -> UEvent? {
        guard bytes.count >= udevHeaderSize, Array(bytes[8..<12]) == udevMagic else { return nil }
        func hostU32(_ offset: Int) -> Int {
            bytes.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let offset = hostU32(16)
        let length = hostU32(20)
        guard offset >= udevHeaderSize, offset <= bytes.count else { return nil }
        let end = min(bytes.count, offset + length)
        let properties = keyValues(bytes[offset..<end])
        guard let action = properties["ACTION"], let devpath = properties["DEVPATH"] else { return nil }
        return UEvent(source: .udev, action: action, devpath: devpath, properties: properties)
    }

    /// Kernel: `ACTION@DEVPATH\0` then NUL-separated KEY=VALUE pairs.
    static func parseKernel(_ bytes: [UInt8]) -> UEvent? {
        guard let firstNul = bytes.firstIndex(of: 0) else { return nil }
        let head = String(decoding: bytes[..<firstNul], as: UTF8.self)
        guard let at = head.firstIndex(of: "@") else { return nil }
        var properties = keyValues(bytes[(firstNul + 1)...])
        let action = properties["ACTION"] ?? String(head[..<at])
        let devpath = properties["DEVPATH"] ?? String(head[head.index(after: at)...])
        guard !action.isEmpty, devpath.hasPrefix("/") else { return nil }
        properties["ACTION"] = action
        properties["DEVPATH"] = devpath
        return UEvent(source: .kernel, action: action, devpath: devpath, properties: properties)
    }

    private static func keyValues(_ bytes: ArraySlice<UInt8>) -> [String: String] {
        var result: [String: String] = [:]
        for field in bytes.split(separator: 0) {
            guard let equals = field.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: field[field.startIndex..<equals], as: UTF8.self)
            let value = String(decoding: field[(equals + 1)...], as: UTF8.self)
            result[key] = value
        }
        return result
    }

    /// Whether udev's ID_USB_INTERFACES (":060101:ffff00:") lists an image
    /// class (6) interface; nil when the property is absent or empty.
    static func interfacesListImageClass(_ value: String?) -> Bool? {
        guard let value else { return nil }
        let entries: [Substring] = value.split(separator: ":").filter { $0.count == 6 }
        guard !entries.isEmpty else { return nil }
        return entries.contains { (entry: Substring) in entry.hasPrefix("06") }
    }
}

/// Linux USB address helpers the watcher shares in shape with SwiftMTP's
/// discovery (kept separate: the targets do not depend on each other).
enum LinuxUSBLocation {
    /// `3-2.1` → 0x03210000: the bus in the top byte, one hex digit per port,
    /// the same shape as macOS's `locationID`. nil for root hubs and interfaces.
    static func locationID(deviceName: String) -> UInt32? {
        guard !deviceName.contains(":") else { return nil }
        let parts = deviceName.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let bus = Int(parts[0]) else { return nil }
        var ports: [Int] = []
        for piece in parts[1].split(separator: ".", omittingEmptySubsequences: false) {
            guard let port = Int(piece) else { return nil }
            ports.append(port)
        }
        guard !ports.isEmpty else { return nil }
        var value = UInt32(UInt8(truncatingIfNeeded: bus)) << 24
        for (index, port) in ports.prefix(6).enumerated() {
            value |= UInt32(min(port, 15)) << UInt32(20 - 4 * index)
        }
        return value
    }
}
#endif
