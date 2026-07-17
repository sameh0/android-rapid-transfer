import Foundation
import MTPKit
import Observation
import XCTest
@testable import AndroidRapidTransferCore

/// Parses a fixture instant. The inputs are literals under test control, so an
/// unparseable string is a bug in the test rather than a runtime condition.
func isoDate(_ iso: String) -> Date {
    guard let date = try? Date(iso, strategy: .iso8601) else {
        preconditionFailure("Invalid fixture date: \(iso)")
    }
    return date
}

@MainActor
final class DateRangeFilterTests: XCTestCase {
    func testBoundsAreInclusiveAtStartAndExclusiveAtEnd() {
        let start = isoDate("2026-07-04T00:00:00Z")
        let end = isoDate("2026-07-11T00:00:00Z")
        let filter = DateRangeFilter(start: start, end: end)

        XCTAssertTrue(filter.matches(start), "A file modified exactly at the start is inside")
        XCTAssertFalse(filter.matches(end), "The upper bound is exclusive")
        XCTAssertTrue(filter.matches(end.addingTimeInterval(-1)))
        XCTAssertFalse(filter.matches(start.addingTimeInterval(-1)))
        XCTAssertFalse(filter.matches(end.addingTimeInterval(1)))
    }

    func testOmittedEndMatchesEverythingAfterStart() {
        let start = isoDate("2026-07-04T00:00:00Z")
        let filter = DateRangeFilter(start: start)

        XCTAssertTrue(filter.matches(start))
        XCTAssertTrue(filter.matches(start.addingTimeInterval(60 * 60 * 24 * 3650)))
        XCTAssertFalse(filter.matches(start.addingTimeInterval(-1)))
    }

    func testCalendarDaysTreatsTheEndDayAsInclusive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let filter = DateRangeFilter.calendarDays(
            from: isoDate("2026-07-04T18:30:00Z"),
            through: isoDate("2026-07-10T06:00:00Z"),
            in: calendar
        )

        XCTAssertEqual(filter.start, isoDate("2026-07-04T00:00:00Z"))
        XCTAssertEqual(filter.end, isoDate("2026-07-11T00:00:00Z"))
        XCTAssertTrue(filter.matches(isoDate("2026-07-04T00:00:00Z")))
        XCTAssertTrue(
            filter.matches(isoDate("2026-07-10T23:59:59Z")),
            "The final day must be fully included"
        )
        XCTAssertFalse(filter.matches(isoDate("2026-07-11T00:00:00Z")))
        XCTAssertFalse(filter.matches(isoDate("2026-07-03T23:59:59Z")))
    }

    func testCalendarDaysWithoutEndRunsUntilNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let filter = DateRangeFilter.calendarDays(
            from: isoDate("2026-07-04T18:30:00Z"),
            in: calendar
        )

        XCTAssertNil(filter.end)
        XCTAssertTrue(filter.matches(isoDate("2030-01-01T00:00:00Z")))
    }

    func testEntriesWithoutAModificationDateNeverMatch() {
        let filter = DateRangeFilter(start: isoDate("2026-07-04T00:00:00Z"))
        let entry = BrowserEntry(
            id: "/DCIM/unknown.jpg",
            name: "unknown.jpg",
            size: 10,
            modified: nil,
            isDirectory: false,
            location: "/DCIM/unknown.jpg"
        )

        XCTAssertFalse(filter.matches(entry))
    }

    func testValidityRejectsAnInvertedRange() {
        let start = isoDate("2026-07-10T00:00:00Z")
        let end = isoDate("2026-07-04T00:00:00Z")

        XCTAssertFalse(DateRangeFilter(start: start, end: end).isValid)
        XCTAssertTrue(DateRangeFilter(start: end, end: start).isValid)
        XCTAssertTrue(DateRangeFilter(start: start).isValid)
    }
}

@MainActor
final class DeviceFolderScannerTests: XCTestCase {
    func testRecursiveScanUsesChildObjectIdsAndPathResolvesRoot() async {
        let child = BrowserEntry(
            id: "/DCIM/Camera",
            name: "Camera",
            size: nil,
            modified: nil,
            isDirectory: true,
            location: "/DCIM/Camera",
            objectId: 41
        )
        let grandchild = BrowserEntry(
            id: "/DCIM/Camera/Raw",
            name: "Raw",
            size: nil,
            modified: nil,
            isDirectory: true,
            location: "/DCIM/Camera/Raw",
            objectId: 42
        )
        var received: [(String, UInt32?)] = []
        let scanner = DeviceFolderScanner { path, objectId in
            received.append((path, objectId))
            return switch path {
            case "/DCIM": [child]
            case "/DCIM/Camera": [grandchild]
            default: []
            }
        }

        _ = await scanner.scan(roots: ["/DCIM"], filter: Self.julyFilter)

        XCTAssertEqual(received.map(\.0), ["/DCIM", "/DCIM/Camera", "/DCIM/Camera/Raw"])
        XCTAssertNil(received[0].1)
        XCTAssertEqual(received[1].1, 41)
        XCTAssertEqual(received[2].1, 42)
    }

