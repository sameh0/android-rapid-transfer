import Foundation
import MTPKit

/// A transport the provider has opened (claimed) and now owns.
public struct MTPOpenedDevice: @unchecked Sendable {
    public let transport: MTPTransport
    public let usb: USBDeviceInfo
    /// The interface had no string; accept it only if its DeviceInfo names a
    /// Microsoft/Fujifilm MTP vendor extension.
    public let needsVendorExtensionCheck: Bool

    public init(transport: MTPTransport, usb: USBDeviceInfo, needsVendorExtensionCheck: Bool = false) {
        self.transport = transport
        self.usb = usb
        self.needsVendorExtensionCheck = needsVendorExtensionCheck
    }
}

/// Metadata of one device object, as far as it is known.
struct ObjectMeta: Equatable {
    var handle: UInt32
    var name: String
    var format: UInt16
    var size: UInt64
    /// Raw PTP DateTime (DateModified, else DateCreated).
    var modified: String
    /// ParentObject as the device reports it (0 for a storage-root object on Android).
    var parent: UInt32

    var isFolder: Bool { format == PTPObjectFormat.association }
}

/// Names (and formats) of one directory's children in device order.
struct DirectoryIndex {
    var handles: [UInt32]
    var names: [UInt32: String]
    var formats: [UInt32: UInt16]
    var fetchedAt: TimeInterval

    func handle(named name: String) -> UInt32? {
        let key = DevicePath.fold(name)
        // First match in device order wins.
        return handles.first { names[$0].map(DevicePath.fold) == key }
    }

    mutating func add(_ handle: UInt32, name: String, format: UInt16) {
        if !handles.contains(handle) { handles.append(handle) }
        names[handle] = name
        formats[handle] = format
    }

    mutating func remove(_ handle: UInt32) {
        handles.removeAll { $0 == handle }
        names[handle] = nil
        formats[handle] = nil
    }
}

/// Where a path resolved to.
struct ResolvedObject {
    var handle: UInt32
    var isFolder: Bool
    /// Device spelling of the last component ("" for the root).
    var name: String
    /// The normalized input path, in the caller's spelling.
    var fullPath: String
    /// Handle of the directory it was found in (0xFFFFFFFF for storage-root objects).
    var parentHandle: UInt32

    static func root() -> ResolvedObject {
        ResolvedObject(handle: PTPHandle.root, isFolder: true, name: "", fullPath: "/", parentHandle: PTPHandle.root)
    }
}

enum PropListStrategy: Equatable {
    case all
    case perProperty
    case unsupported
}

/// The synchronous MTP engine behind ``SwiftMTPProvider``. Every method runs
/// on the provider's dedicated I/O queue, one at a time; nothing here is
/// thread-safe on its own.
final class MTPProviderCore: @unchecked Sendable {
    let session: MTPSession
    let usb: USBDeviceInfo
    let configuration: SwiftMTPProviderConfiguration
    private(set) var deviceInfo: PTPDeviceInfo
    var propListStrategy: PropListStrategy
    /// Set when the device must be closed and reopened by the next call (the
    /// Samsung "allow storage access" quirk).
    var disposeRequested: Bool {
        get { flagLock.withLock { disposeRequestedStorage } }
        set { flagLock.withLock { disposeRequestedStorage = newValue } }
    }
    private var disposeRequestedStorage = false
    /// `needsReopen` is read by the provider actor while the I/O thread runs.
    private let flagLock = NSLock()

    private var directories: [UInt64: DirectoryIndex] = [:]
    private var objects: [UInt32: ObjectMeta] = [:]

    var needsReopen: Bool { disposeRequested || session.isBroken }

    private init(session: MTPSession, usb: USBDeviceInfo, deviceInfo: PTPDeviceInfo,
                 configuration: SwiftMTPProviderConfiguration) {
        self.session = session
        self.usb = usb
        self.deviceInfo = deviceInfo
        self.configuration = configuration
        if configuration.disablePropList || !deviceInfo.supports(PTPOperation.getObjectPropList) {
            propListStrategy = .unsupported
        } else {
            propListStrategy = .all
        }
    }

    // MARK: - Lifecycle

