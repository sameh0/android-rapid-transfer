import Foundation
#if os(macOS)
import IOKit
#endif

/// An MTP-looking USB interface found in the I/O Registry. Discovery reads
/// registry properties only; it opens nothing.
public struct MTPInterfaceCandidate: Equatable, Sendable, CustomStringConvertible {
    public let registryEntryID: UInt64
    public let vendorID: Int
    public let productID: Int
    public let manufacturer: String?
    public let productName: String?
    public let serialNumber: String?
    public let locationID: UInt32?
    public let interfaceNumber: Int
    public let interfaceClass: Int
    public let interfaceSubClass: Int
    public let interfaceProtocol: Int
    public let interfaceName: String?
    public let endpointCount: Int
    /// bcdDevice of the owning USB device (Go's `UsbDeviceInfo.Device`).
    public let deviceRelease: Int

    public init(registryEntryID: UInt64, vendorID: Int, productID: Int, manufacturer: String?,
                productName: String?, serialNumber: String?, locationID: UInt32?,
                interfaceNumber: Int, interfaceClass: Int, interfaceSubClass: Int,
                interfaceProtocol: Int, interfaceName: String?, endpointCount: Int,
                deviceRelease: Int = 0) {
        self.deviceRelease = deviceRelease
        self.registryEntryID = registryEntryID
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = manufacturer
        self.productName = productName
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.interfaceNumber = interfaceNumber
        self.interfaceClass = interfaceClass
        self.interfaceSubClass = interfaceSubClass
        self.interfaceProtocol = interfaceProtocol
        self.interfaceName = interfaceName
        self.endpointCount = endpointCount
    }

    /// No interface string: the device is accepted only if its
    /// DeviceInfo names a Microsoft (or Fujifilm) MTP vendor extension.
    public var needsVendorExtensionCheck: Bool { interfaceName?.isEmpty ?? true }

    public var description: String {
        String(format: "%@ %@ [%04x:%04x] serial %@ iface %d class %d/%d/%d \"%@\"",
               manufacturer ?? "?", productName ?? "?", vendorID, productID, serialNumber ?? "?",
               interfaceNumber, interfaceClass, interfaceSubClass, interfaceProtocol, interfaceName ?? "")
    }
}

/// MTP interface selection: an interface qualifies when it has exactly
/// three endpoints (bulk in, bulk out, interrupt in) and its interface string
/// contains "MTP" (or "CDC"/"ACM" for older Samsung phones). With no interface
/// string the device is kept for a DeviceInfo vendor-extension check. Android
/// reports either class 0xFF/0xFF/0 or PTP class 6/1/1 with the string "MTP";
/// an iPhone's class-6 interface is named "PTP" and is rejected.
public enum MTPInterfaceSelection {
    public static func qualifies(_ c: MTPInterfaceCandidate) -> Bool {
        guard c.endpointCount == 3 else { return false }
        if let name = c.interfaceName, !name.isEmpty {
            return name.contains("MTP") || name.contains("CDC") || name.contains("ACM")
        }
        // No string: only the still-image class is worth a DeviceInfo probe.
        return c.interfaceClass == 6 || c.interfaceClass == 0xFF
    }

    /// A string-less interface is accepted only for these extensions.
    public static func vendorExtensionAcceptable(_ desc: String) -> Bool {
        desc.contains("microsoft/WindowsPhone") || desc.contains("microsoft.com") || desc.contains("fujifilm.co.jp")
    }

    /// Qualifying candidates, ordered so named "MTP" interfaces come first.
    public static func select(_ all: [MTPInterfaceCandidate]) -> [MTPInterfaceCandidate] {
        all.filter(qualifies).sorted { lhs, rhs in
            let l = lhs.interfaceName?.contains("MTP") == true
            let r = rhs.interfaceName?.contains("MTP") == true
            if l != r { return l }
            return lhs.registryEntryID < rhs.registryEntryID
        }
    }
}

#if os(macOS)
public enum USBDeviceDiscovery {
    /// Every IOUSBHostInterface in the registry, described (not opened).
    public static func allInterfaces() -> [MTPInterfaceCandidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [MTPInterfaceCandidate] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let candidate = describe(service) { result.append(candidate) }
        }
        return result
    }

    /// Looks the interface up again by registry ID; the caller releases it.
    static func service(for registryEntryID: UInt64) -> io_service_t? {
        guard let matching = IORegistryEntryIDMatching(registryEntryID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return service == 0 ? nil : service
    }

    static func describe(_ service: io_service_t) -> MTPInterfaceCandidate? {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        /// Device-level properties: the interface first, then its parents
        /// (the IOUSBHostDevice carries the string descriptors).
        func deviceProperty(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        func int(_ key: String) -> Int? { (property(key) as? NSNumber)?.intValue }
        func string(_ key: String) -> String? { property(key) as? String }
        func deviceInt(_ key: String) -> Int? { (deviceProperty(key) as? NSNumber)?.intValue }
        func deviceString(_ keys: String...) -> String? {
            for key in keys { if let value = deviceProperty(key) as? String { return value } }
            return nil
        }
        guard let cls = int("bInterfaceClass") else { return nil }
        return MTPInterfaceCandidate(
            registryEntryID: entryID,
            vendorID: deviceInt("idVendor") ?? 0,
            productID: deviceInt("idProduct") ?? 0,
            manufacturer: deviceString("USB Vendor Name", "kUSBVendorString"),
            productName: deviceString("USB Product Name", "kUSBProductString"),
            serialNumber: deviceString("USB Serial Number", "kUSBSerialNumberString"),
            locationID: deviceInt("locationID").map { UInt32(truncatingIfNeeded: $0) },
            interfaceNumber: int("bInterfaceNumber") ?? 0,
            interfaceClass: cls,
            interfaceSubClass: int("bInterfaceSubClass") ?? 0,
            interfaceProtocol: int("bInterfaceProtocol") ?? 0,
            interfaceName: string("kUSBString") ?? string("USB Interface Name"),
            endpointCount: int("bNumEndpoints") ?? 0,
            deviceRelease: deviceInt("bcdDevice") ?? 0
        )
    }
}
#endif
