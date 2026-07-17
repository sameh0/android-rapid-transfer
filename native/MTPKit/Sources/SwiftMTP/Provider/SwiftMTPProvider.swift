import Foundation
import MTPKit

/// Knobs and injectable seams for ``SwiftMTPProvider``.
public struct SwiftMTPProviderConfiguration: Sendable {
    /// Finds and claims the device. Runs on the provider's I/O thread, once
    /// per session. Tests substitute an in-memory device here.
    public var openDevice: @Sendable () throws -> MTPOpenedDevice
    /// The Mac's zone: device dates (zone-less wall clock) are interpreted in
    /// it for downloaded files' mtimes, and uploads' dates are written in it.
    public var timeZone: TimeZone
    /// Wall clock for the dates of created folders.
    public var now: @Sendable () -> Date
    /// Per bulk transfer.
    public var bulkTimeout: TimeInterval = 15
    /// Size of one bulk transfer in a data phase.
    public var transferChunkSize: Int = 1 << 20
    /// Directories with more children skip the GetObjectPropList wildcard
    /// (0 disables the gate). `ART_MTP_PROPLIST_WILDCARD_MAX_CHILDREN` overrides.
    public var wildcardMaxChildren: Int = 256
    /// List per object only (`ART_MTP_DISABLE_PROPLIST=1`). Diagnostics.
    public var disablePropList = false
    /// How long a directory's name index serves path resolution before it is
    /// fetched again. The provider's own mutations keep it current.
    public var directoryCacheLifetime: TimeInterval = 3
    /// Minimum spacing of transfer progress events (plus one per file).
    public var progressInterval: TimeInterval = 0.25
    /// Minimum spacing of walk progress advances (contract: 100 ms).
    public var walkProgressInterval: TimeInterval = 0.1
    /// Session IDs: random, odd, 31-bit.
    public var sessionIDGenerator: @Sendable () -> UInt32 = { UInt32.random(in: 1...0x7FFF_FFFF) | 1 }
    public var log: (@Sendable (String) -> Void)?

    public init(
        openDevice: (@Sendable () throws -> MTPOpenedDevice)? = nil,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.openDevice = openDevice ?? { try MTPDeviceOpener.openSingleDevice(log: log) }
        self.timeZone = timeZone
        self.now = now
        self.log = log
        let environment = ProcessInfo.processInfo.environment
        if environment["ART_MTP_DISABLE_PROPLIST"] == "1" { disablePropList = true }
        if let raw = environment["ART_MTP_PROPLIST_WILDCARD_MAX_CHILDREN"], let value = Int(raw) {
            wildcardMaxChildren = max(value, 0)
        }
    }

    func makeSessionID() -> UInt32 {
        let id = sessionIDGenerator()
        return (id == 0 || id == 0xFFFF_FFFF) ? 1 : id
    }
}

/// Finds the phone and claims its MTP interface over IOUSBHost.
public enum MTPDeviceOpener {
    /// MTP interface selection over the I/O Registry, then one open (a busy
    /// interface is retried, never reset).
    public static func openSingleDevice(log: (@Sendable (String) -> Void)? = nil) throws -> MTPOpenedDevice {
        let candidate = try choose(MTPInterfaceSelection.select(USBDeviceDiscovery.allInterfaces()))
        log?("opening \(candidate)")
        let transport = try PlatformUSB.open(candidate, log: log.map { log in { log($0) } })
        return MTPOpenedDevice(transport: transport, usb: usbInfo(candidate),
                               needsVendorExtensionCheck: candidate.needsVendorExtensionCheck)
    }

    public static func usbInfo(_ candidate: MTPInterfaceCandidate) -> USBDeviceInfo {
        USBDeviceInfo(vendorID: candidate.vendorID, productID: candidate.productID,
                      deviceRelease: candidate.deviceRelease, manufacturer: candidate.manufacturer ?? "",
                      product: candidate.productName ?? "", serialNumber: candidate.serialNumber ?? "")
    }

    /// One interface per physical device. A device with a named MTP interface
    /// wins over string-less candidates (which would need a DeviceInfo probe);
    /// more than one device is `ErrorMultipleDevice`.
    public static func choose(_ candidates: [MTPInterfaceCandidate]) throws -> MTPInterfaceCandidate {
        var seen = Set<String>()
        var devices: [MTPInterfaceCandidate] = []
        for candidate in candidates {
            let key = "\(candidate.vendorID):\(candidate.productID):\(candidate.serialNumber ?? ""):\(candidate.locationID ?? 0)"
            if seen.insert(key).inserted { devices.append(candidate) }
        }
        let named = devices.filter { !$0.needsVendorExtensionCheck }
        let pool = named.isEmpty ? devices : named
        guard let first = pool.first else {
            throw MTPCallError(message: "no MTP devices found", type: .mtpDetectFailed)
        }
        guard pool.count == 1 else {
            let ids = pool.map { "\($0.manufacturer ?? "") \($0.productName ?? "") \($0.serialNumber ?? "")" }
            throw MTPCallError(message: "mtp: more than 1 device: \(ids.joined(separator: ","))", type: .multipleDevice)
        }
        return first
    }
}

/// Every blocking USB call runs on this one serial queue, never on Swift's
/// cooperative pool. Operations are queued in call order, which is also what
/// serializes them.
final class MTPIOExecutor: Sendable {
    private let queue = DispatchQueue(label: "SwiftMTPProvider.io", qos: .userInitiated)

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    func enqueue(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }
}

