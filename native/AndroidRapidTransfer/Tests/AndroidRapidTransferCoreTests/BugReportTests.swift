import Foundation
import MTPKit
import USBWatcher
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class BugReportTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BugReportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static let completed = DebugToolResult(name: "Test", report: "ok\n", termination: .completed)

    // MARK: - Ordering

    func testDeviceIsReleasedBeforeTheToolRunsAndResumedAfterIt() async throws {
        let log = EventLog()
        let session = RecordingSession(log: log, releaseDelay: .milliseconds(50))
        let tool = RecordingTool(log: log, session: session, result: Self.completed)
        let generator = makeGenerator(session: session, tool: tool, archiver: RecordingArchiver())

        _ = try await generator.generate()

        XCTAssertEqual(
            log.events,
            ["summary", "release-start", "release-end", "tool", "resume(wasActive: true)"]
        )
        XCTAssertEqual(tool.observedReleaseCompleteAtRun, true, "The tool ran before release finished")
        XCTAssertEqual(tool.observedResumedAtRun, false, "The device was resumed before the tool ran")
    }

    func testStagesAreReportedInOrderAroundTheWork() async throws {
        let log = EventLog()
        let session = RecordingSession(log: log)
        let tool = RecordingTool(log: log, session: session, result: Self.completed)
        let generator = makeGenerator(session: session, tool: tool, archiver: RecordingArchiver())

        _ = try await generator.generate { stage in log.events.append("stage(\(stage))") }

        XCTAssertEqual(
            log.events,
            [
                "summary",
                "stage(release)", "release-start", "release-end",
                "stage(diagnose)", "tool", "resume(wasActive: true)",
                "stage(collect)", "stage(archive)"
            ]
        )
        XCTAssertEqual(BugReportStage.allCases, [.release, .diagnose, .collect, .archive])
        XCTAssertTrue(BugReportStage.allCases.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
    }

    func testNoStageIsReportedWhileCopiesBlockTheReport() async {
        let log = EventLog()
        let session = RecordingSession(log: log, hasActiveTransfers: true)
        let tool = RecordingTool(log: log, session: session, result: Self.completed)
        let generator = makeGenerator(session: session, tool: tool, archiver: RecordingArchiver())
        var stages: [BugReportStage] = []

        do {
            _ = try await generator.generate { stages.append($0) }
            XCTFail("Expected transfersInProgress")
        } catch {
            XCTAssertEqual(error as? BugReportError, .transfersInProgress)
        }
        XCTAssertEqual(stages, [])
    }

    func testDeviceIsResumedEvenWhenTheDiagnosticTimesOut() async throws {
        let log = EventLog()
        let session = RecordingSession(log: log)
        let timedOut = DebugToolResult(name: "Test", report: nil, termination: .timedOut(seconds: 60))
        let tool = RecordingTool(log: log, session: session, result: timedOut)
        let archiver = RecordingArchiver()
        let generator = makeGenerator(session: session, tool: tool, archiver: archiver)

        let url = try await generator.generate()

        XCTAssertEqual(log.events.last, "resume(wasActive: true)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let toolText = try XCTUnwrap(archiver.stagedFiles["mtp-diagnostic.txt"])
        XCTAssertTrue(toolText.contains("timed out after 60s and was cancelled"), toolText)
        XCTAssertTrue(toolText.contains("no output"), toolText)
        XCTAssertTrue(
            try XCTUnwrap(archiver.stagedFiles["README.txt"]).contains("did not complete"),
            "README should flag the failed diagnostic"
        )
    }

    func testInactiveSessionIsReportedAsNotToBeResumed() async throws {
        let log = EventLog()
        let session = RecordingSession(log: log, wasActive: false)
        let generator = makeGenerator(
            session: session,
            tool: RecordingTool(log: log, session: session, result: Self.completed),
            archiver: RecordingArchiver()
        )

        _ = try await generator.generate()

        XCTAssertEqual(log.events.last, "resume(wasActive: false)")
    }

    func testActiveTransfersBlockTheReportWithoutReleasingTheDevice() async {
        let log = EventLog()
        let session = RecordingSession(log: log, hasActiveTransfers: true)
        let archiver = RecordingArchiver()
        let generator = makeGenerator(
            session: session,
            tool: RecordingTool(log: log, session: session, result: Self.completed),
            archiver: archiver
        )

        do {
            _ = try await generator.generate()
            XCTFail("Expected transfersInProgress")
        } catch {
            XCTAssertEqual(error as? BugReportError, .transfersInProgress)
        }
        XCTAssertEqual(log.events, [], "Nothing may be released or run while copies are active")
        XCTAssertEqual(archiver.archivedCount, 0)
    }

    // MARK: - Bundle assembly

    func testBundleContainsEveryDocumentedFileWithItsContent() async throws {
        let log = EventLog()
        let session = RecordingSession(log: log, summary: "Model: Test Pixel")
        let completed = DebugToolResult(name: "Test", report: "Model: Test Pixel\n", termination: .completed)
        let archiver = RecordingArchiver()
        let generator = makeGenerator(
            session: session,
            tool: RecordingTool(log: log, session: session, result: completed),
            archiver: archiver,
            diagnostics: BugReportDiagnostics(
                environment: { "macOS: test" },
                appLog: { "log line" },
                settings: { "{\"theme\":\"system\"}" },
                transferHistory: { "No saved batch copies." }
            )
        )

        let url = try await generator.generate()

        XCTAssertEqual(url, temporaryDirectory.appending(path: BugReportGenerator.defaultFileName))
        let expectedNames = Set(generator.contents.map(\.fileName)).union(["README.txt"])
        XCTAssertEqual(Set(archiver.stagedFiles.keys), expectedNames)
        XCTAssertEqual(archiver.stagedDirectoryName, BugReportGenerator.folderName)
        XCTAssertEqual(archiver.stagedFiles["device.txt"], "Model: Test Pixel")
        XCTAssertEqual(archiver.stagedFiles["environment.txt"], "macOS: test")
        XCTAssertEqual(archiver.stagedFiles["app-log.txt"], "log line")
        XCTAssertEqual(archiver.stagedFiles["settings.json"], "{\"theme\":\"system\"}")
        XCTAssertTrue(try XCTUnwrap(archiver.stagedFiles["mtp-diagnostic.txt"]).contains("Outcome: completed"))
        let readme = try XCTUnwrap(archiver.stagedFiles["README.txt"])
        for item in generator.contents {
            XCTAssertTrue(readme.contains(item.fileName), "README omits \(item.fileName)")
        }
        XCTAssertFalse(readme.contains("did not complete"))
    }

    func testIncompleteDiagnosticIsWrittenAndFlagged() async throws {
        let log = EventLog()
        let session = RecordingSession(log: log)
        let diagnosed = DebugToolResult(
            name: SwiftMTPDiagnosticTool.name,
            report: "Model: Test Pixel\nDIAGNOSTIC incomplete: OpenSession failed\n",
            termination: .incomplete
        )
        let archiver = RecordingArchiver()
        let generator = makeGenerator(
            session: session,
            tool: RecordingTool(log: log, session: session, result: diagnosed),
            archiver: archiver
        )

        _ = try await generator.generate()

        XCTAssertEqual(log.events, ["summary", "release-start", "release-end", "tool", "resume(wasActive: true)"])
        let text = try XCTUnwrap(archiver.stagedFiles["mtp-diagnostic.txt"])
        XCTAssertTrue(text.contains("Diagnostic: SwiftMTP"), text)
        XCTAssertTrue(text.contains("Outcome: did not complete"), text)
        XCTAssertTrue(text.contains("OpenSession failed"))
        let readme = try XCTUnwrap(archiver.stagedFiles["README.txt"])
        XCTAssertTrue(readme.contains("- mtp-diagnostic.txt:"), readme)
        XCTAssertTrue(readme.contains("did not complete; see mtp-diagnostic.txt"), readme)
    }

    func testFailingSourceBecomesANoteInsteadOfFailingTheReport() async throws {
        let log = EventLog()
        let session = RecordingSession(log: log)
        let archiver = RecordingArchiver()
        let generator = makeGenerator(
            session: session,
            tool: RecordingTool(log: log, session: session, result: Self.completed),
            archiver: archiver,
            diagnostics: BugReportDiagnostics(
                environment: { "env" },
                appLog: { throw CocoaError(.fileReadNoPermission) },
                settings: { "{}" },
                transferHistory: { "none" }
            )
        )

        _ = try await generator.generate()

        XCTAssertTrue(try XCTUnwrap(archiver.stagedFiles["app-log.txt"]).hasPrefix("Could not collect this section"))
        XCTAssertTrue(try XCTUnwrap(archiver.stagedFiles["mtp-diagnostic.txt"]).contains("Outcome: completed"))
    }

    func testExistingReportIsReplaced() async throws {
        let destination = temporaryDirectory.appending(path: BugReportGenerator.defaultFileName)
        try Data("OLD".utf8).write(to: destination)
        let log = EventLog()
        let session = RecordingSession(log: log)
        let generator = makeGenerator(
            session: session,
            tool: RecordingTool(log: log, session: session, result: Self.completed),
            archiver: RecordingArchiver(payload: "NEW")
        )

        let url = try await generator.generate()

        XCTAssertEqual(url, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "NEW")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertEqual(siblings, [BugReportGenerator.defaultFileName], "Replacement left extra files behind")
    }

    func testFailedArchiveKeepsThePreviousReport() async throws {
        let destination = temporaryDirectory.appending(path: BugReportGenerator.defaultFileName)
        try Data("OLD".utf8).write(to: destination)
        let log = EventLog()
        let session = RecordingSession(log: log)
        let generator = makeGenerator(
            session: session,
            tool: RecordingTool(log: log, session: session, result: Self.completed),
            archiver: RecordingArchiver(failure: CocoaError(.fileWriteOutOfSpace))
        )

        do {
            _ = try await generator.generate()
            XCTFail("Expected couldNotWrite")
        } catch let error as BugReportError {
            guard case .couldNotWrite = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "OLD")
        XCTAssertEqual(log.events.last, "resume(wasActive: true)", "The device must be back even when saving fails")
    }

    func testRealArchiverProducesAZipOfTheFolder() throws {
        let folder = temporaryDirectory.appending(path: BugReportGenerator.folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appending(path: "README.txt"))
        let zip = temporaryDirectory.appending(path: "out.zip")

        try FileCoordinatorArchiver().archive(directory: folder, to: zip)

        let data = try Data(contentsOf: zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "Not a zip local file header")
        // Entry names are stored uncompressed in the local headers.
        XCTAssertNotNil(
            data.range(of: Data("\(BugReportGenerator.folderName)/README.txt".utf8)),
            "The zip should contain the folder and its files"
        )
    }

    // MARK: - Diagnostic result

    func testReportTextDescribesEveryTermination() {
        func text(_ termination: DebugToolResult.Termination) -> String {
            DebugToolResult(name: "T", report: "body\n", termination: termination).reportText
        }
        XCTAssertTrue(text(.completed).contains("Outcome: completed"))
        XCTAssertTrue(text(.incomplete).contains("did not complete"))
        XCTAssertTrue(text(.timedOut(seconds: 60)).contains("timed out after 60s"))
        XCTAssertTrue(text(.completed).contains("body"))
        XCTAssertTrue(DebugToolResult(name: "T", report: nil, termination: .completed).succeeded)
        XCTAssertFalse(DebugToolResult(name: "T", report: "x", termination: .incomplete).succeeded)
    }

    // MARK: - Summaries and links

    func testTransferHistoryKeepsCountsAndErrorsButNotItemPaths() {
        let batch = TransferBatchRecord(
            origin: .copyQueue,
            destinationRoot: "/Users/me/Downloads",
            storageID: 1,
            deviceLabel: "Test Pixel",
            items: [
                .init(devicePath: "/DCIM/secret-a.jpg", displayName: "secret-a.jpg", size: 1,
                      isDirectory: false, destinationDirectory: "/Users/me/Downloads", status: .completed),
                .init(devicePath: "/DCIM/secret-b.jpg", displayName: "secret-b.jpg", size: 1,
                      isDirectory: false, destinationDirectory: "/Users/me/Downloads",
                      status: .failed(message: "ErrorDeviceChanged")),
                .init(devicePath: "/DCIM/secret-c.jpg", displayName: "secret-c.jpg", size: 1,
                      isDirectory: false, destinationDirectory: "/Users/me/Downloads",
                      status: .failed(message: "ErrorDeviceChanged"))
            ]
        )

        let text = BugReportTransferHistory.describe([batch])

        XCTAssertTrue(text.contains("3 items: 1 completed, 0 pending, 2 failed"), text)
        XCTAssertTrue(text.contains("2× ErrorDeviceChanged"), text)
        XCTAssertFalse(text.contains("secret-"), "Item names must not be copied into the report")
        XCTAssertFalse(text.contains("/Users/me"), "Destination paths must not be copied into the report")
    }

    func testDeviceSummaryDescribesConnectedDeviceAndStorages() {
        let text = BugReportDeviceSummary.describe(.connected(
            DeviceInfo(model: "Test Pixel"),
            [StorageInfo(id: 1, storageDescription: "Internal storage")]
        ))

        XCTAssertTrue(text.contains("State: connected"))
        XCTAssertTrue(text.contains("Test Pixel"))
        XCTAssertTrue(text.contains("Internal storage"))
        XCTAssertTrue(BugReportDeviceSummary.describe(.noDevice).contains("no device connected"))
    }

    func testNewIssueURLIsPrefilled() throws {
        let url = BugReportLinks.newIssueURL(appVersion: "0.1.0", macOSVersion: "Version 27.0")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/sameh0/android-rapid-transfer/issues/new")
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("\(AppIdentity.name): 0.1.0"))
        XCTAssertTrue(body.contains("macOS: Version 27.0"))
        XCTAssertTrue(body.contains(BugReportGenerator.defaultFileName))
    }

    // MARK: - Controller release

    func testReleaseDeviceReturnsOnlyAfterTheProviderIsDisposed() async throws {
        let provider = MockMTPProvider(
            deviceInfo: DeviceInfo(model: "Test Pixel"),
            storages: [StorageInfo(id: 1, storageDescription: "Internal storage")]
        )
        let events = AsyncStream<USBDeviceEvent>.makeStream()
        defer { events.continuation.finish() }
        let controller = DeviceConnectionController(
            providerFactory: { provider },
            events: events.stream,
            attachDebounce: .milliseconds(30)
        )
        await controller.start()
        guard case .connected = controller.state else { return XCTFail("Expected a connection") }

        let wasStarted = await controller.releaseDevice()

        XCTAssertTrue(wasStarted)
        XCTAssertEqual(controller.state, .noDevice)
        let calls = await provider.callHistory()
        XCTAssertEqual(calls.last, .dispose, "releaseDevice returned before disposal completed")

        let again = await controller.releaseDevice()
        XCTAssertFalse(again, "A stopped controller must not be reported as needing a restart")
    }

    // MARK: - Helpers

    private func makeGenerator(
        session: RecordingSession,
        tool: RecordingTool,
        archiver: RecordingArchiver,
        diagnostics: BugReportDiagnostics = BugReportDiagnostics(
            environment: { "env" }, appLog: { "log" }, settings: { "{}" }, transferHistory: { "none" }
        )
    ) -> BugReportGenerator {
        BugReportGenerator(
            session: session,
            debugTool: tool,
            diagnostics: diagnostics,
            archiver: archiver,
            outputDirectory: temporaryDirectory,
            now: { Date(timeIntervalSince1970: 0) }
        )
    }
}