    func testRecursiveScanCollectsOnlyMatchingFilesAndPreservesRelativePaths() async {
        let tree = DeviceTreeFixture.standard
        var listed: [String] = []
        let scanner = DeviceFolderScanner { path in
            listed.append(path)
            return tree.entries(in: path)
        }

        let result = await scanner.scan(roots: ["/DCIM"], filter: Self.julyFilter)

        XCTAssertEqual(
            result.matches.map(\.relativePath),
            ["DCIM/root-in-range.jpg", "DCIM/Camera/in-range.jpg", "DCIM/Camera/Raw/deep.dng"],
            "Directories are recursed into but never reported as matches"
        )
        XCTAssertEqual(listed, ["/DCIM", "/DCIM/Camera", "/DCIM/Camera/Raw"])
        XCTAssertEqual(result.scannedFolders, 3)
        XCTAssertFalse(result.isCancelled)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.totalSize, 60)
    }

    func testOnMatchFiresOncePerDirectoryAndBatchesEqualFinalMatchesInOrder() async {
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }
        var batches: [[DateRangeMatch]] = []

        let result = await scanner.scan(
            roots: ["/DCIM"],
            filter: Self.julyFilter,
            onMatch: { batches.append($0) }
        )

        XCTAssertEqual(batches.count, result.scannedFolders)
        XCTAssertEqual(
            batches.map { $0.map(\.relativePath) },
            [
                ["DCIM/root-in-range.jpg"],
                ["DCIM/Camera/in-range.jpg"],
                ["DCIM/Camera/Raw/deep.dng"]
            ]
        )
        XCTAssertEqual(batches.flatMap { $0 }, result.matches)
    }

    func testNilOnMatchMatchesDefaultScanResult() async {
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }

        let defaultResult = await scanner.scan(roots: ["/DCIM"], filter: Self.julyFilter)
        let nilCallbackResult = await scanner.scan(
            roots: ["/DCIM"],
            filter: Self.julyFilter,
            onMatch: nil
        )

        XCTAssertEqual(nilCallbackResult, defaultResult)
    }

    func testNestedMatchesKeepTheRelativeDirectoryUsedForDestinationNesting() async {
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }

        let result = await scanner.scan(roots: ["/DCIM"], filter: Self.julyFilter)

        XCTAssertEqual(
            result.matches.map(\.relativeDirectory),
            ["DCIM", "DCIM/Camera", "DCIM/Camera/Raw"]
        )
    }

    func testMultipleRootsAreScannedIndependently() async {
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }

        let result = await scanner.scan(
            roots: ["/DCIM/Camera", "/Documents"],
            filter: Self.julyFilter
        )

        XCTAssertEqual(
            result.matches.map(\.relativePath),
            ["DCIM/Camera/in-range.jpg", "DCIM/Camera/Raw/deep.dng", "Documents/notes.txt"],
            "Each root contributes paths relative to the storage root"
        )
    }

    func testDifferentSelectedRootsAtSameDepthKeepTheirStorageRootPaths() async {
        let tree = DeviceTreeFixture(foldersByPath: [
            "/A/B/C": [DeviceTreeFixture.file("/A/B/C/x.jpg")],
            "/D/E/F": [DeviceTreeFixture.file("/D/E/F/x.jpg")]
        ])
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }

        let result = await scanner.scan(
            roots: ["/A/B/C", "/D/E/F"],
            filter: Self.julyFilter
        )

        XCTAssertEqual(
            result.matches.map(\.relativePath),
            ["A/B/C/x.jpg", "D/E/F/x.jpg"],
            "Selected roots at the same depth retain their true storage-root locations"
        )
    }

    func testANestedSelectionIsNotScannedTwice() async {
        let tree = DeviceTreeFixture.standard
        var listed: [String] = []
        let scanner = DeviceFolderScanner { path in
            listed.append(path)
            return tree.entries(in: path)
        }

        let result = await scanner.scan(
            roots: ["/DCIM", "/DCIM/Camera"],
            filter: Self.julyFilter
        )

        XCTAssertEqual(listed, ["/DCIM", "/DCIM/Camera", "/DCIM/Camera/Raw"])
        XCTAssertEqual(
            result.matches.map(\.relativePath),
            ["DCIM/root-in-range.jpg", "DCIM/Camera/in-range.jpg", "DCIM/Camera/Raw/deep.dng"],
            "The nested root is dropped so no file is copied under two paths"
        )
    }

    func testListingFailuresAreCollectedWithoutAbortingTheScan() async {
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { path in
            if path == "/DCIM/Camera" {
                throw DeviceBrowserError.operationFailed("Access denied")
            }
            return tree.entries(in: path)
        }

        let result = await scanner.scan(roots: ["/DCIM"], filter: Self.julyFilter)

        XCTAssertEqual(result.failures.map(\.path), ["/DCIM/Camera"])
        XCTAssertEqual(
            result.matches.map(\.relativePath),
            ["DCIM/root-in-range.jpg"],
            "The readable part of the tree still produces matches"
        )
        XCTAssertEqual(result.scannedFolders, 1)
        XCTAssertFalse(result.isCancelled)
        XCTAssertFalse(result.failures[0].message.isEmpty)
    }

    func testCancellationStopsTheWalkAndIsReported() async {
        let tree = DeviceTreeFixture.standard
        let holder = ScanTaskHolder()
        var listed: [String] = []
        let scanner = DeviceFolderScanner { path in
            listed.append(path)
            // Cancel while the first folder is being listed so the walk stops
            // before descending into the subtree it just discovered.
            holder.task?.cancel()
            return tree.entries(in: path)
        }

        let task = Task { await scanner.scan(roots: ["/DCIM"], filter: Self.julyFilter) }
        holder.task = task
        let result = await task.value

        XCTAssertTrue(result.isCancelled)
        XCTAssertEqual(listed, ["/DCIM"], "The scan did not descend after cancellation")
    }

    func testEmptyResultIsReportedCleanly() async {
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }
        let filter = DateRangeFilter(start: isoDate("2030-01-01T00:00:00Z"))

        let result = await scanner.scan(roots: ["/DCIM"], filter: filter)

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.isCancelled)
        XCTAssertEqual(result.scannedFolders, 3, "An empty result still means the tree was walked")
        XCTAssertEqual(result.totalSize, 0)
    }

    func testTopLevelRootsComparesOnPathComponentBoundaries() {
        XCTAssertEqual(
            DeviceFolderScanner.topLevelRoots(["/DCIM", "/DCIM2"]),
            ["/DCIM", "/DCIM2"],
            "A sibling with a shared name prefix is not a descendant"
        )
        XCTAssertEqual(
            DeviceFolderScanner.topLevelRoots(["/DCIM/Camera", "/DCIM"]),
            ["/DCIM"]
        )
        XCTAssertEqual(
            DeviceFolderScanner.topLevelRoots(["/DCIM/", "/DCIM/Camera"]),
            ["/DCIM"],
            "A trailing slash does not hide the ancestor relationship"
        )
    }

    static let julyFilter = DateRangeFilter(
        start: isoDate("2026-07-04T00:00:00Z"),
        end: isoDate("2026-07-11T00:00:00Z")
    )
}

