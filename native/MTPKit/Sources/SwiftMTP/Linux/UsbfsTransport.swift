#if os(Linux)
import CUsbfs
import Foundation

/// errno values from usbfs, mapped onto transport error kinds.
public enum UsbfsErrno {
    public static func kind(_ code: Int32) -> MTPTransportError.Kind {
        switch code {
        case ENODEV, ESHUTDOWN, ENXIO: return .noDevice
        case ETIMEDOUT: return .timeout
        case EPIPE: return .stall
        case EBUSY: return .exclusiveAccess
        case EACCES, EPERM: return .notPermitted
        case ENOENT, ECONNRESET: return .aborted
        default: return .io
        }
    }

    public static func name(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    static func error(_ code: Int32, _ what: String) -> MTPTransportError {
        MTPTransportError(kind(code), status: code, "\(what): \(name(code))")
    }
}

/// One submitted URB and its buffer. Both are plain heap memory the kernel
/// writes into when the URB is reaped, so neither may be freed before then.
final class UsbfsURB: @unchecked Sendable {
    let urb: UnsafeMutablePointer<usbdevfs_urb>
    let buffer: UnsafeMutableRawPointer
    let length: Int

    init(length: Int) {
        urb = cusbfs_urb_new()!
        self.length = length
        buffer = UnsafeMutableRawPointer.allocate(byteCount: max(length, 1), alignment: 64)
    }

    var key: UnsafeMutableRawPointer { UnsafeMutableRawPointer(urb) }
    var status: Int32 { cusbfs_urb_status(urb) }
    var actualLength: Int { Int(cusbfs_urb_actual_length(urb)) }

    func release() {
        free(urb)
        buffer.deallocate()
    }
}

/// Completion bookkeeping for every URB on one usbfs file descriptor.
///
/// usbfs hands completed URBs back through one queue per file descriptor
/// (REAPURB), whichever thread submitted them. One waiting thread at a time
/// polls and reaps; it files each reaped URB so its own waiter finds it.
final class UsbfsReaper: @unchecked Sendable {
    enum Outcome { case reaped, timedOut, deviceGone }

    let fd: Int32
    private let condition = NSCondition()
    private var completed = Set<UnsafeMutableRawPointer>()
    private var inFlight: [UnsafeMutableRawPointer: UsbfsURB] = [:]
    /// URBs whose waiter gave up; freed when reaped (or when the fd closes).
    private var orphans: [UnsafeMutableRawPointer: UsbfsURB] = [:]
    private var polling = false
    private var deviceGone = false
    private(set) var isClosing = false

    init(fd: Int32) { self.fd = fd }

    /// Submits under the lock so `close` never misses a URB. Throws errno
    /// failures; `.aborted` once the transport is closing.
    func submit(_ urb: UsbfsURB, type: UInt8, endpoint: UInt8, flags: UInt32 = 0) throws {
        condition.lock()
        defer { condition.unlock() }
        if isClosing { throw MTPTransportError(.aborted, "transport is closed") }
        if deviceGone { throw MTPTransportError(.noDevice, status: ENODEV, "the device is gone") }
        var result: Int32
        repeat {
            result = cusbfs_submit_urb(fd, urb.urb, type, endpoint, urb.buffer, Int32(urb.length), flags)
        } while result < 0 && errno == EINTR
        if result < 0 {
            throw UsbfsErrno.error(errno, String(format: "submitting a %d-byte URB on endpoint 0x%02x", urb.length, endpoint))
        }
        inFlight[urb.key] = urb
    }

    /// Waits until `urb` is reaped, `deadline` passes (nil: no deadline), or
    /// the device disappears.
    func wait(_ urb: UsbfsURB, until deadline: Date?) -> Outcome {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if completed.remove(urb.key) != nil { return .reaped }
            if deviceGone { return .deviceGone }
            let remaining = deadline.map { $0.timeIntervalSinceNow } ?? .infinity
            if remaining <= 0 { return .timedOut }
            if polling {
                if let deadline { _ = condition.wait(until: deadline) } else { condition.wait() }
                continue
            }
            polling = true
            condition.unlock()
            let (reaped, gone) = pollAndReap(timeoutMS: Int32(min(remaining, 0.5) * 1000) + 1)
            condition.lock()
            polling = false
            for key in reaped {
                inFlight.removeValue(forKey: key)
                if let orphan = orphans.removeValue(forKey: key) {
                    // Its waiter already gave up; nothing else refers to it.
                    orphan.release()
                } else {
                    completed.insert(key)
                }
            }
            if gone { deviceGone = true }
            condition.broadcast()
        }
    }

