import Foundation

/// A USB device lifecycle event emitted by ``USBWatcher``.
public struct USBDeviceEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case attached
        case detached
    }

    public let kind: Kind
    public let vendorId: Int
    public let productId: Int
    public let serialNumber: String?
    public let productName: String?
    public let locationId: UInt64?

    /// Whether an enumerated interface looks like PTP/MTP.
    ///
    /// This is `true` when any interface has USB image class 6 or an interface
    /// name containing "MTP", and `false` when interfaces were enumerated but
    /// none matched. It is `nil` when interface descendants could not be
    /// enumerated from the device registry node. Callers must not interpret
    /// `nil` as proof that a device is not MTP-capable.
    public let isLikelyMTPDevice: Bool?

    public init(
        kind: Kind,
        vendorId: Int,
        productId: Int,
        serialNumber: String?,
        productName: String?,
        isLikelyMTPDevice: Bool?,
        locationId: UInt64? = nil
    ) {
        self.kind = kind
        self.vendorId = vendorId
        self.productId = productId
        self.serialNumber = serialNumber
        self.productName = productName
        self.isLikelyMTPDevice = isLikelyMTPDevice
        self.locationId = locationId
    }
}

extension USBDeviceEvent {
    static func make(
        kind: Kind,
        deviceProperties: [String: Any],
        interfaceProperties: [[String: Any]]?
    ) -> USBDeviceEvent {
        USBDeviceEvent(
            kind: kind,
            vendorId: integer(from: deviceProperties["idVendor"]) ?? 0,
            productId: integer(from: deviceProperties["idProduct"]) ?? 0,
            serialNumber: string(from: deviceProperties["USB Serial Number"]),
            productName: string(from: deviceProperties["USB Product Name"]),
            isLikelyMTPDevice: likelyMTP(from: interfaceProperties),
            locationId: integer(from: deviceProperties["locationID"]).map(UInt64.init)
        )
    }

    private static func likelyMTP(from interfaces: [[String: Any]]?) -> Bool? {
        guard let interfaces else { return nil }

        let nameKeys = ["kUSBString", "USB Interface Name", "Interface Name"]
        return interfaces.contains { properties in
            if integer(from: properties["bInterfaceClass"]) == 6 {
                return true
            }

            return nameKeys.contains { key in
                string(from: properties[key])?
                    .localizedCaseInsensitiveContains("MTP") == true
            }
        }
    }

    private static func integer(from value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        case let value as String:
            Int(value)
        default:
            nil
        }
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let value as String:
            value
        case let value as NSString:
            value as String
        default:
            nil
        }
    }
}
