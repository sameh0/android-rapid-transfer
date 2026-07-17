import Foundation
import MTPKit

/// The outcome of one ``SwiftMTPDiagnostics`` run: a readable report and
/// whether every step completed without an error.
public struct SwiftMTPDiagnosticReport: Equatable, Sendable {
    public var text: String
    public var completed: Bool

    public init(text: String, completed: Bool) {
        self.text = text
        self.completed = completed
    }
}

/// Stops a running diagnostic from another thread. The flag is checked
/// between steps, and the claimed interface is released so a transfer that is
/// blocked on the device ends (at most one bulk timeout later). `cancel()`
/// can block for that long, so call it off the main thread.
public final class SwiftMTPDiagnosticsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var transport: MTPTransport?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let transport: MTPTransport? = lock.withLock {
            cancelled = true
            return self.transport
        }
        transport?.close()
    }

    /// Registers the opened transport; false when already cancelled.
    func attach(_ transport: MTPTransport) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.transport = transport
            return true
        }
    }

    func detach() {
        lock.withLock { transport = nil }
    }
}

/// A read-only, in-process USB/MTP diagnostic for bug reports.
///
/// It lists the USB interfaces that could be the phone, opens the chosen one
/// exactly once, and reads DeviceInfo, the storages and each storage's
/// top-level item counts, timing every step. It never sends an operation that
/// changes the phone (no SendObject, DeleteObject or SetObjectPropValue) and
/// never resets the device. The caller must release the app's own session
/// first: the interface can be claimed by one client at a time.
public enum SwiftMTPDiagnostics {
    public struct Options: Sendable {
        /// Per bulk transfer. Short, so a silent phone cannot stall the report.
        public var bulkTimeout: TimeInterval = 5
        /// Budget for the whole run; later steps are skipped once it is spent.
        public var deadline: TimeInterval = 45
        /// Storages whose top level is counted.
        public var maxStoragesListed = 8
        /// Without GetObjectPropList, folders are counted from this many
        /// GetObjectInfo calls per storage root.
        public var objectInfoSampleLimit = 64
        /// Every USB interface in the I/O Registry (reads properties only).
        public var discover: @Sendable () -> [MTPInterfaceCandidate] = { USBDeviceDiscovery.allInterfaces() }
        /// Claims the chosen interface; the closure receives a log sink.
        public var open: @Sendable (MTPInterfaceCandidate, @escaping (String) -> Void) throws -> MTPTransport = {
            try PlatformUSB.open($0, log: $1)
        }
        public var sessionID: @Sendable () -> UInt32 = { UInt32.random(in: 1...0x7FFF_FFFF) | 1 }
        /// Monotonic nanoseconds.
        public var clock: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        public var date: @Sendable () -> Date = { Date() }

        public init() {}
    }

    private struct Stop: Error {
        let reason: String
    }

    /// Final line of a run that completed; tooling can look for it.
    public static let completionMarker = "DIAGNOSTIC complete"

    public static func run(
        options: Options = Options(),
        cancellation: SwiftMTPDiagnosticsCancellation? = nil
    ) -> SwiftMTPDiagnosticReport {
        let report = ReportWriter(clock: options.clock)
        let started = options.clock()
        report.line("MTP diagnostic (SwiftMTP over IOUSBHost)")
        report.line("Started: \(options.date().formatted(.iso8601))")
        report.line("Read-only: opens the phone once, never writes to it and never resets it.")
        report.line("")

        func checkpoint(_ step: String) throws {
            if cancellation?.isCancelled == true { throw Stop(reason: "cancelled before \(step)") }
            let elapsed = Double(options.clock() &- started) / 1_000_000_000
            if elapsed > options.deadline {
                throw Stop(reason: String(format: "time budget of %.0f s spent before %@", options.deadline, step))
            }
        }

        var session: MTPSession?
        var stopReason: String?
        do {
            session = try diagnose(options: options, cancellation: cancellation, report: report, checkpoint: checkpoint)
        } catch let stop as Stop {
            stopReason = stop.reason
        } catch {
            stopReason = describe(error)
        }

        if let session {
            let ms = report.time { session.close() }
            report.line(String(format: "Closed the session and released the interface (%.1f ms); the device was not reset.", ms))
        }
        cancellation?.detach()

        report.line("")
        report.line("===== Summary =====")
        if report.errors.isEmpty {
            report.line("Errors: none")
        } else {
            report.line("Errors: \(report.errors.count)")
            for error in report.errors { report.line("  - \(error)") }
        }
        report.line(String(format: "Total: %.1f ms", Double(options.clock() &- started) / 1_000_000))
        stopReason = stopReason ?? report.stopReason
        let completed = stopReason == nil && report.errors.isEmpty
        if completed {
            report.line(completionMarker)
        } else {
            report.line("DIAGNOSTIC incomplete: \(stopReason ?? "\(report.errors.count) step(s) failed")")
        }
        return SwiftMTPDiagnosticReport(text: report.text, completed: completed)
    }

