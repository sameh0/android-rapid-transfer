import Foundation
import MTPKit
@testable import SwiftMTP

/// An in-memory MTP device behind the ``MTPTransport`` seam. It decodes
/// command containers, runs the operations against a simulated object tree
/// (Android semantics where they matter), and serves replies with USB bulk
/// rules: a read gathers packets until `maxLength` or a short/zero-length
/// packet; a transfer that is a multiple of the packet size ends with a ZLP.
final class FakeMTPDevice: MTPTransport, @unchecked Sendable {
    struct Object {
        var handle: UInt32
        var storage: UInt32
        /// 0 for a storage-root object (as Android reports ParentObject).
        var parent: UInt32
        var name: String
        var format: UInt16
        var data: Data
        var modified: String
        var created: String
        var isFolder: Bool { format == PTPObjectFormat.association }
    }

    private struct OutTransfer {
        var bytes: Data
        var offset = 0
        var tid: UInt32
        var isObjectData = false
        var isResponse = false
    }

    private struct PendingOut {
        var command: PTPCommand
        var expected: Int?
        var received = Data()
    }

    let maxPacketSizeIn: Int
    let maxPacketSizeOut: Int
    private let lock = NSRecursiveLock()

    var deviceInfo = PTPDeviceInfo(
        vendorExtensionDesc: "microsoft.com: 1.0; android.com: 1.0;",
        operationsSupported: [0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x100B,
                              0x100C, 0x100D, 0x9803, 0x9804, 0x9805],
        manufacturer: "FakeCo", model: "Fake Phone 5G", deviceVersion: "1.0", serialNumber: "FAKE0001"
    )
    var storages: [(UInt32, PTPStorageInfo)] = [
        (0x10001, PTPStorageInfo(maxCapacity: 128_000_000_000, freeSpaceInBytes: 64_000_000_000,
                                 storageDescription: "Internal shared storage")),
        (0x20001, PTPStorageInfo(storageType: 4, maxCapacity: 32_000_000_000, freeSpaceInBytes: 1_000_000,
                                 storageDescription: "SD card"))
    ]

    // MARK: Behaviour knobs

    var supportsPropList = true
    /// Refuse the all-properties wildcard for a parent with more children.
    var wildcardRefuseAbove: Int?
    var wildcardRefusalCode: UInt16 = PTPResponseCode.mtpInvalidObjectPropCode
    /// Per-property GetObjectPropList calls for these properties fail.
    var failingProperties: Set<UInt16> = []
    var storeFull = false
    var renameAnswersGeneralError = false
    var sendsZLP = true
    /// The device disappears once this many GetObject payload bytes were served.
    var vanishAfterObjectBytes: Int?
    /// The device disappears once this many SendObject bytes arrived.
    var vanishAfterSendObjectBytes: Int?
    /// Get Device Status answers DeviceBusy this many times after a cancel.
    var statusBusyPollsAfterCancel = 1
    /// After a cancel, the device still answers the cancelled transaction.
    var answersCancelledTransaction = true
    var stallNextRead = false
    /// Sleep per bulk read of object data (lets a test cancel mid-transfer).
    var objectReadDelay: TimeInterval = 0
    /// Sleep per bulk write of SendObject data.
    var objectWriteDelay: TimeInterval = 0
    /// OpenSession answers this code instead of OK.
    var openSessionFailure: UInt16?
    /// GetStorageIDs sends an empty data phase (Samsung before "Allow").
    var emptyStorageIDsPayload = false
    /// DeleteObject answers this code instead of deleting.
    var deleteFailure: UInt16?
    /// An earlier host died in the middle of this SendObject transaction: the
    /// next bulk write is taken as the rest of its data and answered with
    /// GeneralError for it (a Xiaomi after the app quit mid-upload).
    var abandonedSendObject: UInt32?

    /// The phone is unplugged.
    func vanish() {
        lock.withLock { gone = true }
    }

    // MARK: Recording