    /// Hands over a URB whose waiter gives up (it may still complete): it is
    /// freed when reaped, or once the file descriptor is closed.
    func orphan(_ urb: UsbfsURB) {
        condition.lock()
        defer { condition.unlock() }
        if completed.remove(urb.key) != nil {
            urb.release()
            return
        }
        orphans[urb.key] = urb
    }

    /// Discards `urb` (it still completes, with -ENOENT, unless it already finished).
    func discard(_ urb: UsbfsURB) {
        condition.lock()
        defer { condition.unlock() }
        if inFlight[urb.key] != nil { _ = cusbfs_discard_urb(fd, urb.urb) }
    }

    /// Stops new submissions and discards every URB still in flight.
    func beginClosing() {
        condition.lock()
        defer { condition.unlock() }
        isClosing = true
        for urb in inFlight.values { _ = cusbfs_discard_urb(fd, urb.urb) }
        condition.broadcast()
    }

    /// After the fd is closed the kernel has dropped every URB: free the orphans.
    func releaseAllOrphans() {
        condition.lock()
        defer { condition.unlock() }
        for urb in orphans.values { urb.release() }
        orphans.removeAll()
    }

    /// Reaps whatever is ready, polling up to `timeoutMS` when nothing is.
    private func pollAndReap(timeoutMS: Int32) -> (reaped: [UnsafeMutableRawPointer], gone: Bool) {
        var reaped: [UnsafeMutableRawPointer] = []
        var gone = false
        func drain() {
            while true {
                var out: UnsafeMutablePointer<usbdevfs_urb>?
                if cusbfs_reap_urb_nodelay(fd, &out) == 0 {
                    if let out { reaped.append(UnsafeMutableRawPointer(out)) }
                    continue
                }
                switch errno {
                case EINTR: continue
                case EAGAIN: return
                case ENODEV, ESHUTDOWN: gone = true; return
                default: return
                }
            }
        }
        drain()
        if !reaped.isEmpty || gone { return (reaped, gone) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT | POLLWRNORM), revents: 0)
        let ready = poll(&pfd, 1, timeoutMS)
        if ready > 0 {
            drain()
            if reaped.isEmpty, pfd.revents & Int16(POLLERR | POLLHUP) != 0 { gone = true }
        }
        return (reaped, gone)
    }
}

/// The retry schedule of `UsbfsTransport.open`: a busy interface waits for
/// its holder to let go, and a node not yet accessible waits (briefly) for
/// udev to grant access. Everything else fails at once.
public enum UsbfsOpenRetry {
    /// 0.85 s in all: udev applies its ACL within milliseconds of the node
    /// appearing, so a longer wait would only delay a real permission error.
    public static let permissionDelays: [TimeInterval] = [0.1, 0.25, 0.5]

    static func run<T>(busyDelays: [TimeInterval], permissionDelays: [TimeInterval],
                       sleep: (TimeInterval) -> Void, log: ((String) -> Void)?,
                       _ attempt: () throws -> T) throws -> T {
        var busyAttempts = 0
        var permissionAttempts = 0
        while true {
            do {
                return try attempt()
            } catch let error as MTPTransportError where error.kind == .exclusiveAccess {
                guard busyAttempts < busyDelays.count else { throw error }
                let delay = busyDelays[busyAttempts]
                log?("open attempt failed: \(error); retrying in \(delay) s (no reset)")
                sleep(delay)
                busyAttempts += 1
            } catch let error as MTPTransportError where error.kind == .notPermitted {
                guard permissionAttempts < permissionDelays.count else { throw error }
                let delay = permissionDelays[permissionAttempts]
                log?("open attempt failed: \(error); retrying in \(delay) s (udev may not have granted access yet)")
                sleep(delay)
                permissionAttempts += 1
            }
        }
    }
}