@MainActor
final class ScanExclusionRulesTests: XCTestCase {
    func testNoRulesSkipNothing() {
        let rules = ScanExclusionRules.none

        XCTAssertFalse(rules.shouldSkip(name: ".hidden", isDirectory: false))
        XCTAssertFalse(rules.shouldSkip(name: ".thumbnails", isDirectory: true))
        XCTAssertFalse(rules.shouldSkip(name: "Cache", isDirectory: true))
        XCTAssertFalse(rules.shouldSkip(name: "scratch.tmp", isDirectory: false))
    }

    func testDotRuleSkipsDotPrefixedFilesAndDirectories() {
        let rules = ScanExclusionRules(ignoresDotFiles: true)

        XCTAssertTrue(rules.shouldSkip(name: ".hidden.jpg", isDirectory: false))
        XCTAssertTrue(rules.shouldSkip(name: ".thumbnails", isDirectory: true))
        XCTAssertFalse(rules.shouldSkip(name: "visible.jpg", isDirectory: false))
        XCTAssertFalse(
            rules.shouldSkip(name: "dotted.name.jpg", isDirectory: false),
            "Only a leading dot marks an entry as hidden"
        )
        XCTAssertFalse(
            rules.shouldSkip(name: "Cache", isDirectory: true),
            "The dot rule alone must not touch cache directories"
        )
    }

    func testCacheRuleSkipsNamedDirectoriesCaseInsensitively() {
        let rules = ScanExclusionRules(ignoresCacheFiles: true)

        for name in ["cache", "Cache", "CACHE", ".cache", ".Thumbnails", ".THUMBNAILS", ".trash", ".Trash"] {
            XCTAssertTrue(
                rules.shouldSkip(name: name, isDirectory: true),
                "\(name) is a cache-typical directory"
            )
        }
        XCTAssertFalse(
            rules.shouldSkip(name: "MyCachePhotos", isDirectory: true),
            "The whole name must match — containing \"cache\" is not enough"
        )
        XCTAssertFalse(
            rules.shouldSkip(name: "cache", isDirectory: false),
            "The directory-name set does not apply to files"
        )
    }

    func testCacheRuleSkipsTmpFilesCaseInsensitively() {
        let rules = ScanExclusionRules(ignoresCacheFiles: true)

        XCTAssertTrue(rules.shouldSkip(name: "scratch.tmp", isDirectory: false))
        XCTAssertTrue(rules.shouldSkip(name: "SCRATCH.TMP", isDirectory: false))
        XCTAssertTrue(
            rules.shouldSkip(name: ".tmp", isDirectory: false),
            "A file named exactly .tmp is still a temporary file"
        )
        XCTAssertFalse(rules.shouldSkip(name: "tmp", isDirectory: false))
        XCTAssertFalse(rules.shouldSkip(name: "scratch.tmp2", isDirectory: false))
        XCTAssertFalse(
            rules.shouldSkip(name: "backup.tmp", isDirectory: true),
            "The file-suffix rule does not apply to directories"
        )
    }

    func testIgnoredCntExtensionSkipsMatchingFiles() {
        let rules = ScanExclusionRules(ignoredExtensions: [".cnt"])

        XCTAssertTrue(rules.shouldSkip(name: "metadata.cnt", isDirectory: false))
        XCTAssertFalse(rules.shouldSkip(name: "metadata.txt", isDirectory: false))
    }

    func testIgnoredExtensionsAreMatchedCaseInsensitively() {
        let rules = ScanExclusionRules(ignoredExtensions: [".cnt"])

        XCTAssertTrue(rules.shouldSkip(name: "metadata.CNT", isDirectory: false))
    }

    func testIgnoredExtensionsNeverMatchDirectories() {
        let rules = ScanExclusionRules(ignoredExtensions: [".cnt"])

        XCTAssertFalse(rules.shouldSkip(name: "foo.cnt", isDirectory: true))
    }

    func testEmptyIgnoredExtensionSetSkipsNothing() {
        let rules = ScanExclusionRules(ignoredExtensions: [])

        XCTAssertEqual(rules, .none)
        XCTAssertFalse(rules.shouldSkip(name: "metadata.cnt", isDirectory: false))
        XCTAssertFalse(rules.shouldSkip(name: "foo.cnt", isDirectory: true))
    }
}