    /// Opens the device once: claim the interface, discard stale input from a
    /// previous host process, GetDeviceInfo, OpenSession. Never resets.
    static func open(_ configuration: SwiftMTPProviderConfiguration) throws -> MTPProviderCore {
        let opened: MTPOpenedDevice
        do {
            opened = try configuration.openDevice()
        } catch let error as MTPCallError {
            configuration.log?("open failed: \(error)")
            throw ProviderError.finalize(error)
        } catch let error as MTPTransportError {
            // The transport error names the OS status and kind; a taken
            // interface comes back as `.exclusiveAccess` naming its holder.
            configuration.log?("could not open the MTP interface: \(error)")
            switch error.kind {
            case .noDevice:
                throw ProviderError.call("no MTP devices found (\(error))", .mtpDetectFailed)
            default:
                throw ProviderError.call("could not open the MTP interface: \(error)", .deviceSetup)
            }
        } catch {
            configuration.log?("could not open the MTP interface: \(error)")
            throw ProviderError.call("could not open the MTP interface: \(error)", .deviceSetup)
        }

        func makeSession() -> MTPSession {
            MTPSession(transport: opened.transport, timeout: configuration.bulkTimeout,
                       transferChunkSize: configuration.transferChunkSize)
        }
        var session = makeSession()
        let drained = session.drainStaleInput()
        if drained > 0 { configuration.log?("discarded \(drained) stale byte(s) from an earlier host") }

        let info: PTPDeviceInfo
        do {
            do {
                info = try session.getDeviceInfo()
            } catch where mayBeAnEarlierHostsTransaction(error) {
                // A host that died mid-SendObject (the app quit during an
                // upload) leaves the phone expecting the rest of that data: our
                // command is taken as its tail and answered with GeneralError
                // for the dead transaction, after which the phone is idle
                // (seen on a Xiaomi). So ask once more, on a fresh session
                // object since a protocol error marks the first one broken.
                // No class Cancel: sent to the now idle Xiaomi it made the
                // following OpenSession time out.
                configuration.log?("GetDeviceInfo failed (\(error)); retrying once")
                session = makeSession()
                session.drainStaleInput()
                info = try session.getDeviceInfo()
            }
        } catch {
            let broken = session.isBroken
            configuration.log?("GetDeviceInfo failed: \(error)")
            session.close()
            if broken, (error as? MTPTransportError)?.kind == .noDevice {
                throw ProviderError.deviceLost("GetDeviceInfo: \(error)")
            }
            throw ProviderError.call("GetDeviceInfo failed: \(ProviderError.text(error))", .deviceInfo)
        }
        if opened.needsVendorExtensionCheck,
           !MTPInterfaceSelection.vendorExtensionAcceptable(info.vendorExtensionDesc) {
            session.close()
            throw ProviderError.call("no MTP devices found", .mtpDetectFailed)
        }

        do {
            try session.openSession(id: configuration.makeSessionID())
        } catch {
            configuration.log?("OpenSession failed: \(error)")
            session.close()
            // Surfaced as "replug required"; the device is never reset.
            throw ProviderError.call("OpenSession failed: \(ProviderError.text(error))", .deviceSetup)
        }
        configuration.log?("opened \(info.manufacturer) \(info.model) (serial \(info.serialNumber))")
        return MTPProviderCore(session: session, usb: opened.usb, deviceInfo: info, configuration: configuration)
    }

    /// Whether a failed first GetDeviceInfo may be the device's answer to a
    /// transaction an earlier host abandoned: an error answer or a container
    /// that does not fit — not a missing or silent device.
    static func mayBeAnEarlierHostsTransaction(_ error: Error) -> Bool {
        error is MTPResponseError || error is MTPProtocolError
    }

    /// CloseSession unless the device is gone, then release the interface.
    func close() {
        session.close()
    }

    // MARK: - Error mapping

    /// Maps a failure of an operation whose ordinary error type is `type`.
    func failure(_ error: Error, _ type: MTPErrorType, prefix: String = "") -> Error {
        if error is CancellationError { return error }
        if let call = error as? MTPCallError { return ProviderError.finalize(call) }
        if let reason = session.brokenReason { return ProviderError.deviceLost(reason) }
        return ProviderError.call(prefix + ProviderError.text(error), type)
    }

    /// Rethrows when the session died; lets the caller swallow anything else.
    func rethrowIfFatal(_ error: Error) throws {
        if error is CancellationError { throw error }
        if let reason = session.brokenReason { throw ProviderError.deviceLost(reason) }
    }

    // MARK: - Device info and storages

