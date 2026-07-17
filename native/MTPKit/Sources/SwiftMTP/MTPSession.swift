import Foundation

/// A non-OK response to an operation.
public struct MTPResponseError: Error, Equatable, CustomStringConvertible, Sendable {
    public let operation: UInt16
    public let code: UInt16
    public let parameters: [UInt32]

    public init(operation: UInt16, code: UInt16, parameters: [UInt32] = []) {
        self.operation = operation
        self.code = code
        self.parameters = parameters
    }

    public var description: String {
        "\(PTPOperation.name(operation)) failed: \(PTPResponseCode.name(code)) (0x\(String(code, radix: 16, uppercase: true)))"
    }
}

/// The device broke the container protocol (lost synchronisation).
public struct MTPProtocolError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "MTP protocol error: \(message)" }
}

/// The host side of a data phase failed: the ``MTPDataSource`` ended early.
/// The session aborts the transaction and stays usable.
public struct MTPDataSourceError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A byte source for an out data phase (SendObject, SendObjectInfo, ...).
public struct MTPDataSource {
    /// Exact number of payload bytes the source will produce.
    public let length: UInt64
    /// Returns up to `maxLength` bytes; an empty result means end of input.
    public let read: (_ maxLength: Int) throws -> Data

    public init(length: UInt64, read: @escaping (_ maxLength: Int) throws -> Data) {
        self.length = length
        self.read = read
    }

    public init(data: Data) {
        var offset = 0
        self.length = UInt64(data.count)
        self.read = { maxLength in
            let end = min(data.count, offset + maxLength)
            defer { offset = end }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
        }
    }

    public init(bytes: [UInt8]) { self.init(data: Data(bytes)) }

    /// Streams `length` bytes from an open file handle.
    public init(fileHandle: FileHandle, length: UInt64) {
        self.length = length
        self.read = { maxLength in
            if #available(macOS 10.15.4, *) {
                return try fileHandle.read(upToCount: maxLength) ?? Data()
            }
            return fileHandle.readData(ofLength: maxLength)
        }
    }
}

/// Receives an in data phase chunk by chunk (in order).
public typealias MTPDataSink = (_ chunk: Data) throws -> Void
/// Progress in payload bytes; `total` is nil for a >4 GB (unknown length) phase.
public typealias MTPProgress = (_ transferred: UInt64, _ total: UInt64?) -> Void

/// PTP/MTP session over an ``MTPTransport``: transaction IDs, data phases,
/// response parsing. Every call is serialised by an internal lock, so one
/// session may be shared across threads but runs one transaction at a time.
public final class MTPSession: @unchecked Sendable {
    public let transport: MTPTransport
    /// Per-transfer timeout for bulk I/O.
    public var timeout: TimeInterval
    /// Size of each bulk transfer in a data phase (rounded to max packet size).
    public var transferChunkSize: Int
    /// MTP 1.1 Appendix H: send the data-phase header in its own packet.
    /// Switched on automatically when the device does so.
    public private(set) var separateHeader = false

    public private(set) var sessionID: UInt32?
    private var nextTransactionID: UInt32 = 1
    private var closed = false
    private let lock = NSRecursiveLock()
    /// Set once a USB error, a lost container sync or a failed abort leaves the
    /// device in an unknown state. Every later transaction fails fast with a
    /// `.noDevice` transport error; the owner should close and reopen.
    private var brokenReasonStorage: String?
    /// Transactions this host abandoned (cancelled or stalled). A late
    /// container that still carries one of these IDs is discarded instead of
    /// being mistaken for the answer to a newer transaction.
    private var abandonedTransactionIDs: [UInt32] = []

    /// How long an abort waits for Get Device Status to report OK.
    public var abortStatusTimeout: TimeInterval = 5
    /// Per-read timeout while discarding stale bulk-in data during an abort.
    public var abortDrainTimeout: TimeInterval = 0.15
    /// Pause between Get Device Status polls during an abort.
    public var abortStatusPollInterval: TimeInterval = 0.02

