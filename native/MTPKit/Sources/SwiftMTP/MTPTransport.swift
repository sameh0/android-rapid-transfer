import Foundation

/// Which pipe a stall is cleared on.
public enum MTPEndpoint: Sendable {
    case bulkIn
    case bulkOut
    case interruptIn
}

/// A failure below the PTP layer (USB I/O, device gone, timeout).
public struct MTPTransportError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: Equatable, Sendable {
        case noDevice
        case timeout
        case stall
        case exclusiveAccess
        case notPermitted
        case aborted
        case io
    }

    public let kind: Kind
    /// The OS status behind the failure, when there is one: an IOReturn on
    /// macOS, an errno value on Linux.
    public let status: Int32?
    public let message: String

    public init(_ kind: Kind, status: Int32? = nil, _ message: String) {
        self.kind = kind
        self.status = status
        self.message = message
    }

    public var description: String {
        if let status {
            #if os(macOS)
            return "\(message) (\(kind), IOReturn 0x\(String(UInt32(bitPattern: status), radix: 16)))"
            #else
            return "\(message) (\(kind), errno \(status))"
            #endif
        }
        return "\(message) (\(kind))"
    }
}

/// The bytes-on-the-wire seam between the PTP session layer and USB.
///
/// Semantics follow USB bulk transfers:
/// - `bulkRead(maxLength:)` completes when `maxLength` bytes arrived or the
///   device ended the transfer with a short (or zero-length) packet. Callers
///   pass a multiple of `maxPacketSizeIn` so a packet never overruns.
/// - `bulkWrite` sends the bytes as one transfer. An empty write sends a
///   zero-length packet. The transport never adds a ZLP on its own.
///
/// Implementations must never reset or re-enumerate the device.
public protocol MTPTransport: AnyObject {
    var maxPacketSizeIn: Int { get }
    var maxPacketSizeOut: Int { get }

    func bulkWrite(_ data: Data, timeout: TimeInterval) throws
    func bulkRead(maxLength: Int, timeout: TimeInterval) throws -> Data
    /// Reads one event from the interrupt endpoint; nil on timeout.
    func interruptRead(maxLength: Int, timeout: TimeInterval) throws -> Data?
    /// CLEAR_FEATURE(ENDPOINT_HALT) on one pipe. Not a device reset.
    func clearStall(_ endpoint: MTPEndpoint) throws
    /// Class request 0x64: cancel the transaction `transactionID`.
    func cancelRequest(transactionID: UInt32) throws
    /// Class request 0x67: the device status block (u16 length, u16 code, params).
    func getDeviceStatus() throws -> Data
    /// Releases the interface. Idempotent. Never resets the device.
    func close()
}

extension MTPTransport {
    public func interruptRead(maxLength: Int, timeout: TimeInterval) throws -> Data? { nil }
}

/// Parsed class request 0x67 reply.
public struct PTPDeviceStatus: Equatable, Sendable {
    public var code: UInt16
    public var parameters: [UInt32]

    public static func decode(_ bytes: [UInt8]) throws -> PTPDeviceStatus {
        var r = PTPReader(bytes)
        let length = Int(try r.u16("status length"))
        let code = try r.u16("status code")
        let available = min(length, bytes.count)
        var params: [UInt32] = []
        while r.offset + 4 <= available { params.append(try r.u32("status parameter")) }
        return PTPDeviceStatus(code: code, parameters: params)
    }
}

/// Endpoint addresses and packet sizes a concrete USB transport can report
/// for diagnostics.
public protocol USBEndpointDescribing {
    var bulkInAddress: UInt8 { get }
    var bulkOutAddress: UInt8 { get }
    var interruptAddress: UInt8 { get }
    var maxPacketSizeIn: Int { get }
    var maxPacketSizeOut: Int { get }
    var maxPacketSizeInterrupt: Int { get }
}