    func deviceInfoPayload() throws -> DeviceInfo {
        do {
            deviceInfo = try session.getDeviceInfo()
        } catch {
            throw failure(error, .deviceInfo)
        }
        return DeviceInfo(
            manufacturer: deviceInfo.manufacturer,
            model: deviceInfo.model,
            deviceVersion: deviceInfo.deviceVersion,
            serialNumber: deviceInfo.serialNumber,
            standardVersion: Int(deviceInfo.standardVersion),
            vendorExtensionID: Int(deviceInfo.vendorExtensionID),
            vendorExtensionVersion: Int(deviceInfo.vendorExtensionVersion),
            vendorExtensionDescription: deviceInfo.vendorExtensionDesc,
            functionalMode: Int(deviceInfo.functionalMode),
            operationsSupported: deviceInfo.operationsSupported,
            eventsSupported: deviceInfo.eventsSupported,
            devicePropertiesSupported: deviceInfo.devicePropertiesSupported,
            captureFormats: deviceInfo.captureFormats,
            playbackFormats: deviceInfo.playbackFormats,
            usb: usb
        )
    }

    func storagesPayload() throws -> [StorageInfo] {
        let ids: [UInt32]
        do {
            ids = try session.getStorageIDs()
        } catch {
            throw storageFailure(error)
        }
        guard !ids.isEmpty else { throw ProviderError.call("no storage found", .noStorage) }
        var result: [StorageInfo] = []
        for id in ids {
            do {
                let info = try session.getStorageInfo(id)
                result.append(Self.storage(id, info))
            } catch {
                throw storageFailure(error)
            }
        }
        return result
    }

    /// A zero-length or short dataset is how Samsung (and a locked phone)
    /// answer before the user allows access; it is reported as
    /// "allow storage access" and the device is dropped.
    private func storageFailure(_ error: Error) -> Error {
        if error is PTPDecodingError {
            disposeRequested = true
            return ProviderError.call("error allow storage access. EOF (\(error))", .allowStorageAccess)
        }
        return failure(error, .storageInfo)
    }

    static func storage(_ id: UInt32, _ info: PTPStorageInfo) -> StorageInfo {
        StorageInfo(
            id: id,
            storageDescription: info.storageDescription,
            volumeLabel: info.volumeIdentifier,
            maxCapacity: info.maxCapacity,
            freeSpaceInBytes: info.freeSpaceInBytes,
            freeSpaceInObjects: info.freeSpaceInObjects,
            storageType: info.storageType,
            filesystemType: info.filesystemType,
            accessCapability: info.accessCapability
        )
    }

    // MARK: - Caches

    private func key(_ storage: UInt32, _ handle: UInt32) -> UInt64 {
        UInt64(storage) << 32 | UInt64(handle)
    }

    func invalidateCaches() {
        directories.removeAll()
        objects.removeAll()
    }

    /// Records an object this provider just created.
    func cacheCreated(storage: UInt32, parent: UInt32, meta: ObjectMeta) {
        objects[meta.handle] = meta
        directories[key(storage, parent)]?.add(meta.handle, name: meta.name, format: meta.format)
    }

    /// Forgets an object this provider just deleted (and everything cached
    /// below it, which is simplest done by dropping the directory indexes).
    func cacheDeleted(storage: UInt32, parent: UInt32, handle: UInt32) {
        objects[handle] = nil
        let parentKey = key(storage, parent)
        let parentIndex = directories[parentKey]
        directories.removeAll()
        if var parentIndex {
            parentIndex.remove(handle)
            directories[parentKey] = parentIndex
        }
    }

    /// Stores a fresh full listing (from a walk) as the directory's index.
    private func cacheListing(storage: UInt32, parent: UInt32, handles: [UInt32], metas: [UInt32: ObjectMeta]) {
        var index = DirectoryIndex(handles: [], names: [:], formats: [:], fetchedAt: providerUptime())
        for handle in handles {
            guard let meta = metas[handle] else { continue }
            index.add(handle, name: meta.name, format: meta.format)
            objects[handle] = meta
        }
        directories[key(storage, parent)] = index
    }

    // MARK: - Object metadata

    /// GetObjectInfo, with the 64-bit size for objects of 4 GB and more.
    func fetchMeta(_ handle: UInt32) throws -> ObjectMeta {
        let info = try session.getObjectInfo(handle)
        var size = UInt64(info.compressedSize)
        if info.compressedSize == 0xFFFF_FFFF, !info.isFolder {
            do {
                let value = try session.getObjectPropValue(handle, property: MTPObjectProperty.objectSize,
                                                           dataType: PTPDataType.uint64)
                size = value.unsignedValue ?? size
            } catch {
                try rethrowIfFatal(error)
            }
        }
        let date = info.modificationDate.isEmpty ? info.captureDate : info.modificationDate
        let meta = ObjectMeta(handle: handle, name: info.filename, format: info.objectFormat,
                              size: info.isFolder ? 0 : size, modified: date, parent: info.parentObject)
        objects[handle] = meta
        return meta
    }