    /// Runs the device steps. Returns the open session (for the caller to
    /// close) once the device was opened, whatever happened afterwards.
    private static func diagnose(
        options: Options,
        cancellation: SwiftMTPDiagnosticsCancellation?,
        report: ReportWriter,
        checkpoint: (String) throws -> Void
    ) throws -> MTPSession? {
        // 1. USB interfaces.
        report.section("USB interfaces")
        var all: [MTPInterfaceCandidate] = []
        let discoverMs = report.time { all = options.discover() }
        report.line(String(format: "Interfaces in the I/O Registry: %d (%.1f ms)", all.count, discoverMs))
        let relevant = all.filter(isPossiblyMTP)
        report.line("Still-image, vendor-specific or MTP/PTP-named interfaces: \(relevant.count)")
        for candidate in relevant {
            report.line("  - \(describe(candidate))")
        }
        let qualifying = MTPInterfaceSelection.select(all)
        report.line("Qualifying MTP candidates: \(qualifying.count)")
        let chosen: MTPInterfaceCandidate
        do {
            chosen = try MTPDeviceOpener.choose(qualifying)
        } catch {
            report.error("device selection: \(describe(error))")
            throw Stop(reason: "no single MTP device to open")
        }
        report.line("Chosen: \(chosen)")

        // 2. Open once.
        try checkpoint("opening the interface")
        report.section("Open")
        var transport: MTPTransport?
        do {
            let ms = try report.timeThrowing {
                transport = try options.open(chosen) { report.line("  \($0)") }
            }
            report.line(String(format: "Claimed interface %d in %.1f ms", chosen.interfaceNumber, ms))
        } catch {
            report.error("open: \(describe(error))")
            throw Stop(reason: "the MTP interface could not be opened")
        }
        guard let transport else { throw Stop(reason: "the MTP interface could not be opened") }
        if let usb = transport as? USBEndpointDescribing {
            report.line(String(format: "Endpoints: bulk-in 0x%02x (mps %d), bulk-out 0x%02x (mps %d), interrupt 0x%02x (mps %d)",
                               usb.bulkInAddress, usb.maxPacketSizeIn, usb.bulkOutAddress, usb.maxPacketSizeOut,
                               usb.interruptAddress, usb.maxPacketSizeInterrupt))
        } else {
            report.line("Max packet size: in \(transport.maxPacketSizeIn), out \(transport.maxPacketSizeOut)")
        }
        guard cancellation?.attach(transport) ?? true else {
            transport.close()
            throw Stop(reason: "cancelled before the session opened")
        }
        let session = MTPSession(transport: transport, timeout: options.bulkTimeout)
        do {
            try diagnoseSession(session, chosen: chosen, options: options, report: report, checkpoint: checkpoint)
        } catch let stop as Stop {
            report.line("Stopped: \(stop.reason)")
            report.stopReason = stop.reason
        }
        return session
    }