// MARK: - Test doubles

@MainActor
private final class EventLog {
    var events: [String] = []
}

@MainActor
private final class RecordingSession: BugReportDeviceSession {
    private let log: EventLog
    private let releaseDelay: Duration?
    private let wasActive: Bool
    private let summary: String
    let hasActiveTransfers: Bool
    private(set) var releaseCompleted = false
    private(set) var resumed = false

    init(
        log: EventLog,
        releaseDelay: Duration? = nil,
        wasActive: Bool = true,
        hasActiveTransfers: Bool = false,
        summary: String = "summary"
    ) {
        self.log = log
        self.releaseDelay = releaseDelay
        self.wasActive = wasActive
        self.hasActiveTransfers = hasActiveTransfers
        self.summary = summary
    }

    func deviceSummary() -> String {
        log.events.append("summary")
        return summary
    }

    func release() async -> Bool {
        log.events.append("release-start")
        if let releaseDelay {
            try? await Task.sleep(for: releaseDelay)
        }
        releaseCompleted = true
        log.events.append("release-end")
        return wasActive
    }

    func resume(wasActive: Bool) async {
        resumed = true
        log.events.append("resume(wasActive: \(wasActive))")
    }
}

@MainActor
private final class RecordingTool: DebugToolRunning {
    private let log: EventLog
    private let session: RecordingSession
    private let result: DebugToolResult
    private(set) var observedReleaseCompleteAtRun: Bool?
    private(set) var observedResumedAtRun: Bool?
    nonisolated let reportItem: BugReportItem

