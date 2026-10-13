import Foundation
import MTPKit
import USBWatcher

struct USBDeviceIdentity: Equatable, Sendable {
    let vendorID: Int?
    let productID: Int?
    let serialNumber: String?
    let productName: String?
    let locationID: UInt64?

    init(event: USBDeviceEvent) {
        vendorID = event.vendorId == 0 ? nil : event.vendorId
        productID = event.productId == 0 ? nil : event.productId
        serialNumber = event.serialNumber
        productName = event.productName
        locationID = event.locationId
    }

    init?(deviceInfo: DeviceInfo) {
        let usb = deviceInfo.usb
        vendorID = usb.vendorID == 0 ? nil : usb.vendorID
        productID = usb.productID == 0 ? nil : usb.productID
        serialNumber = usb.serialNumber.isEmpty ? nil : usb.serialNumber
        productName = usb.product.isEmpty ? nil : usb.product
        // Port location comes only from USBWatcher.
        locationID = nil

        guard vendorID != nil || productID != nil || serialNumber != nil else {
            return nil
        }
    }

    /// The name to show before the phone's MTP model is known: its USB
    /// product string unless generic, else its maker (``DeviceFriendlyName``).
    var friendlyName: String? {
        DeviceFriendlyName.resolve(model: nil, productName: productName, vendorID: vendorID)
    }

    func matches(_ other: USBDeviceIdentity) -> Bool {
        guard !positivelyIdentifiesDifferentDevice(from: other) else { return false }

        if vendorID != nil,
           productID != nil,
           vendorID == other.vendorID,
           productID == other.productID {
            return true
        }

        if let serialNumber, serialNumber == other.serialNumber {
            return true
        }

        // A port match may corroborate a partial identity, but must never be
        // sufficient by itself: replugging into another port is still a match.
        guard let locationID, locationID == other.locationID else { return false }
        return (vendorID != nil && vendorID == other.vendorID)
            || (productID != nil && productID == other.productID)
    }

    func positivelyIdentifiesDifferentDevice(from other: USBDeviceIdentity) -> Bool {
        Self.differs(vendorID, other.vendorID)
            || Self.differs(productID, other.productID)
            || Self.differs(serialNumber, other.serialNumber)
    }

    func merging(_ other: USBDeviceIdentity?) -> USBDeviceIdentity {
        USBDeviceIdentity(
            vendorID: vendorID ?? other?.vendorID,
            productID: productID ?? other?.productID,
            serialNumber: serialNumber ?? other?.serialNumber,
            productName: productName ?? other?.productName,
            locationID: locationID ?? other?.locationID
        )
    }

    private init(
        vendorID: Int?,
        productID: Int?,
        serialNumber: String?,
        productName: String?,
        locationID: UInt64?
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.productName = productName
        self.locationID = locationID
    }

    private static func differs<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }
}