    private static func diagnoseSession(
        _ session: MTPSession,
        chosen: MTPInterfaceCandidate,
        options: Options,
        report: ReportWriter,
        checkpoint: (String) throws -> Void
    ) throws {
        var drained = 0
        let drainMs = report.time { drained = session.drainStaleInput() }
        report.line(String(format: "Stale bulk-in bytes discarded: %d (%.1f ms)", drained, drainMs))

        // 3. DeviceInfo.
        try checkpoint("GetDeviceInfo")
        report.section("GetDeviceInfo")
        var info: PTPDeviceInfo?
        do {
            let ms = try report.timeThrowing { info = try session.getDeviceInfo() }
            report.line(String(format: "Read in %.1f ms", ms))
        } catch {
            report.error("GetDeviceInfo: \(describe(error))")
            throw Stop(reason: "GetDeviceInfo failed")
        }
        guard let info else { throw Stop(reason: "GetDeviceInfo failed") }
        describe(info, into: report)
        if chosen.needsVendorExtensionCheck {
            let acceptable = MTPInterfaceSelection.vendorExtensionAcceptable(info.vendorExtensionDesc)
            report.line("Unnamed interface; MTP vendor extension acceptable: \(acceptable)")
            if !acceptable { throw Stop(reason: "the unnamed interface does not report an MTP vendor extension") }
        }

        // 4. Session.
        try checkpoint("OpenSession")
        report.section("Session")
        let sessionID = options.sessionID()
        do {
            let ms = try report.timeThrowing { try session.openSession(id: (sessionID == 0 || sessionID == 0xFFFF_FFFF) ? 1 : sessionID) }
            report.line(String(format: "OpenSession ok (%.1f ms)", ms))
        } catch {
            report.error("OpenSession: \(describe(error))")
            throw Stop(reason: "OpenSession failed")
        }

        // 5. Storages.
        try checkpoint("GetStorageIDs")
        report.section("Storages")
        var storageIDs: [UInt32] = []
        do {
            let ms = try report.timeThrowing { storageIDs = try session.getStorageIDs() }
            report.line(String(format: "GetStorageIDs: %d (%.1f ms)%@", storageIDs.count, ms,
                               storageIDs.isEmpty ? " -- none: the phone may be locked or waiting for \"Allow access\"" : ""))
        } catch {
            report.error("GetStorageIDs: \(describe(error))")
            throw Stop(reason: "GetStorageIDs failed")
        }
        for id in storageIDs {
            try checkpoint("GetStorageInfo")
            do {
                var storage: PTPStorageInfo?
                let ms = try report.timeThrowing { storage = try session.getStorageInfo(id) }
                if let s = storage {
                    report.line(String(format: "  %@ \"%@\" volume \"%@\": capacity %@, free %@ (%llu objects free), type %d, filesystem %d, access %d (%.1f ms)",
                                       hex32(id), s.storageDescription, s.volumeIdentifier, bytes(s.maxCapacity),
                                       bytes(s.freeSpaceInBytes), UInt64(s.freeSpaceInObjects), s.storageType,
                                       s.filesystemType, s.accessCapability, ms))
                }
            } catch {
                report.error("GetStorageInfo \(hex32(id)): \(describe(error))")
            }
        }

        // 6. Top-level counts.
        let usesPropList = info.supports(PTPOperation.getObjectPropList)
        report.section("Storage roots")
        report.line(usesPropList ? "Folders counted with GetObjectPropList (ObjectFormat, depth 1)"
                                 : "Folders counted with GetObjectInfo (up to \(options.objectInfoSampleLimit) per root)")
        for id in storageIDs.prefix(options.maxStoragesListed) {
            try checkpoint("listing the root of \(hex32(id))")
            var handles: [UInt32] = []
            do {
                let ms = try report.timeThrowing {
                    handles = try session.getObjectHandles(storageID: id, parent: PTPHandle.root)
                }
                report.line(String(format: "  %@: %d top-level items (GetObjectHandles %.1f ms)", hex32(id), handles.count, ms))
            } catch {
                report.error("GetObjectHandles \(hex32(id)) root: \(describe(error))")
                continue
            }
            guard !handles.isEmpty else { continue }
            try checkpoint("counting folders in \(hex32(id))")
            do {
                var folders = 0
                var examined = 0
                let ms = try report.timeThrowing {
                    if usesPropList {
                        let wanted = Set(handles)
                        // Handle 0 with depth 1: the root's children (all storages on Android).
                        let elements = try session.getObjectPropList(handle: 0, property: UInt32(MTPObjectProperty.objectFormat))
                        var formats: [UInt32: UInt16] = [:]
                        for element in elements where wanted.contains(element.handle) {
                            formats[element.handle] = UInt16(truncatingIfNeeded: element.value.unsignedValue ?? 0)
                        }
                        examined = formats.count
                        folders = formats.values.filter { $0 == PTPObjectFormat.association }.count
                    } else {
                        for handle in handles.prefix(options.objectInfoSampleLimit) {
                            try checkpoint("GetObjectInfo in \(hex32(id))")
                            if try session.getObjectInfo(handle).isFolder { folders += 1 }
                            examined += 1
                        }
                    }
                }
                report.line(String(format: "    %d folders, %d files among %d examined (%.1f ms)",
                                   folders, examined - folders, examined, ms))
            } catch let stop as Stop {
                throw stop
            } catch {
                report.error("counting folders in \(hex32(id)): \(describe(error))")
            }
        }
        if storageIDs.count > options.maxStoragesListed {
            report.line("  (\(storageIDs.count - options.maxStoragesListed) more storages not listed)")
        }
    }