    private(set) var objects: [UInt32: Object] = [:]
    private var order: [UInt32] = []
    private var nextHandle: UInt32 = 100
    private(set) var commands: [PTPCommand] = []
    private(set) var cancelRequests: [UInt32] = []
    private(set) var statusRequests = 0
    private(set) var clearedStalls: [MTPEndpoint] = []
    private(set) var closeCount = 0
    private(set) var gone = false
    private(set) var sessionOpen = false
    private(set) var zeroLengthWrites = 0

    // MARK: Wire state

    private var output: [OutTransfer] = []
    private var pendingOut: PendingOut?
    private var pendingSendObject: UInt32?
    private var objectBytesServed = 0
    private var statusBusyRemaining = 0

    init(maxPacketSize: Int = 512) {
        maxPacketSizeIn = maxPacketSize
        maxPacketSizeOut = maxPacketSize
    }

    // MARK: Seeding and inspection

    private func split(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    func child(named name: String, parent: UInt32, storage: UInt32) -> Object? {
        lock.withLock {
            order.lazy.compactMap { self.objects[$0] }
                .first { $0.parent == parent && $0.storage == storage && $0.name == name }
        }
    }

    /// Exact-case lookup.
    func object(at path: String, storage: UInt32 = 0x10001) -> Object? {
        lock.withLock {
            var parent: UInt32 = 0
            var found: Object?
            for component in split(path) {
                guard let next = child(named: component, parent: parent, storage: storage) else { return nil }
                found = next
                parent = next.handle
            }
            return found
        }
    }

    /// Names of `path`'s children in device order.
    func childNames(_ path: String, storage: UInt32 = 0x10001) -> [String] {
        lock.withLock {
            let parent = path == "/" ? 0 : (object(at: path, storage: storage)?.handle ?? 0xDEAD)
            return order.compactMap { objects[$0] }.filter { $0.parent == parent && $0.storage == storage }.map(\.name)
        }
    }

    @discardableResult
    func insert(name: String, parent: UInt32, storage: UInt32, format: UInt16, data: Data = Data(),
                modified: String = "20240102T030405", created: String = "20230101T000000") -> UInt32 {
        lock.withLock {
            let handle = nextHandle
            nextHandle += 1
            objects[handle] = Object(handle: handle, storage: storage, parent: parent, name: name, format: format,
                                     data: data, modified: modified, created: created)
            order.append(handle)
            return handle
        }
    }

    /// mkdir -p with exact-case components.
    @discardableResult
    func addFolder(_ path: String, storage: UInt32 = 0x10001, modified: String = "20240102T030405") -> UInt32 {
        lock.withLock {
            var parent: UInt32 = 0
            for component in split(path) {
                if let existing = child(named: component, parent: parent, storage: storage) {
                    parent = existing.handle
                } else {
                    parent = insert(name: component, parent: parent, storage: storage,
                                    format: PTPObjectFormat.association, modified: modified)
                }
            }
            return parent
        }
    }

    @discardableResult
    func addFile(_ path: String, data: Data, storage: UInt32 = 0x10001, modified: String = "20240102T030405",
                 created: String = "20230101T000000") -> UInt32 {
        lock.withLock {
            let components = split(path)
            let folder = components.dropLast().joined(separator: "/")
            let parent = folder.isEmpty ? 0 : addFolder(folder, storage: storage)
            return insert(name: components.last!, parent: parent, storage: storage,
                          format: PTPObjectFormat.exifJPEG, data: data, modified: modified, created: created)
        }
    }

    func setModified(_ handle: UInt32, modified: String, created: String? = nil) {
        lock.withLock {
            objects[handle]?.modified = modified
            if let created { objects[handle]?.created = created }
        }
    }

    /// Removes an object behind the provider's back (a change made on the phone).
    func removeExternally(_ handle: UInt32) {
        lock.withLock { delete(handle) }
    }

    /// The phone comes back after vanishing (new enumeration, no session).
    func reattach() {
        lock.withLock {
            gone = false
            sessionOpen = false
            output.removeAll()
            pendingOut = nil
            vanishAfterObjectBytes = nil
            vanishAfterSendObjectBytes = nil
        }
    }

    func calls(_ code: UInt16) -> [PTPCommand] {
        lock.withLock { commands.filter { $0.code == code } }
    }

    func propListCalls(property: UInt32) -> Int {
        lock.withLock { commands.filter { $0.code == PTPOperation.getObjectPropList && $0.parameters[2] == property }.count }
    }

    func resetRecording() {
        lock.withLock {
            commands.removeAll()
            cancelRequests.removeAll()
            statusRequests = 0
        }
    }

    // MARK: MTPTransport

    func bulkWrite(_ data: Data, timeout: TimeInterval) throws {
        let delay = lock.withLock { pendingOut?.command.code == PTPOperation.sendObject ? objectWriteDelay : 0 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try lock.withLock {
            if gone { throw MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "fake device is gone") }
            if let stale = abandonedSendObject, !data.isEmpty {
                abandonedSendObject = nil
                respond(PTPResponseCode.generalError, tid: stale)
                return
            }
            if var pending = pendingOut {
                if data.isEmpty {
                    zeroLengthWrites += 1
                    return
                }
                pending.received.append(data)
                if pending.expected == nil, pending.received.count >= 12 {
                    let header = try PTPContainerHeader.decode([UInt8](pending.received.prefix(12)))
                    pending.expected = Int(header.length)
                }
                if pending.command.code == PTPOperation.sendObject, let limit = vanishAfterSendObjectBytes,
                   pending.received.count - 12 > limit {
                    gone = true
                    pendingOut = nil
                    throw MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "fake device vanished mid-upload")
                }
                if let expected = pending.expected, pending.received.count >= expected {
                    pendingOut = nil
                    finishDataOut(pending)
                } else {
                    pendingOut = pending
                }
                return
            }
            if data.isEmpty {
                zeroLengthWrites += 1
                return
            }
            let command = try PTPCommand.decode([UInt8](data))
            commands.append(command)
            handle(command)
        }
    }