    func meta(_ handle: UInt32) throws -> ObjectMeta {
        if let cached = objects[handle] { return cached }
        return try fetchMeta(handle)
    }

    // MARK: - Directory index (names, for path resolution)

    /// ObjectPropList parent: 0 means "children of the root" at depth 1. The
    /// wildcard 0xFFFFFFFF would ask for every object on the device.
    private func propListHandle(_ parent: UInt32) -> UInt32 {
        parent == PTPHandle.root ? 0 : parent
    }

    /// The names and formats of `parent`'s children in `storage`, cached for
    /// `directoryCacheLifetime` and kept current by this provider's own
    /// mutations.
    func index(storage: UInt32, parent: UInt32, fresh: Bool = false) throws -> DirectoryIndex {
        let cacheKey = key(storage, parent)
        if !fresh, let cached = directories[cacheKey],
           providerUptime() - cached.fetchedAt < configuration.directoryCacheLifetime {
            return cached
        }
        let handles = try session.getObjectHandles(storageID: storage, parent: parent)
        var index = DirectoryIndex(handles: handles, names: [:], formats: [:], fetchedAt: providerUptime())
        let wanted = Set(handles)
        if !handles.isEmpty, propListStrategy != .unsupported {
            for property in [MTPObjectProperty.objectFileName, MTPObjectProperty.objectFormat] {
                do {
                    let elements = try session.getObjectPropList(handle: propListHandle(parent), property: UInt32(property))
                    for element in elements where wanted.contains(element.handle) && element.propertyCode == property {
                        if property == MTPObjectProperty.objectFileName, let name = element.value.stringValue {
                            index.names[element.handle] = name
                        } else if property == MTPObjectProperty.objectFormat, let format = element.value.unsignedValue {
                            index.formats[element.handle] = UInt16(truncatingIfNeeded: format)
                        }
                    }
                } catch {
                    try rethrowIfFatal(error)
                }
            }
        }
        for handle in handles where index.names[handle] == nil {
            if let cached = objects[handle] {
                index.names[handle] = cached.name
                index.formats[handle] = cached.format
                continue
            }
            do {
                let meta = try fetchMeta(handle)
                index.names[handle] = meta.name
                index.formats[handle] = meta.format
            } catch {
                // A child the device cannot describe is skipped.
                try rethrowIfFatal(error)
            }
        }
        index.handles = handles.filter { index.names[$0] != nil }
        directories[cacheKey] = index
        return index
    }

    func isFolder(_ handle: UInt32, in index: DirectoryIndex) throws -> Bool {
        if let format = index.formats[handle] { return format == PTPObjectFormat.association }
        return try meta(handle).isFolder
    }

    // MARK: - Path resolution

    /// Resolves `rawPath` component by component from the root,
    /// case-insensitively, first match in device order. `fullPath` in the result keeps the
    /// caller's spelling, normalized.
    func resolve(storage: UInt32, path rawPath: String, fresh: Bool = false) throws -> ResolvedObject {
        guard !rawPath.isEmpty else {
            throw ProviderError.call("path does not Exists. path: \(rawPath)", .invalidPath)
        }
        let normalized = DevicePath.normalize(rawPath)
        let components = DevicePath.components(normalized)
        var current = ResolvedObject.root()
        for (position, component) in components.enumerated() {
            let listing: DirectoryIndex
            do {
                listing = try index(storage: storage, parent: current.handle, fresh: fresh)
            } catch {
                throw failure(error, .fileObjectRead)
            }
            guard let handle = listing.handle(named: component) else {
                throw ProviderError.call("path not found: \(rawPath)\nreason: file not found: \(component)", .invalidPath)
            }
            let folder: Bool
            do {
                folder = try isFolder(handle, in: listing)
            } catch {
                throw failure(error, .fileObjectRead)
            }
            if position < components.count - 1, !folder {
                throw ProviderError.call("path not found: \(rawPath)", .invalidPath)
            }
            current = ResolvedObject(handle: handle, isFolder: folder, name: listing.names[handle] ?? component,
                                     fullPath: normalized, parentHandle: current.handle)
        }
        return current
    }

