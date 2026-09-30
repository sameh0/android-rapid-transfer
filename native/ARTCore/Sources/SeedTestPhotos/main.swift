#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#endif
import Dispatch
import Foundation
import MTPKit
import AndroidRapidTransferCore

@main
@MainActor
struct SeedTestPhotos {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        var start = DispatchTime.now().uptimeNanoseconds
        var uploaded = 0
        var passed = false

        do {
            guard let source = environment["SEED_SOURCE_DIR"],
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(description: "SEED_SOURCE_DIR is required and must name a local directory.")
            }
            let destination = environment["SEED_DEST"] ?? "/DCIM/Camera"
            guard destination.hasPrefix("/"), !destination.contains("\0"),
                  !destination.split(separator: "/").contains("..") else {
                throw Failure(description: "SEED_DEST must be an absolute device path without '..'.")
            }
            let batchSize = try integer(environment["SEED_BATCH"] ?? "100", name: "SEED_BATCH", minimum: 1)
            let limit = try environment["SEED_LIMIT"].map { try integer($0, name: "SEED_LIMIT", minimum: 0) }
            let directory = URL(fileURLWithPath: source, isDirectory: true).standardizedFileURL
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw Failure(description: "SEED_SOURCE_DIR is not a directory: \(source)")
            }
            let candidates = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ).filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var files: [URL] = []
            for file in candidates {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard file.lastPathComponent.hasPrefix("TESTIMG_") else {
                    throw Failure(description: "Refusing source filename without TESTIMG_ prefix: \(file.lastPathComponent)")
                }
                files.append(file)
            }
            guard !files.isEmpty else {
                throw Failure(description: "SEED_SOURCE_DIR has no matching regular *.jpg files: \(directory.path)")
            }
            if let limit { files = Array(files.prefix(limit)) }
            var names: Set<String> = []
            for file in files {
                guard names.insert(collisionKey(file.lastPathComponent)).inserted else {
                    throw Failure(description: "Source filenames could collide on the device: \(file.lastPathComponent)")
                }
            }
            print("SeedTestPhotos: destination=\(destination), files=\(files.count), batchSize=\(batchSize)")
            if environment["SEED_ASSUME_YES"] != "1" {
                print("Type yes to upload these test photos:")
                guard readLine() == "yes" else {
                    throw Failure(description: "Confirmation declined; no files uploaded.")
                }
            }
            start = DispatchTime.now().uptimeNanoseconds
            let provider = MTPProviderFactory.make(log: nil)
            let browser = DeviceBrowserViewModel(provider: provider)
            await browser.load()
            if let error = browser.error {
                throw Failure(description: "Device load failed: \(error.message)")
            }
            guard let firstStorage = browser.storages.first else {
                throw Failure(description: "No MTP storages found. Connect and unlock the phone in file-transfer mode.")
            }
            let storageID = browser.selectedStorageID ?? firstStorage.id
            if browser.selectedStorageID != storageID {
                await browser.selectStorage(id: storageID)
                if let error = browser.error {
                    throw Failure(description: "Storage selection failed: \(error.message)")
                }
            }

            // The provider reuses existing directories and returns success; a file at this path is an error.
            guard try await provider.makeDirectory(input: MakeDirectoryInput(
                storageId: storageID, fullPath: destination
            )) else {
                throw Failure(description: "Could not ensure destination directory exists: \(destination)")
            }
            var entries = try await browser.listDirectoryForScan(destination, storageID: storageID)
            let baseline = entries.filter { $0.name.hasPrefix("TESTIMG_") && !$0.isDirectory }.count
            try refuseCollisions(files, entries: entries)
            let batchCount = files.count / batchSize + (files.count % batchSize == 0 ? 0 : 1)
            var transferFailed = false
            for (index, offset) in stride(from: 0, to: files.count, by: batchSize).enumerated() {
                let batch = Array(files[offset..<offset + min(batchSize, files.count - offset)])
                let batchStart = DispatchTime.now().uptimeNanoseconds
                var confirmed = 0
                do {
                    // UploadFiles overwrites collisions internally; recheck before each batch.
                    if index > 0 {
                        entries = try await browser.listDirectoryForScan(destination, storageID: storageID)
                    }
                    try refuseCollisions(batch, entries: entries)
                    let operation = try await provider.uploadFiles(input: UploadFilesInput(
                        storageId: storageID, sources: batch.map(\.path),
                        destination: destination, preprocessFiles: true
                    ))
                    for await event in operation.progress {
                        if case let .progress(info) = event {
                            confirmed = max(confirmed, Int(clamping: max(0, min(info.filesSent, Int64(batch.count)))))
                        }
                    }
                    let ok = try await operation.result.value
                    print("batch \(index + 1)/\(batchCount): \(batch.count) files, "
                        + "\(number(elapsedMilliseconds(since: batchStart)))ms, ok=\(ok)")
                    uploaded += ok ? batch.count : confirmed
                    if !ok {
                        print("ERROR: Batch returned false; stopping. At least \(uploaded) files uploaded.")
                        transferFailed = true
                        break
                    }
                } catch {
                    uploaded += confirmed
                    print("batch \(index + 1)/\(batchCount): \(batch.count) files, "
                        + "\(number(elapsedMilliseconds(since: batchStart)))ms, ok=false")
                    print("ERROR: Batch failed: \(error). Stopping; at least \(uploaded) files uploaded.")
                    transferFailed = true
                    break
                }
            }

            entries = try await browser.listDirectoryForScan(destination, storageID: storageID)
            let present = entries.filter { $0.name.hasPrefix("TESTIMG_") && !$0.isDirectory }.count
            let delta = present - baseline
            let uploadedNames = Set(files.map(\.lastPathComponent))
            let matching = entries.filter { uploadedNames.contains($0.name) && !$0.isDirectory }.count
            print("VERIFICATION: TESTIMG_ files baseline=\(baseline), final=\(present), delta=\(delta), uploaded=\(uploaded), planned names present=\(matching)")
            if transferFailed {
                print("Failed-batch progress is a lower bound; device entries may include an incomplete file.")
            }
            passed = !transferFailed && delta == uploaded && matching == files.count
            print("\(passed ? "PASS" : "FAIL"): device TESTIMG_ file delta versus uploaded count and planned names present")
        } catch {
            print("ERROR: \(error)")
        }

        let totalMS = elapsedMilliseconds(since: start)
        print("Total uploaded (confirmed)=\(uploaded)")
        print("Total wall-clock: \(number(totalMS))ms")
        let mean = uploaded > 0 ? number(totalMS / Double(uploaded)) + "ms" : "N/A"
        print("Mean per uploaded file: \(mean)")
        exit(passed ? 0 : 1)
    }

    private static func integer(_ text: String, name: String, minimum: Int) throws -> Int {
        guard let value = Int(text), value >= minimum else {
            throw Failure(description: "\(name) must be an integer >= \(minimum); got \(text).")
        }
        return value
    }

    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func refuseCollisions(_ files: [URL], entries: [BrowserEntry]) throws {
        let existing = Set(entries.map { collisionKey($0.name) })
        if let offender = files.first(where: { existing.contains(collisionKey($0.lastPathComponent)) }) {
            throw Failure(description: "Refusing to overwrite existing device entry: \(offender.lastPathComponent)")
        }
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
