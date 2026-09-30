#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
struct RecursiveWalkProbe {
    private enum Arm: String {
        case a = "A"
        case b = "B"
    }

    private struct Run {
        let arm: Arm
        let elapsedMS: Double
        let matches: [DateRangeMatch]
        let scannedFolders: Int?
        let failures: Int?
        let returnedEntries: Int?

        var digest: String {
            let sortedIDs = matches.map(\.id).sorted().joined(separator: "\n")
            return SHA256.hash(data: Data(sortedIDs.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["SCAN_ROOT"] ?? "/DCIM"
        let daysText = environment["SCAN_DAYS"] ?? "3650"
        guard let days = Double(daysText), days.isFinite, days >= 0,
              (days * 86_400).isFinite else {
            print("ERROR: SCAN_DAYS must be a finite, non-negative number; got \(oneLine(daysText)).")
            exit(1)
        }
        guard root.hasPrefix("/") else {
            print("ERROR: SCAN_ROOT must be an absolute device path; got \(oneLine(root)).")
            exit(1)
        }
        let timeoutText = environment["WALK_TIMEOUT_SECONDS"] ?? "300"
        guard let timeout = Int(timeoutText), timeout > 0 else {
            print("ERROR: WALK_TIMEOUT_SECONDS must be a positive integer; got \(oneLine(timeoutText)).")
            exit(1)
        }
        do {
            let provider = MTPProviderFactory.make(log: nil)
            let browser = DeviceBrowserViewModel(provider: provider)
            await browser.load()
            if let error = browser.error {
                print("ERROR: Device load failed: \(oneLine(error.message))")
                exit(1)
            }
            guard let firstStorage = browser.storages.first else {
                print("ERROR: No MTP storages found. Connect and unlock the phone in file-transfer mode.")
                exit(1)
            }
            let storageID = browser.selectedStorageID ?? firstStorage.id
            if browser.selectedStorageID != storageID {
                await browser.selectStorage(id: storageID)
                if let error = browser.error {
                    print("ERROR: Storage selection failed: \(oneLine(error.message))")
                    exit(1)
                }
            }

            let scanner = DeviceFolderScanner { path, objectID in
                try await browser.listDirectoryForScan(path, objectId: objectID, storageID: storageID)
            }
            let filter = DateRangeFilter(start: Date().addingTimeInterval(-days * 86_400))
            let input = DirectoryWalkInput(
                storageId: storageID, fullPath: root, objectId: nil,
                skipDisallowedFiles: true, skipHiddenFiles: false
            )
            print("RecursiveWalkProbe: root=\(oneLine(root)), days=\(number(days)), "
                + "storageID=\(storageID), recursiveTimeoutSeconds=\(timeout)")
            print("One session, no replug; one untimed A warm-up, then A B B A A B B A.")
            print("A = app scanner, B = depth-first provider walk.")

            // Warm device metadata caches without retaining any warm-up timing.
            _ = await scanner.scan(roots: [root], filter: filter, exclusions: .none)

            var runs: [Run] = []
            let sequence: [Arm] = [.a, .b, .b, .a, .a, .b, .b, .a]
            for arm in sequence {
                switch arm {
                case .a:
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = await scanner.scan(roots: [root], filter: filter, exclusions: .none)
                    let elapsedMS = elapsedMilliseconds(since: start)
                    runs.append(Run(
                        arm: arm, elapsedMS: elapsedMS, matches: result.matches,
                        scannedFolders: result.scannedFolders, failures: result.failures.count,
                        returnedEntries: nil
                    ))
                case .b:
                    let start = DispatchTime.now().uptimeNanoseconds
                    let entries = try await recursiveWalk(
                        provider, input: input, timeoutSeconds: timeout
                    )
                    // No exclusions or deduplication: the digest gate tests equivalence.
                    let matches = entries.map { BrowserEntry(walkEntry: $0) }.compactMap { entry -> DateRangeMatch? in
                        guard !entry.isDirectory, filter.matches(entry) else { return nil }
                        let relativePath = entry.location.hasPrefix("/")
                            ? String(entry.location.dropFirst()) : entry.location
                        return DateRangeMatch(entry: entry, relativePath: relativePath)
                    }
                    let elapsedMS = elapsedMilliseconds(since: start)
                    runs.append(Run(
                        arm: arm, elapsedMS: elapsedMS, matches: matches,
                        scannedFolders: nil, failures: nil, returnedEntries: entries.count
                    ))
                }
            }

            print("\nRESULTS")
            for (index, run) in runs.enumerated() {
                var details = ""
                if let folders = run.scannedFolders, let failures = run.failures {
                    details = "scannedFolders=\(folders), failures=\(failures)"
                }
                if let entries = run.returnedEntries {
                    details = "recursiveWalkCalls=1, returnedEntries=\(entries) (files + folders)"
                }
                print("Run \(index + 1) \(run.arm.rawValue): \(number(run.elapsedMS))ms, \(details)")
            }
            print("Median A: \(number(median(runs.filter { $0.arm == .a }.map(\.elapsedMS))))ms")
            print("Median B: \(number(median(runs.filter { $0.arm == .b }.map(\.elapsedMS))))ms")
            let deltas = stride(from: 0, to: runs.count, by: 2).map { index in
                let first = runs[index]
                let second = runs[index + 1]
                return first.arm == .a
                    ? first.elapsedMS - second.elapsedMS : second.elapsedMS - first.elapsedMS
            }
            print("Median paired delta (A - B): \(number(median(deltas)))ms "
                + "(positive means recursive is faster; pairs 1/2, 3/4, 5/6, 7/8)")

            print("\nCOMPARABILITY")
            let digests = runs.map(\.digest)
            for (index, run) in runs.enumerated() {
                print("Run \(index + 1) \(run.arm.rawValue): matches=\(run.matches.count), "
                    + "SHA-256=\(digests[index])")
            }
            let passed = Set(digests).count == 1
            if passed {
                print("PASS: all 8 match digests are identical.")
            } else {
                print("FAIL: match digests differ. A timing comparison between arms that found "
                    + "different files is meaningless.")
                // Prefer the timed pairs; also detect drift between otherwise equal pairs.
                var pairs = stride(from: 0, to: runs.count, by: 2).map { ($0, $0 + 1) }
                for i in runs.indices {
                    for j in runs.indices where j > i && runs[i].arm != runs[j].arm {
                        pairs.append((i, j))
                    }
                }
                if let (i, j) = pairs.first(where: { digests[$0.0] != digests[$0.1] }) {
                    let left = Set(runs[i].matches.map(\.id))
                    let right = Set(runs[j].matches.map(\.id))
                    printDifference(left.subtracting(right), from: i, absentFrom: j, runs: runs)
                    printDifference(right.subtracting(left), from: j, absentFrom: i, runs: runs)
                    if left == right {
                        print("Unique IDs agree, but duplicate ID counts differ; digests still fail.")
                    }
                }
            }
            exit(passed ? 0 : 1)
        } catch {
            print("\nCOMPARABILITY\nFAIL: probe could not complete: \(oneLine(String(describing: error)))")
            print("No valid timing comparison is available.")
            exit(1)
        }
    }

    private static func printDifference(_ ids: Set<String>, from: Int, absentFrom: Int, runs: [Run]) {
        print("IDs in run \(from + 1) \(runs[from].arm.rawValue) absent from "
            + "run \(absentFrom + 1) \(runs[absentFrom].arm.rawValue): \(ids.count) (showing up to 10)")
        for id in ids.sorted().prefix(10) {
            print("  \(oneLine(id))")
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Arm B: the provider walked depth-first, one directory listing per
    /// folder, bypassing the app's scanner, bounded by `timeoutSeconds`.
    private static func recursiveWalk(
        _ provider: any MTPDeviceProvider,
        input: DirectoryWalkInput,
        timeoutSeconds: Int
    ) async throws -> [WalkEntry] {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds) * 1_000_000_000
        var entries: [WalkEntry] = []
        var pending: [(path: String, objectId: UInt32?)] = [(input.fullPath, input.objectId)]
        while let next = pending.popLast() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw ProbeTimeout(seconds: timeoutSeconds)
            }
            let children = try await provider.walk(input: DirectoryWalkInput(
                storageId: input.storageId, fullPath: next.path, objectId: next.objectId,
                skipDisallowedFiles: input.skipDisallowedFiles, skipHiddenFiles: input.skipHiddenFiles
            ))
            entries.append(contentsOf: children)
            for child in children.reversed() where child.isFolder {
                pending.append((child.path, child.objectId))
            }
        }
        return entries
    }

    private struct ProbeTimeout: Error, CustomStringConvertible {
        let seconds: Int
        var description: String { "the recursive walk exceeded \(seconds)s" }
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }
}