@MainActor
final class DeviceFolderScannerExclusionTests: XCTestCase {
    func testDotRuleSkipsDotFilesAndPrunesDotDirectoriesFromTheWalk() async {
        let tree = DeviceTreeFixture.exclusions
        var listed: [String] = []
        let scanner = DeviceFolderScanner { path in
            listed.append(path)
            return tree.entries(in: path)
        }

        let result = await scanner.scan(
            roots: ["/Root"],
            filter: DeviceFolderScannerTests.julyFilter,
            exclusions: ScanExclusionRules(ignoresDotFiles: true)
        )

        XCTAssertEqual(
            listed,
            ["/Root", "/Root/Camera", "/Root/Cache", "/Root/MyCachePhotos"],
            "Dot directories are pruned — their subtrees are never listed"
        )
        XCTAssertEqual(
            result.matches.map(\.relativePath),
            [
                "Root/keep.jpg",
                "Root/scratch.TMP",
                "Root/Camera/photo.jpg",
                "Root/Cache/cached.jpg",
                "Root/MyCachePhotos/vacation.jpg"
            ],
            "Dot files vanish; cache entries survive because that toggle is off"
        )
        XCTAssertFalse(
            result.matches.map(\.relativePath).contains("Root/.hiddenDir/inside.jpg"),
            "A file inside a skipped dot directory is invisible even in the date window"
        )
    }

    func testCacheRulePrunesCacheDirectoriesButKeepsLookalikes() async {
        let tree = DeviceTreeFixture.exclusions
        var listed: [String] = []
        let scanner = DeviceFolderScanner { path in
            listed.append(path)
            return tree.entries(in: path)
        }

        let result = await scanner.scan(
            roots: ["/Root"],
            filter: DeviceFolderScannerTests.julyFilter,
            exclusions: ScanExclusionRules(ignoresCacheFiles: true)
        )

        XCTAssertEqual(
            listed,
            ["/Root", "/Root/Camera", "/Root/.hiddenDir", "/Root/MyCachePhotos"],
            "Cache and .thumbnails are pruned; MyCachePhotos is only a lookalike"
        )
        XCTAssertEqual(
            result.matches.map(\.relativePath),
            [
                "Root/keep.jpg",
                "Root/.hidden.jpg",
                "Root/Camera/photo.jpg",
                "Root/.hiddenDir/inside.jpg",
                "Root/MyCachePhotos/vacation.jpg"
            ],
            "Dot entries survive because that toggle is off; the .TMP file is gone"
        )
    }

    func testBothRulesOffProducesTheSameResultAsAScanWithoutRules() async {
        let tree = DeviceTreeFixture.exclusions
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }

        let withoutArgument = await scanner.scan(
            roots: ["/Root"],
            filter: DeviceFolderScannerTests.julyFilter
        )
        let withDisabledRules = await scanner.scan(
            roots: ["/Root"],
            filter: DeviceFolderScannerTests.julyFilter,
            exclusions: ScanExclusionRules(ignoresDotFiles: false, ignoresCacheFiles: false)
        )

        XCTAssertEqual(withoutArgument, withDisabledRules)
        XCTAssertEqual(
            withoutArgument.matches.count,
            8,
            "The regression guard must compare non-empty results"
        )
        XCTAssertEqual(withoutArgument.scannedFolders, 6)
    }

    func testBothRulesTogetherPruneEveryExcludedEntry() async {
        let tree = DeviceTreeFixture.exclusions
        var listed: [String] = []
        let scanner = DeviceFolderScanner { path in
            listed.append(path)
            return tree.entries(in: path)
        }

        let result = await scanner.scan(
            roots: ["/Root"],
            filter: DeviceFolderScannerTests.julyFilter,
            exclusions: ScanExclusionRules(ignoresDotFiles: true, ignoresCacheFiles: true)
        )

        XCTAssertEqual(listed, ["/Root", "/Root/Camera", "/Root/MyCachePhotos"])
        XCTAssertEqual(
            result.matches.map(\.relativePath),
            ["Root/keep.jpg", "Root/Camera/photo.jpg", "Root/MyCachePhotos/vacation.jpg"]
        )
        XCTAssertEqual(result.scannedFolders, 3)
        XCTAssertEqual(result.totalSize, 60, "Excluded files never reach the matched totals")
    }

    func testAnExcludedFileInsideTheDateWindowStaysExcluded() async {
        let tree = DeviceTreeFixture.exclusions
        let filter = DeviceFolderScannerTests.julyFilter
        let dotFile = tree.entries(in: "/Root").first { $0.name == ".hidden.jpg" }!
        let tmpFile = tree.entries(in: "/Root").first { $0.name == "scratch.TMP" }!
        XCTAssertTrue(filter.matches(dotFile), "The fixture must place the dot file in the window")
        XCTAssertTrue(filter.matches(tmpFile), "The fixture must place the .TMP file in the window")
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }

        let result = await scanner.scan(
            roots: ["/Root"],
            filter: filter,
            exclusions: ScanExclusionRules(ignoresDotFiles: true, ignoresCacheFiles: true)
        )

        let matched = Set(result.matches.map(\.entry.location))
        XCTAssertFalse(matched.contains(dotFile.location))
        XCTAssertFalse(matched.contains(tmpFile.location))
    }

    func testAnInWindowCntFileIsStillExcluded() async {
        let cntFile = DeviceTreeFixture.file("/Root/metadata.CNT")
        let keptFile = DeviceTreeFixture.file("/Root/photo.jpg")
        let tree = DeviceTreeFixture(foldersByPath: ["/Root": [cntFile, keptFile]])
        let filter = DeviceFolderScannerTests.julyFilter
        XCTAssertTrue(filter.matches(cntFile), "The fixture must place the .CNT file in the window")
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }

        let result = await scanner.scan(
            roots: ["/Root"],
            filter: filter,
            exclusions: ScanExclusionRules(ignoredExtensions: [".cnt"])
        )

        XCTAssertEqual(result.matches.map(\.entry.location), [keptFile.location])
    }
}

@MainActor
final class DateRangeCopyPlanTests: XCTestCase {
    func testGroupsCarryObjectIdHints() {
        let entry = BrowserEntry(
            id: "/DCIM/a.jpg",
            name: "a.jpg",
            size: 10,
            modified: isoDate("2026-07-06T12:00:00Z"),
            isDirectory: false,
            location: "/DCIM/a.jpg",
            objectId: 303
        )

        let plan = DateRangeCopyPlan(
            matches: [DateRangeMatch(entry: entry, relativePath: "DCIM/a.jpg")]
        )

        XCTAssertEqual(plan.groups.first?.sourceObjectIds, ["/DCIM/a.jpg": 303])
    }