    public init(transport: MTPTransport, timeout: TimeInterval = 30, transferChunkSize: Int = 1 << 20) {
        self.transport = transport
        self.timeout = timeout
        self.transferChunkSize = transferChunkSize
    }

    public var isSessionOpen: Bool { lock.withLock { sessionID != nil } }

    /// Why the session is unusable, or nil while it is healthy.
    public var brokenReason: String? { lock.withLock { brokenReasonStorage } }
    public var isBroken: Bool { brokenReason != nil }

    private func markBroken(_ reason: String) {
        if brokenReasonStorage == nil { brokenReasonStorage = reason }
    }

    // MARK: - Transactions

    /// Runs one transaction. `dataOut` and `dataIn` are mutually exclusive.
    /// Returns the response when it is OK (0x2001); throws
    /// ``MTPResponseError`` otherwise.
    @discardableResult
    public func execute(
        _ operation: UInt16,
        _ parameters: [UInt32] = [],
        dataOut: MTPDataSource? = nil,
        dataIn: MTPDataSink? = nil,
        progress: MTPProgress? = nil
    ) throws -> PTPResponse {
        let response = try transact(operation, parameters, dataOut: dataOut, dataIn: dataIn, progress: progress)
        guard response.isOK else {
            throw MTPResponseError(operation: operation, code: response.code, parameters: response.parameters)
        }
        return response
    }

    /// Like ``execute(_:_:dataOut:dataIn:progress:)`` but returns non-OK
    /// responses instead of throwing them.
    public func transact(
        _ operation: UInt16,
        _ parameters: [UInt32] = [],
        dataOut: MTPDataSource? = nil,
        dataIn: MTPDataSink? = nil,
        progress: MTPProgress? = nil
    ) throws -> PTPResponse {
        precondition(dataOut == nil || dataIn == nil, "a transaction has at most one data phase")
        return try lock.withLock {
            guard !closed else { throw MTPTransportError(.noDevice, "session is closed") }
            if let brokenReasonStorage {
                throw MTPTransportError(.noDevice, "session is unusable after an earlier failure: \(brokenReasonStorage)")
            }
            let tid = allocateTransactionID()
            do {
                try transport.bulkWrite(Data(PTPCommand(code: operation, transactionID: tid, parameters: parameters).bytes),
                                        timeout: timeout)
                if let dataOut {
                    try sendDataPhase(operation: operation, transactionID: tid, source: dataOut, progress: progress)
                    return try readResponse(operation: operation, transactionID: tid, leftover: [])
                }
                return try receive(operation: operation, transactionID: tid, sink: dataIn, progress: progress)
            } catch let error as MTPTransportError {
                if error.kind == .stall {
                    // A halted pipe stays halted until cleared; clearing is an
                    // endpoint request, not a device reset. Then wait for the
                    // device to settle so the next transaction starts clean.
                    if recover(transactionID: tid, sendCancel: false, clearStalls: true) { throw error }
                }
                markBroken("\(PTPOperation.name(operation)): \(error)")
                throw error
            } catch let error as MTPProtocolError {
                markBroken("\(PTPOperation.name(operation)): \(error)")
                throw error
            } catch {
                // The host side of the data phase failed (the sink or source
                // threw, or the caller cancelled). Cancel the transaction with
                // the class request, wait for the device to report OK and
                // discard whatever it still had queued, so the session survives.
                if !recover(transactionID: tid, sendCancel: true, clearStalls: false) {
                    markBroken("\(PTPOperation.name(operation)): aborting transaction \(tid) did not complete after \(error)")
                }
                throw error
            }
        }
    }

    // MARK: - Abort and recovery

    private func abandon(_ tid: UInt32) {
        guard sessionID != nil else { return }
        abandonedTransactionIDs.append(tid)
        if abandonedTransactionIDs.count > 16 { abandonedTransactionIDs.removeFirst() }
    }