    /// Runs `body` on a cached resolution; if the device rejects a cached
    /// handle as stale (the phone changed behind our back), drops the caches
    /// and retries once with a fresh resolution.
    func withResolved<T>(storage: UInt32, path: String,
                         _ body: (ResolvedObject) throws -> T) throws -> T {
        do {
            return try body(try resolve(storage: storage, path: path))
        } catch {
            try rethrowIfFatal(error)
            guard Self.isStaleHandleError(error) else { throw error }
            invalidateCaches()
            return try body(try resolve(storage: storage, path: path, fresh: true))
        }
    }

    static func isStaleHandleError(_ error: Error) -> Bool {
        guard let code = ProviderError.responseCode(error) else {
            if let call = error as? MTPCallError {
                return call.message.contains("InvalidObjectHandle") || call.message.contains("InvalidParentObject")
            }
            return false
        }
        return code == PTPResponseCode.invalidObjectHandle || code == PTPResponseCode.invalidParentObject
    }

    /// Uses a per-session handle hint when it still names the expected
    /// object; otherwise falls back to path resolution instead of
    /// failing with InvalidObjectHandle.
    func resolve(storage: UInt32, path: String, hint: UInt32?) throws -> ResolvedObject {
        if let hint, hint != 0, hint != PTPHandle.root {
            let normalized = path.isEmpty ? "" : DevicePath.normalize(path)
            do {
                let meta = try fetchMeta(hint)
                let expected = DevicePath.base(normalized)
                if normalized.isEmpty || DevicePath.fold(meta.name) == DevicePath.fold(expected) {
                    return ResolvedObject(handle: hint, isFolder: meta.isFolder, name: meta.name,
                                          fullPath: normalized.isEmpty ? "/" + meta.name : normalized,
                                          parentHandle: meta.parent == 0 ? PTPHandle.root : meta.parent)
                }
                configuration.log?("handle hint \(hint) names \"\(meta.name)\", not \"\(expected)\"; resolving \(path) by path")
            } catch {
                try rethrowIfFatal(error)
                guard !path.isEmpty else { throw failure(error, .fileObjectRead) }
                configuration.log?("handle hint \(hint) is stale (\(ProviderError.text(error))); resolving \(path) by path")
            }
        }
        return try withResolved(storage: storage, path: path) { $0 }
    }

    // MARK: - fileExists

    func fileExists(storage: UInt32, paths: [String]) throws -> [FileExistsData] {
        var result: [FileExistsData] = []
        for path in paths {
            var exists = false
            if !path.isEmpty {
                do {
                    _ = try withResolved(storage: storage, path: path) { $0 }
                    exists = true
                } catch {
                    // Any resolution failure means "does not exist", except a
                    // dead session, which must surface as device loss.
                    try rethrowIfFatal(error)
                }
            }
            result.append(FileExistsData(fullpath: path, exists: exists))
        }
        return result
    }

    // MARK: - deleteFiles

    func deleteFiles(storage: UInt32, paths: [String]) throws -> Bool {
        // DeleteObject(0xFFFFFFFF) means "every object": never send it.
        if let root = paths.first(where: { !$0.isEmpty && DevicePath.normalize($0) == "/" }) {
            throw ProviderError.call("refusing to delete the storage root: \(root)", .invalidPath)
        }
        for path in paths where !path.isEmpty {
            do {
                try withResolved(storage: storage, path: path) { target in
                    try session.deleteObject(target.handle)
                    cacheDeleted(storage: storage, parent: target.parentHandle, handle: target.handle)
                }
            } catch {
                try rethrowIfFatal(error)
                if ProviderError.isNotFound(error) {
                    // A missing path is skipped and the rest still deleted,
                    // rather than stopping at the first missing path.
                    continue
                }
                if (error as? MTPCallError)?.type == .fileObjectRead { throw error }
                throw failure(error, .fileObjectRead)
            }
        }
        return true
    }

    // MARK: - makeDirectory

    /// mkdir -p. Returns the handle of the (existing or new) directory.
    @discardableResult
    func makeDirectory(storage: UInt32, path: String) throws -> UInt32 {
        let normalized = DevicePath.normalize(path)
        var parent = PTPHandle.root
        for component in DevicePath.components(normalized) {
            parent = try childDirectory(storage: storage, parent: parent, name: component)
        }
        return parent
    }