    func testMatchesAreGroupedByRelativeDirectoryInScanOrder() async {
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }
        let result = await scanner.scan(
            roots: ["/DCIM"],
            filter: DeviceFolderScannerTests.julyFilter
        )

        let plan = DateRangeCopyPlan(matches: result.matches)

        XCTAssertEqual(
            plan.groups.map(\.relativeDirectory),
            ["DCIM", "DCIM/Camera", "DCIM/Camera/Raw"]
        )
        XCTAssertEqual(
            plan.groups.map(\.sources),
            [
                ["/DCIM/root-in-range.jpg"],
                ["/DCIM/Camera/in-range.jpg"],
                ["/DCIM/Camera/Raw/deep.dng"]
            ]
        )
        XCTAssertEqual(plan.fileCount, 3)
        XCTAssertEqual(plan.totalSize, 60)
        XCTAssertFalse(plan.isEmpty)
    }

    func testFilesSharingADirectoryTravelInOneGroup() {
        let matches = [
            DateRangeMatch(
                entry: DeviceTreeFixture.file("/DCIM/Camera/a.jpg", size: 1),
                relativePath: "DCIM/Camera/a.jpg"
            ),
            DateRangeMatch(
                entry: DeviceTreeFixture.file("/DCIM/Camera/b.jpg", size: 2),
                relativePath: "DCIM/Camera/b.jpg"
            )
        ]

        let plan = DateRangeCopyPlan(matches: matches)

        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(
            plan.groups[0].sources,
            ["/DCIM/Camera/a.jpg", "/DCIM/Camera/b.jpg"]
        )
        XCTAssertEqual(plan.totalSize, 3)
    }

    func testAnEmptyMatchListProducesAnEmptyPlan() {
        let plan = DateRangeCopyPlan(matches: [])

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.fileCount, 0)
        XCTAssertEqual(plan.totalSize, 0)
    }
}

@MainActor
final class DateRangeCopyViewModelTests: XCTestCase {
    func testPreviewScanLeavesTheUserInReviewWithoutCopying() async throws {
        let tree = DeviceTreeFixture.standard
        var copiedPlans: [DateRangeCopyPlan] = []
        let model = Self.makeModel(tree: tree) { plan, _ in copiedPlans.append(plan) }

        model.startScan(intent: .preview)
        try await Self.waitForReview(model)

        XCTAssertTrue(copiedPlans.isEmpty, "Preview must not start a transfer")
        XCTAssertEqual(
            model.selectedFileCount,
            4,
            "An open-ended range also picks up the file dated after the fixture window"
        )
        XCTAssertEqual(model.selectedTotalSize, 80)
        XCTAssertTrue(model.canCopySelection)
    }

    func testCopyNowDeliversThePlanAsSoonAsTheScanFinishes() async throws {
        let tree = DeviceTreeFixture.standard
        var copiedPlans: [DateRangeCopyPlan] = []
        var copiedDestinations: [String] = []
        let model = Self.makeModel(tree: tree) { plan, destination in
            copiedPlans.append(plan)
            copiedDestinations.append(destination)
        }
        model.destination = "/tmp/chosen-copy-now"

        model.startScan(intent: .copyNow)
        try await Self.waitForReview(model)

        XCTAssertEqual(copiedPlans.count, 1)
        XCTAssertEqual(copiedPlans[0].fileCount, 4)
        XCTAssertEqual(
            copiedPlans[0].groups.map(\.relativeDirectory),
            ["DCIM", "DCIM/Camera", "DCIM/Camera/Raw"]
        )
        XCTAssertEqual(copiedDestinations, ["/tmp/chosen-copy-now"])
    }

    func testCopyNowWaitsForCompleteResultInsteadOfCopyingStreamedMatches() async throws {
        let gate = MockTransferGate()
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { path in
            if path == "/DCIM/Camera" {
                await gate.wait()
            }
            return tree.entries(in: path)
        }
        var copiedPlans: [DateRangeCopyPlan] = []
        let model = Self.makeModel(scanner: scanner) { plan, _ in copiedPlans.append(plan) }

        model.startScan(intent: .copyNow)
        try await Self.waitForStreamedMatchCount(1, in: model)

        XCTAssertTrue(model.isScanning)
        XCTAssertFalse(model.canCopySelection)
        XCTAssertTrue(copiedPlans.isEmpty, "A streamed partial result must not start a copy")

        await gate.open()
        try await Self.waitForReview(model)

        XCTAssertEqual(copiedPlans.count, 1)
        XCTAssertEqual(copiedPlans[0].fileCount, 4)
        XCTAssertEqual(model.result?.matches.count, 4)
    }

    func testStreamedMatchesAccumulateDuringScanningAndCannotBeCopied() async throws {
        let cameraGate = MockTransferGate()
        let rawGate = MockTransferGate()
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { path in
            if path == "/DCIM/Camera" {
                await cameraGate.wait()
            } else if path == "/DCIM/Camera/Raw" {
                await rawGate.wait()
            }
            return tree.entries(in: path)
        }
        let model = Self.makeModel(scanner: scanner) { _, _ in }
        model.hasEndDate = true

        model.startScan(intent: .preview)
        try await Self.waitForStreamedMatchCount(1, in: model)

        XCTAssertEqual(model.streamedMatches.map(\.relativePath), ["DCIM/root-in-range.jpg"])
        XCTAssertTrue(model.isScanning)
        XCTAssertFalse(model.canCopySelection)

        await cameraGate.open()
        try await Self.waitForStreamedMatchCount(2, in: model)

        XCTAssertEqual(
            model.streamedMatches.map(\.relativePath),
            ["DCIM/root-in-range.jpg", "DCIM/Camera/in-range.jpg"]
        )
        XCTAssertTrue(model.isScanning)
        XCTAssertFalse(model.canCopySelection)

        await rawGate.open()
        try await Self.waitForReview(model)

        XCTAssertEqual(model.streamedMatches, model.result?.matches)
        XCTAssertTrue(model.canCopySelection)
    }