    private func isAbandoned(_ tid: UInt32) -> Bool {
        sessionID != nil && abandonedTransactionIDs.contains(tid)
    }

    /// Brings the device back to idle after an aborted data phase (USB Still
    /// Image Capture Device Definition §5.2): optionally Cancel (0x64) for
    /// `tid`, then poll Get Device Status (0x67) until OK, clearing any stalled
    /// endpoint it names and discarding bulk-in data. Never resets the device.
    /// Returns false when the device did not settle.
    @discardableResult
    func recover(transactionID tid: UInt32, sendCancel: Bool, clearStalls: Bool) -> Bool {
        abandon(tid)
        if clearStalls {
            try? transport.clearStall(.bulkIn)
            try? transport.clearStall(.bulkOut)
        }
        if sendCancel {
            do {
                try transport.cancelRequest(transactionID: tid)
            } catch let error as MTPTransportError where error.kind == .noDevice {
                return false
            } catch {
                // Some devices reject the request; Get Device Status and the
                // drain below still resynchronise them.
            }
        }
        var settled = false
        let deadline = Date().addingTimeInterval(abortStatusTimeout)
        while true {
            discardInput(timeout: abortDrainTimeout)
            do {
                let status = try deviceStatus()
                if status.code == PTPResponseCode.ok {
                    settled = true
                    break
                }
                // A non-OK status may list the endpoints the device halted.
                for endpoint in status.parameters where endpoint != 0 {
                    try? transport.clearStall(endpoint & 0x80 != 0 ? .bulkIn : .bulkOut)
                }
            } catch let error as MTPTransportError where error.kind == .noDevice {
                return false
            } catch {
                // No usable Get Device Status: rely on the drain alone.
                settled = true
                break
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: abortStatusPollInterval)
        }
        discardInput(timeout: abortDrainTimeout)
        return settled
    }

    /// Reads and discards bulk-in data until a read times out (or fails).
    @discardableResult
    private func discardInput(timeout drainTimeout: TimeInterval, maxReads: Int = 256) -> Int {
        var discarded = 0
        for _ in 0..<maxReads {
            guard let data = try? transport.bulkRead(maxLength: inChunk, timeout: drainTimeout) else { break }
            discarded += data.count
        }
        return discarded
    }

    /// Data-in transaction collecting the whole payload.
    public func executeData(_ operation: UInt16, _ parameters: [UInt32] = []) throws -> (PTPResponse, [UInt8]) {
        var payload = Data()
        let response = try execute(operation, parameters, dataIn: { payload.append($0) })
        return (response, [UInt8](payload))
    }

    private func allocateTransactionID() -> UInt32 {
        // Outside a session (GetDeviceInfo, OpenSession) the ID is 0.
        guard sessionID != nil else { return 0 }
        let tid = nextTransactionID
        nextTransactionID = (tid >= 0xFFFF_FFFE) ? 1 : tid + 1
        return tid
    }

    private var inChunk: Int {
        let mps = max(transport.maxPacketSizeIn, 1)
        return max(mps, (transferChunkSize / mps) * mps)
    }

    private var outChunk: Int {
        let mps = max(transport.maxPacketSizeOut, 1)
        return max(mps, (transferChunkSize / mps) * mps)
    }

    /// Reads one transfer, skipping up to `maxEmpty` zero-length packets (the
    /// ZLP that ends a data phase whose length is a multiple of the packet size).
    private func readNonEmpty(maxLength: Int, maxEmpty: Int = 3) throws -> [UInt8] {
        for _ in 0...maxEmpty {
            let data = try transport.bulkRead(maxLength: maxLength, timeout: timeout)
            if !data.isEmpty { return [UInt8](data) }
        }
        throw MTPProtocolError("device sent only zero-length packets where a container was expected")
    }

