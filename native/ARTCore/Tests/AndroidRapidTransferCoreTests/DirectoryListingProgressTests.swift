import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class DirectoryListingProgressTests: XCTestCase {
    private let filter = DateRangeFilter(start: .distantPast)
    private let progress = WalkProgress(fullPath: "/A", itemCount: 2003, fractionCompleted: 0.25)

    func testListingStartsBeforeEachCallAndPreservesMatchProgressOrder() async {
        var events: [String] = []
        let scanner = DeviceFolderScanner { path, _, report in
            events.append("list \(path)")
            await Task.detached {
                report(WalkProgress(fullPath: path, itemCount: 2, fractionCompleted: 0.5))
            }.value
            await self.drainMainQueue()
            return []
        }
        let result = await scanner.scan(roots: ["/A", "/B"], filter: filter,
            onMatch: { _ in events.append("match") },
            onProgress: { events.append("done \($0.currentPath)") },
            onListing: { events.append("\($0.itemCount == nil ? "start" : "progress") \($0.path)") })
        XCTAssertEqual(result.scannedFolders, 2)
        XCTAssertEqual(events, ["start /A", "list /A", "progress /A", "match", "done /A",
                                "start /B", "list /B", "progress /B", "match", "done /B"])
    }

    func testNilListingKeepsExistingCallbackOrder() async {
        var events: [String] = []
        let scanner = DeviceFolderScanner { path, _ in
            events.append("list \(path)")
            return []
        }
        _ = await scanner.scan(roots: ["/A", "/B"], filter: filter,
            onMatch: { _ in events.append("match") }, onProgress: { _ in events.append("done") })
        XCTAssertEqual(events, ["list /A", "match", "done", "list /B", "match", "done"])
    }

    func testLateProgressAfterCompletionAndFailureIsDroppedIncludingRepeatedPath() async {
        var reporters: [@Sendable (WalkProgress) -> Void] = []
        var listings: [DirectoryListingProgress] = []
        var fail = false
        let scanner = DeviceFolderScanner { _, _, report in
            reporters.append(report)
            if reporters.count > 1 {
                reporters[0](self.progress)
                await self.drainMainQueue()
            }
            if fail { throw ListingFailure.failed }
            return []
        }
        _ = await scanner.scan(roots: ["/A"], filter: filter,
            onProgress: { _ in reporters[0](self.progress) }, onListing: { listings.append($0) })
        fail = true
        let result = await scanner.scan(roots: ["/A"], filter: filter, onListing: { listings.append($0) })
        for report in reporters { report(progress) }
        await drainMainQueue()
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(listings, Array(repeating: DirectoryListingProgress(path: "/A", itemCount: nil,
                                                                         fractionCompleted: nil), count: 2))
    }

    func testCancellationDropsProgressWhileListingIsStillSuspended() async {
        let gate = MockTransferGate()
        var reporter: (@Sendable (WalkProgress) -> Void)?
        var listings: [DirectoryListingProgress] = []
        let started = expectation(description: "Listing started")
        let scanner = DeviceFolderScanner { _, _, report in
            reporter = report
            started.fulfill()
            await gate.wait()
            return []
        }
        let task = Task {
            await scanner.scan(roots: ["/A"], filter: filter, onListing: { listings.append($0) })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        reporter?(progress)
        await drainMainQueue()
        XCTAssertEqual(listings.count, 1)
        await gate.open()
        let result = await task.value
        XCTAssertTrue(result.isCancelled)
        reporter?(progress)
        await drainMainQueue()
        XCTAssertEqual(listings.count, 1)
    }

    func testListingHandlerCanCancelItsOwnScan() async {
        var task: Task<DateRangeScanResult, Never>?
        var listings: [DirectoryListingProgress] = []
        let scanner = DeviceFolderScanner { _, _, report in
            report(self.progress)
            await self.drainMainQueue()
            report(self.progress)
            await self.drainMainQueue()
            return []
        }
        task = Task {
            await scanner.scan(roots: ["/A"], filter: filter, onListing: { listing in
                listings.append(listing)
                if listing.itemCount != nil { task?.cancel() }
            })
        }
        let result = await task!.value
        XCTAssertTrue(result.isCancelled)
        XCTAssertEqual(listings.count, 2)
    }

    func testMonitoringProviderAndBrowserForwardProgress() async throws {
        let base = MockMTPProvider(walkProgress: [progress])
        let provider = ConnectionMonitoringProvider(provider: base, connectionLost: { _ in XCTFail("Unexpected error") })
        let browser = DeviceBrowserViewModel(provider: provider)
        let values = ListingRecorder()
        _ = try await browser.listDirectoryForScan("/A", objectId: 42, storageID: 1) { values.append($0) }
        XCTAssertEqual(values.values, [progress])
        let inputs = await base.walkInputs()
        XCTAssertEqual(inputs.first?.objectId, 42)
        _ = try await browser.listDirectoryForScan("/A", storageID: 1)
        XCTAssertEqual(values.values, [progress])
    }

    func testCurrentListingClearsOnFinishCancelAndEdit() async {
        for action in ["finish", "cancel", "edit"] {
            let gate = MockTransferGate()
            let started = expectation(description: action)
            var reporter: (@Sendable (WalkProgress) -> Void)?
            let scanner = DeviceFolderScanner { _, _, report in
                reporter = report
                report(self.progress)
                await self.drainMainQueue()
                started.fulfill()
                await gate.wait()
                return []
            }
            let model = DateRangeCopyViewModel(roots: ["/A"], destination: "/tmp", scanner: scanner) { _, _ in }
            model.startScan(intent: .preview)
            await fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(model.currentListing, DirectoryListingProgress(path: "/A", itemCount: 2003,
                                                                          fractionCompleted: 0.25))
            if action == "cancel" { model.cancelScan() }
            if action == "edit" { model.editRange() }
            if action != "finish" {
                XCTAssertNil(model.currentListing)
                reporter?(progress)
                await drainMainQueue()
                XCTAssertNil(model.currentListing)
            }
            await gate.open()
            for _ in 0..<100 where model.isScanning { await Task.yield() }
            await drainMainQueue()
            XCTAssertFalse(model.isScanning)
            XCTAssertNil(model.currentListing)
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private enum ListingFailure: Error { case failed }
private final class ListingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WalkProgress] = []
    var values: [WalkProgress] { lock.withLock { events } }
    func append(_ value: WalkProgress) { lock.withLock { events.append(value) } }
}