    init(
        log: EventLog,
        session: RecordingSession,
        result: DebugToolResult,
        reportItem: BugReportItem = .deviceDiagnostic
    ) {
        self.log = log
        self.session = session
        self.result = result
        self.reportItem = reportItem
    }

    func run() async -> DebugToolResult {
        observedReleaseCompleteAtRun = session.releaseCompleted
        observedResumedAtRun = session.resumed
        log.events.append("tool")
        return result
    }
}

/// Records what was staged instead of zipping it, then writes a marker file.
private final class RecordingArchiver: BugReportArchiving, @unchecked Sendable {
    private let lock = NSLock()
    private let payload: String
    private let failure: Error?
    private var _stagedFiles: [String: String] = [:]
    private var _stagedDirectoryName: String?
    private var _archivedCount = 0

    init(payload: String = "zip", failure: Error? = nil) {
        self.payload = payload
        self.failure = failure
    }

    var stagedFiles: [String: String] { lock.withLock { _stagedFiles } }
    var stagedDirectoryName: String? { lock.withLock { _stagedDirectoryName } }
    var archivedCount: Int { lock.withLock { _archivedCount } }

    func archive(directory: URL, to destination: URL) throws {
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            files[name] = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        }
        lock.withLock {
            _stagedFiles = files
            _stagedDirectoryName = directory.lastPathComponent
            _archivedCount += 1
        }
        if let failure { throw failure }
        try Data(payload.utf8).write(to: destination)
    }
}