    private func receive(operation: UInt16, transactionID tid: UInt32,
                         sink: MTPDataSink?, progress: MTPProgress?) throws -> PTPResponse {
        let mps = max(transport.maxPacketSizeIn, 1)
        let chunk = inChunk
        var first: [UInt8]
        var header: PTPContainerHeader
        while true {
            first = try readNonEmpty(maxLength: chunk)
            guard first.count >= PTPContainerHeader.size else {
                throw MTPProtocolError("container of \(first.count) byte(s) is shorter than its header")
            }
            header = try PTPContainerHeader.decode(Array(first[0..<PTPContainerHeader.size]))
            // A late answer to a transaction this host abandoned: skip it.
            guard header.transactionID != tid, isAbandoned(header.transactionID) else { break }
            if header.containerType == .data {
                try skipContainer(first: first, header: header)
            }
        }

        switch header.containerType {
        case .response:
            return try finishResponse(first, operation: operation, transactionID: tid)
        case .data:
            break
        default:
            throw MTPProtocolError("container type \(header.type) where data or a response was expected")
        }

        if sessionID != nil, header.transactionID != tid {
            throw MTPProtocolError("data phase transaction ID \(header.transactionID), expected \(tid)")
        }

        var delivered: UInt64 = 0
        let unknownLength = header.length == PTPContainerHeader.unknownLength
        let total: UInt64? = unknownLength ? nil : UInt64(header.length) - UInt64(PTPContainerHeader.size)
        func deliver(_ bytes: ArraySlice<UInt8>) throws {
            guard !bytes.isEmpty else { return }
            if let sink { try sink(Data(bytes)) }
            delivered += UInt64(bytes.count)
            progress?(delivered, total)
        }
        func deliver(_ data: Data) throws {
            guard !data.isEmpty else { return }
            if let sink { try sink(data) }
            delivered += UInt64(data.count)
            progress?(delivered, total)
        }

        var leftover: [UInt8] = []
        if unknownLength {
            // More than 4 GB: the only end marker is a short packet.
            try deliver(first[PTPContainerHeader.size...])
            var lastWasShort = first.count < chunk
            while !lastWasShort {
                let data = try transport.bulkRead(maxLength: chunk, timeout: timeout)
                try deliver(data)
                lastWasShort = data.count < chunk
            }
        } else {
            let declared = Int(header.length)
            guard declared >= PTPContainerHeader.size else {
                throw MTPProtocolError("data container length \(declared) is shorter than its header")
            }
            if first.count == PTPContainerHeader.size, declared > PTPContainerHeader.size {
                // MTP 1.1 Appendix H: header and payload in separate packets.
                // Both sides must then keep doing so.
                separateHeader = true
            }
            var received: Int
            if first.count > declared {
                // Device omitted the ZLP and the response arrived in the same transfer.
                try deliver(first[PTPContainerHeader.size..<declared])
                leftover = Array(first[declared...])
                received = declared
            } else {
                try deliver(first[PTPContainerHeader.size...])
                received = first.count
            }
            var emptyReads = 0
            while received < declared {
                let remaining = declared - received
                // Never ask for more than the container still holds (rounded up to
                // whole packets), so the response cannot be swallowed.
                let want = min(chunk, (remaining + mps - 1) / mps * mps)
                let data = try transport.bulkRead(maxLength: want, timeout: timeout)
                if data.isEmpty {
                    emptyReads += 1
                    if emptyReads > 3 {
                        throw MTPProtocolError("data phase stalled at \(received) of \(declared) byte(s)")
                    }
                    continue
                }
                emptyReads = 0
                if data.count > remaining {
                    let bytes = [UInt8](data)
                    try deliver(bytes[0..<remaining])
                    leftover = Array(bytes[remaining...])
                    received = declared
                } else {
                    try deliver(data)
                    received += data.count
                }
            }
        }

        let response = try readResponse(operation: operation, transactionID: tid, leftover: leftover)
        if sink == nil {
            throw MTPProtocolError("\(PTPOperation.name(operation)) returned an unexpected data phase of \(delivered) byte(s)")
        }
        return response
    }

