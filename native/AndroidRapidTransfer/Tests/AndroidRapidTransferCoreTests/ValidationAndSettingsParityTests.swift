import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

/// Name/path validation, "Show directories first", and the per-direction
/// "Display overall progress" (preprocessing) settings.
@MainActor
final class ValidationAndSettingsParityTests: XCTestCase {
    // MARK: - Name validation

    func testNameValidationRejectsEveryForbiddenCharacter() {
        for character in ["\\", "?", "%", "*", ":", "|", "\"", "<", ">"] {
            XCTAssertEqual(
                FileNameValidator.validationMessage(for: "a\(character)b", existingNames: []),
                "The name cannot contain any of these characters: / \\ ? % * : | \" < >",
                "expected \(character) to be rejected"
            )
        }
        // The slash keeps its specific message.
        XCTAssertEqual(
            FileNameValidator.validationMessage(for: "a/b", existingNames: []),
            "The name cannot contain a slash (/)."
        )
        XCTAssertNil(
            FileNameValidator.validationMessage(
                for: "Holiday 2024 (1) - copy.jpg",
                existingNames: ["Holiday.jpg"]
            )
        )
    }

    func testTransferPathValidationRejectsBackslashAndColon() {
        XCTAssertNil(
            TransferPathValidator.validationMessage(
                destinationDirectory: "/DCIM/Camera",
                sources: ["/Users/me/photo.jpg", "/Users/me/Album"]
            )
        )
        XCTAssertEqual(
            TransferPathValidator.validationMessage(
                destinationDirectory: "/DCIM",
                sources: ["/Users/me/12:30.jpg"]
            ),
            TransferPathValidator.invalidPathMessage
        )
        XCTAssertEqual(
            TransferPathValidator.validationMessage(
                destinationDirectory: "/Users/me/back\\slash",
                sources: ["/DCIM/photo.jpg"]
            ),
            TransferPathValidator.invalidPathMessage
        )
        XCTAssertNil(
            TransferPathValidator.validationMessage(destinationDirectory: "/", names: ["photo.jpg"])
        )
    }

    // MARK: - Directories first

    func testSorterGroupsDirectoriesOnlyWhenRequested() {
        let entries = [
            Self.entry("alpha.txt", isDirectory: false),
            Self.entry("Zeta", isDirectory: true),
            Self.entry("beta.txt", isDirectory: false),
        ]
        let descriptor = BrowserSortDescriptor()
        XCTAssertEqual(
            BrowserEntrySorter.sorted(entries, by: descriptor).map(\.name),
            ["Zeta", "alpha.txt", "beta.txt"]
        )
        XCTAssertEqual(
            BrowserEntrySorter.sorted(entries, by: descriptor, directoriesFirst: false).map(\.name),
            ["alpha.txt", "beta.txt", "Zeta"]
        )
        // All-lowercase names so grouped and mixed orders differ regardless of
        // how the comparator orders strings.
        let lowercase = [
            Self.entry("gamma.txt", isDirectory: false),
            Self.entry("beta", isDirectory: true),
            Self.entry("alpha.txt", isDirectory: false),
        ]
        let byName = [KeyPathComparator(\BrowserEntry.name)]
        XCTAssertEqual(
            BrowserEntrySorter.sorted(lowercase, using: byName).map(\.name),
            ["beta", "alpha.txt", "gamma.txt"]
        )
        XCTAssertEqual(
            BrowserEntrySorter.sorted(lowercase, using: byName, directoriesFirst: false).map(\.name),
            ["alpha.txt", "beta", "gamma.txt"]
        )
    }

    func testLocalPaneHonoursDirectoriesFirstAndResortsOnChange() async throws {
        let fixture = try LocalParityFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()
        XCTAssertEqual(model.entries.map(\.name), ["Zeta", "alpha.txt"])

        model.setDirectoriesFirst(false)
        XCTAssertEqual(model.entries.map(\.name), ["alpha.txt", "Zeta"])

        let mixedFromStart = LocalBrowserViewModel(rootURL: fixture.root, directoriesFirst: false)
        await mixedFromStart.load()
        XCTAssertEqual(mixedFromStart.entries.map(\.name), ["alpha.txt", "Zeta"])
    }

    func testDevicePaneHonoursDirectoriesFirstAndResortsOnChange() async throws {
        let model = DeviceBrowserViewModel(provider: Self.deviceProvider())
        await model.load()
        XCTAssertEqual(model.entries.map(\.name), ["Zeta", "alpha.txt"])

        model.setDirectoriesFirst(false)
        XCTAssertEqual(model.entries.map(\.name), ["alpha.txt", "Zeta"])

        let mixedFromStart = DeviceBrowserViewModel(
            provider: Self.deviceProvider(),
            directoriesFirst: false
        )
        await mixedFromStart.load()
        XCTAssertEqual(mixedFromStart.entries.map(\.name), ["alpha.txt", "Zeta"])
    }

    // MARK: - Local collision and illegal-name checks

    func testLocalCollisionCheckSeesHiddenEntries() async throws {
        let fixture = try LocalParityFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()
        XCTAssertFalse(model.entries.contains { $0.name == ".hidden" })

        let didCreate = await model.makeDirectory(named: ".hidden")
        XCTAssertFalse(didCreate)
        XCTAssertEqual(model.error?.message, "An item named “.hidden” already exists.")
    }

