#if os(macOS)
import Foundation
import IOKit
import IOUSBHost

/// Bulk/interrupt/control I/O on one MTP interface through IOUSBHost.
///
/// Opening an IOUSBHostInterface establishes exclusive ownership of the
/// interface (the same kernel open libusb's claim performs). The device is
/// opened exactly once; a busy interface is retried after a pause, and the
/// device is never reset or re-enumerated (that drops Android out of File
/// transfer mode). `close()` aborts pending I/O and destroys the user client.
public final class IOUSBHostTransport: MTPTransport, @unchecked Sendable {
    public let candidate: MTPInterfaceCandidate
    public let maxPacketSizeIn: Int
    public let maxPacketSizeOut: Int
    public let maxPacketSizeInterrupt: Int
    public let bulkInAddress: UInt8
    public let bulkOutAddress: UInt8
    public let interruptAddress: UInt8

    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let interruptIn: IOUSBHostPipe
    private let lock = NSLock()
    private var isClosed = false
    /// DMA-friendly read buffers reused across transfers, keyed by length.
    /// An ioData buffer's length is fixed (setting it raises
    /// `ioDataSetLengthException`), and the transfer length is the buffer
    /// length, so each request size needs its own buffer.
    private var readBuffers: [Int: NSMutableData] = [:]

    private func readBuffer(length: Int) -> NSMutableData {
        if let cached = readBuffers[length] { return cached }
        guard readBuffers.count < 8, let buffer = try? interface.ioData(withCapacity: length), buffer.length == length else {
            // Odd sizes (the tail of a data phase) use ordinary memory.
            return NSMutableData(length: length)!
        }
        readBuffers[length] = buffer
        return buffer
    }

    /// Opens the interface. A taken interface (kIOReturnExclusiveAccess, or
    /// any failure while the registry names a holder) and
    /// kIOReturnInternalError are retried after each delay in `retryDelays`:
    /// nothing is held between attempts, and the device is never reset. See
    /// ``USBClaimRetry``.
    ///
    /// - Parameter holder: reads who holds the interface (by registry entry
    ///   ID); injectable for tests.
    public static func open(_ candidate: MTPInterfaceCandidate,
                            retryDelays: [TimeInterval] = [0.25, 0.5, 1.0, 2.0],
                            log: ((String) -> Void)? = nil,
                            holder: (UInt64) -> String? = USBDeviceDiscovery.claimHolder(ofInterface:))
        throws -> IOUSBHostTransport {
        try USBClaimRetry.run(retryDelays: retryDelays,
                              retryableStatuses: [IOReturnCode.internalError],
                              sleep: { Thread.sleep(forTimeInterval: $0) },
                              log: log,
                              owner: { holder(candidate.registryEntryID) }) {
            try IOUSBHostTransport(candidate: candidate)
        }
    }