    private func readResponse(operation: UInt16, transactionID tid: UInt32, leftover: [UInt8]) throws -> PTPResponse {
        let mps = max(transport.maxPacketSizeIn, 1)
        var bytes = leftover
        func header(_ bytes: [UInt8]) -> PTPContainerHeader? {
            guard bytes.count >= PTPContainerHeader.size else { return nil }
            return try? PTPContainerHeader.decode(Array(bytes[0..<PTPContainerHeader.size]))
        }
        while true {
            if bytes.isEmpty { bytes = try readNonEmpty(maxLength: mps) }
            while true {
                if let h = header(bytes), Int(h.length) <= bytes.count { break }
                // A response split across transfers (only seen with glued leftovers).
                bytes += try readNonEmpty(maxLength: mps)
                if bytes.count > 64 { throw MTPProtocolError("response container larger than 64 bytes") }
            }
            // A late response to a transaction this host abandoned: drop it.
            if let h = header(bytes), h.containerType == .response, h.transactionID != tid,
               isAbandoned(h.transactionID), Int(h.length) >= PTPContainerHeader.size {
                bytes = Array(bytes[Int(h.length)...])
                continue
            }
            return try finishResponse(bytes, operation: operation, transactionID: tid)
        }
    }

    /// Reads and drops the rest of a data container that began with `first`.
    private func skipContainer(first: [UInt8], header: PTPContainerHeader) throws {
        let chunk = inChunk
        if header.length == PTPContainerHeader.unknownLength {
            var last = first.count
            while last >= chunk { last = try transport.bulkRead(maxLength: chunk, timeout: timeout).count }
            return
        }
        var received = first.count
        var empty = 0
        while received < Int(header.length) {
            let data = try transport.bulkRead(maxLength: chunk, timeout: timeout)
            if data.isEmpty {
                empty += 1
                if empty > 3 { break }
            }
            received += data.count
        }
    }

    private func finishResponse(_ bytes: [UInt8], operation: UInt16, transactionID tid: UInt32) throws -> PTPResponse {
        let response: PTPResponse
        do {
            response = try PTPResponse.decode(bytes)
        } catch let error as PTPDecodingError {
            throw MTPProtocolError("\(PTPOperation.name(operation)): \(error.message)")
        }
        if sessionID != nil, response.transactionID != tid {
            throw MTPProtocolError("response transaction ID \(response.transactionID), expected \(tid)")
        }
        return response
    }

    private func sendDataPhase(operation: UInt16, transactionID tid: UInt32,
                               source: MTPDataSource, progress: MTPProgress?) throws {
        let mps = max(transport.maxPacketSizeOut, 1)
        let chunk = outChunk
        let containerLength = UInt64(PTPContainerHeader.size) + source.length
        let header = PTPContainerHeader(
            length: containerLength > 0xFFFF_FFFF ? PTPContainerHeader.unknownLength : UInt32(containerLength),
            type: .data, code: operation, transactionID: tid
        )

        var buffer = Data(header.bytes)
        let splitHeader = separateHeader
        if splitHeader {
            try transport.bulkWrite(buffer, timeout: timeout)
            buffer.removeAll(keepingCapacity: true)
        }

        var sent: UInt64 = 0
        repeat {
            // Every write but the last is a whole number of packets, so no short
            // packet ends the container early.
            let room = chunk - buffer.count
            let want = Int(min(UInt64(room), source.length - sent))
            var gathered = 0
            while gathered < want {
                let piece = try source.read(want - gathered)
                if piece.isEmpty {
                    throw MTPDataSourceError("data source ended after \(sent + UInt64(gathered)) of \(source.length) byte(s)")
                }
                buffer.append(piece)
                gathered += piece.count
            }
            sent += UInt64(gathered)
            if !buffer.isEmpty {
                try transport.bulkWrite(buffer, timeout: timeout)
                buffer.removeAll(keepingCapacity: true)
                if gathered > 0 { progress?(sent, source.length) }
            }
        } while sent < source.length

        // A transfer that is an exact multiple of the packet size has no short
        // packet to end it, so terminate it with a zero-length packet.
        let transferLength = splitHeader ? source.length : containerLength
        if transferLength > 0, transferLength % UInt64(mps) == 0 {
            try transport.bulkWrite(Data(), timeout: timeout)
        }
    }