    // MARK: - Formatting

    static func isPossiblyMTP(_ candidate: MTPInterfaceCandidate) -> Bool {
        if candidate.interfaceClass == 6 || candidate.interfaceClass == 0xFF { return true }
        let name = candidate.interfaceName ?? ""
        return name.contains("MTP") || name.contains("PTP")
    }

    static func describe(_ c: MTPInterfaceCandidate) -> String {
        String(format: "%@ %@ [%04x:%04x] bcdDevice %04x serial %@ location %@ | iface %d class %d/%d/%d \"%@\" endpoints %d | %@",
               c.manufacturer ?? "?", c.productName ?? "?", c.vendorID, c.productID, c.deviceRelease,
               c.serialNumber ?? "?", c.locationID.map { String(format: "0x%08x", $0) } ?? "?",
               c.interfaceNumber, c.interfaceClass, c.interfaceSubClass, c.interfaceProtocol,
               c.interfaceName ?? "", c.endpointCount,
               MTPInterfaceSelection.qualifies(c) ? "qualifies" : "not MTP")
    }

    private static func describe(_ info: PTPDeviceInfo, into report: ReportWriter) {
        report.line("Manufacturer: \(info.manufacturer)")
        report.line("Model: \(info.model)")
        report.line("Device version: \(info.deviceVersion)")
        report.line("Serial number: \(info.serialNumber)")
        report.line("Standard version: \(info.standardVersion), functional mode: \(info.functionalMode)")
        report.line("Vendor extension: id \(info.vendorExtensionID) version \(info.vendorExtensionVersion) \"\(info.vendorExtensionDesc)\"")
        report.line("Operations supported (\(info.operationsSupported.count)):")
        for code in info.operationsSupported {
            report.line(String(format: "  0x%04X %@", code, PTPOperation.names[code] ?? ""))
        }
        report.line("Events supported: \(hexList(info.eventsSupported))")
        report.line("Device properties supported: \(hexList(info.devicePropertiesSupported))")
        report.line("Capture formats: \(hexList(info.captureFormats))")
        report.line("Playback formats: \(hexList(info.playbackFormats))")
    }

    static func describe(_ error: Error) -> String {
        if let call = error as? MTPCallError { return call.description }
        return String(describing: error)
    }

    private static func hex32(_ value: UInt32) -> String { String(format: "0x%08X", value) }

    private static func hexList(_ values: [UInt16]) -> String {
        values.isEmpty ? "none" : "\(values.count): " + values.map { String(format: "0x%04X", $0) }.joined(separator: " ")
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

/// Accumulates report lines. Only the diagnostic's own thread writes to it
/// (open's log sink runs synchronously inside the open call).
private final class ReportWriter {
    private(set) var text = ""
    var errors: [String] = []
    /// Why the device steps ended early, when they did.
    var stopReason: String?
    private let clock: () -> UInt64

    init(clock: @escaping () -> UInt64) {
        self.clock = clock
    }

    func line(_ value: String) {
        text += value + "\n"
    }

    func section(_ title: String) {
        text += "\n===== \(title) =====\n"
    }

    func error(_ message: String) {
        errors.append(message)
        line("ERROR: \(message)")
    }

    func time(_ body: () -> Void) -> Double {
        let start = clock()
        body()
        return Double(clock() &- start) / 1_000_000
    }

    func timeThrowing(_ body: () throws -> Void) throws -> Double {
        let start = clock()
        try body()
        return Double(clock() &- start) / 1_000_000
    }
}