    func testLocalOperationsRejectIllegalCharacters() async throws {
        let fixture = try LocalParityFixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()

        let didCreate = await model.makeDirectory(named: "10:30")
        XCTAssertFalse(didCreate)
        XCTAssertTrue(model.error?.message.contains("cannot contain any of these") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "10:30").path))

        model.dismissError()
        model.selectEntry(id: fixture.root.appending(path: "alpha.txt").path, extending: false, toggling: false)
        let didRename = await model.renameSelectedEntry(to: "what?.txt")
        XCTAssertFalse(didRename)
        XCTAssertTrue(model.error?.message.contains("cannot contain any of these") == true)
    }

    // MARK: - Settings

    func testSettingsDefaultToClassicValuesAndRoundTrip() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertTrue(settings.showDirectoriesFirst)
        XCTAssertTrue(settings.preprocessFilesBeforeUpload)
        XCTAssertTrue(settings.preprocessFilesBeforeDownload)

        settings.showDirectoriesFirst = false
        settings.preprocessFilesBeforeUpload = false
        let reloaded = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertFalse(reloaded.showDirectoriesFirst)
        XCTAssertFalse(reloaded.preprocessesFiles(for: .upload))
        XCTAssertTrue(reloaded.preprocessesFiles(for: .download))
    }

    func testNativeSettingsWrittenBeforeTheseKeysDecodeToDefaults() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        try Data(#"{"theme":"dark","deviceFirstLayoutVersion":1}"#.utf8)
            .write(to: fixture.nativeSettings)
        let settings = AppSettings(
            settingsURL: fixture.nativeSettings
        )
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertTrue(settings.showDirectoriesFirst)
        XCTAssertTrue(settings.preprocessFilesBeforeUpload)
        XCTAssertTrue(settings.preprocessFilesBeforeDownload)
    }

    // MARK: - Transfers

    func testTransfersPreprocessPerDirectionSetting() async throws {
        let fixture = try LocalParityFixture()
        defer { fixture.remove() }
        let local = LocalBrowserViewModel(rootURL: fixture.root)
        await local.load()
        let device = DeviceBrowserViewModel(provider: Self.deviceProvider())
        await device.load()
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(
            localModel: local,
            preprocessesFiles: { $0 == .download }
        )
        model.attach(queue: queue, deviceModel: device)

        // Names that exist on neither side, so no conflict prompt is raised.
        let uploadSource = fixture.root.appending(path: "Zeta/upload.txt")
        try Data("u".utf8).write(to: uploadSource)
        let uploadIDs = await model.enqueueDroppedFilesOnDevice([uploadSource])
        let downloadIDs = await model.enqueueDroppedDeviceItems(
            sources: ["/remote.jpg"],
            storageID: 1
        )
        XCTAssertEqual(uploadIDs.count, 1)
        XCTAssertEqual(downloadIDs.count, 1)

        let jobs = await queue.snapshot.jobs
        let upload = try XCTUnwrap(jobs.first { $0.request.direction == .upload })
        let download = try XCTUnwrap(jobs.first { $0.request.direction == .download })
        XCTAssertFalse(upload.request.preprocessFiles)
        XCTAssertTrue(download.request.preprocessFiles)
        model.detach()
    }

    func testTransferWithColonInPathIsRefusedBeforeEnqueue() async throws {
        let fixture = try LocalParityFixture()
        defer { fixture.remove() }
        let local = LocalBrowserViewModel(rootURL: fixture.root)
        await local.load()
        let device = DeviceBrowserViewModel(provider: Self.deviceProvider())
        await device.load()
        let queue = TransferQueue(provider: MockMTPProvider())
        let model = TransferViewModel(localModel: local)
        model.attach(queue: queue, deviceModel: device)

        let ids = await model.enqueueDroppedDeviceItems(sources: ["/10:30.jpg"], storageID: 1)

        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue(model.isShowingOperationError)
        XCTAssertEqual(model.operationErrorMessage, TransferPathValidator.invalidPathMessage)
        let jobs = await queue.snapshot.jobs
        XCTAssertTrue(jobs.isEmpty)
        model.detach()
    }

    // MARK: - Fixtures

    private static func entry(_ name: String, isDirectory: Bool) -> BrowserEntry {
        BrowserEntry(
            id: "/\(name)",
            name: name,
            size: isDirectory ? nil : 1,
            modified: nil,
            isDirectory: isDirectory,
            location: "/\(name)"
        )
    }

    private static func deviceProvider() -> MockMTPProvider {
        MockMTPProvider(
            storages: [
                StorageInfo(id: 1, storageDescription: "Internal storage", maxCapacity: 8_000_000_000, freeSpaceInBytes: 2_000_000_000),
            ],
            entries: [
                walkEntry(path: "/alpha.txt", folder: false, objectID: 1),
                walkEntry(path: "/Zeta", folder: true, objectID: 2),
            ]
        )
    }

    private static func walkEntry(path: String, folder: Bool, objectID: UInt32) -> WalkEntry {
        WalkEntry(
            size: folder ? 0 : 1,
            isFolder: folder,
            modified: wallClockDate("2026-01-01T00:00:00Z"),
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            parentPath: "/",
            extension: folder ? "" : URL(fileURLWithPath: path).pathExtension,
            parentId: 0,
            objectId: objectID
        )
    }
}

private struct LocalParityFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ART-ParityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "Zeta"),
            withIntermediateDirectories: true
        )
        try Data("a".utf8).write(to: root.appending(path: "alpha.txt"))
        try Data("secret".utf8).write(to: root.appending(path: ".hidden"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct SettingsFixture {
    let root: URL
    let nativeSettings: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ART-ParitySettings-\(UUID().uuidString)")
        nativeSettings = root.appending(path: "native/settings.json")
        try FileManager.default.createDirectory(
            at: nativeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