    /// The handle of directory `name` inside `parent`, created if missing.
    func childDirectory(storage: UInt32, parent: UInt32, name: String) throws -> UInt32 {
        func lookup(fresh: Bool) throws -> (UInt32, Bool)? {
            let listing = try index(storage: storage, parent: parent, fresh: fresh)
            guard let handle = listing.handle(named: name) else { return nil }
            return (handle, try isFolder(handle, in: listing))
        }
        var existing: (UInt32, Bool)?
        do {
            existing = try lookup(fresh: false)
        } catch {
            try rethrowIfFatal(error)
            guard Self.isStaleHandleError(error) else { throw failure(error, .fileObjectRead) }
            invalidateCaches()
            do { existing = try lookup(fresh: true) } catch { throw failure(error, .fileObjectRead) }
        }
        if let (handle, folder) = existing {
            guard folder else {
                throw ProviderError.call("invalid path: \(name). The object is not a directory", .invalidPath)
            }
            return handle
        }
        let now = configuration.now()
        let info = PTPObjectInfo(
            storageID: storage, objectFormat: PTPObjectFormat.association,
            parentObject: parent, associationType: PTPAssociationType.genericFolder,
            filename: name, modificationDate: MTPDateTime.format(now, in: configuration.timeZone)
        )
        let handle: UInt32
        do {
            handle = try session.sendObjectInfo(storageID: storage, parent: parent, info: info).handle
        } catch is PTPDecodingError {
            throw ProviderError.call("string too long", .sendObject)
        } catch {
            throw failure(error, .sendObject)
        }
        cacheCreated(storage: storage, parent: parent, meta: ObjectMeta(
            handle: handle, name: name, format: PTPObjectFormat.association, size: 0,
            modified: info.modificationDate, parent: parent == PTPHandle.root ? 0 : parent))
        return handle
    }

    // MARK: - renameFile

    func rename(storage: UInt32, path: String, newName: String) throws -> Bool {
        if !path.isEmpty, DevicePath.normalize(path) == "/" {
            throw ProviderError.call("refusing to rename the storage root: \(path)", .invalidPath)
        }
        do {
            try withResolved(storage: storage, path: path) { target in
                do {
                    try session.setObjectPropValue(target.handle, property: MTPObjectProperty.objectFileName,
                                                   value: .string(newName))
                } catch let error as MTPResponseError where error.code == PTPResponseCode.generalError {
                    // GeneralError here is treated as success (and logged).
                    configuration.log?("rename of \(path) answered GeneralError; treated as success")
                } catch is PTPDecodingError {
                    throw ProviderError.call("string too long", .fileObjectRead)
                }
                invalidateCaches()
            }
        } catch {
            try rethrowIfFatal(error)
            if ProviderError.isNotFound(error) {
                throw ProviderError.call("file not found: \(path)", .invalidPath)
            }
            throw failure(error, .fileObjectRead)
        }
        return true
    }

    // MARK: - Walk

    func walk(_ input: DirectoryWalkInput, onProgress: ((WalkProgress) -> Void)?) throws -> [WalkEntry] {
        let target = try resolve(storage: input.storageId, path: input.fullPath, hint: input.objectId)
        let hinted = (input.objectId ?? 0) != 0
        if input.skipDisallowedFiles, DevicePath.isDisallowed(target.name) {
            throw ProviderError.call("disallowed file \(target.name)", .invalidPath)
        }
        if !target.isFolder {
            let meta: ObjectMeta
            do { meta = try fetchMeta(target.handle) } catch { throw failure(error, .fileObjectRead) }
            let parentPath = hinted ? DevicePath.dir(target.fullPath) : "/"
            return [entry(meta, path: target.fullPath, parentPath: parentPath, parentId: target.parentHandle)]
        }
        let parentPath = target.fullPath
        let listed: [(ObjectMeta, UInt32)]
        do {
            listed = try listDirectory(storage: input.storageId, parent: target.handle,
                                       progressPath: input.fullPath, onProgress: onProgress)
        } catch {
            try rethrowIfFatal(error)
            guard !hinted, Self.isStaleHandleError(error) else { throw failure(error, .listDirectory) }
            // A cached handle went stale: resolve afresh once.
            invalidateCaches()
            let fresh = try resolve(storage: input.storageId, path: input.fullPath, fresh: true)
            do {
                listed = try listDirectory(storage: input.storageId, parent: fresh.handle,
                                           progressPath: input.fullPath, onProgress: onProgress)
            } catch {
                throw failure(error, .listDirectory)
            }
        }
        var entries: [WalkEntry] = []
        entries.reserveCapacity(listed.count)
        for (meta, parentId) in listed {
            if input.skipHiddenFiles, DevicePath.isHidden(meta.name) { continue }
            if input.skipDisallowedFiles, DevicePath.isDisallowed(meta.name) { continue }
            entries.append(entry(meta, path: DevicePath.join(parentPath, meta.name), parentPath: parentPath,
                                 parentId: parentId))
        }
        return entries
    }