    func bulkRead(maxLength: Int, timeout: TimeInterval) throws -> Data {
        var delay: TimeInterval = 0
        let result: Data = try lock.withLock {
            if gone { throw MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "fake device is gone") }
            if stallNextRead {
                stallNextRead = false
                throw MTPTransportError(.stall, status: IOReturnCode.pipeStalled, "stalled")
            }
            var out = Data()
            while !output.isEmpty {
                var transfer = output[0]
                let remaining = transfer.bytes.count - transfer.offset
                if remaining == 0 {
                    // Only the ZLP of this transfer is left: it ends the read.
                    output.removeFirst()
                    return out
                }
                let n = min(remaining, maxLength - out.count)
                if n <= 0 { return out }
                if transfer.isObjectData {
                    delay = objectReadDelay
                    objectBytesServed += n
                    if let limit = vanishAfterObjectBytes, objectBytesServed > limit {
                        gone = true
                        output.removeAll()
                        throw MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "fake device vanished mid-download")
                    }
                }
                out.append(transfer.bytes.subdata(in: transfer.offset..<(transfer.offset + n)))
                transfer.offset += n
                if transfer.offset < transfer.bytes.count {
                    output[0] = transfer
                    return out
                }
                let aligned = transfer.bytes.count % maxPacketSizeIn == 0
                if !aligned {
                    output.removeFirst()
                    return out
                }
                if sendsZLP {
                    if out.count < maxLength {
                        output.removeFirst() // the ZLP arrives within this read
                    } else {
                        output[0] = transfer // the ZLP is the next read
                    }
                    return out
                }
                // No ZLP: the read runs on into the next transfer.
                output.removeFirst()
                if out.count == maxLength { return out }
            }
            if out.isEmpty {
                throw MTPTransportError(.timeout, status: IOReturnCode.timeout, "no data queued")
            }
            return out
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return result
    }

    func clearStall(_ endpoint: MTPEndpoint) throws {
        lock.withLock { clearedStalls.append(endpoint) }
    }

    func cancelRequest(transactionID: UInt32) throws {
        try lock.withLock {
            if gone { throw MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "fake device is gone") }
            cancelRequests.append(transactionID)
            statusBusyRemaining = statusBusyPollsAfterCancel
            // A data phase in flight stops after what is already queued on the
            // endpoint (two packets here); its OK response is never sent.
            if let index = output.firstIndex(where: { $0.tid == transactionID && !$0.isResponse }) {
                var transfer = output[index]
                let keep = min(transfer.bytes.count, transfer.offset + 2 * maxPacketSizeIn)
                transfer.bytes = transfer.bytes.prefix(keep)
                output[index] = transfer
            }
            output.removeAll { $0.tid == transactionID && $0.isResponse }
            if let pending = pendingOut, pending.command.transactionID == transactionID {
                pendingOut = nil
                if pending.command.code == PTPOperation.sendObject, let handle = pendingSendObject {
                    delete(handle) // Android drops a cancelled upload
                    pendingSendObject = nil
                }
            }
            if answersCancelledTransaction {
                respond(PTPResponseCode.transactionCancelled, tid: transactionID)
            }
        }
    }

    func getDeviceStatus() throws -> Data {
        try lock.withLock {
            if gone { throw MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "fake device is gone") }
            statusRequests += 1
            if statusBusyRemaining > 0 {
                statusBusyRemaining -= 1
                return Data([4, 0, 0x19, 0x20])
            }
            return Data([4, 0, 0x01, 0x20])
        }
    }

    func close() {
        lock.withLock { closeCount += 1 }
    }

    // MARK: Replies

    private func respond(_ code: UInt16, tid: UInt32, params: [UInt32] = []) {
        output.append(OutTransfer(bytes: Data(PTPResponse(code: code, transactionID: tid, parameters: params).bytes),
                                  tid: tid, isResponse: true))
    }

    private func sendData(_ command: PTPCommand, _ payload: Data, isObject: Bool = false) {
        var bytes = Data(PTPContainerHeader(length: UInt32(12 + payload.count), type: .data, code: command.code,
                                            transactionID: command.transactionID).bytes)
        bytes.append(payload)
        output.append(OutTransfer(bytes: bytes, tid: command.transactionID, isObjectData: isObject))
    }

    private func children(of parent: UInt32, storage: UInt32?) -> [Object] {
        order.compactMap { objects[$0] }.filter { $0.parent == parent && (storage == nil || $0.storage == storage) }
    }

    private func delete(_ handle: UInt32) {
        for child in children(of: handle, storage: nil) { delete(child.handle) }
        objects[handle] = nil
        order.removeAll { $0 == handle }
    }

    private func handle(_ command: PTPCommand) {
        let tid = command.transactionID
        let p = command.parameters
        func param(_ index: Int) -> UInt32 { index < p.count ? p[index] : 0 }
        switch command.code {
        case PTPOperation.getDeviceInfo:
            sendData(command, Data((try? deviceInfo.encode()) ?? []))
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.openSession:
            if let failure = openSessionFailure {
                respond(failure, tid: tid)
            } else if sessionOpen {
                respond(PTPResponseCode.sessionAlreadyOpen, tid: tid)
            } else {
                sessionOpen = true
                respond(PTPResponseCode.ok, tid: tid)
            }
        case PTPOperation.closeSession:
            sessionOpen = false
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.getStorageIDs:
            var w = PTPWriter()
            w.u32Array(storages.map(\.0))
            sendData(command, emptyStorageIDsPayload ? Data() : w.data)
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.getStorageInfo:
            guard let info = storages.first(where: { $0.0 == param(0) })?.1 else {
                respond(PTPResponseCode.invalidStorageID, tid: tid)
                return
            }
            sendData(command, Data((try? info.encode()) ?? []))
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.getObjectHandles:
            let storage = param(0)
            let parent = param(2)
            let list: [Object]
            if parent == PTPHandle.root || parent == 0 {
                list = children(of: 0, storage: storage == PTPHandle.allStorages ? nil : storage)
            } else {
                guard let folder = objects[parent], folder.isFolder else {
                    respond(PTPResponseCode.invalidParentObject, tid: tid)
                    return
                }
                list = children(of: folder.handle, storage: nil)
            }
            var w = PTPWriter()
            w.u32Array(list.map(\.handle))
            sendData(command, w.data)
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.getObjectInfo:
            guard let object = objects[param(0)] else {
                respond(PTPResponseCode.invalidObjectHandle, tid: tid)
                return
            }
            let info = PTPObjectInfo(
                storageID: object.storage, objectFormat: object.format,
                compressedSize: object.isFolder ? 4096 : UInt32(min(object.data.count, 0xFFFF_FFFF)),
                parentObject: object.parent,
                associationType: object.isFolder ? PTPAssociationType.genericFolder : 0,
                filename: object.name, captureDate: object.created, modificationDate: object.modified
            )
            sendData(command, Data((try? info.encode()) ?? []))
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.getObject:
            guard let object = objects[param(0)], !object.isFolder else {
                respond(PTPResponseCode.invalidObjectHandle, tid: tid)
                return
            }
            sendData(command, object.data, isObject: true)
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.deleteObject:
            let handle = param(0)
            if let failure = deleteFailure {
                respond(failure, tid: tid)
            } else if handle == PTPHandle.root {
                order.map { $0 }.forEach(delete)
                respond(PTPResponseCode.ok, tid: tid)
            } else if objects[handle] == nil {
                respond(PTPResponseCode.invalidObjectHandle, tid: tid)
            } else {
                delete(handle)
                respond(PTPResponseCode.ok, tid: tid)
            }
        case PTPOperation.sendObjectInfo, PTPOperation.sendObject, PTPOperation.setObjectPropValue:
            pendingOut = PendingOut(command: command)
        case PTPOperation.getObjectPropValue:
            guard let object = objects[param(0)] else {
                respond(PTPResponseCode.invalidObjectHandle, tid: tid)
                return
            }
            guard let value = value(of: object, property: UInt16(truncatingIfNeeded: param(1))) else {
                respond(PTPResponseCode.mtpObjectPropNotSupported, tid: tid)
                return
            }
            var w = PTPWriter()
            try? value.encode(into: &w)
            sendData(command, w.data)
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.getObjectPropList:
            getObjectPropList(command)
        default:
            respond(PTPResponseCode.operationNotSupported, tid: tid)
        }
    }

    private func value(of object: Object, property: UInt16) -> PTPValue? {
        switch property {
        case MTPObjectProperty.storageID: return .uint32(object.storage)
        case MTPObjectProperty.objectFormat: return .uint16(object.format)
        case MTPObjectProperty.objectSize: return .uint64(UInt64(object.isFolder ? 4096 : object.data.count))
        case MTPObjectProperty.objectFileName: return .string(object.name)
        case MTPObjectProperty.dateCreated: return object.created.isEmpty ? .undefined : .string(object.created)
        case MTPObjectProperty.dateModified: return object.modified.isEmpty ? .undefined : .string(object.modified)
        case MTPObjectProperty.parentObject: return .uint32(object.parent)
        default: return nil
        }
    }

    private func getObjectPropList(_ command: PTPCommand) {
        let tid = command.transactionID
        guard supportsPropList else {
            respond(PTPResponseCode.operationNotSupported, tid: tid)
            return
        }
        let handle = command.parameters[0]
        let property = command.parameters[2]
        var list: [Object]
        var childCount: Int
        if handle == PTPHandle.root {
            // Android: every object, plus the root's children again.
            list = order.compactMap { objects[$0] } + children(of: 0, storage: nil)
            childCount = list.count
        } else if handle == 0 {
            // Android: the root children of every storage.
            list = children(of: 0, storage: nil)
            childCount = list.count
        } else {
            guard let object = objects[handle] else {
                respond(PTPResponseCode.invalidObjectHandle, tid: tid)
                return
            }
            // Android also returns the object itself.
            let kids = children(of: handle, storage: nil)
            list = [object] + kids
            childCount = kids.count
        }
        var elements: [MTPObjectPropListElement] = []
        if property == MTPObjectProperty.all {
            if let limit = wildcardRefuseAbove, childCount > limit {
                respond(wildcardRefusalCode, tid: tid)
                return
            }
            let all = [MTPObjectProperty.storageID, MTPObjectProperty.objectFormat, MTPObjectProperty.objectSize,
                       MTPObjectProperty.objectFileName, MTPObjectProperty.dateCreated, MTPObjectProperty.dateModified,
                       MTPObjectProperty.parentObject]
            for object in list {
                for code in all {
                    if let value = value(of: object, property: code) {
                        elements.append(MTPObjectPropListElement(handle: object.handle, propertyCode: code, value: value))
                    }
                }
            }
        } else {
            let code = UInt16(truncatingIfNeeded: property)
            if failingProperties.contains(code) {
                respond(PTPResponseCode.generalError, tid: tid)
                return
            }
            for object in list {
                if let value = value(of: object, property: code) {
                    elements.append(MTPObjectPropListElement(handle: object.handle, propertyCode: code, value: value))
                }
            }
        }
        sendData(command, Data((try? MTPObjectPropList.encode(elements)) ?? []))
        respond(PTPResponseCode.ok, tid: tid)
    }

    private func finishDataOut(_ pending: PendingOut) {
        let command = pending.command
        let tid = command.transactionID
        let expected = pending.expected ?? pending.received.count
        let payload = pending.received.subdata(in: 12..<expected)
        switch command.code {
        case PTPOperation.sendObjectInfo:
            let storage = command.parameters[0]
            let parentParam = command.parameters[1]
            let parent = parentParam == PTPHandle.root ? 0 : parentParam
            if storeFull {
                respond(PTPResponseCode.storeFull, tid: tid)
                return
            }
            guard parent == 0 || objects[parent]?.isFolder == true else {
                respond(PTPResponseCode.invalidParentObject, tid: tid)
                return
            }
            guard let info = try? PTPObjectInfo.decode([UInt8](payload)) else {
                respond(PTPResponseCode.invalidDataset, tid: tid)
                return
            }
            // Android's storage is case-insensitive: a clashing name is refused.
            let clash = children(of: parent, storage: storage)
                .contains { $0.name.lowercased() == info.filename.lowercased() }
            if clash {
                respond(PTPResponseCode.generalError, tid: tid)
                return
            }
            let handle = insert(name: info.filename, parent: parent, storage: storage, format: info.objectFormat,
                                modified: info.modificationDate, created: info.captureDate)
            pendingSendObject = info.isFolder ? nil : handle
            respond(PTPResponseCode.ok, tid: tid, params: [storage, parentParam, handle])
        case PTPOperation.sendObject:
            guard let handle = pendingSendObject else {
                respond(PTPResponseCode.noValidObjectInfo, tid: tid)
                return
            }
            objects[handle]?.data = payload
            pendingSendObject = nil
            respond(PTPResponseCode.ok, tid: tid)
        case PTPOperation.setObjectPropValue:
            let handle = command.parameters[0]
            let property = UInt16(truncatingIfNeeded: command.parameters[1])
            guard objects[handle] != nil else {
                respond(PTPResponseCode.invalidObjectHandle, tid: tid)
                return
            }
            var reader = PTPReader([UInt8](payload))
            guard property == MTPObjectProperty.objectFileName, let name = try? reader.string() else {
                respond(PTPResponseCode.mtpObjectPropNotSupported, tid: tid)
                return
            }
            if renameAnswersGeneralError {
                respond(PTPResponseCode.generalError, tid: tid)
                return
            }
            objects[handle]?.name = name
            respond(PTPResponseCode.ok, tid: tid)
        default:
            respond(PTPResponseCode.operationNotSupported, tid: tid)
        }
    }
}

/// Opens the fake device for a ``SwiftMTPProvider``, counting opens.
final class FakeDeviceFactory: @unchecked Sendable {
    let device: FakeMTPDevice
    private let lock = NSLock()
    private var openCount = 0
    var openDelay: TimeInterval = 0
    var failNextOpen: Error?

    init(device: FakeMTPDevice) {
        self.device = device
    }

    var opens: Int { lock.withLock { openCount } }

    func open() throws -> MTPOpenedDevice {
        if openDelay > 0 { Thread.sleep(forTimeInterval: openDelay) }
        try lock.withLock {
            if let failure = failNextOpen {
                failNextOpen = nil
                throw failure
            }
            if device.gone { throw MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "no device") }
            openCount += 1
        }
        return MTPOpenedDevice(transport: device, usb: USBDeviceInfo(
            vendorID: 0x2717, productID: 0xFF48, deviceRelease: 0x0606,
            manufacturer: "FakeCo", product: "Fake Phone 5G", serialNumber: "FAKE0001"))
    }
}