/// Bulk/interrupt/control I/O on one MTP interface through Linux usbfs
/// (`/dev/bus/usb/BBB/DDD`).
///
/// Claiming the interface gives this process exclusive use of it (another
/// process's claim makes the claim fail with EBUSY; it is never taken over).
/// A busy interface is retried after a pause; the device is never reset or
/// re-enumerated (that drops Android out of File transfer mode). `close()`
/// discards pending URBs, releases the interface and closes the node.
///
/// Every transfer is one asynchronous URB (so a timeout can discard it and
/// the kernel may build a scatter-gather list instead of one large contiguous
/// buffer), waited for synchronously, which keeps USB bulk semantics exact:
/// a read ends at `maxLength` bytes or at a short or zero-length packet.
public final class UsbfsTransport: MTPTransport, USBEndpointDescribing, @unchecked Sendable {
    public let candidate: MTPInterfaceCandidate
    public let devicePath: String
    public let maxPacketSizeIn: Int
    public let maxPacketSizeOut: Int
    public let maxPacketSizeInterrupt: Int
    public let bulkInAddress: UInt8
    public let bulkOutAddress: UInt8
    public let interruptAddress: UInt8
    /// USBDEVFS_GET_CAPABILITIES bits.
    public let capabilities: UInt32

    /// Largest single URB. Bigger requests are split into sequential URBs,
    /// which keeps short-packet semantics (a short piece ends the read) while
    /// staying far below the global `usbfs_memory_mb` budget (16 MB default).
    public static let maxURBLength = 4 << 20

    private let fd: Int32
    private let reaper: UsbfsReaper
    private let bulkLock = NSLock()
    private let interruptLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false
    private var claimed = true

    /// Opens the interface. Retries a busy (claimed elsewhere) interface after
    /// each delay in `retryDelays`, never resetting. A final busy failure
    /// names the process holding the phone when it is visible. A node this
    /// user may not open yet is retried after each of `permissionRetryDelays`:
    /// a hotplug attach can race the udev rule that grants the login session
    /// access (it cannot when the event comes from udev after its rules, but
    /// it can from the kernel's own group, or from a sysfs scan of a device
    /// that is still being set up).
    public static func open(_ candidate: MTPInterfaceCandidate,
                            retryDelays: [TimeInterval] = [0.25, 0.5, 1.0, 2.0],
                            permissionRetryDelays: [TimeInterval] = UsbfsOpenRetry.permissionDelays,
                            log: ((String) -> Void)? = nil) throws -> UsbfsTransport {
        try UsbfsOpenRetry.run(busyDelays: retryDelays, permissionDelays: permissionRetryDelays,
                               sleep: { Thread.sleep(forTimeInterval: $0) }, log: log) {
            try UsbfsTransport(candidate: candidate, log: log)
        }
    }

    private init(candidate: MTPInterfaceCandidate, log: ((String) -> Void)?) throws {
        self.candidate = candidate
        guard let bus = candidate.busNumber, let address = candidate.deviceAddress else {
            throw MTPTransportError(.noDevice, "interface \(candidate.platformPath ?? "?") has no bus/device address")
        }
        let path = LinuxUSBAddress.deviceNodePath(bus: bus, device: address)
        devicePath = path

        var fd: Int32
        repeat { fd = Glibc.open(path, O_RDWR | O_CLOEXEC) } while fd < 0 && errno == EINTR
        if fd < 0 {
            let code = errno
            switch code {
            case EACCES, EPERM:
                throw MTPTransportError(.notPermitted, status: code,
                                        "cannot open \(path): \(UsbfsErrno.name(code)). \(USBDeviceNodeDiagnostics.permissionReport(path: path))")
            case ENOENT, ENODEV, ENXIO:
                throw MTPTransportError(.noDevice, status: code, "\(path) is gone: \(UsbfsErrno.name(code))")
            default:
                throw UsbfsErrno.error(code, "opening \(path)")
            }
        }
        var ok = false
        defer { if !ok { Glibc.close(fd) } }

        // The node's own descriptors: also proves it is still the same device.
        let blob = Self.readAll(fd)
        guard blob.count >= 18 else { throw MTPTransportError(.noDevice, "\(path): no device descriptor") }
        let vendor = Int(blob[8]) | Int(blob[9]) << 8
        let product = Int(blob[10]) | Int(blob[11]) << 8
        guard vendor == candidate.vendorID, product == candidate.productID else {
            throw MTPTransportError(.noDevice, String(format: "%@ is now %04x:%04x, not %04x:%04x", path,
                                                      vendor, product, candidate.vendorID, candidate.productID))
        }
        let configuration = candidate.sysfsDeviceName.flatMap { SysfsUSBDiscovery.activeConfiguration(deviceName: $0) }
        let endpoints: MTPEndpointSet
        do {
            endpoints = try USBDescriptorParser.mtpEndpoints(blob, configurationValue: configuration,
                                                              interfaceNumber: candidate.interfaceNumber)
        } catch {
            throw MTPTransportError(.io, "\(path): \(error)")
        }

        var caps: UInt32 = 0
        if cusbfs_get_capabilities(fd, &caps) != 0 { caps = 0 }

        try Self.claim(fd: fd, interface: UInt32(candidate.interfaceNumber), path: path, bus: bus, address: address, log: log)

        ok = true
        self.fd = fd
        reaper = UsbfsReaper(fd: fd)
        capabilities = caps
        bulkInAddress = endpoints.bulkIn.address
        bulkOutAddress = endpoints.bulkOut.address
        interruptAddress = endpoints.interruptIn.address
        maxPacketSizeIn = endpoints.bulkIn.maxPacketSize
        maxPacketSizeOut = endpoints.bulkOut.maxPacketSize
        maxPacketSizeInterrupt = endpoints.interruptIn.maxPacketSize
        if let raw = ProcessInfo.processInfo.environment["ART_USBFS_WRITE_QUEUE_DEPTH"], let depth = Int(raw) {
            writeQueueDepth = max(depth, 1)
        }
        log?(String(format: "usbfs %@: capabilities 0x%x, write queue depth %d", path, caps, writeQueueDepth))
    }