    func entry(_ meta: ObjectMeta, path: String, parentPath: String, parentId: UInt32) -> WalkEntry {
        WalkEntry(
            size: meta.isFolder ? 0 : Int64(clamping: meta.size),
            isFolder: meta.isFolder,
            modified: MTPDateTime.parse(meta.modified)?.date(in: configuration.timeZone),
            name: meta.name,
            path: path,
            parentPath: parentPath,
            extension: DevicePath.fileExtension(meta.name, isFolder: meta.isFolder),
            parentId: parentId,
            objectId: meta.handle
        )
    }

    // MARK: - Listing (contract §5.3)

    /// One directory's children with full metadata, in GetObjectHandles
    /// order, each paired with the `parentId` to report. Uses
    /// GetObjectPropList (wildcard below the size gate, per property above it)
    /// and falls back to GetObjectInfo per child.
    func listDirectory(storage: UInt32, parent: UInt32, progressPath: String,
                       onProgress: ((WalkProgress) -> Void)?) throws -> [(ObjectMeta, UInt32)] {
        let handles = try session.getObjectHandles(storageID: storage, parent: parent)
        let progress = WalkProgressReporter(path: progressPath, itemCount: handles.count,
                                            interval: configuration.walkProgressInterval, emit: onProgress)
        progress.start()
        guard !handles.isEmpty else {
            cacheListing(storage: storage, parent: parent, handles: [], metas: [:])
            return []
        }

        var partials: [UInt32: PartialMeta]?
        var usedBulk = false
        let gate = configuration.wildcardMaxChildren
        switch propListStrategy {
        case .unsupported:
            partials = nil
        case .perProperty:
            partials = try perPropertyListing(parent: parent, handles: handles, progress: progress)
            if partials == nil { propListStrategy = .unsupported }
        case .all where gate > 0 && handles.count > gate:
            // Large folders: skip the wildcard (the Xiaomi spends ~4 s refusing
            // it) without demoting the strategy.
            partials = try perPropertyListing(parent: parent, handles: handles, progress: progress)
            if partials == nil {
                partials = try wildcardListing(parent: parent, handles: handles, progress: progress)
            }
        case .all:
            partials = try wildcardListing(parent: parent, handles: handles, progress: progress)
        }
        usedBulk = partials != nil

        var metas: [UInt32: ObjectMeta] = [:]
        var parentIds: [UInt32: UInt32] = [:]
        var processed = 0
        for handle in handles {
            if let partial = partials?[handle], let meta = partial.complete(handle: handle) {
                metas[handle] = meta
                parentIds[handle] = parent
                continue
            }
            do {
                let meta = try fetchMeta(handle)
                metas[handle] = meta
                parentIds[handle] = meta.parent
            } catch {
                // A child the device cannot describe is dropped.
                try rethrowIfFatal(error)
            }
            processed += 1
            if !usedBulk { progress.advance(Double(processed) / Double(handles.count)) }
        }
        cacheListing(storage: storage, parent: parent, handles: handles, metas: metas)
        return handles.compactMap { handle in metas[handle].map { ($0, parentIds[handle] ?? parent) } }
    }

    /// Per-property GetObjectPropList: filename, format, size, date modified,
    /// then date created only for handles without a date modified. Returns
    /// nil when the route is unusable for this directory.
    private func perPropertyListing(parent: UInt32, handles: [UInt32],
                                    progress: WalkProgressReporter) throws -> [UInt32: PartialMeta]? {
        let wanted = Set(handles)
        var partials: [UInt32: PartialMeta] = [:]
        var anySucceeded = false
        let properties = [MTPObjectProperty.objectFileName, MTPObjectProperty.objectFormat,
                          MTPObjectProperty.objectSize, MTPObjectProperty.dateModified]
        func fetch(_ property: UInt16) throws {
            do {
                let elements = try session.getObjectPropList(handle: propListHandle(parent), property: UInt32(property))
                anySucceeded = true
                for element in elements where wanted.contains(element.handle) && element.propertyCode == property {
                    partials[element.handle, default: PartialMeta()].merge(element)
                }
            } catch {
                try rethrowIfFatal(error)
            }
        }
        for (position, property) in properties.enumerated() {
            try fetch(property)
            progress.advance(Double(position + 1) / 4)
        }
        if handles.contains(where: { partials[$0]?.hasDateModified != true }) {
            try fetch(MTPObjectProperty.dateCreated)
            progress.advance(1)
        }
        guard anySucceeded, handles.contains(where: { partials[$0]?.complete(handle: $0) != nil }) else {
            return nil
        }
        return partials
    }

