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
struct ScanProbe {
    private struct Batch {
        let elapsedMS: Double
        let matches: [DateRangeMatch]
        let cumulativeCount: Int
    }

    private struct ProgressSample {
        let elapsedMS: Double
        let path: String
        let scannedFolders: Int
        let matchedFiles: Int
    }

    private struct ListingSample {
        let elapsedMS: Double
        let progress: DirectoryListingProgress
    }

    private struct FolderTiming {
        let sample: ProgressSample
        let deltaMS: Double
        let matches: Int
    }

    private struct GroupTiming {
        var folders = 0
        var totalMS = 0.0
        var matches = 0
    }

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let cohortPrefixes = Set((environment["SCAN_COHORT_PREFIXES"] ?? "Android,MIUI")
            .split(separator: ",")
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "/" })) }
            .filter { !$0.isEmpty })
        let root = environment["SCAN_ROOT"] ?? "/DCIM"
        let daysText = environment["SCAN_DAYS"] ?? "3650"
        guard let days = Double(daysText), days.isFinite, days >= 0,
              (days * 86_400).isFinite else {
            print("ERROR: SCAN_DAYS must be a finite, non-negative number; got \(daysText).")
            exit(1)
        }
        guard root.hasPrefix("/") else {
            print("ERROR: SCAN_ROOT must be an absolute device path; got \(root).")
            exit(1)
        }
        let provider = MTPProviderFactory.make(log: nil)
        let browser = DeviceBrowserViewModel(provider: provider)
        await browser.load()
        if let error = browser.error {
            print("ERROR: Device load failed: \(error.message)")
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
                print("ERROR: Storage selection failed: \(error.message)")
                exit(1)
            }
        }

        var listingDurations: [String: Double] = [:]
        let scanner = DeviceFolderScanner { path, objectID, onProgress in
            let listingStart = DispatchTime.now().uptimeNanoseconds
            defer { listingDurations[path] = elapsedMilliseconds(since: listingStart) }
            return try await browser.listDirectoryForScan(
                path, objectId: objectID, storageID: storageID, onProgress: onProgress
            )
        }
        let filter = DateRangeFilter(start: Date().addingTimeInterval(-days * 86_400))
        var batches: [Batch] = []
        var progressSamples: [ProgressSample] = []
        var listingSamples: [ListingSample] = []
        var cumulativeCount = 0
        var progressCount = 0
        var lastProgress: DateRangeScanProgress?
        print("ScanProbe: root=\(root), days=\(daysText), storageID=\(storageID)")
        let start = DispatchTime.now().uptimeNanoseconds
        let result = await scanner.scan(
            roots: [root],
            filter: filter,
            onMatch: { matches in
                let elapsedMS = elapsedMilliseconds(since: start)
                cumulativeCount += matches.count
                // Defer printing so console I/O does not distort callback timing.
                batches.append(Batch(
                    elapsedMS: elapsedMS, matches: matches, cumulativeCount: cumulativeCount
                ))
            },
            onProgress: { progress in
                progressSamples.append(ProgressSample(
                    elapsedMS: elapsedMilliseconds(since: start),
                    path: progress.currentPath,
                    scannedFolders: progress.scannedFolders,
                    matchedFiles: progress.matchedFiles
                ))
                progressCount += 1
                lastProgress = progress
            },
            onListing: { listing in
                listingSamples.append(ListingSample(
                    elapsedMS: elapsedMilliseconds(since: start), progress: listing
                ))
            }
        )
        let totalMS = elapsedMilliseconds(since: start)
        print("\nSCAN SUMMARY")
        print("Total wall-clock: \(number(totalMS))ms")
        print("scannedFolders=\(result.scannedFolders), total matches=\(result.matches.count), "
            + "failures=\(result.failures.count), isCancelled=\(result.isCancelled)")
        print("onMatch callbacks=\(batches.count), onProgress callbacks=\(progressCount)")
        if let lastProgress {
            print("Last progress: scannedFolders=\(lastProgress.scannedFolders), "
                + "matchedFiles=\(lastProgress.matchedFiles), currentPath=\(lastProgress.currentPath)")
        }

        let nonEmpty = batches.filter { !$0.matches.isEmpty }
        print("\nSTREAMING TIMELINE")
        if nonEmpty.isEmpty {
            print("No non-empty batches.")
        }
        for (index, batch) in nonEmpty.enumerated() {
            if nonEmpty.count > 40, index >= 20, index < nonEmpty.count - 20 {
                if index == 20 {
                    print("... \(nonEmpty.count - 40) non-empty batches omitted ...")
                }
                continue
            }
            if let first = batch.matches.first {
                print("\(number(batch.elapsedMS))ms  +\(batch.matches.count)  "
                    + "total=\(batch.cumulativeCount)  \(first.relativePath)")
            }
        }

        print("\nWHERE THE TIME WENT")
        var previousElapsedMS = 0.0
        var folderTimings: [FolderTiming] = []
        var groups: [String: GroupTiming] = [:]
        for (sample, batch) in zip(progressSamples, batches) {
            let deltaMS = sample.elapsedMS - previousElapsedMS
            previousElapsedMS = sample.elapsedMS
            folderTimings.append(FolderTiming(
                sample: sample, deltaMS: deltaMS, matches: batch.matches.count
            ))
            let components = sample.path.split(separator: "/").prefix(2)
            let group = "/" + components.joined(separator: "/")
            var entry = groups[group, default: GroupTiming()]
            entry.folders += 1
            entry.totalMS += deltaMS
            entry.matches += batch.matches.count
            groups[group] = entry
        }
        if folderTimings.isEmpty {
            print("No folder timings.")
        } else {
            print("Top 20 folder deltas:")
        }
        for timing in folderTimings.sorted(by: {
            if $0.deltaMS != $1.deltaMS { return $0.deltaMS > $1.deltaMS }
            return $0.sample.scannedFolders < $1.sample.scannedFolders
        }).prefix(20) {
            print("\(number(timing.deltaMS))ms  at \(number(timing.sample.elapsedMS))ms  "
                + "+\(timing.matches)  \(oneLine(timing.sample.path))")
        }
        if groups.isEmpty {
            print("No groups.")
        } else {
            print("Groups (share of total wall-clock):")
        }
        let sortedGroups = groups.sorted {
            if $0.value.totalMS != $1.value.totalMS { return $0.value.totalMS > $1.value.totalMS }
            return $0.key < $1.key
        }
        for (group, timing) in sortedGroups.prefix(20) {
            printGroup(group, timing: timing, totalMS: totalMS)
        }
        if sortedGroups.count > 20 {
            var other = GroupTiming()
            for (_, timing) in sortedGroups.dropFirst(20) {
                other.folders += timing.folders
                other.totalMS += timing.totalMS
                other.matches += timing.matches
            }
            printGroup("(other)", timing: other, totalMS: totalMS)
        }
        if !result.failures.isEmpty {
            print("Caveat: failed listings emit no progress callback, so their time lands in the next "
                + "folder's delta and skews attribution; trailing failures remain outside folder deltas.")
        }

        print("\nLISTING PROGRESS")
        let starts = listingSamples.indices.filter { listingSamples[$0].progress.itemCount == nil }
        for (offset, index) in starts.enumerated() {
            let sample = listingSamples[index]
            let nextIndex = offset + 1 < starts.count ? starts[offset + 1] : listingSamples.endIndex
            guard let duration = listingDurations[sample.progress.path], duration >= 250 else { continue }
            print("\(oneLine(sample.progress.path))  listing=\(number(duration))ms")
            for event in listingSamples[index..<nextIndex] {
                let count = event.progress.itemCount.map(String.init) ?? "unknown"
                let fraction = event.progress.fractionCompleted.map(number) ?? "unknown"
                print("\(number(event.elapsedMS))ms  path=\(oneLine(event.progress.path))  "
                    + "itemCount=\(count)  fraction=\(fraction)")
            }
        }

        print("\nMEAN TIME-TO-MATCH")
        var privateCount = 0
        var privateArrivalMS = 0.0
        var visibleCount = 0
        var visibleArrivalMS = 0.0
        for batch in batches {
            for match in batch.matches {
                if let first = match.relativePath.split(separator: "/").first,
                   cohortPrefixes.contains(String(first)) {
                    privateCount += 1
                    privateArrivalMS += batch.elapsedMS
                } else {
                    visibleCount += 1
                    visibleArrivalMS += batch.elapsedMS
                }
            }
        }
        print("App-private prefixes: \(oneLine(cohortPrefixes.sorted().joined(separator: ",")))")
        printMean("app-private", count: privateCount, arrivalMS: privateArrivalMS, totalMS: totalMS)
        printMean("user-visible", count: visibleCount, arrivalMS: visibleArrivalMS, totalMS: totalMS)
        printMean("blended", count: privateCount + visibleCount,
                  arrivalMS: privateArrivalMS + visibleArrivalMS, totalMS: totalMS)
        print("Cohort means separate app-private demotion delays from user-visible arrival times.")

        print("\nRUN DIGEST")
        let sortedIDs = result.matches.map(\.id).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(sortedIDs.utf8))
            .map { String(format: "%02x", $0) }.joined()
        print("scannedFolders=\(result.scannedFolders), failures=\(result.failures.count), "
            + "matches=\(result.matches.count), SHA-256=\(digest)")
        print("The digest is an ORDER-INSENSITIVE SET comparison: equal digests across an A/B pair "
            + "prove both runs found the same set of matches, making the pair comparable.")
        print("Nothing in ScanProbe detects cross-run ORDERING changes; the in-order "
            + "streamed-vs-result check only validates one run's internal consistency.")

        print("\nKEY NUMBERS")
        if let first = nonEmpty.first {
            print("First non-empty batch: \(number(first.elapsedMS))ms")
            let percentage = totalMS > 0 ? number(first.elapsedMS / totalMS * 100) + "%" : "N/A"
            print("First batch / total: \(percentage)")
        } else {
            print("First non-empty batch: N/A; first batch / total: N/A (no matches)")
        }
        let midpoint = result.matches.count / 2 + result.matches.count % 2
        if midpoint > 0, let median = nonEmpty.first(where: { $0.cumulativeCount >= midpoint }) {
            print("50th-percentile match (#\(midpoint), nearest rank): \(number(median.elapsedMS))ms")
        } else {
            print("50th-percentile match: N/A (no corresponding streamed match)")
        }
        print("Total elapsed: \(number(totalMS))ms")

        print("\nVERIFICATION")
        let sequencePassed = batches.flatMap { $0.matches.map(\.id) } == result.matches.map(\.id)
        let countPassed = batches.count == result.scannedFolders
        print("\(sequencePassed ? "PASS" : "FAIL"): streamed IDs equal result.matches IDs in order")
        print("\(countPassed ? "PASS" : "FAIL"): onMatch callbacks (\(batches.count)) "
            + "== scannedFolders (\(result.scannedFolders))")
        var progressivePassed = true
        if nonEmpty.count == 1 {
            print("INCONCLUSIVE: progressive delivery requires at least two non-empty batches; got one")
        } else if let first = nonEmpty.first {
            progressivePassed = first.elapsedMS <= totalMS * 0.9
            print("\(progressivePassed ? "PASS" : "FAIL"): progressive delivery; "
                + "first of \(nonEmpty.count) non-empty batches must arrive by 90% of total elapsed")
        } else {
            print("PASS: progressive delivery threshold not triggered (no non-empty batches)")
        }

        if !result.failures.isEmpty {
            print("\nSCAN FAILURES (showing up to 20 of \(result.failures.count))")
            for failure in result.failures.prefix(20) {
                print("\(oneLine(failure.path)): \(oneLine(failure.message))")
            }
        }
        exit(sequencePassed && countPassed && progressivePassed ? 0 : 1)
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func printGroup(_ group: String, timing: GroupTiming, totalMS: Double) {
        let share = totalMS > 0 ? number(timing.totalMS / totalMS * 100) + "%" : "N/A"
        print("\(oneLine(group))  folders=\(timing.folders)  \(number(timing.totalMS))ms  "
            + "share=\(share)  matches=\(timing.matches)")
    }

    private static func printMean(_ cohort: String, count: Int, arrivalMS: Double, totalMS: Double) {
        guard count > 0 else {
            print("\(cohort): count=0, mean=N/A, normalized AUC=N/A")
            return
        }
        let meanMS = arrivalMS / Double(count)
        let auc = totalMS > 0 ? number(1 - meanMS / totalMS) : "N/A"
        print("\(cohort): count=\(count), mean=\(number(meanMS))ms, normalized AUC=\(auc)")
    }

    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }
}
