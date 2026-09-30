#if !os(macOS)
import Foundation
#if os(Linux)
import CUsbfs
#endif

public enum USBWatcherError: Error, Equatable, Sendable {
    case notificationPortCreationFailed
    /// The uevent netlink socket could not be created or bound (errno).
    case netlinkSocketFailed(errno: Int32)
}

#if os(Linux)
/// Watches Linux USB hotplug through a raw `NETLINK_KOBJECT_UEVENT` socket
/// (no libudev). It listens on udev's multicast group when udev runs, so an
/// attach arrives after udev's rules (and their device-node permissions)
/// have been applied, and on the kernel's group otherwise.
///
/// `start()` first reports every USB device already present as `.attached`,
/// as the macOS watcher does. Detach events carry the details cached at
/// attach time (sysfs is gone by then). A background thread owns the socket.
public final class USBWatcher: @unchecked Sendable {
    public let events: AsyncStream<USBDeviceEvent>
    private let continuation: AsyncStream<USBDeviceEvent>.Continuation

    static let netlinkKobjectUevent: Int32 = 15
    static let kernelGroup: UInt32 = 1
    static let udevGroup: UInt32 = 2

    private let sysfsRoot: String
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var wakeFDs: (read: Int32, write: Int32) = (-1, -1)
    private var thread: Thread?
    private var finished: DispatchSemaphore?
    /// Attached devices by DEVPATH-derived sysfs name.
    private var attached: [String: USBDeviceEvent] = [:]

    public init() {
        self.sysfsRoot = "/sys"
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
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }

        let fd = socket(AF_NETLINK, Int32(SOCK_RAW.rawValue) | Int32(SOCK_CLOEXEC.rawValue) | Int32(SOCK_NONBLOCK.rawValue),
                        Self.netlinkKobjectUevent)
        guard fd >= 0 else { throw USBWatcherError.netlinkSocketFailed(errno: errno) }
        var bufferSize: Int32 = 1 << 20
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        let group = FileManager.default.fileExists(atPath: "/run/udev/control") ? Self.udevGroup : Self.kernelGroup
        if cusbfs_netlink_bind(fd, group) != 0 {
            let code = errno
            Glibc.close(fd)
            throw USBWatcherError.netlinkSocketFailed(errno: code)
        }
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let code = errno
            Glibc.close(fd)
            throw USBWatcherError.netlinkSocketFailed(errno: code)
        }
        for end in pipeFDs {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
        }
        socketFD = fd
        wakeFDs = (pipeFDs[0], pipeFDs[1])

        // The socket is bound before the scan, so nothing is missed; an add
        // for a device the scan already reported is dropped as a duplicate.
        for name in Self.presentDevices(sysfsRoot: sysfsRoot) {
            let event = Self.attachEvent(name: name, devicePath: "\(sysfsRoot)/bus/usb/devices/\(name)", properties: [:])
            attached[name] = event
            continuation.yield(event)
        }

        let done = DispatchSemaphore(value: 0)
        finished = done
        let wake = wakeFDs
        // The thread owns the three descriptors and closes them when it exits,
        // which happens only once stop() has written to the wake pipe. It
        // holds the watcher weakly, so dropping the last reference still runs
        // deinit (which stops the thread).
        let thread = Thread { [weak self] in
            Self.run(socket: fd, wake: wake.read) { event in self?.handle(event) }
            Glibc.close(fd)
            Glibc.close(wake.read)
            Glibc.close(wake.write)
            done.signal()
        }
        thread.name = "USBWatcher"
        self.thread = thread
        thread.start()
    }

    /// Stops watching and closes the socket. Calling this while already
    /// stopped has no effect. The event stream stays open so the same watcher
    /// can be started again.
    public func stop() {
        lock.lock()
        guard let running = thread else {
            lock.unlock()
            return
        }
        let wake = wakeFDs, done = finished
        thread = nil
        finished = nil
        socketFD = -1
        wakeFDs = (-1, -1)
        attached.removeAll()
        lock.unlock()

        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
        // Stopped from the watcher thread itself (a handler dropped the last
        // reference): it exits after this event, so don't wait for it.
        if Thread.current !== running { done?.wait() }
    }

    /// Reads uevents until the wake pipe becomes readable (its only exit).
    private static func run(socket fd: Int32, wake: Int32, handle: (UEvent) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno != EINTR { usleep(100_000) }
                continue
            }
            if fds[1].revents != 0 { return }
            // POLLERR (a receive-buffer overrun) is cleared by the next recv.
            guard fds[0].revents != 0 else { continue }
            while true {
                var sender = sockaddr_nl()
                var senderLength = socklen_t(MemoryLayout<sockaddr_nl>.size)
                let n = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &sender) { address in
                        address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &senderLength)
                        }
                    }
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    break // EAGAIN (drained) or ENOBUFS (overrun: later events still arrive)
                }
                guard n > 0, let event = UEventParser.parse(Array(buffer[0..<n])) else { continue }
                // Kernel messages come from port 0; udev's from its own port.
                // Anything else on the kernel group is not from the kernel.
                if event.source == .kernel, sender.nl_pid != 0 { continue }
                if event.source == .udev, sender.nl_pid == 0 { continue }
                handle(event)
            }
        }
    }

    private func handle(_ event: UEvent) {
        guard event.subsystem == "usb", event.devtype == "usb_device" else { return }
        let name = event.sysfsName
        guard LinuxUSBLocation.locationID(deviceName: name) != nil else { return } // root hubs
        switch event.action {
        case "add":
            let alreadyKnown = lock.withLock { attached[name] != nil }
            if alreadyKnown { return }
            let result = Self.attachEvent(name: name, devicePath: sysfsRoot + event.devpath, properties: event.properties)
            lock.withLock { attached[name] = result }
            continuation.yield(result)
        case "remove":
            let cached = lock.withLock { attached.removeValue(forKey: name) }
            continuation.yield(Self.detachEvent(name: name, properties: event.properties, cached: cached))
        default:
            break
        }
    }

    // MARK: - sysfs

    /// USB devices (not root hubs, not interfaces) under /sys/bus/usb/devices.
    static func presentDevices(sysfsRoot: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "\(sysfsRoot)/bus/usb/devices")) ?? []
        return names.filter { LinuxUSBLocation.locationID(deviceName: $0) != nil }.sorted()
    }

    /// An attach event from sysfs, with the uevent's properties as fallback.
    static func attachEvent(name: String, devicePath: String, properties: [String: String]) -> USBDeviceEvent {
        var product = properties["PRODUCT"].map { $0.split(separator: "/").map { Int($0, radix: 16) ?? 0 } } ?? []
        while product.count < 2 { product.append(0) }
        var likelyMTP = interfacesLikelyMTP(devicePath: devicePath, name: name)
        if likelyMTP == nil {
            likelyMTP = UEventParser.interfacesListImageClass(properties["ID_USB_INTERFACES"])
        }
        if likelyMTP == nil, !properties.isEmpty {
            // A kernel add arrives before the interfaces are registered: give
            // them a moment to appear.
            for _ in 0..<6 where likelyMTP == nil {
                Thread.sleep(forTimeInterval: 0.05)
                likelyMTP = interfacesLikelyMTP(devicePath: devicePath, name: name)
            }
        }
        return USBDeviceEvent(
            kind: .attached,
            vendorId: attribute(devicePath, "idVendor").flatMap { Int($0, radix: 16) } ?? product[0],
            productId: attribute(devicePath, "idProduct").flatMap { Int($0, radix: 16) } ?? product[1],
            serialNumber: attribute(devicePath, "serial") ?? properties["ID_SERIAL_SHORT"],
            productName: attribute(devicePath, "product") ?? properties["ID_MODEL"],
            isLikelyMTPDevice: likelyMTP,
            locationId: LinuxUSBLocation.locationID(deviceName: name).map(UInt64.init)
        )
    }

    static func detachEvent(name: String, properties: [String: String], cached: USBDeviceEvent?) -> USBDeviceEvent {
        let product = properties["PRODUCT"].map { $0.split(separator: "/").map { Int($0, radix: 16) ?? 0 } } ?? []
        return USBDeviceEvent(
            kind: .detached,
            vendorId: cached?.vendorId ?? (product.count > 0 ? product[0] : 0),
            productId: cached?.productId ?? (product.count > 1 ? product[1] : 0),
            serialNumber: cached?.serialNumber ?? properties["ID_SERIAL_SHORT"],
            productName: cached?.productName ?? properties["ID_MODEL"],
            isLikelyMTPDevice: cached?.isLikelyMTPDevice ?? UEventParser.interfacesListImageClass(properties["ID_USB_INTERFACES"]),
            locationId: LinuxUSBLocation.locationID(deviceName: name).map(UInt64.init)
        )
    }

    /// true when an interface is image class 6 or named "...MTP...", false
    /// when interfaces exist but none matches, nil when none is registered.
    static func interfacesLikelyMTP(devicePath: String, name: String) -> Bool? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: devicePath) else { return nil }
        let interfaces = entries.filter { $0.hasPrefix(name + ":") }
        guard !interfaces.isEmpty else { return nil }
        return interfaces.contains { interface in
            let dir = devicePath + "/" + interface
            if attribute(dir, "bInterfaceClass").flatMap({ Int($0, radix: 16) }) == 6 { return true }
            return attribute(dir, "interface")?.localizedCaseInsensitiveContains("MTP") == true
        }
    }

    static func attribute(_ directory: String, _ name: String) -> String? {
        let fd = open(directory + "/" + name, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Glibc.close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while bytes.count < 1 << 16 {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            bytes.append(contentsOf: chunk[0..<n])
        }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
#else
/// Placeholder watcher for platforms without a hotplug backend: it starts
/// and stops cleanly but never emits events.
public final class USBWatcher: @unchecked Sendable {
    public let events: AsyncStream<USBDeviceEvent>
    private let continuation: AsyncStream<USBDeviceEvent>.Continuation

    public init() {
        let pair = AsyncStream<USBDeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    deinit { continuation.finish() }

    public func start() throws {}
    public func stop() {}
}
#endif
#endif
