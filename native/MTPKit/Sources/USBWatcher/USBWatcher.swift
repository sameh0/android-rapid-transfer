#if os(macOS)
import Dispatch
import Foundation
import IOKit

private final class USBNotificationContext: @unchecked Sendable {
    weak var watcher: USBWatcher?
    let kind: USBDeviceEvent.Kind

    init(watcher: USBWatcher, kind: USBDeviceEvent.Kind) {
        self.watcher = watcher
        self.kind = kind
    }
}

public enum USBWatcherError: Error, Equatable, Sendable {
    case notificationPortCreationFailed
    case matchingDictionaryCreationFailed(serviceClass: String)
    case notificationRegistrationFailed(serviceClass: String, kind: USBDeviceEvent.Kind, code: Int32)
}

/// Watches macOS's I/O Registry for USB device attachment and termination.
///
/// USB watching is a separate SwiftPM library target because it is an OS-level
/// integration boundary independent of the MTP provider API. Keeping it
/// separate also lets the `usb-watch` diagnostic executable avoid linking the
/// MTP code.
///
/// Notifications and registry reads run on a dedicated serial dispatch queue.
/// Both legacy `IOUSBDevice` and modern `IOUSBHostDevice` service classes are
/// registered to cover the macOS versions the app supports.
public final class USBWatcher: @unchecked Sendable {
    public let events: AsyncStream<USBDeviceEvent>

    private static let serviceClasses = ["IOUSBDevice", "IOUSBHostDevice"]
    private static let devicePropertyKeys = [
        "idVendor",
        "idProduct",
        "locationID",
        "USB Serial Number",
        "USB Product Name"
    ]
    private static let interfacePropertyKeys = [
        "bInterfaceClass",
        "kUSBString",
        "USB Interface Name",
        "Interface Name"
    ]

    private let queue = DispatchQueue(label: "USBWatcher")
    private let continuation: AsyncStream<USBDeviceEvent>.Continuation
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var callbackContexts: [USBNotificationContext] = []
    private var cachedEvents: [UInt64: USBDeviceEvent] = [:]

    public init() {
        let pair = AsyncStream<USBDeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        stop()
        continuation.finish()
    }

    /// Starts watching. Calling this while already started has no effect.
    public func start() throws {
        try queue.sync {
            guard notificationPort == nil else { return }
            try startOnQueue()
        }
    }

    /// Stops watching and releases all IOKit registrations.
    /// Calling this while already stopped has no effect. The event stream stays
    /// open so the same watcher can be started again.
    public func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func startOnQueue() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw USBWatcherError.notificationPortCreationFailed
        }

        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        do {
            for serviceClass in Self.serviceClasses {
                try register(
                    serviceClass: serviceClass,
                    notification: kIOFirstMatchNotification,
                    kind: .attached,
                    port: port
                )
                try register(
                    serviceClass: serviceClass,
                    notification: kIOTerminatedNotification,
                    kind: .detached,
                    port: port
                )
            }
        } catch {
            stopOnQueue()
            throw error
        }
    }

    private func stopOnQueue() {
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        iterators.removeAll()

        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }

        callbackContexts.removeAll()
        cachedEvents.removeAll()
    }

    private func register(
        serviceClass: String,
        notification: String,
        kind: USBDeviceEvent.Kind,
        port: IONotificationPortRef
    ) throws {
        guard let matching = IOServiceMatching(serviceClass) else {
            throw USBWatcherError.matchingDictionaryCreationFailed(serviceClass: serviceClass)
        }

        let callbackContext = USBNotificationContext(watcher: self, kind: kind)
        callbackContexts.append(callbackContext)

        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            notification,
            matching,
            { opaqueContext, iterator in
                guard let opaqueContext else { return }
                let context = Unmanaged<USBNotificationContext>
                    .fromOpaque(opaqueContext)
                    .takeUnretainedValue()
                context.watcher?.drain(iterator: iterator, kind: context.kind)
            },
            Unmanaged.passUnretained(callbackContext).toOpaque(),
            &iterator
        )

        guard result == KERN_SUCCESS else {
            callbackContexts.removeLast()
            throw USBWatcherError.notificationRegistrationFailed(
                serviceClass: serviceClass,
                kind: kind,
                code: result
            )
        }

        iterators.append(iterator)
        drain(iterator: iterator, kind: kind)
    }

    private func drain(iterator: io_iterator_t, kind: USBDeviceEvent.Kind) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            let registryID = registryID(for: service)
            let properties = Self.deviceProperties(for: service)
            let interfaces = Self.interfaceProperties(for: service)
            var event = USBDeviceEvent.make(
                kind: kind,
                deviceProperties: properties,
                interfaceProperties: interfaces
            )

            if kind == .attached {
                if let registryID {
                    cachedEvents[registryID] = event
                }
            } else if let registryID, let cached = cachedEvents.removeValue(forKey: registryID) {
                event = USBDeviceEvent(
                    kind: .detached,
                    vendorId: properties["idVendor"] == nil ? cached.vendorId : event.vendorId,
                    productId: properties["idProduct"] == nil ? cached.productId : event.productId,
                    serialNumber: event.serialNumber ?? cached.serialNumber,
                    productName: event.productName ?? cached.productName,
                    isLikelyMTPDevice: event.isLikelyMTPDevice ?? cached.isLikelyMTPDevice,
                    locationId: event.locationId ?? cached.locationId
                )
            }

            continuation.yield(event)
        }
    }

    private func registryID(for service: io_service_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else {
            return nil
        }
        return identifier
    }

    private static func deviceProperties(for service: io_service_t) -> [String: Any] {
        properties(keys: devicePropertyKeys, for: service)
    }

    private static func interfaceProperties(for service: io_service_t) -> [[String: Any]]? {
        var iterator: io_iterator_t = 0
        let result = IORegistryEntryCreateIterator(
            service,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var interfaces: [[String: Any]] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            let properties = properties(keys: interfacePropertyKeys, for: child)
            if properties["bInterfaceClass"] != nil ||
                properties["kUSBString"] != nil ||
                properties["USB Interface Name"] != nil ||
                properties["Interface Name"] != nil {
                interfaces.append(properties)
            }
        }

        // A successfully-created recursive iterator can still expose no USB
        // interfaces from a device node, depending on driver ownership/layout.
        return interfaces.isEmpty ? nil : interfaces
    }

    private static func properties(
        keys: [String],
        for entry: io_registry_entry_t
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            if let value = IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() {
                result[key] = value
            }
        }
        return result
    }
}
#endif