    private init(candidate: MTPInterfaceCandidate) throws {
        self.candidate = candidate
        guard let service = USBDeviceDiscovery.service(for: candidate.registryEntryID) else {
            throw MTPTransportError(.noDevice, "interface \(candidate.registryEntryID) is no longer in the I/O Registry")
        }
        defer { IOObjectRelease(service) }
        // The object keeps its own reference to the service; give it one so our
        // release above stays balanced whichever way the framework counts.
        IOObjectRetain(service)

        let interface: IOUSBHostInterface
        do {
            // Options .none: never DeviceCapture (it terminates other clients and
            // resets the device on destroy) and never DeviceSeize.
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            IOObjectRelease(service)
            throw Self.transportError(error, "opening IOUSBHostInterface")
        }

        var inAddr: UInt8 = 0, outAddr: UInt8 = 0, intAddr: UInt8 = 0
        let config = interface.configurationDescriptor
        let ifaceDesc = interface.interfaceDescriptor
        var current: UnsafePointer<IOUSBDescriptorHeader>? = UnsafeRawPointer(ifaceDesc).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(config, ifaceDesc, current) {
            let address = endpoint.pointee.bEndpointAddress
            let type = endpoint.pointee.bmAttributes & 0x03
            let isIn = address & 0x80 != 0
            switch (type, isIn) {
            case (2, true): inAddr = address
            case (2, false): outAddr = address
            case (3, true): intAddr = address
            default: break
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard inAddr != 0, outAddr != 0, intAddr != 0 else {
            interface.destroy()
            throw MTPTransportError(.io, String(format: "interface lacks bulk-in/bulk-out/interrupt-in endpoints (0x%02x/0x%02x/0x%02x)", inAddr, outAddr, intAddr))
        }

        do {
            bulkIn = try interface.copyPipe(withAddress: Int(inAddr))
            bulkOut = try interface.copyPipe(withAddress: Int(outAddr))
            interruptIn = try interface.copyPipe(withAddress: Int(intAddr))
        } catch {
            interface.destroy()
            throw Self.transportError(error, "copying pipes")
        }
        self.interface = interface
        bulkInAddress = inAddr
        bulkOutAddress = outAddr
        interruptAddress = intAddr
        maxPacketSizeIn = Int(bulkIn.descriptors.pointee.descriptor.wMaxPacketSize & 0x7FF)
        maxPacketSizeOut = Int(bulkOut.descriptors.pointee.descriptor.wMaxPacketSize & 0x7FF)
        maxPacketSizeInterrupt = Int(interruptIn.descriptors.pointee.descriptor.wMaxPacketSize & 0x7FF)
    }

    deinit { close() }

    static func transportError(_ error: Error, _ what: String) -> MTPTransportError {
        let ns = error as NSError
        let code = Int32(truncatingIfNeeded: ns.code)
        return MTPTransportError(IOReturnCode.kind(code), status: code,
                                 "\(what): \(IOReturnCode.name(code)) [\(ns.domain)]")
    }

    private func checkOpen() throws {
        if isClosed { throw MTPTransportError(.noDevice, "transport is closed") }
    }

    public func bulkWrite(_ data: Data, timeout: TimeInterval) throws {
        try lock.withLock {
            try checkOpen()
            var transferred = 0
            do {
                if data.isEmpty {
                    // nil data sends a zero-length packet.
                    try bulkOut.__sendIORequest(with: nil, bytesTransferred: &transferred, completionTimeout: timeout)
                } else {
                    let buffer = NSMutableData(data: data)
                    try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
                }
            } catch {
                throw Self.transportError(error, "bulk write of \(data.count) byte(s)")
            }
            if transferred != data.count {
                throw MTPTransportError(.io, "bulk write sent \(transferred) of \(data.count) byte(s)")
            }
        }
    }

    public func bulkRead(maxLength: Int, timeout: TimeInterval) throws -> Data {
        try lock.withLock {
            try checkOpen()
            let buffer = readBuffer(length: maxLength)
            var transferred = 0
            do {
                try bulkIn.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                throw Self.transportError(error, "bulk read of up to \(maxLength) byte(s)")
            }
            return Data(bytes: buffer.bytes, count: transferred)
        }
    }

    /// Interrupt pipes do not accept a completion timeout, so the request is
    /// enqueued and aborted if no event arrives in time.
    public func interruptRead(maxLength: Int, timeout: TimeInterval) throws -> Data? {
        try lock.withLock { try checkOpen() }
        let buffer = NSMutableData(length: max(maxLength, maxPacketSizeInterrupt))!
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var status: Int32 = 0; var count = 0 }
        let box = Box()
        do {
            try interruptIn.enqueueIORequest(with: buffer, completionTimeout: 0) { status, count in
                box.status = status
                box.count = count
                done.signal()
            }
        } catch {
            throw Self.transportError(error, "enqueueing interrupt read")
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            try? interruptIn.__abort(with: .synchronous)
            done.wait()
            return nil
        }
        if box.status != IOReturnCode.success {
            if box.status == IOReturnCode.aborted { return nil }
            throw MTPTransportError(IOReturnCode.kind(box.status), status: box.status, "interrupt read: \(IOReturnCode.name(box.status))")
        }
        return Data(bytes: buffer.bytes, count: box.count)
    }

    public func clearStall(_ endpoint: MTPEndpoint) throws {
        let pipe: IOUSBHostPipe
        switch endpoint {
        case .bulkIn: pipe = bulkIn
        case .bulkOut: pipe = bulkOut
        case .interruptIn: pipe = interruptIn
        }
        do { try pipe.clearStall() } catch { throw Self.transportError(error, "clearing stall") }
    }

    private func classRequest(direction: UInt8, request: UInt8, length: Int, data: NSMutableData?) throws -> Int {
        let req = IOUSBDeviceRequest(
            bmRequestType: direction | 0x20 | 0x01, // class, recipient interface
            bRequest: request,
            wValue: 0,
            wIndex: UInt16(candidate.interfaceNumber),
            wLength: UInt16(length)
        )
        var transferred = 0
        do {
            try interface.__send(req, data: data, bytesTransferred: &transferred, completionTimeout: 5)
        } catch {
            throw Self.transportError(error, String(format: "class request 0x%02x", request))
        }
        return transferred
    }

    public func cancelRequest(transactionID: UInt32) throws {
        var w = PTPWriter()
        w.u16(PTPClassRequest.cancelEventCode)
        w.u32(transactionID)
        _ = try classRequest(direction: 0x00, request: PTPClassRequest.cancel, length: 6, data: NSMutableData(data: w.data))
    }

    public func getDeviceStatus() throws -> Data {
        let buffer = NSMutableData(length: 64)!
        let n = try classRequest(direction: 0x80, request: PTPClassRequest.getDeviceStatus, length: 64, data: buffer)
        return Data(bytes: buffer.bytes, count: n)
    }

    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            for pipe in [bulkIn, bulkOut, interruptIn] { try? pipe.__abort(with: .synchronous) }
            // Releases the exclusive open. Not a reset: the device stays
            // enumerated and Android stays in File transfer mode.
            interface.destroy()
        }
    }
}
extension IOUSBHostTransport: USBEndpointDescribing {}
#endif
