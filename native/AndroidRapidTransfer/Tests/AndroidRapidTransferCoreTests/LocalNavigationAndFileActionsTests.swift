import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

@MainActor
final class LocalNavigationAndFileActionsTests: XCTestCase {
    func testDefaultsStartAtHomeUnderTheFilesystemRoot() {
        let model = LocalBrowserViewModel()
        let home = URL.homeDirectory.standardizedFileURL.path

        XCTAssertEqual(model.currentLocation, home)
        XCTAssertTrue(model.canGoUp)
        XCTAssertEqual(model.breadcrumbs.first?.label, "Root")
        XCTAssertEqual(model.breadcrumbs.first?.location, "/")
        XCTAssertEqual(model.breadcrumbs.last?.location, home)
        XCTAssertEqual(
            model.breadcrumbs.map(\.label),
            ["Root"] + home.split(separator: "/").map(String.init)
        )
    }

    func testUpClimbsPastHomeToTheFilesystemRootAndStopsThere() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(startURL: fixture.summer)

        await model.load()
        XCTAssertEqual(model.currentLocation, fixture.summer.path)
        XCTAssertEqual(model.breadcrumbs.last?.label, "Summer")

        let depth = fixture.summer.path.split(separator: "/").count
        for _ in 0..<depth where model.canGoUp {
            await model.goUp()
        }
        XCTAssertEqual(model.currentLocation, "/")
        XCTAssertFalse(model.canGoUp)
        XCTAssertEqual(model.breadcrumbs.map(\.label), ["Root"])

        await model.goUp()
        XCTAssertEqual(model.currentLocation, "/")
    }

    func testStartOutsideTheRootFallsBackToTheRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let confined = LocalBrowserViewModel(rootURL: fixture.root)
        XCTAssertEqual(confined.currentLocation, fixture.root.path)
        XCTAssertFalse(confined.canGoUp)

        let nested = LocalBrowserViewModel(rootURL: fixture.root, startURL: fixture.albums)
        XCTAssertEqual(nested.currentLocation, fixture.albums.path)
        XCTAssertTrue(nested.canGoUp)
        XCTAssertEqual(nested.breadcrumbs.map(\.label), [fixture.root.lastPathComponent, "Albums"])
    }

    func testStandardFavoritesMatchTheClassicDrawer() {
        let favorites = LocalFavorite.standard

        XCTAssertEqual(favorites.map(\.label), ["Home", "Desktop", "Downloads", "Removable Disks", "Root"])
        XCTAssertEqual(
            favorites.map(\.path),
            [
                URL.homeDirectory.standardizedFileURL.path,
                URL.desktopDirectory.standardizedFileURL.path,
                URL.downloadsDirectory.standardizedFileURL.path,
                "/Volumes",
                "/",
            ]
        )
    }

    func testFavoritesNavigateRecordHistoryAndReportTheCurrentOne() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let albums = LocalFavorite(label: "Albums", systemImage: "folder", path: fixture.albums.path)
        let summer = LocalFavorite(label: "Summer", systemImage: "folder", path: fixture.summer.path)
        let model = LocalBrowserViewModel(rootURL: fixture.root, favorites: [albums, summer])
        await model.load()
        XCTAssertFalse(model.isCurrent(albums))

        await model.navigate(to: albums)
        XCTAssertEqual(model.currentLocation, fixture.albums.path)
        XCTAssertTrue(model.isCurrent(albums))
        XCTAssertFalse(model.isCurrent(summer))
        XCTAssertTrue(model.canGoBack)

        await model.navigate(to: summer)
        await model.navigate(to: summer)
        await model.goBack()
        XCTAssertEqual(model.currentLocation, fixture.albums.path)
        await model.goBack()
        XCTAssertEqual(model.currentLocation, fixture.root.path)
        XCTAssertFalse(model.canGoBack)
    }

    func testOpeningAFileHandsItToTheOpenerWithoutNavigating() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let opener = RecordingOpener()
        let model = LocalBrowserViewModel(rootURL: fixture.root, fileOpener: opener)
        await model.load()

        let file = try XCTUnwrap(model.entries.first { $0.name == "notes.txt" })
        model.selectEntry(id: file.id, extending: false, toggling: false)
        await model.openSelection()
        XCTAssertEqual(opener.openedURLs, [fixture.root.appending(path: "notes.txt").standardizedFileURL])
        XCTAssertEqual(model.currentLocation, fixture.root.path)

        let folder = try XCTUnwrap(model.entries.first { $0.name == "Albums" })
        await model.openEntry(folder)
        XCTAssertEqual(model.currentLocation, fixture.albums.path)
        XCTAssertEqual(opener.openedURLs.count, 1)
    }

    func testLocalRevealAndCopyPathsFollowListingOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = LocalBrowserViewModel(rootURL: fixture.root)
        await model.load()
        let ids = Set(model.entries.filter { $0.name == "notes.txt" || $0.name == "Albums" }.map(\.id))
        let expected = model.entries.filter { ids.contains($0.id) }.map(\.location)

        XCTAssertTrue(model.supportsRevealInFinder)
        XCTAssertEqual(expected.count, 2)
        XCTAssertEqual(model.copyablePaths(for: ids), expected)
        XCTAssertEqual(model.revealableURLs(for: ids), expected.map { URL(fileURLWithPath: $0) })
        XCTAssertTrue(model.copyablePaths(for: []).isEmpty)
    }

    func testDevicePaneCopiesDevicePathsAndCannotRevealOrOpenFiles() async throws {
        let model = DeviceBrowserViewModel(provider: Self.makeDeviceProvider())
        await model.load()
        let camera = try XCTUnwrap(model.entries.first { $0.name == "Camera" })
        await model.navigate(to: camera)
        let photo = try XCTUnwrap(model.entries.first { $0.name == "photo.jpg" })

        XCTAssertFalse(model.supportsRevealInFinder)
        XCTAssertTrue(model.revealableURLs(for: [photo.id]).isEmpty)
        XCTAssertEqual(model.copyablePaths(for: [photo.id]), ["/Camera/photo.jpg"])

        await model.openEntry(photo)
        XCTAssertEqual(model.currentLocation, "/Camera")
    }

    private static func makeDeviceProvider() -> MockMTPProvider {
        func entry(_ path: String, folder: Bool, objectID: UInt32) -> WalkEntry {
            let url = URL(fileURLWithPath: path)
            return WalkEntry(
                size: folder ? 0 : 10,
                isFolder: folder,
                modified: wallClockDate("2026-01-01T00:00:00Z"),
                name: url.lastPathComponent,
                path: path,
                parentPath: url.deletingLastPathComponent().path,
                extension: folder ? "" : url.pathExtension,
                parentId: 0,
                objectId: objectID
            )
        }
        return MockMTPProvider(
            deviceInfo: DeviceInfo(model: "Test Phone"),
            storages: [
                StorageInfo(id: 1, storageDescription: "Internal storage", maxCapacity: 8_000_000_000, freeSpaceInBytes: 2_000_000_000)
            ],
            entries: [
                entry("/Camera", folder: true, objectID: 1),
                entry("/Camera/photo.jpg", folder: false, objectID: 2)
            ]
        )
    }
}

@MainActor
private final class RecordingOpener: LocalFileOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

private struct Fixture {
    let root: URL
    let albums: URL
    let summer: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ART-LocalNavigationTests-\(UUID().uuidString)")
            .standardizedFileURL
        albums = root.appending(path: "Albums")
        summer = albums.appending(path: "Summer")
        try FileManager.default.createDirectory(at: summer, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: root.appending(path: "notes.txt"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
