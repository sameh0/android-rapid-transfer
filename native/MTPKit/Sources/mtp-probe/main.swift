// mtp-probe: read-only go/no-go probe for the pure-Swift MTP stack.
//
// Finds the phone, opens its MTP interface once over IOUSBHost, and exercises
// the session layer: DeviceInfo, storages, a root listing two ways, a timed
// DCIM/Camera listing two ways, and a partial download. It never writes to or
// deletes from the device and never resets it. The last line is
// "VERIFICATION ok" only when every step completed.

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
@preconcurrency import Glibc
#endif
import Foundation
import SwiftMTP

setvbuf(stdout, nil, _IOLBF, 0)

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ line: String) { print(line) }

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func sha256(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func formatBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

struct Entry {
    var name: String
    var format: UInt16
    var size: UInt64
    var modified: String
}

/// Sorted-name digest: the comparability gate between listing strategies.
func digest(_ entries: [UInt32: Entry]) -> String {
    let names = entries.values.map(\.name).sorted()
    return String(sha256(Data(names.joined(separator: "\n").utf8)).prefix(16))
}

/// Per-property GetObjectPropList (filename, format, size, date modified),
/// restricted to the authoritative handle list. Android's depth-1 reply also
/// includes the parent itself; handle filtering drops it.
func listByPropList(_ session: MTPSession, parent: UInt32, handles: [UInt32]) throws
    -> (entries: [UInt32: Entry], calls: Int, extraElements: Int) {
    let wanted = Set(handles)
    var entries: [UInt32: Entry] = [:]
    var extra = 0
    let properties: [UInt16] = [MTPObjectProperty.objectFileName, MTPObjectProperty.objectFormat,
                                MTPObjectProperty.objectSize, MTPObjectProperty.dateModified]
    for property in properties {
        let elements = try session.getObjectPropList(handle: parent, property: UInt32(property), depth: 1)
        for element in elements {
            guard wanted.contains(element.handle) else { extra += 1; continue }
            var entry = entries[element.handle] ?? Entry(name: "", format: 0, size: 0, modified: "")
            switch element.propertyCode {
            case MTPObjectProperty.objectFileName: entry.name = element.value.stringValue ?? ""
            case MTPObjectProperty.objectFormat: entry.format = UInt16(truncatingIfNeeded: element.value.unsignedValue ?? 0)
            case MTPObjectProperty.objectSize: entry.size = element.value.unsignedValue ?? 0
            case MTPObjectProperty.dateModified: entry.modified = element.value.stringValue ?? ""
            default: break
            }
            entries[element.handle] = entry
        }
    }
    return (entries, properties.count, extra)
}

func listByObjectInfo(_ session: MTPSession, handles: [UInt32]) throws -> [UInt32: Entry] {
    var entries: [UInt32: Entry] = [:]
    for handle in handles {
        let info = try session.getObjectInfo(handle)
        entries[handle] = Entry(name: info.filename, format: info.objectFormat,
                                size: UInt64(info.compressedSize), modified: info.modificationDate)
    }
    return entries
}

func compare(_ label: String, _ a: [UInt32: Entry], _ b: [UInt32: Entry], handles: [UInt32]) throws {
    let da = digest(a), db = digest(b)
    log("  \(label): proplist items=\(a.count) digest=\(da) | objectinfo items=\(b.count) digest=\(db)")
    guard a.count == handles.count, b.count == handles.count else {
        throw ProbeFailure("\(label): item counts differ from \(handles.count) handles (proplist \(a.count), objectinfo \(b.count))")
    }
    guard da == db else { throw ProbeFailure("\(label): name digests differ") }
    var formatMismatches = 0, sizeMismatches = 0
    for (handle, x) in a {
        guard let y = b[handle] else { continue }
        if x.format != y.format { formatMismatches += 1 }
        // ObjectInfo sizes are 32-bit; 0xFFFFFFFF stands for >= 4 GB.
        if x.size != y.size, !(y.size == 0xFFFF_FFFF && x.size >= 0xFFFF_FFFF) { sizeMismatches += 1 }
    }
    log("  \(label): per-handle format mismatches=\(formatMismatches) size mismatches=\(sizeMismatches)")
    if formatMismatches + sizeMismatches > 0 { throw ProbeFailure("\(label): per-handle metadata differs") }
}

func run() throws {
    let all = PlatformUSB.allInterfaces()
    log("USB interfaces in registry: \(all.count)")
    let candidates = MTPInterfaceSelection.select(all)
    for c in candidates { log("candidate: \(c)") }
    guard let candidate = candidates.first else { throw ProbeFailure("no MTP interface found") }

    log("opening \(candidate.productName ?? "?") interface \(candidate.interfaceNumber) via \(PlatformUSB.backendName)")
    var transport: (MTPTransport & USBEndpointDescribing)!
    let openMs = try milliseconds {
        transport = try PlatformUSB.open(candidate, log: { log("  \($0)") })
    }
    log(String(format: "opened in %.1f ms: bulk-in 0x%02x (mps %d) bulk-out 0x%02x (mps %d) interrupt 0x%02x (mps %d)",
               openMs, transport.bulkInAddress, transport.maxPacketSizeIn, transport.bulkOutAddress,
               transport.maxPacketSizeOut, transport.interruptAddress, transport.maxPacketSizeInterrupt))

    let session = MTPSession(transport: transport)
    defer {
        session.close()
        log("closed (CloseSession sent if open; interface released; no reset)")
    }

    let drainMs = milliseconds { () -> Void in
        let stale = session.drainStaleInput()
        log("stale bulk-in bytes drained: \(stale)")
    }
    log(String(format: "  drain took %.1f ms", drainMs))

    // 1. DeviceInfo (outside a session, transaction ID 0).
    var info: PTPDeviceInfo!
    let diMs = try milliseconds { info = try session.getDeviceInfo() }
    log(String(format: "GetDeviceInfo (%.1f ms):", diMs))
    log("  manufacturer: \(info.manufacturer)")
    log("  model: \(info.model)")
    log("  serial: \(info.serialNumber)")
    log("  device version: \(info.deviceVersion)")
    log("  standard version: \(info.standardVersion) vendor extension: \(info.vendorExtensionID) \"\(info.vendorExtensionDesc)\"")
    log("  operations supported: \(info.operationsSupported.count)")
    let hasPropList = info.supports(PTPOperation.getObjectPropList)
    let hasPartial64 = info.supports(PTPOperation.androidGetPartialObject64)
    let hasPartial = info.supports(PTPOperation.getPartialObject)
    log("  GetObjectPropList (0x9805): \(hasPropList)  GetPartialObject (0x101B): \(hasPartial)  GetPartialObject64 (0x95C1): \(hasPartial64)")
    if candidate.needsVendorExtensionCheck, !MTPInterfaceSelection.vendorExtensionAcceptable(info.vendorExtensionDesc) {
        throw ProbeFailure("interface has no name and no MTP vendor extension")
    }

    // 2. Session.
    let osMs = try milliseconds { try session.openSession(id: 1) }
    log(String(format: "OpenSession(1) ok (%.1f ms)", osMs))

    // 3. Storages.
    let storageIDs = try session.getStorageIDs()
    log("storages: \(storageIDs.map { String(format: "0x%08X", $0) }.joined(separator: ", "))")
    guard !storageIDs.isEmpty else { throw ProbeFailure("device reports no storage (phone locked?)") }
    for id in storageIDs {
        let s = try session.getStorageInfo(id)
        log(String(format: "  0x%08X \"%@\" capacity %@ free %@ (type %d, fs %d, access %d)", id,
                   s.storageDescription, formatBytes(s.maxCapacity), formatBytes(s.freeSpaceInBytes),
                   s.storageType, s.filesystemType, s.accessCapability))
    }
    let storage = storageIDs[0]

    // 4. Root listing, both ways.
    let rootHandles = try session.getObjectHandles(storageID: storage, parent: PTPHandle.root)
    log("root of 0x\(String(storage, radix: 16)): \(rootHandles.count) handles")
    guard hasPropList else { throw ProbeFailure("device does not advertise GetObjectPropList") }
    var rootProp: [UInt32: Entry] = [:]
    var rootExtra = 0
    let rootPropMs = try milliseconds {
        // Handle 0 with depth 1 is "children of the root" (0xFFFFFFFF would be every object).
        let result = try listByPropList(session, parent: 0, handles: rootHandles)
        rootProp = result.entries
        rootExtra = result.extraElements
    }
    var rootInfo: [UInt32: Entry] = [:]
    let rootInfoMs = try milliseconds { rootInfo = try listByObjectInfo(session, handles: rootHandles) }
    log(String(format: "  root via GetObjectPropList x4: %.1f ms (%d elements outside this storage's root dropped)", rootPropMs, rootExtra))
    log(String(format: "  root via GetObjectInfo x%d: %.1f ms", rootHandles.count, rootInfoMs))
    let rootNames = rootInfo.values.sorted { $0.name < $1.name }
        .map { $0.format == PTPObjectFormat.association ? $0.name + "/" : $0.name }
    log("  root names: \(rootNames.joined(separator: ", "))")
    try compare("root", rootProp, rootInfo, handles: rootHandles)

    // 5. Resolve DCIM/Camera (or DCIM).
    guard let dcim = rootInfo.first(where: { $0.value.name == "DCIM" && $0.value.format == PTPObjectFormat.association })?.key else {
        throw ProbeFailure("no DCIM folder at the root")
    }
    let dcimHandles = try session.getObjectHandles(storageID: storage, parent: dcim)
    let dcimNames = try session.getObjectPropList(handle: dcim, property: UInt32(MTPObjectProperty.objectFileName))
    var target = dcim
    var targetPath = "DCIM"
    if let camera = dcimNames.first(where: { $0.value.stringValue == "Camera" && Set(dcimHandles).contains($0.handle) }) {
        target = camera.handle
        targetPath = "DCIM/Camera"
    }
    let numObjects = try session.getNumObjects(storageID: storage, parent: target)
    log("target \(targetPath): handle 0x\(String(target, radix: 16)), GetNumObjects=\(numObjects)")

    // 6. Timed listing of the target, both strategies, twice, alternating.
    var lastProp: [UInt32: Entry] = [:]
    var lastInfo: [UInt32: Entry] = [:]
    var targetHandles: [UInt32] = []
    for round in 1...2 {
        var handlesMs = 0.0, propMs = 0.0, infoMs = 0.0
        handlesMs = try milliseconds {
            targetHandles = try session.getObjectHandles(storageID: storage, parent: target)
        }
        propMs = try milliseconds { lastProp = try listByPropList(session, parent: target, handles: targetHandles).entries }
        let handlesMs2 = try milliseconds {
            targetHandles = try session.getObjectHandles(storageID: storage, parent: target)
        }
        infoMs = try milliseconds { lastInfo = try listByObjectInfo(session, handles: targetHandles) }
        log(String(format: "TIMING round %d %@ (%d items): GetObjectHandles+GetObjectPropList x4 = %.1f ms (%.1f + %.1f) | GetObjectHandles+GetObjectInfo x%d = %.1f ms (%.1f + %.1f) | ratio %.1fx",
                   round, targetPath, targetHandles.count, handlesMs + propMs, handlesMs, propMs,
                   targetHandles.count, handlesMs2 + infoMs, handlesMs2, infoMs,
                   (handlesMs2 + infoMs) / max(handlesMs + propMs, 0.001)))
        try compare("\(targetPath) round \(round)", lastProp, lastInfo, handles: targetHandles)
    }

    // 7. Partial download of one file.
    let files = lastInfo.filter { $0.value.format != PTPObjectFormat.association && $0.value.size > 0 }
        .sorted { $0.value.name < $1.value.name }
    // Prefer the first file (by name) of at least 1 MB, else the largest one.
    guard let (fileHandle, file) = files.first(where: { $0.value.size >= 1 << 20 })
            ?? files.max(by: { $0.value.size < $1.value.size })
    else { throw ProbeFailure("no file in \(targetPath) to download") }
    let want = UInt32(min(UInt64(1 << 20), file.size))
    var chunk = Data()
    let dlMs = try milliseconds { chunk = try session.getPartialObject(fileHandle, offset: 0, maxBytes: want) }
    guard chunk.count == Int(want) else { throw ProbeFailure("GetPartialObject returned \(chunk.count) of \(want) bytes") }
    log(String(format: "GetPartialObject %@/%@ (size %llu) bytes 0..<%u: %.1f ms, %.1f MB/s, sha256 %@",
               targetPath, file.name, file.size, want, dlMs, Double(want) / 1_048_576 / (dlMs / 1000),
               sha256(chunk)))
    if hasPartial64 {
        let chunk64 = try session.getPartialObject64(fileHandle, offset: 0, maxBytes: want)
        guard chunk64 == chunk else { throw ProbeFailure("GetPartialObject64 bytes differ from GetPartialObject") }
        log("GetPartialObject64 0..<\(want): identical bytes")
    }

    // Informational: bulk throughput on a 32 MB read of the largest file.
    if hasPartial64, let (bigHandle, big) = files.max(by: { $0.value.size < $1.value.size }), big.size >= 32 << 20 {
        var received = 0
        let ms = try milliseconds {
            received = try session.getPartialObject64(bigHandle, offset: 0, maxBytes: 32 << 20).count
        }
        log(String(format: "throughput: GetPartialObject64 %@ 32 MB in %.1f ms = %.1f MB/s",
                   big.name, ms, Double(received) / 1_048_576 / (ms / 1000)))
    }

    // 8. Close the session explicitly (close() below then only releases).
    try session.closeSession()
    log("CloseSession ok")
}

do {
    try run()
    log("VERIFICATION ok")
    exit(0)
} catch {
    log("VERIFICATION failed: \(error)")
    exit(1)
}