    /// The all-properties wildcard. Refused with MTP_InvalidObjectPropCode:
    /// demote to per-property for the session and retry this directory. Any
    /// other failure, or an empty reply: per-object for this directory only.
    private func wildcardListing(parent: UInt32, handles: [UInt32],
                                 progress: WalkProgressReporter) throws -> [UInt32: PartialMeta]? {
        let elements: [MTPObjectPropListElement]
        do {
            elements = try session.getObjectPropList(handle: propListHandle(parent), property: MTPObjectProperty.all)
        } catch {
            try rethrowIfFatal(error)
            if ProviderError.responseCode(error) == PTPResponseCode.mtpInvalidObjectPropCode {
                propListStrategy = .perProperty
                let partials = try perPropertyListing(parent: parent, handles: handles, progress: progress)
                if partials == nil { propListStrategy = .unsupported }
                return partials
            }
            return nil
        }
        let wanted = Set(handles)
        var partials: [UInt32: PartialMeta] = [:]
        for element in elements where wanted.contains(element.handle) {
            partials[element.handle, default: PartialMeta()].merge(element)
        }
        guard !partials.isEmpty else { return nil }
        progress.advance(1)
        return partials
    }
}

/// Properties gathered for one handle from GetObjectPropList replies.
struct PartialMeta {
    var name: String?
    var format: UInt16?
    var size: UInt64?
    var dateModified: String?
    var dateCreated: String?
    var parent: UInt32?

    var hasDateModified: Bool { !(dateModified ?? "").isEmpty }

    mutating func merge(_ element: MTPObjectPropListElement) {
        switch element.propertyCode {
        case MTPObjectProperty.objectFileName:
            if let value = element.value.stringValue { name = value }
        case MTPObjectProperty.objectFormat:
            if let value = element.value.unsignedValue { format = UInt16(truncatingIfNeeded: value) }
        case MTPObjectProperty.objectSize:
            if let value = element.value.unsignedValue { size = value }
        case MTPObjectProperty.dateModified:
            if let value = element.value.stringValue { dateModified = value }
        case MTPObjectProperty.dateCreated:
            if let value = element.value.stringValue { dateCreated = value }
        case MTPObjectProperty.parentObject:
            if let value = element.value.unsignedValue { parent = UInt32(truncatingIfNeeded: value) }
        default:
            break
        }
    }

    /// Complete when name, format, size (files) and some date element are
    /// present. A date that is present but unparseable no longer drops the
    /// child (deliberate fix): it lists with the zero date.
    func complete(handle: UInt32) -> ObjectMeta? {
        guard let name, let format else { return nil }
        let folder = format == PTPObjectFormat.association
        guard folder || size != nil else { return nil }
        let date: String
        if let modified = dateModified, !modified.isEmpty, MTPDateTime.parse(modified) != nil {
            date = modified
        } else if let created = dateCreated, !created.isEmpty, MTPDateTime.parse(created) != nil {
            date = created
        } else if dateModified != nil || dateCreated != nil {
            date = ""
        } else {
            return nil
        }
        return ObjectMeta(handle: handle, name: name, format: format, size: folder ? 0 : (size ?? 0),
                          modified: date, parent: parent ?? 0)
    }
}

/// Walk progress per contract §1.3: one event right after GetObjectHandles,
/// then monotone advances at most every `interval` seconds, clamped to 1.
final class WalkProgressReporter {
    private let path: String
    private let itemCount: Int
    private let interval: TimeInterval
    private let emit: ((WalkProgress) -> Void)?
    private var lastFraction = 0.0
    private var lastReport: TimeInterval = 0

    init(path: String, itemCount: Int, interval: TimeInterval, emit: ((WalkProgress) -> Void)?) {
        self.path = path
        self.itemCount = itemCount
        self.interval = interval
        self.emit = emit
    }

    func start() {
        lastReport = providerUptime()
        emit?(WalkProgress(fullPath: path, itemCount: itemCount, fractionCompleted: 0))
    }

    func advance(_ fraction: Double) {
        let clamped = min(fraction, 1)
        let now = providerUptime()
        guard clamped > lastFraction, now - lastReport >= interval else { return }
        lastFraction = clamped
        lastReport = now
        emit?(WalkProgress(fullPath: path, itemCount: itemCount, fractionCompleted: clamped))
    }
}