    /// Discards whatever the device still has queued on bulk-in from an
    /// earlier host process that died mid-transaction (its reply would
    /// otherwise answer our first command). Reads with a short timeout until
    /// one times out. Returns the number of bytes discarded. Never resets.
    @discardableResult
    public func drainStaleInput(timeout drainTimeout: TimeInterval = 0.2, maxReads: Int = 64) -> Int {
        lock.withLock {
            var discarded = 0
            for _ in 0..<maxReads {
                guard let data = try? transport.bulkRead(maxLength: inChunk, timeout: drainTimeout) else { break }
                discarded += data.count
            }
            return discarded
        }
    }

    // MARK: - Session management

    public func getDeviceInfo() throws -> PTPDeviceInfo {
        let (_, bytes) = try executeData(PTPOperation.getDeviceInfo)
        return try PTPDeviceInfo.decode(bytes)
    }

    /// Opens session `id` (OpenSession runs with
    /// transaction ID 0, then IDs count from 1). A SessionAlreadyOpen reply is
    /// answered with CloseSession and a second OpenSession.
    public func openSession(id: UInt32 = 1) throws {
        try lock.withLock {
            precondition(id != 0 && id != 0xFFFF_FFFF, "session ID 0 and 0xFFFFFFFF are reserved")
            let first = try transact(PTPOperation.openSession, [id])
            if first.code == PTPResponseCode.sessionAlreadyOpen {
                _ = try? transact(PTPOperation.closeSession)
                try execute(PTPOperation.openSession, [id])
            } else if !first.isOK {
                throw MTPResponseError(operation: PTPOperation.openSession, code: first.code, parameters: first.parameters)
            }
            sessionID = id
            nextTransactionID = 1
        }
    }

    public func closeSession() throws {
        try lock.withLock {
            defer { sessionID = nil }
            try execute(PTPOperation.closeSession)
        }
    }

    /// CloseSession (when open) and release the interface. Never resets.
    public func close() {
        lock.withLock {
            guard !closed else { return }
            if sessionID != nil { try? closeSession() }
            closed = true
            transport.close()
        }
    }

    // MARK: - Operations

    public func getStorageIDs() throws -> [UInt32] {
        let (_, bytes) = try executeData(PTPOperation.getStorageIDs)
        var r = PTPReader(bytes)
        return try r.u32Array("StorageIDs")
    }

    public func getStorageInfo(_ storageID: UInt32) throws -> PTPStorageInfo {
        let (_, bytes) = try executeData(PTPOperation.getStorageInfo, [storageID])
        return try PTPStorageInfo.decode(bytes)
    }

    public func getNumObjects(storageID: UInt32, format: UInt16 = 0, parent: UInt32) throws -> UInt32 {
        let response = try execute(PTPOperation.getNumObjects, [storageID, UInt32(format), parent])
        guard let count = response.parameters.first else {
            throw MTPProtocolError("GetNumObjects response carries no count")
        }
        return count
    }

    /// `parent` is ``PTPHandle/root`` for the storage root.
    public func getObjectHandles(storageID: UInt32, format: UInt16 = 0, parent: UInt32) throws -> [UInt32] {
        let (_, bytes) = try executeData(PTPOperation.getObjectHandles, [storageID, UInt32(format), parent])
        var r = PTPReader(bytes)
        return try r.u32Array("ObjectHandles")
    }

    public func getObjectInfo(_ handle: UInt32) throws -> PTPObjectInfo {
        let (_, bytes) = try executeData(PTPOperation.getObjectInfo, [handle])
        return try PTPObjectInfo.decode(bytes)
    }

