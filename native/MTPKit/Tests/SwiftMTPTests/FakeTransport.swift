import Foundation
@testable import SwiftMTP

/// A USB-faithful fake: the device's output is a queue of packets, and
/// `bulkRead(maxLength:)` follows bulk-transfer rules: it gathers packets until
/// `maxLength` bytes arrived or a short (or zero-length) packet ended the
/// transfer, and a packet that would overrun the buffer is a babble error.
final class FakeTransport: MTPTransport, @unchecked Sendable {
    let maxPacketSizeIn: Int
    let maxPacketSizeOut: Int

    private(set) var packetsIn: [Data] = []
    private(set) var writes: [Data] = []
    private(set) var readRequests: [Int] = []
    private(set) var clearedStalls: [MTPEndpoint] = []
    private(set) var cancelledTransactions: [UInt32] = []
    private(set) var closeCount = 0
    var stallNextRead = false
    /// Thrown by the next bulk read (then cleared).
    var failNextRead: MTPTransportError?
    var deviceStatus = Data([4, 0, 0x01, 0x20])
    /// Replies to Get Device Status served before falling back to `deviceStatus`.
    var deviceStatusReplies: [Data] = []
    private(set) var deviceStatusRequests = 0

    init(maxPacketSize: Int = 512) {
        maxPacketSizeIn = maxPacketSize
        maxPacketSizeOut = maxPacketSize
    }

    // MARK: Scripting the device

    /// Queues one device-side transfer, split into max-size packets. A transfer
    /// that is an exact multiple of the packet size gets a ZLP when `zlp`.
    func deviceSends(_ bytes: [UInt8], zlp: Bool = true) {
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + maxPacketSizeIn)
            packetsIn.append(Data(bytes[offset..<end]))
            offset = end
        }
        if bytes.isEmpty || (zlp && bytes.count % maxPacketSizeIn == 0) {
            packetsIn.append(Data())
        }
    }

    func deviceSendsData(code: UInt16, tid: UInt32, payload: [UInt8], zlp: Bool = true, lengthField: UInt32? = nil) {
        let header = PTPContainerHeader(length: lengthField ?? UInt32(12 + payload.count), type: .data, code: code, transactionID: tid)
        deviceSends(header.bytes + payload, zlp: zlp)
    }

    func deviceResponds(_ code: UInt16 = PTPResponseCode.ok, tid: UInt32, params: [UInt32] = []) {
        deviceSends(PTPResponse(code: code, transactionID: tid, parameters: params).bytes)
    }

    var commands: [PTPCommand] {
        writes.compactMap { data in
            guard data.count >= 12, let cmd = try? PTPCommand.decode([UInt8](data)) else { return nil }
            return cmd
        }
    }

    var remainingPackets: Int { packetsIn.count }

    // MARK: MTPTransport

    func bulkWrite(_ data: Data, timeout: TimeInterval) throws {
        writes.append(data)
    }

    func bulkRead(maxLength: Int, timeout: TimeInterval) throws -> Data {
        readRequests.append(maxLength)
        if stallNextRead {
            stallNextRead = false
            throw MTPTransportError(.stall, status: IOReturnCode.pipeStalled, "stalled")
        }
        if let failure = failNextRead {
            failNextRead = nil
            throw failure
        }
        guard !packetsIn.isEmpty else {
            throw MTPTransportError(.timeout, status: IOReturnCode.timeout, "no data queued")
        }
        var out = Data()
        while let packet = packetsIn.first {
            if out.count + packet.count > maxLength {
                if out.isEmpty { throw MTPTransportError(.io, "babble: packet of \(packet.count) overruns \(maxLength)") }
                break
            }
            packetsIn.removeFirst()
            out.append(packet)
            if packet.count < maxPacketSizeIn || out.count == maxLength { break }
        }
        return out
    }

    func clearStall(_ endpoint: MTPEndpoint) throws { clearedStalls.append(endpoint) }
    func cancelRequest(transactionID: UInt32) throws { cancelledTransactions.append(transactionID) }
    func getDeviceStatus() throws -> Data {
        deviceStatusRequests += 1
        if !deviceStatusReplies.isEmpty { return deviceStatusReplies.removeFirst() }
        return deviceStatus
    }
    func close() { closeCount += 1 }
}

func bytes(_ values: UInt8...) -> [UInt8] { values }

func patterned(_ count: Int, seed: Int = 7) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }
}