    private static func claim(fd: Int32, interface: UInt32, path: String, bus: Int, address: Int,
                              log: ((String) -> Void)?) throws {
        if cusbfs_claim_interface(fd, interface) == 0 { return }
        var code = errno
        if code == EBUSY {
            var name = [CChar](repeating: 0, count: 256)
            let driver: String? = cusbfs_get_driver(fd, interface, &name, name.count) == 0
                ? String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            if let driver, driver != "usbfs" {
                // A kernel driver (not another process) is bound: detach it and
                // claim atomically, but never from another usbfs user.
                log?("interface \(interface) is bound to kernel driver \"\(driver)\"; detaching it")
                if cusbfs_disconnect_claim_except_usbfs(fd, interface) == 0 { return }
                code = errno
            }
            if code == EBUSY {
                let holders = USBDeviceHolder.find(bus: bus, dev: address)
                let who = USBDeviceHolder.busyMessage(holders)
                    ?? "another program has claimed the phone's MTP interface\(driver.map { " (driver \($0))" } ?? "")"
                throw MTPTransportError(.exclusiveAccess, status: EBUSY, "claiming interface \(interface) of \(path): \(who)")
            }
        }
        throw UsbfsErrno.error(code, "claiming interface \(interface) of \(path)")
    }

    static func readAll(_ fd: Int32) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var offset: off_t = 0
        while result.count < 1 << 16 {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            result.append(contentsOf: buffer[0..<n])
            offset += off_t(n)
        }
        return result
    }

    deinit { close() }

    private func checkOpen() throws {
        if stateLock.withLock({ isClosed }) { throw MTPTransportError(.noDevice, "transport is closed") }
    }

    /// Submits one URB (its buffer filled by `fill`).
    private func start(type: UInt8, endpoint: UInt8, length: Int,
                       fill: ((UnsafeMutableRawPointer) -> Void)? = nil) throws -> UsbfsURB {
        let urb = UsbfsURB(length: length)
        fill?(urb.buffer)
        do {
            try reaper.submit(urb, type: type, endpoint: endpoint)
        } catch {
            urb.release()
            throw error
        }
        return urb
    }

    private static func deadline(_ timeout: TimeInterval) -> Date? {
        timeout > 0 ? Date(timeIntervalSinceNow: timeout) : nil
    }

    /// Runs one URB to completion. Returns the URB (caller releases it) with
    /// status 0; throws for every other outcome.
    private func run(type: UInt8, endpoint: UInt8, length: Int, timeout: TimeInterval,
                     fill: ((UnsafeMutableRawPointer) -> Void)? = nil, what: () -> String) throws -> UsbfsURB {
        let urb = try start(type: type, endpoint: endpoint, length: length, fill: fill)
        return try finish(urb, deadline: Self.deadline(timeout), what: what)
    }

    /// Waits for a submitted URB. Returns it (caller releases it) when its
    /// status is 0; otherwise releases (or orphans) it and throws. A URB still
    /// pending at `deadline` is discarded and reported as a timeout.
    private func finish(_ urb: UsbfsURB, deadline: Date?, what: () -> String) throws -> UsbfsURB {
        var timedOut = false
        switch reaper.wait(urb, until: deadline) {
        case .reaped:
            break
        case .deviceGone:
            reaper.orphan(urb)
            throw MTPTransportError(.noDevice, status: ENODEV, "\(what()): the device is gone")
        case .timedOut:
            timedOut = true
            reaper.discard(urb)
            switch reaper.wait(urb, until: Date(timeIntervalSinceNow: 5)) {
            case .reaped:
                break
            case .timedOut, .deviceGone:
                reaper.orphan(urb)
                throw MTPTransportError(.timeout, status: ETIMEDOUT, "\(what()): timed out (URB not returned after discard)")
            }
        }
        let status = -urb.status
        if urb.status == 0 { return urb }
        urb.release()
        if status == ENOENT || status == ECONNRESET {
            if timedOut { throw MTPTransportError(.timeout, status: ETIMEDOUT, "\(what()): timed out") }
            throw MTPTransportError(.aborted, status: status, "\(what()): aborted")
        }
        throw UsbfsErrno.error(status, what())
    }

    /// A bulk-out URB submitted by `bulkWrite` that has not been waited for.
    private struct PendingWrite {
        let urb: UsbfsURB
        let deadline: Date?
        let total: Int
    }
    private var pendingWrites: [PendingWrite] = []

    /// How many bulk-out URBs may be in flight at once. Above 1, `bulkWrite`
    /// returns once its data is queued (the kernel keeps URBs on one endpoint
    /// in order), so the bus never idles between writes; a failure then
    /// surfaces from the next transport call, and every other call waits for
    /// queued writes first. 3 × the session's 1 MiB chunk stays well under
    /// the usbfs memory budget.
    public var writeQueueDepth = 3

    /// Waits for the oldest queued write. On failure the rest are discarded
    /// (so no stale data follows a stall once it is cleared) and it throws.
    private func completeOldestWrite() throws {
        let pending = pendingWrites.removeFirst()
        do {
            let urb = try finish(pending.urb, deadline: pending.deadline,
                                 what: { "bulk write of \(pending.total) byte(s)" })
            let sent = urb.actualLength
            let expected = urb.length
            urb.release()
            if sent != expected {
                throw MTPTransportError(.io, "bulk write sent \(sent) of \(expected) byte(s) in one URB")
            }
        } catch {
            abandonPendingWrites()
            throw error
        }
    }

    private func abandonPendingWrites() {
        let rest = pendingWrites
        pendingWrites.removeAll()
        for pending in rest { reaper.discard(pending.urb) }
        for pending in rest {
            if reaper.wait(pending.urb, until: Date(timeIntervalSinceNow: 5)) == .reaped {
                pending.urb.release()
            } else {
                reaper.orphan(pending.urb)
            }
        }
    }

    /// Waits for every queued write; throws the first failure. Caller holds bulkLock.
    private func flushWrites() throws {
        while !pendingWrites.isEmpty { try completeOldestWrite() }
    }

    public func bulkWrite(_ data: Data, timeout: TimeInterval) throws {
        try bulkLock.withLock {
            try checkOpen()
            let depth = max(writeQueueDepth, 1)
            var offset = 0
            repeat {
                // Each piece but the last is a multiple of the packet size, so
                // no short packet ends the transfer early.
                let count = min(data.count - offset, Self.maxURBLength)
                let urb: UsbfsURB
                do {
                    urb = try start(type: UInt8(CUSBFS_URB_TYPE_BULK), endpoint: bulkOutAddress, length: count,
                                    fill: { buffer in
                                        if count > 0 {
                                            data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: count) }
                                        }
                                    })
                } catch {
                    abandonPendingWrites()
                    throw error
                }
                pendingWrites.append(PendingWrite(urb: urb, deadline: Self.deadline(timeout), total: data.count))
                while pendingWrites.count >= depth { try completeOldestWrite() }
                offset += count
            } while offset < data.count
        }
    }

    public func bulkRead(maxLength: Int, timeout: TimeInterval) throws -> Data {
        try bulkLock.withLock {
            try checkOpen()
            try flushWrites()
            var result = Data()
            var remaining = maxLength
            repeat {
                let want = min(remaining, Self.maxURBLength)
                let urb = try run(type: UInt8(CUSBFS_URB_TYPE_BULK), endpoint: bulkInAddress, length: want, timeout: timeout,
                                  what: { "bulk read of up to \(maxLength) byte(s)" })
                let got = urb.actualLength
                result.append(urb.buffer.assumingMemoryBound(to: UInt8.self), count: got)
                urb.release()
                remaining -= got
                // A short (or zero-length) packet ends the transfer.
                if got < want { break }
            } while remaining > 0
            return result
        }
    }

    /// Submits one interrupt URB and discards it if no event arrives in time.
    public func interruptRead(maxLength: Int, timeout: TimeInterval) throws -> Data? {
        try interruptLock.withLock {
            try checkOpen()
            let length = max(maxLength, maxPacketSizeInterrupt)
            let urb: UsbfsURB
            do {
                urb = try run(type: UInt8(CUSBFS_URB_TYPE_INTERRUPT), endpoint: interruptAddress, length: length,
                              timeout: timeout, what: { "interrupt read" })
            } catch let error as MTPTransportError where error.kind == .timeout || error.kind == .aborted {
                return nil
            }
            defer { urb.release() }
            return Data(bytes: urb.buffer, count: urb.actualLength)
        }
    }

    public func clearStall(_ endpoint: MTPEndpoint) throws {
        try checkOpen()
        let address: UInt8
        switch endpoint {
        case .bulkIn: address = bulkInAddress
        case .bulkOut: address = bulkOutAddress
        case .interruptIn: address = interruptAddress
        }
        try bulkLock.withLock {
            // Queued writes go first (a failed one is discarded with the rest).
            try? flushWrites()
            if cusbfs_clear_halt(fd, UInt32(address)) != 0 {
                throw UsbfsErrno.error(errno, String(format: "clearing stall on endpoint 0x%02x", address))
            }
        }
    }

    private func classRequest(direction: UInt8, request: UInt8, buffer: UnsafeMutableRawPointer?, length: Int) throws -> Int {
        try checkOpen()
        try bulkLock.withLock { try flushWrites() }
        var result: Int32
        repeat {
            result = cusbfs_control(fd, direction | 0x20 | 0x01, request, 0, UInt16(candidate.interfaceNumber),
                                    UInt16(length), buffer, 5000)
        } while result < 0 && errno == EINTR
        if result < 0 { throw UsbfsErrno.error(errno, String(format: "class request 0x%02x", request)) }
        return Int(result)
    }

    public func cancelRequest(transactionID: UInt32) throws {
        var w = PTPWriter()
        w.u16(PTPClassRequest.cancelEventCode)
        w.u32(transactionID)
        var bytes = [UInt8](w.data)
        _ = try bytes.withUnsafeMutableBytes {
            try classRequest(direction: 0x00, request: PTPClassRequest.cancel, buffer: $0.baseAddress, length: 6)
        }
    }

    public func getDeviceStatus() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = try buffer.withUnsafeMutableBytes {
            try classRequest(direction: 0x80, request: PTPClassRequest.getDeviceStatus, buffer: $0.baseAddress, length: 64)
        }
        return Data(buffer[0..<n])
    }

    /// Discards pending URBs, releases the interface and closes the node.
    /// Never USBDEVFS_RESET: the phone stays enumerated in File transfer mode.
    public func close() {
        let first = stateLock.withLock { () -> Bool in
            if isClosed { return false }
            isClosed = true
            return true
        }
        guard first else { return }
        reaper.beginClosing()
        // In-flight transfers return promptly once discarded.
        bulkLock.lock()
        abandonPendingWrites()
        interruptLock.lock()
        if claimed {
            _ = cusbfs_release_interface(fd, UInt32(candidate.interfaceNumber))
            claimed = false
        }
        Glibc.close(fd)
        reaper.releaseAllOrphans()
        interruptLock.unlock()
        bulkLock.unlock()
    }
}
#endif