    /// Streams the whole object into `sink`.
    public func getObject(_ handle: UInt32, sink: @escaping MTPDataSink, progress: MTPProgress? = nil) throws {
        try execute(PTPOperation.getObject, [handle], dataIn: sink, progress: progress)
    }

    /// Standard GetPartialObject (32-bit offset). Returns the bytes read.
    public func getPartialObject(_ handle: UInt32, offset: UInt32, maxBytes: UInt32) throws -> Data {
        var data = Data()
        try execute(PTPOperation.getPartialObject, [handle, offset, maxBytes], dataIn: { data.append($0) })
        return data
    }

    /// Android GetPartialObject64 (0x95C1): 64-bit offset.
    public func getPartialObject64(_ handle: UInt32, offset: UInt64, maxBytes: UInt32) throws -> Data {
        var data = Data()
        try execute(PTPOperation.androidGetPartialObject64,
                    [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), maxBytes],
                    dataIn: { data.append($0) })
        return data
    }

    /// Returns the (storage, parent, handle) the device assigned.
    public func sendObjectInfo(storageID: UInt32, parent: UInt32, info: PTPObjectInfo)
        throws -> (storageID: UInt32, parent: UInt32, handle: UInt32) {
        let response = try execute(PTPOperation.sendObjectInfo, [storageID, parent],
                                   dataOut: MTPDataSource(bytes: try info.encode()))
        guard response.parameters.count >= 3 else {
            throw MTPProtocolError("SendObjectInfo response carries \(response.parameters.count) parameter(s), need 3")
        }
        return (response.parameters[0], response.parameters[1], response.parameters[2])
    }

    /// Sends the object announced by the preceding SendObjectInfo.
    public func sendObject(_ source: MTPDataSource, progress: MTPProgress? = nil) throws {
        try execute(PTPOperation.sendObject, dataOut: source, progress: progress)
    }

    public func deleteObject(_ handle: UInt32, format: UInt16 = 0) throws {
        try execute(PTPOperation.deleteObject, [handle, UInt32(format)])
    }

    public func setObjectPropValue(_ handle: UInt32, property: UInt16, value: PTPValue) throws {
        var w = PTPWriter()
        try value.encode(into: &w)
        try execute(PTPOperation.setObjectPropValue, [handle, UInt32(property)], dataOut: MTPDataSource(bytes: w.bytes))
    }

    /// The value's datatype is not in the reply, so the caller names it.
    public func getObjectPropValue(_ handle: UInt32, property: UInt16, dataType: UInt16) throws -> PTPValue {
        let (_, bytes) = try executeData(PTPOperation.getObjectPropValue, [handle, UInt32(property)])
        var r = PTPReader(bytes)
        return try PTPValue.decode(dataType, from: &r)
    }

    /// GetObjectPropList. With `depth` 1, `handle` 0 means the children of the
    /// root; a nonzero handle means that object's children (Android also
    /// returns the object itself). 0xFFFFFFFF means every object on the device.
    public func getObjectPropList(handle: UInt32, format: UInt32 = 0, property: UInt32,
                                  group: UInt32 = 0, depth: UInt32 = 1,
                                  progress: MTPProgress? = nil) throws -> [MTPObjectPropListElement] {
        var payload = Data()
        try execute(PTPOperation.getObjectPropList, [handle, format, property, group, depth],
                    dataIn: { payload.append($0) }, progress: progress)
        return try MTPObjectPropList.decode([UInt8](payload))
    }

    /// Class request 0x64 for the transaction in flight. Not a reset.
    public func cancelTransaction(_ transactionID: UInt32) throws {
        try transport.cancelRequest(transactionID: transactionID)
    }

    public func deviceStatus() throws -> PTPDeviceStatus {
        try PTPDeviceStatus.decode([UInt8](try transport.getDeviceStatus()))
    }
}