    func testStartScanClearsStreamedMatches() async throws {
        let model = Self.makeModel(tree: .standard) { _, _ in }
        model.startScan(intent: .preview)
        try await Self.waitForReview(model)
        XCTAssertFalse(model.streamedMatches.isEmpty)

        model.startScan(intent: .preview)

        XCTAssertTrue(model.streamedMatches.isEmpty)
        XCTAssertTrue(model.isScanning)
        model.cancelScan()
    }

    func testDeselectedMatchesAreExcludedFromTheCopy() async throws {
        let tree = DeviceTreeFixture.standard
        var copiedPlans: [DateRangeCopyPlan] = []
        var copiedDestinations: [String] = []
        let model = Self.makeModel(tree: tree) { plan, destination in
            copiedPlans.append(plan)
            copiedDestinations.append(destination)
        }

        model.startScan(intent: .preview)
        try await Self.waitForReview(model)
        let excluded = try XCTUnwrap(model.result?.matches.first)
        model.setIncluded(false, for: excluded)
        model.destination = "/tmp/chosen-after-preview"

        XCTAssertFalse(model.isIncluded(excluded))
        XCTAssertEqual(model.selectedFileCount, 3)
        model.copySelection()

        XCTAssertEqual(copiedPlans.count, 1)
        XCTAssertFalse(
            copiedPlans[0].groups.flatMap(\.sources).contains(excluded.entry.location)
        )
        XCTAssertEqual(copiedDestinations, ["/tmp/chosen-after-preview"])
    }

    func testCopyNowWithNoMatchesFallsThroughToTheEmptyReview() async throws {
        let tree = DeviceTreeFixture.standard
        var copiedPlans: [DateRangeCopyPlan] = []
        let model = Self.makeModel(tree: tree, startDate: Self.farFuture) { plan, _ in
            copiedPlans.append(plan)
        }

        model.startScan(intent: .copyNow)
        try await Self.waitForReview(model)

        XCTAssertTrue(copiedPlans.isEmpty, "Nothing to copy must not enqueue an empty transfer")
        XCTAssertEqual(model.result?.isEmpty, true)
        XCTAssertFalse(model.canCopySelection)
    }

