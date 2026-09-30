#if os(Linux)
import Foundation

/// One endpoint descriptor (USB 2.0 §9.6.6).
public struct USBEndpointDescriptor: Equatable, Sendable {
    public var address: UInt8
    public var attributes: UInt8
    /// wMaxPacketSize bits 0–10 (the packet size; high-bandwidth bits dropped).
    public var maxPacketSize: Int
    public var interval: UInt8

    public init(address: UInt8, attributes: UInt8, maxPacketSize: Int, interval: UInt8 = 0) {
        self.address = address
        self.attributes = attributes
        self.maxPacketSize = maxPacketSize
        self.interval = interval
    }

    public var isIn: Bool { address & 0x80 != 0 }
    /// 0 control, 1 isochronous, 2 bulk, 3 interrupt.
    public var transferType: UInt8 { attributes & 0x03 }
}

/// One interface alternate setting with its endpoints.
public struct USBInterfaceDescriptor: Equatable, Sendable {
    public var number: Int
    public var alternateSetting: Int
    public var interfaceClass: Int
    public var interfaceSubClass: Int
    public var interfaceProtocol: Int
    public var endpoints: [USBEndpointDescriptor]
}

/// One configuration with every interface alternate setting in it.
public struct USBConfigurationDescriptor: Equatable, Sendable {
    public var value: Int
    public var interfaces: [USBInterfaceDescriptor]
}

/// The bulk-in, bulk-out and interrupt-in endpoints an MTP interface needs.
public struct MTPEndpointSet: Equatable, Sendable {
    public var bulkIn: USBEndpointDescriptor
    public var bulkOut: USBEndpointDescriptor
    public var interruptIn: USBEndpointDescriptor
}

public struct USBDescriptorError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Parses the raw descriptor blob usbfs returns from `read(2)` on
/// `/dev/bus/usb/BBB/DDD` (and sysfs `descriptors`): the 18-byte device
/// descriptor followed by one or more complete configuration descriptors.
public enum USBDescriptorParser {
    static let deviceType: UInt8 = 1
    static let configurationType: UInt8 = 2
    static let interfaceType: UInt8 = 4
    static let endpointType: UInt8 = 5

    public static func configurations(_ bytes: [UInt8]) throws -> [USBConfigurationDescriptor] {
        guard bytes.count >= 18, bytes[1] == deviceType else {
            throw USBDescriptorError("descriptor blob does not start with a device descriptor")
        }
        var offset = Int(bytes[0])
        guard offset >= 18 else { throw USBDescriptorError("device descriptor length \(offset) is too short") }
        var result: [USBConfigurationDescriptor] = []
        while offset + 9 <= bytes.count {
            let length = Int(bytes[offset])
            guard length >= 2 else { break }
            guard bytes[offset + 1] == configurationType else {
                // Not a configuration header: skip this descriptor.
                offset += length
                continue
            }
            let total = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
            let end = min(bytes.count, offset + max(total, length))
            result.append(parseConfiguration(bytes, from: offset, to: end))
            offset = end
        }
        guard !result.isEmpty else { throw USBDescriptorError("no configuration descriptor") }
        return result
    }

    private static func parseConfiguration(_ bytes: [UInt8], from start: Int, to end: Int) -> USBConfigurationDescriptor {
        var config = USBConfigurationDescriptor(value: Int(bytes[start + 5]), interfaces: [])
        var offset = start + Int(bytes[start])
        while offset + 2 <= end {
            let length = Int(bytes[offset])
            guard length >= 2, offset + length <= end else { break }
            switch bytes[offset + 1] {
            case interfaceType where length >= 9:
                config.interfaces.append(USBInterfaceDescriptor(
                    number: Int(bytes[offset + 2]), alternateSetting: Int(bytes[offset + 3]),
                    interfaceClass: Int(bytes[offset + 5]), interfaceSubClass: Int(bytes[offset + 6]),
                    interfaceProtocol: Int(bytes[offset + 7]), endpoints: []))
            case endpointType where length >= 7:
                if !config.interfaces.isEmpty {
                    let raw = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                    config.interfaces[config.interfaces.count - 1].endpoints.append(USBEndpointDescriptor(
                        address: bytes[offset + 2], attributes: bytes[offset + 3],
                        maxPacketSize: raw & 0x7FF, interval: bytes[offset + 6]))
                }
            default:
                break
            }
            offset += length
        }
        return config
    }

    /// The MTP endpoints of interface `interfaceNumber` (alternate setting 0)
    /// in the configuration `configurationValue` (the first one when nil or
    /// not found).
    public static func mtpEndpoints(_ bytes: [UInt8], configurationValue: Int?,
                                    interfaceNumber: Int) throws -> MTPEndpointSet {
        let configs = try configurations(bytes)
        let config = configs.first { $0.value == configurationValue } ?? configs[0]
        guard let interface = config.interfaces.first(where: { $0.number == interfaceNumber && $0.alternateSetting == 0 }) else {
            throw USBDescriptorError("configuration \(config.value) has no interface \(interfaceNumber)")
        }
        var bulkIn: USBEndpointDescriptor?, bulkOut: USBEndpointDescriptor?, interruptIn: USBEndpointDescriptor?
        for endpoint in interface.endpoints {
            switch (endpoint.transferType, endpoint.isIn) {
            case (2, true): bulkIn = endpoint
            case (2, false): bulkOut = endpoint
            case (3, true): interruptIn = endpoint
            default: break
            }
        }
        guard let bulkIn, let bulkOut, let interruptIn else {
            throw USBDescriptorError(String(format: "interface lacks bulk-in/bulk-out/interrupt-in endpoints (0x%02x/0x%02x/0x%02x)",
                                            bulkIn?.address ?? 0, bulkOut?.address ?? 0, interruptIn?.address ?? 0))
        }
        return MTPEndpointSet(bulkIn: bulkIn, bulkOut: bulkOut, interruptIn: interruptIn)
    }
}
#endif
