// swift-provider-probe: end-to-end device probe that drives ONLY the public
// MTPDeviceProvider API, against SwiftMTPProvider.
//
// Everything it writes lives in /Download/ART-Phase7-Probe/ on the phone,
// which it deletes first if present and deletes again at the end. The last
// line is "VERIFICATION ok" only when every step passed (including a download
// and an upload cancelled mid-file); otherwise
// "VERIFICATION failed: <reason>" and exit status 1.

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
@preconcurrency import Glibc
#endif
import Foundation
import MTPKit
import SwiftMTP

setvbuf(stdout, nil, _IOLBF, 0)

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ line: String) { print(line) }

func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ProbeFailure(message()) }
}

func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

// MARK: - Arguments

var verbose = false
var asciiNames = false
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--verbose":
        verbose = true
    case "--ascii-names":
        // Plain ASCII names instead of emoji and accented ones.
        asciiNames = true
    default:
        log("usage: swift-provider-probe [--verbose] [--ascii-names]")
        exit(2)
    }
}

let sandbox = "/Download/ART-Phase7-Probe"

// MARK: - Local fixtures

struct LocalFile {
    let url: URL
    let size: Int
    let sha256: String
}

func writeRandomFile(_ url: URL, size: Int) throws -> LocalFile {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var remaining = size
    var buffer = [UInt8](repeating: 0, count: 8 << 20)
    while remaining > 0 {
        let count = min(remaining, buffer.count)
        buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
        let chunk = Data(buffer[0..<count])
        hasher.update(data: chunk)
        try handle.write(contentsOf: chunk)
        remaining -= count
    }
    return LocalFile(url: url, size: size, sha256: hex(hasher.finalize()))
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hex(hasher.finalize())
}

// MARK: - Provider helpers

struct TransferStats {
    var events = 0
    var preprocess = 0
    var lastProgress: TransferProgressInfo?
    var seconds: Double = 0
}

func perform(_ start: () async throws -> TransferOperation) async throws -> TransferStats {
    let begin = now()
    let operation = try await start()
    var stats = TransferStats()
    for await event in operation.progress {
        stats.events += 1
        switch event {
        case .preprocess: stats.preprocess += 1
        case let .progress(info): stats.lastProgress = info
        }
    }
    let ok = try await operation.result.value
    stats.seconds = now() - begin
    try check(ok, "transfer result was false")
    return stats
}

/// Starts a transfer, cancels it once 20 MB have moved, and requires it to
/// end with an error. Returns the bytes moved at cancel time and how long
/// the transfer took to settle after the cancel.
func abortMidFile(label: String, _ start: () async throws -> TransferOperation) async throws -> (at: Int64, settle: Double) {
    let operation = try await start()
    var cancelledAt: Int64?
    var cancelTime = 0.0
    for await event in operation.progress {
        guard cancelledAt == nil, case let .progress(info) = event else { continue }
        if info.bulkFileSize.sent >= 20_000_000, info.bulkFileSize.sent < info.bulkFileSize.total {
            cancelledAt = info.bulkFileSize.sent
            cancelTime = now()
            operation.result.cancel()
        }
    }
    guard let cancelledAt else {
        _ = try? await operation.result.value
        throw ProbeFailure("\(label): no progress between 20 MB and the end to cancel at")
    }
    do {
        _ = try await operation.result.value
        throw ProbeFailure("\(label): finished although it was cancelled")
    } catch let failure as ProbeFailure {
        throw failure
    } catch {
        log("\(label) cancelled at \(cancelledAt) B: \(error)")
    }
    return (cancelledAt, now() - cancelTime)
}

func megabytesPerSecond(_ bytes: Int, _ seconds: Double) -> String {
    String(format: "%.1f MB/s (%.1f MiB/s)", Double(bytes) / 1_000_000 / seconds, Double(bytes) / 1_048_576 / seconds)
}

// MARK: - The run