    func testCancellingAScanReturnsToTheFormAndDiscardsPartialResults() async throws {
        let gate = MockTransferGate()
        let tree = DeviceTreeFixture.standard
        let scanner = DeviceFolderScanner { path in
            if path == "/DCIM/Camera" {
                await gate.wait()
            }
            return tree.entries(in: path)
        }
        let model = Self.makeModel(scanner: scanner) { _, _ in }

        model.startScan(intent: .preview)
        try await Self.waitForStreamedMatchCount(1, in: model)
        XCTAssertTrue(model.isScanning)
        XCTAssertFalse(model.streamedMatches.isEmpty)
        model.cancelScan()

        XCTAssertEqual(model.phase, .configuring)
        XCTAssertTrue(model.streamedMatches.isEmpty)
        XCTAssertNil(model.result)
        await gate.open()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.phase, .configuring)
        XCTAssertTrue(model.streamedMatches.isEmpty)
    }

    func testEditRangeClearsStreamedMatches() async throws {
        let model = Self.makeModel(tree: .standard) { _, _ in }

        model.startScan(intent: .preview)
        try await Self.waitForReview(model)
        XCTAssertFalse(model.streamedMatches.isEmpty)

        model.editRange()

        XCTAssertEqual(model.phase, .configuring)
        XCTAssertTrue(model.streamedMatches.isEmpty)
    }

    func testTheRangeSpansTheChosenCalendarDaysInclusively() {
        let model = Self.makeModel(tree: DeviceTreeFixture.standard) { _, _ in }
        model.startDate = isoDate("2026-07-04T09:00:00Z")
        model.endDate = isoDate("2026-07-10T09:00:00Z")
        model.hasEndDate = true

        XCTAssertEqual(model.filter.start, isoDate("2026-07-04T00:00:00Z"))
        XCTAssertEqual(model.filter.end, isoDate("2026-07-11T00:00:00Z"))
        XCTAssertTrue(model.canStartScan)

        model.hasEndDate = false
        XCTAssertNil(model.filter.end)
    }

    func testAnInvertedRangeBlocksTheScan() {
        let model = Self.makeModel(tree: DeviceTreeFixture.standard) { _, _ in }
        model.startDate = isoDate("2026-07-10T00:00:00Z")
        model.endDate = isoDate("2026-07-04T00:00:00Z")
        model.hasEndDate = true

        XCTAssertFalse(model.filter.isValid)
        XCTAssertFalse(model.canStartScan)
    }

    func testTheExclusionTogglesReachTheScannerAndShrinkTheSelection() async throws {
        let tree = DeviceTreeFixture.exclusions
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }
        let model = DateRangeCopyViewModel(
            roots: ["/Root"],
            destination: "/tmp",
            scanner: scanner,
            calendar: Self.utcCalendar,
            now: isoDate("2026-07-10T12:00:00Z")
        ) { _, _ in }
        model.startDate = isoDate("2026-07-04T00:00:00Z")
        model.hasEndDate = false
        model.ignoreDotFiles = true
        model.ignoreCacheFiles = true

        XCTAssertEqual(
            model.exclusionRules,
            ScanExclusionRules(
                ignoresDotFiles: true,
                ignoresCacheFiles: true,
                ignoredExtensions: [".cnt"]
            )
        )
        model.startScan(intent: .preview)
        try await Self.waitForReview(model)

        XCTAssertEqual(
            model.result?.matches.map(\.relativePath),
            ["Root/keep.jpg", "Root/Camera/photo.jpg", "Root/MyCachePhotos/vacation.jpg"],
            "The preview counts only what the exclusion rules let through"
        )
    }

    func testCustomExtensionsAreNormalizedAndDuplicatesCollapse() {
        let model = Self.makeModel(tree: .standard) { _, _ in }

        for rawValue in [" CNT", "cnt", ".cnt"] {
            model.customExtensionInput = rawValue
            model.addCustomExtension()
        }

        XCTAssertEqual(model.ignoredExtensions, [".cnt"])
        XCTAssertTrue(model.customExtensions.isEmpty, "The existing .cnt preset is not duplicated")

        for rawValue in [" LOGCAT ", "logcat", "...LOGCAT"] {
            model.customExtensionInput = rawValue
            model.addCustomExtension()
        }

        XCTAssertEqual(model.customExtensions, [".logcat"])
        XCTAssertEqual(model.ignoredExtensions, [".cnt", ".logcat"])
        XCTAssertEqual(DateRangeCopyViewModel.normalizeExtension(" . "), nil)
    }

    static let farFuture = isoDate("2030-01-01T00:00:00Z")

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func makeModel(
        tree: DeviceTreeFixture,
        startDate: Date = isoDate("2026-07-04T00:00:00Z"),
        copy: @escaping (DateRangeCopyPlan, String) -> Void
    ) -> DateRangeCopyViewModel {
        let scanner = DeviceFolderScanner { tree.entries(in: $0) }
        return makeModel(scanner: scanner, startDate: startDate, copy: copy)
    }

    static func makeModel(
        scanner: DeviceFolderScanner,
        startDate: Date = isoDate("2026-07-04T00:00:00Z"),
        copy: @escaping (DateRangeCopyPlan, String) -> Void
    ) -> DateRangeCopyViewModel {
        let model = DateRangeCopyViewModel(
            roots: ["/DCIM"],
            destination: "/tmp/destination",
            scanner: scanner,
            calendar: utcCalendar,
            now: isoDate("2026-07-10T12:00:00Z"),
            copy: copy
        )
        model.startDate = startDate
        model.hasEndDate = false
        return model
    }

    static func waitForStreamedMatchCount(
        _ count: Int,
        in model: DateRangeCopyViewModel,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while model.streamedMatches.count < count {
            guard clock.now < deadline else {
                return XCTFail("The scan did not stream \(count) matches before timing out")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func waitForReview(
        _ model: DateRangeCopyViewModel,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while model.phase != .reviewing {
            guard clock.now < deadline else {
                return XCTFail("The scan did not reach the review phase before timing out")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
final class TransferViewModelDateRangeTests: XCTestCase {
    func testNestedMatchesLandInMirroredDestinationDirectories() async throws {
        let fixture = try DestinationFixture()
        defer { fixture.cleanUp() }
        let provider = MockMTPProvider()
        let queue = TransferQueue(provider: provider)
        let local = DateRangeTestPane(title: "This Mac", currentLocation: fixture.root.path)
        let device = DateRangeTestPane(title: "Phone", currentLocation: "/", selectedStorageID: 7)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let plan = DateRangeCopyPlan(matches: [
            DateRangeMatch(
                entry: DeviceTreeFixture.file("/DCIM/root.jpg", objectId: 501),
                relativePath: "DCIM/root.jpg"
            ),
            DateRangeMatch(
                entry: DeviceTreeFixture.file("/DCIM/Camera/x.jpg", objectId: 502),
                relativePath: "DCIM/Camera/x.jpg"
            ),
            DateRangeMatch(
                entry: DeviceTreeFixture.file("/DCIM/Camera/Raw/y.dng", objectId: 503),
                relativePath: "DCIM/Camera/Raw/y.dng"
            )
        ])

        let ids = await model.enqueueDateRangeCopy(plan)
        XCTAssertEqual(ids.count, 3, "One request per relative directory")

        let snapshot = await queue.snapshot
        XCTAssertEqual(
            snapshot.jobs.map(\.request.destination),
            [
                fixture.root.appending(path: "DCIM").path,
                fixture.root.appending(path: "DCIM/Camera").path,
                fixture.root.appending(path: "DCIM/Camera/Raw").path
            ]
        )
        XCTAssertEqual(
            snapshot.jobs.map(\.request.sources),
            [["/DCIM/root.jpg"], ["/DCIM/Camera/x.jpg"], ["/DCIM/Camera/Raw/y.dng"]]
        )
        XCTAssertEqual(snapshot.jobs.map(\.request.storageId), [7, 7, 7])
        XCTAssertEqual(snapshot.jobs.map(\.request.sourceObjectIds), [
            ["/DCIM/root.jpg": 501],
            ["/DCIM/Camera/x.jpg": 502],
            ["/DCIM/Camera/Raw/y.dng": 503]
        ])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "DCIM/Camera/Raw").path
            ),
            "Nested destinations are created before the engine writes into them"
        )
    }

    func testAnEmptyPlanEnqueuesNothing() async throws {
        let fixture = try DestinationFixture()
        defer { fixture.cleanUp() }
        let queue = TransferQueue(provider: MockMTPProvider())
        let local = DateRangeTestPane(title: "This Mac", currentLocation: fixture.root.path)
        let device = DateRangeTestPane(title: "Phone", currentLocation: "/", selectedStorageID: 7)
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let ids = await model.enqueueDateRangeCopy(DateRangeCopyPlan(matches: []))

        XCTAssertTrue(ids.isEmpty)
        let snapshot = await queue.snapshot
        XCTAssertTrue(snapshot.jobs.isEmpty)
    }
}

// MARK: - Fixtures

/// A fake device tree keyed by directory path, standing in for `provider.walk`.
struct DeviceTreeFixture {
    let foldersByPath: [String: [BrowserEntry]]

    func entries(in path: String) -> [BrowserEntry] {
        foldersByPath[path] ?? []
    }

    static func file(
        _ path: String,
        modified: String = "2026-07-06T12:00:00Z",
        size: Int64 = 20,
        objectId: UInt32? = nil
    ) -> BrowserEntry {
        BrowserEntry(
            id: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            size: size,
            modified: isoDate(modified),
            isDirectory: false,
            location: path,
            objectId: objectId
        )
    }

    static func folder(_ path: String) -> BrowserEntry {
        BrowserEntry(
            id: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            size: nil,
            modified: isoDate("2026-07-06T12:00:00Z"),
            isDirectory: true,
            location: path
        )
    }

    /// Mixed files and folders, three levels deep, with in-range and out-of-range
    /// files at every level plus a sibling root.
    static let standard = DeviceTreeFixture(foldersByPath: [
        "/DCIM": [
            folder("/DCIM/Camera"),
            file("/DCIM/root-in-range.jpg", modified: "2026-07-05T08:00:00Z"),
            file("/DCIM/too-old.jpg", modified: "2026-06-01T08:00:00Z")
        ],
        "/DCIM/Camera": [
            folder("/DCIM/Camera/Raw"),
            file("/DCIM/Camera/in-range.jpg", modified: "2026-07-06T08:00:00Z"),
            file("/DCIM/Camera/too-new.jpg", modified: "2026-08-01T08:00:00Z")
        ],
        "/DCIM/Camera/Raw": [
            file("/DCIM/Camera/Raw/deep.dng", modified: "2026-07-10T23:59:00Z")
        ],
        "/DCIM2": [
            file("/DCIM2/sibling.jpg", modified: "2026-07-06T08:00:00Z")
        ],
        "/Documents": [
            file("/Documents/notes.txt", modified: "2026-07-07T08:00:00Z")
        ]
    ])

    /// Every file sits inside the July window on purpose, so any entry missing
    /// from a result was removed by an exclusion rule rather than by the date
    /// filter. Mixes dot entries, real cache directories, a cache lookalike,
    /// and an uppercase `.TMP` file.
    static let exclusions = DeviceTreeFixture(foldersByPath: [
        "/Root": [
            folder("/Root/Camera"),
            folder("/Root/.hiddenDir"),
            folder("/Root/Cache"),
            folder("/Root/.thumbnails"),
            folder("/Root/MyCachePhotos"),
            file("/Root/keep.jpg"),
            file("/Root/.hidden.jpg"),
            file("/Root/scratch.TMP")
        ],
        "/Root/Camera": [
            file("/Root/Camera/photo.jpg")
        ],
        "/Root/.hiddenDir": [
            file("/Root/.hiddenDir/inside.jpg")
        ],
        "/Root/Cache": [
            file("/Root/Cache/cached.jpg")
        ],
        "/Root/.thumbnails": [
            file("/Root/.thumbnails/thumb.jpg")
        ],
        "/Root/MyCachePhotos": [
            file("/Root/MyCachePhotos/vacation.jpg")
        ]
    ])
}

/// Holds the scan task so the injected lister can cancel the very walk it is
/// serving, which makes mid-scan cancellation deterministic.
@MainActor
final class ScanTaskHolder {
    var task: Task<DateRangeScanResult, Never>?
}

/// A real temporary directory, because ``TransferViewModel`` creates the nested
/// destinations on disk before enqueueing.
struct DestinationFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ART-DateRangeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Observable
final class DateRangeTestPane: DeviceTransferPaneModel {
    let title: String
    var entries: [BrowserEntry] = []
    var breadcrumbs: [BreadcrumbSegment] = []
    var currentLocation: String
    var sortDescriptor = BrowserSortDescriptor()
    var tableSortOrder = [KeyPathComparator(\BrowserEntry.name)]
    var selectedEntryIDs: Set<BrowserEntry.ID> = []
    var viewMode: BrowserViewMode = .list
    var showsHiddenFiles = false
    var capacity: BrowserCapacity?
    var isLoading = false
    var hasLoaded = true
    var error: BrowserPaneError?
    var canGoBack = false
    var canGoUp = false
    var selectedStorageID: UInt32?

    init(title: String, currentLocation: String, selectedStorageID: UInt32? = nil) {
        self.title = title
        self.currentLocation = currentLocation
        self.selectedStorageID = selectedStorageID
    }

    func load() async {}
    func refresh() async {}
    func navigate(to entry: BrowserEntry) async {}
    func navigate(to breadcrumb: BreadcrumbSegment) async {}
    func goBack() async {}
    func goUp() async {}
    func setShowsHiddenFiles(_ showsHiddenFiles: Bool) async {
        self.showsHiddenFiles = showsHiddenFiles
    }

    func selectEntry(id: BrowserEntry.ID, extending: Bool, toggling: Bool) {
        selectedEntryIDs.insert(id)
    }

    func selectAll() { selectedEntryIDs = Set(entries.map(\.id)) }
    func clearSelection() { selectedEntryIDs.removeAll() }
    func moveSelection(by offset: Int, extending: Bool) {}
    func openSelection() async {}
    func toggleSort(_ column: BrowserSortColumn) {}
    func dismissError() { error = nil }
}