/// A pure-Swift ``MTPDeviceProvider`` over IOUSBHost.
///
/// - The device is opened lazily by the first call, exactly once even when
///   several calls arrive together, and again after ``dispose()`` or after the
///   session died. It is never USB-reset.
/// - Device loss is reported as `MTPCallError(type: .deviceChanged)` whose
///   message contains `LIBUSB_ERROR_NO_DEVICE`, so the app reconnects.
/// - Transfers stream to and from disk and can be cancelled by cancelling
///   `TransferOperation.result`; the data phase is then aborted with the
///   class Cancel request and the session stays usable.
public actor SwiftMTPProvider: MTPDeviceProvider {
    public nonisolated let configuration: SwiftMTPProviderConfiguration
    private let io = MTPIOExecutor()
    private var core: MTPProviderCore?
    private var initializing: Task<MTPProviderCore, Error>?
    /// How many times a device session was opened (diagnostics and tests).
    public private(set) var sessionsOpened = 0

    public init(configuration: SwiftMTPProviderConfiguration = SwiftMTPProviderConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - MTPDeviceProvider

    public func deviceInfo() async throws -> DeviceInfo {
        try await perform { try $0.deviceInfoPayload() }
    }

    public func storages() async throws -> [StorageInfo] {
        try await perform { try $0.storagesPayload() }
    }

    public func walk(input: DirectoryWalkInput) async throws -> [WalkEntry] {
        try await perform { try $0.walk(input, onProgress: nil) }
    }

    public func walk(
        input: DirectoryWalkInput,
        onProgress: @escaping @Sendable (WalkProgress) -> Void
    ) async throws -> [WalkEntry] {
        try await perform { try $0.walk(input, onProgress: onProgress) }
    }

    public func fileExists(input: FileExistsInput) async throws -> [FileExistsData] {
        try await perform { try $0.fileExists(storage: input.storageId, paths: input.files) }
    }

    public func deleteFiles(input: DeleteFileInput) async throws -> Bool {
        try await perform { try $0.deleteFiles(storage: input.storageId, paths: input.files) }
    }

    public func makeDirectory(input: MakeDirectoryInput) async throws -> Bool {
        try await perform { core in
            try core.makeDirectory(storage: input.storageId, path: input.fullPath)
            return true
        }
    }

    public func renameFile(input: RenameFileInput) async throws -> Bool {
        try await perform { try $0.rename(storage: input.storageId, path: input.fullPath, newName: input.newFileName) }
    }

    public func downloadFiles(input: DownloadFilesInput) async throws -> TransferOperation {
        let core = try await ensureInitialized()
        return startTransfer(core) { core, emit, cancel in try core.download(input, emit: emit, cancel: cancel) }
    }

    public func uploadFiles(input: UploadFilesInput) async throws -> TransferOperation {
        let core = try await ensureInitialized()
        return startTransfer(core) { core, emit, cancel in try core.upload(input, emit: emit, cancel: cancel) }
    }

    public func dispose() async throws -> Bool {
        // Let an initialization already under way finish first, so it cannot
        // complete after the dispose and leave a session open.
        _ = await initializing?.result
        if let core {
            self.core = nil
            _ = try? await io.run { core.close() }
        }
        return true
    }

    // MARK: - Plumbing

    private func ensureInitialized() async throws -> MTPProviderCore {
        if let core, !core.needsReopen { return core }
        if let initializing { return try await initializing.value }
        let stale = core
        core = nil
        let io = io
        let configuration = configuration
        let task = Task { () throws -> MTPProviderCore in
            if let stale {
                configuration.log?("closing the previous session: \(stale.session.brokenReason ?? "reopen requested")")
                _ = try? await io.run { stale.close() }
            }
            return try await io.run { try MTPProviderCore.open(configuration) }
        }
        initializing = task
        defer { initializing = nil }
        let opened = try await task.value
        core = opened
        sessionsOpened += 1
        return opened
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (MTPProviderCore) throws -> T) async throws -> T {
        let core = try await ensureInitialized()
        return try await io.run { try Self.guarded(core) { try body(core) } }
    }

    /// Final error mapping: every failure the app sees is a `MTPCallError`
    /// (or a `CancellationError` for a cancelled transfer).
    static func guarded<T>(_ core: MTPProviderCore, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as MTPCallError {
            throw ProviderError.finalize(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let reason = core.session.brokenReason { throw ProviderError.deviceLost(reason) }
            throw ProviderError.call(ProviderError.text(error), .general)
        }
    }

    private func startTransfer(
        _ core: MTPProviderCore,
        _ body: @escaping @Sendable (MTPProviderCore, @escaping (TransferEvent) -> Void, ProviderCancelFlag) throws -> Bool
    ) -> TransferOperation {
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream(bufferingPolicy: .unbounded)
        let cancel = ProviderCancelFlag()
        let promise = ProviderPromise<Bool>()
        // Queued now, so the transfer keeps its place relative to later calls.
        io.enqueue {
            let result = Result { try Self.guarded(core) { try body(core, { continuation.yield($0) }, cancel) } }
            continuation.finish()
            promise.fulfill(result)
        }
        let result = Task<Bool, Error> {
            try await withTaskCancellationHandler {
                try await promise.value
            } onCancel: {
                cancel.cancel()
            }
        }
        return TransferOperation(progress: stream, result: result)
    }
}