func run(_ provider: any MTPDeviceProvider, asciiNames: Bool) async throws {
    // 1. Device info and storages.
    var begin = now()
    let info = try await provider.deviceInfo()
    log(String(format: "deviceInfo (%.0f ms): %@ %@ serial %@ | usb %04x:%04x \"%@\" serial %@",
               (now() - begin) * 1000, info.manufacturer, info.model, info.serialNumber,
               info.usb.vendorID, info.usb.productID, info.usb.product, info.usb.serialNumber))
    try check(!info.model.isEmpty, "no Model in deviceInfo")

    begin = now()
    let storages = try await provider.storages()
    try check(!storages.isEmpty, "no storages")
    var storageId: UInt32?
    for storage in storages {
        log(String(format: "storage 0x%08X \"%@\" capacity %.1f GB free %.1f GB", storage.id,
                   storage.storageDescription, Double(storage.maxCapacity) / 1e9,
                   Double(storage.freeSpaceInBytes) / 1e9))
        if storageId == nil { storageId = storage.id }
    }
    log(String(format: "storages took %.0f ms", (now() - begin) * 1000))
    guard let storage = storageId else { throw ProbeFailure("no storage id") }

    func exists(_ paths: [String]) async throws -> [Bool] {
        let result = try await provider.fileExists(input: FileExistsInput(storageId: storage, files: paths))
        try check(result.map(\.fullpath) == paths, "fileExists did not echo its input in order")
        return result.map(\.exists)
    }
    func walk(_ path: String, objectId: UInt32? = nil) async throws -> [WalkEntry] {
        try await provider.walk(input: DirectoryWalkInput(storageId: storage, fullPath: path, objectId: objectId,
                                                          skipDisallowedFiles: true, skipHiddenFiles: false))
    }

    // 2. Fresh sandbox.
    if try await exists([sandbox]) == [true] {
        log("removing a sandbox left by an earlier run")
        let deleted = try await provider.deleteFiles(input: DeleteFileInput(storageId: storage, files: [sandbox]))
        try check(deleted, "deleting the old sandbox returned false")
    }
    try check(try await exists([sandbox]) == [false], "the old sandbox is still there")
    try check(try await provider.makeDirectory(input: MakeDirectoryInput(storageId: storage, fullPath: sandbox)),
              "makeDirectory(sandbox) returned false")
    log("sandbox \(sandbox) created")

    // 3. mkdir -p of a nested path, and again (exists-ok).
    try check(try await provider.makeDirectory(input: MakeDirectoryInput(storageId: storage, fullPath: "\(sandbox)/a/b/c")),
              "makeDirectory a/b/c returned false")
    try check(try await provider.makeDirectory(input: MakeDirectoryInput(storageId: storage, fullPath: "\(sandbox)/A/b/")),
              "makeDirectory on an existing directory (case variant) returned false")
    let bEntries = try await walk("\(sandbox)/a/b")
    try check(bEntries.map(\.name) == ["c"] && bEntries.first?.isFolder == true, "a/b does not hold folder c: \(bEntries.map(\.name))")
    try check(try await exists(["\(sandbox)/a/b/c"]) == [true], "a/b/c does not exist")
    log("mkdir -p a/b/c ok")

    // 4. Local files.
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("swift-provider-probe-\(UUID().uuidString)")
    let upDir = workspace.appendingPathComponent("up")
    let downDir = workspace.appendingPathComponent("down")
    try FileManager.default.createDirectory(at: upDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    begin = now()
    let big = try writeRandomFile(upDir.appendingPathComponent("big-200MB.bin"), size: 200_000_000)
    let aligned = try writeRandomFile(upDir.appendingPathComponent("aligned-512x2000.bin"), size: 512 * 2000)
    let containerAligned = try writeRandomFile(upDir.appendingPathComponent("container-aligned.bin"), size: 512 * 1000 - 12)
    let empty = try writeRandomFile(upDir.appendingPathComponent("empty.bin"), size: 0)
    let unicodeName = asciiNames ? "Cafe unicode.txt" : "📷 Café ünïcødé 🎉.txt"
    let unicodeVariant = asciiNames ? "cAFE UNICODE.TXT" : "📷 café ÜNÏCØDÉ 🎉.TXT"
    let emoji = try writeRandomFile(upDir.appendingPathComponent(unicodeName), size: 3333)
    let manyDir = upDir.appendingPathComponent("many")
    try FileManager.default.createDirectory(at: manyDir, withIntermediateDirectories: true)
    var many: [LocalFile] = []
    for index in 0..<50 {
        many.append(try writeRandomFile(manyDir.appendingPathComponent(String(format: "file-%02d.txt", index)),
                                        size: 1000 + index * 97))
    }
    log(String(format: "local fixtures written in %.1f s", now() - begin))
    let singles = [big, aligned, containerAligned, empty, emoji]

    // 5. Uploads, one source per call (as the app does), then the folder.
    var bigUploadSeconds = 0.0
    for file in singles {
        let stats = try await perform {
            try await provider.uploadFiles(input: UploadFilesInput(storageId: storage, sources: [file.url.path],
                                                                   destination: sandbox, preprocessFiles: true))
        }
        let last = stats.lastProgress
        log(String(format: "upload %@ (%d B): %.2f s, %d events, last progress: filesSent %lld/%lld sent %lld/%lld speed %.2f",
                   file.url.lastPathComponent, file.size, stats.seconds, stats.events,
                   last?.filesSent ?? -1, last?.totalFiles ?? -1, last?.bulkFileSize.sent ?? -1,
                   last?.bulkFileSize.total ?? -1, last?.speed ?? -1))
        if file.url == big.url { bigUploadSeconds = stats.seconds }
    }
    let folderStats = try await perform {
        try await provider.uploadFiles(input: UploadFilesInput(storageId: storage, sources: [manyDir.path],
                                                               destination: sandbox, preprocessFiles: true))
    }
    log(String(format: "upload folder many/ (50 files): %.2f s, %d events (%d preprocess), filesSent %lld/%lld",
               folderStats.seconds, folderStats.events, folderStats.preprocess,
               folderStats.lastProgress?.filesSent ?? -1, folderStats.lastProgress?.totalFiles ?? -1))
    log("THROUGHPUT upload 200 MB: " + megabytesPerSecond(big.size, bigUploadSeconds))

    // 6. Walk and verify names and sizes.
    begin = now()
    let top = try await walk(sandbox)
    let expectedTop = Set(singles.map(\.url.lastPathComponent) + ["a", "many"])
    try check(Set(top.map(\.name)) == expectedTop, "sandbox listing \(top.map(\.name).sorted()) != \(expectedTop.sorted())")
    for file in singles {
        guard let entry = top.first(where: { $0.name == file.url.lastPathComponent }) else {
            throw ProbeFailure("\(file.url.lastPathComponent) missing from the listing")
        }
        try check(!entry.isFolder && entry.size == Int64(file.size),
                  "\(entry.name): size \(entry.size) != \(file.size)")
        try check(entry.path == "\(sandbox)/\(entry.name)", "\(entry.name): path \(entry.path)")
        try check(entry.objectId != 0, "\(entry.name): objectId 0")
        try check(entry.modified != nil, "\(entry.name): no modification date")
    }
    let manyEntries = try await walk("\(sandbox)/many")
    try check(manyEntries.count == 50, "many/ lists \(manyEntries.count) entries")
    for file in many {
        guard let entry = manyEntries.first(where: { $0.name == file.url.lastPathComponent }),
              entry.size == Int64(file.size) else {
            throw ProbeFailure("many/\(file.url.lastPathComponent) missing or wrong size")
        }
    }
    log(String(format: "walk verified %d + %d entries (%.0f ms)", top.count, manyEntries.count, (now() - begin) * 1000))

    // 7. fileExists with case variants.
    let variants = ["\(sandbox.lowercased())/BIG-200MB.BIN", "/DOWNLOAD/art-phase7-probe/MANY/File-07.TXT",
                    "\(sandbox)/A/B/C", "\(sandbox)/\(unicodeVariant)", "\(sandbox)/missing.bin"]
    let variantResult = try await exists(variants)
    try check(variantResult == [true, true, true, true, false], "case-variant fileExists gave \(variantResult)")
    log("fileExists case variants ok: \(variantResult)")

    // 8. Rename.
    try check(try await provider.renameFile(input: RenameFileInput(
        storageId: storage, fullPath: "\(sandbox)/aligned-512x2000.bin", newFileName: "renamed-512x2000.bin")),
        "renameFile returned false")
    let afterRename = try await exists(["\(sandbox)/aligned-512x2000.bin", "\(sandbox)/renamed-512x2000.bin"])
    try check(afterRename == [false, true], "after rename fileExists gave \(afterRename)")
    log("rename ok")

    // 9. Download everything and compare SHA-256.
    let listing = try await walk(sandbox)
    var expectedHashes: [String: String] = [:]
    for file in singles { expectedHashes[file.url.lastPathComponent] = file.sha256 }
    expectedHashes["renamed-512x2000.bin"] = aligned.sha256
    expectedHashes["aligned-512x2000.bin"] = nil
    var bigDownloadSeconds = 0.0
    for entry in listing where !entry.isFolder {
        let stats = try await perform {
            try await provider.downloadFiles(input: DownloadFilesInput(
                storageId: storage, sources: [entry.path],
                sourceProps: [SourceProp(fullPath: entry.path, objectId: entry.objectId)],
                destination: downDir.path, preprocessFiles: true))
        }
        let local = downDir.appendingPathComponent(entry.name)
        let hash = try sha256(of: local)
        try check(hash == expectedHashes[entry.name], "\(entry.name): SHA-256 mismatch after download")
        log(String(format: "download %@: %.2f s, %d events, sha256 ok", entry.name, stats.seconds, stats.events))
        if entry.name == big.url.lastPathComponent { bigDownloadSeconds = stats.seconds }
    }
    let manyEntry = listing.first { $0.name == "many" }
    let manyDownload = try await perform {
        try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: storage, sources: ["\(sandbox)/many"],
            sourceProps: manyEntry.map { [SourceProp(fullPath: $0.path, objectId: $0.objectId)] } ?? [],
            destination: downDir.path, preprocessFiles: true))
    }
    for file in many {
        let hash = try sha256(of: downDir.appendingPathComponent("many").appendingPathComponent(file.url.lastPathComponent))
        try check(hash == file.sha256, "many/\(file.url.lastPathComponent): SHA-256 mismatch")
    }
    log(String(format: "download folder many/: %.2f s, 50 files sha256 ok", manyDownload.seconds))
    log("THROUGHPUT download 200 MB: " + megabytesPerSecond(big.size, bigDownloadSeconds))

    // 9b. Abort a download and an upload mid-file; the session must survive
    // and neither side may keep a partial file.
    let abortDown = workspace.appendingPathComponent("abort-down")
    try FileManager.default.createDirectory(at: abortDown, withIntermediateDirectories: true)
    guard let bigEntry = listing.first(where: { $0.name == big.url.lastPathComponent }) else {
        throw ProbeFailure("big file missing before the abort test")
    }
    let downAbort = try await abortMidFile(label: "download") {
        try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: storage, sources: [bigEntry.path],
            sourceProps: [SourceProp(fullPath: bigEntry.path, objectId: bigEntry.objectId)],
            destination: abortDown.path, preprocessFiles: true))
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: abortDown.path)
    try check(leftovers.isEmpty, "aborted download left local files: \(leftovers)")
    let abortName = "abort-up-200MB.bin"
    let abortSource = upDir.appendingPathComponent(abortName)
    try FileManager.default.linkItem(at: big.url, to: abortSource)
    let upAbort = try await abortMidFile(label: "upload") {
        try await provider.uploadFiles(input: UploadFilesInput(storageId: storage, sources: [abortSource.path],
                                                               destination: sandbox, preprocessFiles: true))
    }
    let afterAbort = try await walk(sandbox)
    try check(!afterAbort.contains { $0.name == abortName }, "aborted upload left \(abortName) on the phone")
    try check(Set(afterAbort.map(\.name)) == Set(listing.map(\.name)), "listing changed after the aborts")
    let checkDir = workspace.appendingPathComponent("after-abort")
    guard let small = afterAbort.first(where: { $0.name == "renamed-512x2000.bin" }) else {
        throw ProbeFailure("renamed file missing after the aborts")
    }
    _ = try await perform {
        try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: storage, sources: [small.path],
            sourceProps: [SourceProp(fullPath: small.path, objectId: small.objectId)],
            destination: checkDir.path, preprocessFiles: false))
    }
    try check(try sha256(of: checkDir.appendingPathComponent(small.name)) == aligned.sha256,
              "download after the aborts: SHA-256 mismatch")
    log(String(format: "ABORT download at %.0f MB settled in %.2f s; upload at %.0f MB settled in %.2f s; session usable, no partial files",
               Double(downAbort.at) / 1e6, downAbort.settle, Double(upAbort.at) / 1e6, upAbort.settle))

    // 10. Upload over an existing name (replace), then verify by download.
    let replaceDir = workspace.appendingPathComponent("replace")
    try FileManager.default.createDirectory(at: replaceDir, withIntermediateDirectories: true)
    let replacement = try writeRandomFile(replaceDir.appendingPathComponent(emoji.url.lastPathComponent), size: 777)
    _ = try await perform {
        try await provider.uploadFiles(input: UploadFilesInput(storageId: storage, sources: [replacement.url.path],
                                                               destination: sandbox, preprocessFiles: true))
    }
    let afterReplace = try await walk(sandbox).filter { $0.name == emoji.url.lastPathComponent }
    try check(afterReplace.count == 1 && afterReplace[0].size == 777,
              "replace left \(afterReplace.count) entries, sizes \(afterReplace.map(\.size))")
    let replaceDown = workspace.appendingPathComponent("replace-down")
    _ = try await perform {
        try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: storage, sources: [afterReplace[0].path], destination: replaceDown.path, preprocessFiles: false))
    }
    try check(try sha256(of: replaceDown.appendingPathComponent(emoji.url.lastPathComponent)) == replacement.sha256,
              "replaced file content mismatch")
    log("upload over an existing name replaced it (1 entry, new content)")

    // 11. Delete the sandbox and verify it is gone.
    try check(try await provider.deleteFiles(input: DeleteFileInput(storageId: storage, files: [sandbox])),
              "deleting the sandbox returned false")
    try check(try await exists([sandbox]) == [false], "the sandbox still exists after delete")
    let download = try await walk("/Download")
    try check(!download.contains { $0.name == "ART-Phase7-Probe" }, "the sandbox is still listed in /Download")
    log("sandbox deleted and gone")
}

// MARK: - Main

let providerLog: (@Sendable (String) -> Void)? = verbose ? { @Sendable line in print("  [swift] \(line)") } : nil
let provider: any MTPDeviceProvider = SwiftMTPProvider(configuration: SwiftMTPProviderConfiguration(log: providerLog))
log("provider: SwiftMTPProvider")

let started = now()
var failureReason: String?
do {
    try await run(provider, asciiNames: asciiNames)
} catch {
    failureReason = "\(error)"
    log("ERROR: \(error)")
    // Best effort: leave nothing behind on the phone.
    if let storages = try? await provider.storages(), let first = storages.first {
        _ = try? await provider.deleteFiles(input: DeleteFileInput(storageId: first.id, files: [sandbox]))
    }
}
_ = try? await provider.dispose()
log(String(format: "total %.1f s", now() - started))
if let failureReason {
    log("VERIFICATION failed: \(failureReason)")
    exit(1)
}
log("VERIFICATION ok")
exit(0)
